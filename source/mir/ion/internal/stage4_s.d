module mir.ion.internal.stage4_s;

import mir.ion.exception: IonErrorCode;

///
struct IonErrorInfo
{
    ///
    IonErrorCode code;
    ///
    size_t location;
    /// refers tape or text
    const(char)[] key;
}

// version = measure;

version(measure)
{
    import std.traits;
    auto assumePure(T)(T t)
    if (isFunctionPointer!T || isDelegate!T)
    {
        enum attrs = functionAttributes!T | FunctionAttribute.pure_;
        return cast(SetFunctionAttributes!(T, functionLinkage!T, attrs)) t;
    }
}


///
IonErrorInfo singleThreadJson(size_t nMax, SymbolTable, TapeHolder)(
    ref SymbolTable table,
    ref TapeHolder tapeHolder,
    scope const(char)[] text,
)
    if (nMax % 64 == 0 && nMax)
{
    version (LDC) pragma(inline, true);

    import core.stdc.string: memset, memcpy;
    import mir.ion.internal.stage1;
    import mir.ion.internal.stage2;
    import mir.ion.internal.stage3;
    import mir.utility: _expect, min;

    enum k = nMax / 64;
    enum extendLength = nMax * 4;

    ulong[2][k + 2] pairedMask1 = void;
    ulong[2][k + 2] pairedMask2 = void;
    align(64) ubyte[64][k + 2] vector = void;

    bool backwardEscapeBit;

    // vector[$ - 1] = ' ';
    // pairedMask1[$ - 1] = [0UL,  0UL];
    // pairedMask2[$ - 1] = [0UL,  ulong.max];


    Stage3State stage;

    version(LDC) pragma(inline, true);

    stage.strPtr = cast(const(char)*)vector.ptr.ptr + 64;
    stage.pairedMask1 = pairedMask1.ptr + 1;
    stage.pairedMask2 = pairedMask2.ptr + 1;

    stage3!(() @trusted
        {
            version(LDC) pragma(inline, true);
            tapeHolder.extend(stage.currentTapePosition + extendLength);

            vector[0] = vector[$ - 2];
            pairedMask1[0] = pairedMask1[$ - 2];
            pairedMask2[0] = pairedMask2[$ - 2];
            stage.index -= stage.n;
            stage.location += stage.n;

            stage.tape = tapeHolder.allData;

            stage.n = min(text.length, nMax);
            size_t spaceStart = stage.n / 64 * 64;
            memcpy(cast(char*)(vector.ptr.ptr + 64), text.ptr, stage.n);
            text = text[stage.n .. text.length];
            stage.eof = text.length == 0;

            if (stage.n)
            {
                memset(vector.ptr.ptr + 64 + stage.n, ' ', 64 - stage.n % 64);
                auto vlen = stage.n / 64 + (stage.n % 64 != 0);
                stage1(vlen, cast(const) vector.ptr + 1, pairedMask1.ptr + 1, backwardEscapeBit);
                pairedMask1[vlen + 1] = 0;
                stage2(vlen, cast(const) vector.ptr + 1, pairedMask2.ptr + 1);
                pairedMask2[vlen + 1] = 0;
            }
            return true;
        })(stage, table);
    tapeHolder.currentTapePosition = stage.currentTapePosition;
    stage.location += stage.index;
R:
    return typeof(return)(stage.errorCode, stage.location, stage.key);
}

///
version(mir_ion_test) unittest
{
    static ubyte[] jsonToIonTest(scope const(char)[] text)
    @trusted pure
    {
        import mir.serde: SerdeMirException;
        import mir.ion.exception: ionErrorMsg;
        import mir.ion.internal.data_holder;
        import mir.ion.symbol_table;

        enum nMax = 128u;

        IonSymbolTable!false table = void;
        table.initialize;
        IonTapeHolder!(nMax * 4) tapeHolder = void;
        tapeHolder.initialize;

        auto errorInfo = singleThreadJson!nMax(table, tapeHolder, text);
        if (errorInfo.code)
            throw new SerdeMirException(errorInfo.code.ionErrorMsg, ". location = ", errorInfo.location, ", last input key = ", errorInfo.key);

        return tapeHolder.data.dup;
    }

    import mir.ion.value;
    import mir.ion.type_code;

    assert(jsonToIonTest("1 2 3") == [0x21, 1, 0x21, 2, 0x21, 3]);
    assert(IonValue(jsonToIonTest("12345")).describe.get!IonUInt.get!ulong == 12345);
    assert(IonValue(jsonToIonTest("-12345")).describe.get!IonNInt.get!long == -12345);
    // assert(IonValue(jsonToIonTest("-12.345")).describe.get!IonDecimal.get!double == -12.345);
    version (MirDecimalJson)
    {
        assert(IonValue(jsonToIonTest("\t \r\n-12345e-3 \t\r\n")).describe.get!IonDecimal.get!double == -12.345);
        assert(IonValue(jsonToIonTest(" -12345e-3 ")).describe.get!IonDecimal.get!double == -12.345);
    }
    else
    {
        assert(IonValue(jsonToIonTest("\t \r\n-12345e-3 \t\r\n")).describe.get!IonFloat.get!double == -12.345);
        assert(IonValue(jsonToIonTest(" -12345e-3 ")).describe.get!IonFloat.get!double == -12.345);
    }
    assert(IonValue(jsonToIonTest("   null")).describe.get!IonNull == IonNull(IonTypeCode.null_));
    assert(IonValue(jsonToIonTest("true ")).describe.get!bool == true);
    assert(IonValue(jsonToIonTest("  false")).describe.get!bool == false);
    assert(IonValue(jsonToIonTest(` "string"`)).describe.get!(const(char)[]) == "string");

    enum str = "iwfpwqocbpwoewouivhqpeobvnqeon wlekdnfw;lefqoeifhq[woifhdq[owifhq[owiehfq[woiehf[  oiehwfoqwewefiqweopurefhqweoifhqweofihqeporifhq3eufh38hfoidf";
    auto data = jsonToIonTest(`"` ~ str ~ `"`);
    assert(IonValue(jsonToIonTest(`"` ~ str ~ `"`)).describe.get!(const(char)[]) == str);

    assert(IonValue(jsonToIonTest(`"hey \uD801\uDC37tee"`)).describe.get!(const(char)[]) == "hey 𐐷tee");
    assert(IonValue(jsonToIonTest(`[]`)).describe.get!IonList.data.length == 0);
    assert(IonValue(jsonToIonTest(`{}`)).describe.get!IonStruct.data.length == 0);

    // assert(jsonToIonTest(" [ {}, true , \t\r\nfalse, null, \"string\", 12.3 ]") ==
        // cast(ubyte[])"\xbe\x8e\xd0\x11\x10\x0f\x86\x73\x74\x72\x69\x6e\x67\x52\xc1\x7b");

    data = jsonToIonTest(` { "a": "b",  "key": ["array", {"a": "c" } ] } `);
    assert(data == cast(ubyte[])"\xde\x8f\x8a\x81b\x8b\xba\x85array\xd3\x8a\x81c");

    data = jsonToIonTest(
    `{
        "tags":[
            "russian",
            "novel",
            "19th century"
        ]
    }`);

}
