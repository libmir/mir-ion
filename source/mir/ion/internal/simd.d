module mir.ion.internal.simd;

version (LDC) import ldc.llvmasm;

version (ARM)
    version = ARM_Any;

version (AArch64)
    version = ARM_Any;

version (X86)
    version = X86_Any;

version (X86_64)
    version = X86_Any;

@safe pure nothrow @nogc:

// uint _mm_movemask_aarch64(__vector(ubyte[16]) input)
// {
//     __vector(ubyte[16]) = [-7,-6,-5,-4,-3,-2,-1,0,-7,-6,-5,-4,-3,-2,-1,0];
//     __vector(ubyte[16]) vshift = vld1q_u8(ucShift);
//     __vector(ubyte[16]) vmask = vandq_u8(input, vdupq_n_u8(0x80));
//     uint ret;
//     vmask = vshlq_u8(vmask, vshift);
//     ret = vaddv_u8(vget_low_u8(vmask));
//     ret += (vaddv_u8(vget_high_u8(vmask)) << 8);
//     return ret;
// }


version (X86_Any)
{
    version (LDC)
    {
        public import mir.llvmint:
            ssse3_pshuf_b_128,
            avx2_pshuf_b,
            avx512_pshuf_b_512;
    }

    version (GDC)
    {
        public import gcc.builtins:
            ssse3_pshuf_b_128 = __builtin_ia32_pshufb,
            avx2_pshuf_b = __builtin_ia32_pshufb256,
            avx512_pshuf_b_512 = __builtin_ia32_pshufb512;
    }
}

version (ARM_Any)
{
    version (LDC)
    {
        import ldc.simd: equalMask;
        alias __builtin_vceqq_u8 = equalMask!(__vector(ubyte[16]));
    }

    version (GDC)
    {
        public import gcc.builtins: __builtin_vceqq_u8;
    }
}

version (AArch64)
{
    version (LDC)
    {
        public import mir.llvmint:
            neon_addp_v16i8,
            neon_tbl2_v16i8,
            neon_tbl1_v16i8,
            neon_tbx2_v16i8,
            neon_tbx1_v16i8;
    }

    version (GNU)
    {
        public import gcc.builtins: neon_addp_v16i8 = __builtin_vpadd_u32;
    }
}

version (ARM)
{
    version (LDC)
    {
        public import gcc.builtins:
            neon_vpaddlu_v8i16_v16i8,
            neon_vpaddlu_v4i32_v8i16,
            neon_vpaddlu_v2i64_v4i32;

        // vld1q
        // vandq
        // vdupq_n
        // vshlq
        // vaddv
        // vget_low
        // vget_high
    }

    version (GNU)
    {
        public import gcc.builtins:
            neon_vpaddlu_v8i16_v16i8 = __builtin_vpaddlq_u8,
            neon_vpaddlu_v4i32_v8i16 = __builtin_vpaddlq_u16,
            neon_vpaddlu_v2i64_v4i32 = __builtin_vpaddlq_u32;
    }
}


private template isFloatingPoint(T)
{
    enum isFloatingPoint =
        is(T == float) ||
        is(T == double) ||
        is(T == real);
}

private template isIntegral(T)
{
    enum isIntegral =
        is(T == byte) ||
        is(T == ubyte) ||
        is(T == short) ||
        is(T == ushort) ||
        is(T == int) ||
        is(T == uint) ||
        is(T == long) ||
        is(T == ulong);
}

private template isSigned(T)
{
    enum isSigned =
        is(T == byte) ||
        is(T == short) ||
        is(T == int) ||
        is(T == long);
}

private template IntOf(T)
if(isIntegral!T || isFloatingPoint!T)
{
    enum n = T.sizeof;
    static if(n == 1)
        alias byte IntOf;
    else static if(n == 2)
        alias short IntOf;
    else static if(n == 4)
        alias int IntOf;
    else static if(n == 8)
        alias long IntOf;
    else
        static assert(0, "Type not supported");
}

private template BaseType(V)
{
    alias typeof(V.array[0]) BaseType;
}

private template numElements(V)
{
    enum numElements = V.sizeof / BaseType!(V).sizeof;
}

private template llvmType(T)
{
    static if(is(T == float))
        enum llvmType = "float";
    else static if(is(T == double))
        enum llvmType = "double";
    else static if(is(T == byte) || is(T == ubyte) || is(T == void))
        enum llvmType = "i8";
    else static if(is(T == short) || is(T == ushort))
        enum llvmType = "i16";
    else static if(is(T == int) || is(T == uint))
        enum llvmType = "i32";
    else static if(is(T == long) || is(T == ulong))
        enum llvmType = "i64";
    else
        static assert(0,
            "Can't determine llvm type for D type " ~ T.stringof);
}

private template llvmVecType(V)
{
    static if(is(V == __vector(void[16])))
        enum llvmVecType =  "<16 x i8>";
    else static if(is(V == __vector(void[32])))
        enum llvmVecType =  "<32 x i8>";
    else
    {
        alias BaseType!V T;
        enum int n = numElements!V;
        enum llvmT = llvmType!T;
        enum llvmVecType = "<"~n.stringof~" x "~llvmT~">";
    }
}

enum Cond{ eq, ne, gt, ge }

template cmpMaskB(Cond cond)
{
    template cmpMaskB(V)
    if(is(IntOf!(BaseType!V)))
    {
        alias BaseType!V T;
        enum llvmT = llvmType!T;

        alias IntOf!T Relem;

        enum int n = numElements!V;

        static if (n <= 8)
            alias R = ubyte;
        else static if (n <= 16)
            alias R = ushort;
        else static if (n <= 32)
            alias R = uint;
        else static if (n <= 64)
            alias R = ulong;
        else static assert(0);

        enum int rN = R.sizeof * 8;

        enum llvmV = llvmVecType!V;
        enum sign =
            (cond == Cond.eq || cond == Cond.ne) ? "" :
            isSigned!T ? "s" : "u";
        enum condStr =
            cond == Cond.eq ? "eq" :
            cond == Cond.ne ? "ne" :
            cond == Cond.ge ? "ge" : "gt";
        enum op =
            isFloatingPoint!T ? "fcmp o"~condStr : "icmp "~sign~condStr;

        enum ir = `
            %cmp = `~op~` `~llvmV~` %0, %1
            %bc = bitcast <`~n.stringof~` x i1> %cmp to i`~rN.stringof~`
            ret i`~rN.stringof~` %bc`;
        alias __ir_pure!(ir, R, V, V) cmpMaskB;
    }
}

alias cmpMaskB!(Cond.eq) equalMaskB;
alias cmpMaskB!(Cond.ne) notEqualMaskB; /// Ditto
alias cmpMaskB!(Cond.gt) greaterMaskB; /// Ditto
alias cmpMaskB!(Cond.ge) greaterOrEqualMaskB; /// Ditto

version (LDC)
version(mir_ion_test) unittest
{
    __vector(ubyte[8]) vec;
    __vector(ubyte[8]) vec23 = 23;
    vec.array[4] = 23;
    auto b = equalMaskB!(__vector(ubyte[8]))(vec, vec23);
    assert(b == 16);
}
