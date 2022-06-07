///
module mir.ion.thunderbolt;

import mir.ion.type_code;
import mir.ion.value: IonDescriptor;
import core.stdc.string: memmove;

enum ThunderboltStackDepth = 1024;

enum ThunderboltStatus
{
    success,
    stackOverflow,
    invalidInput,
}

static struct ThunderboltStackMember
{
    ubyte* position;
    size_t length;
    size_t annotationsLength;
    // null type code encodes end of the value.
    IonTypeCode type;

@system pure nothrow @nogc:

    this(IonTypeCode type, size_t length, ubyte* currentPosition, size_t annotationsLength = 0)
    {
        this.annotationsLength = annotationsLength;
        this.length = length;
        this.position = currentPosition - length + annotationsLength;
        this.type = type;
    }
}

// pure
ubyte[] thunderbolt(const(ubyte)[] joy)
{
    import mir.exception: MirException;
    auto ion = new ubyte[joy.length + 16];
    if (auto error = thunderbolt(ion.ptr + 16, joy.ptr, joy.length))
        throw new MirException("thunderbolt: ", error);
    return ion[16 .. $];
}

unittest
{
    import mir.test;
    // empty input
    [].thunderbolt.should == [];
    // null
    [0x0F].thunderbolt.should == [0x0F];
    [0x0F].thunderbolt.should == [0x0F];
    [0x1F].thunderbolt.should == [0x1F];
    [0x2F].thunderbolt.should == [0x2F];
    [0x3F].thunderbolt.should == [0x3F];
    [0x4F].thunderbolt.should == [0x4F];
    [0x5F].thunderbolt.should == [0x5F];
    [0x6F].thunderbolt.should == [0x6F];
    [0x7F].thunderbolt.should == [0x7F];
    [0x8F].thunderbolt.should == [0x8F];
    [0x9F].thunderbolt.should == [0x9F];
    [0xAF].thunderbolt.should == [0xAF];
    [0xBF].thunderbolt.should == [0xBF];
    [0xCF].thunderbolt.should == [0xCF];
    [0xDF].thunderbolt.should == [0xDF];
    // zero lengths
    [0x00].thunderbolt.should == [0x00];
    [0x10].thunderbolt.should == [0x10];
    [0x20].thunderbolt.should == [0x20];
    [0x30].thunderbolt.should == [0x30];
    [0x40].thunderbolt.should == [0x40];
    [0x50].thunderbolt.should == [0x50];
    [0x60].thunderbolt.should == [0x60];
    [0x70].thunderbolt.should == [0x70];
    [0x80].thunderbolt.should == [0x80];
    [0x90].thunderbolt.should == [0x90];
    [0xA0].thunderbolt.should == [0xA0];
    [0xB0].thunderbolt.should == [0xB0];
    [0xC0].thunderbolt.should == [0xC0];
    [0xD0].thunderbolt.should == [0xD0];
    // and true
    [0x11].thunderbolt.should == [0x11];

    // nop
    [0x33, 0x01].thunderbolt.should == [0x01, 0x33];
    [0x33, 0x81, 0x0E].thunderbolt.should == [0x0E, 0x81, 0x33];
    [0x33, 0x34, 0x82, 0x0E].thunderbolt.should == [0x0E, 0x82, 0x33, 0x34];
    // int
    [0x03, 0x21].thunderbolt.should == [0x21, 0x03];
    [0x03, 0x95, 0x82, 0x3E].thunderbolt.should == [0x3E, 0x82, 0x03, 0x95];
    /// list
    [0x11, 0xB1].thunderbolt.should == [0xB1, 0x11];
    [0x10, 0x11, 0xB2].thunderbolt.should == [0xB2, 0x10, 0x11];

    [0x11, 0x21, 0x23, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2D, 0x8F, 0xBE].thunderbolt.should ==
    [0xBE, 0x8F, 0x11, 0x2D, 0x21, 0x23, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D];

    // struct
    [0x84, 0x10, 0x85, 0x11, 0x0F, 0xB2, 0xD6].thunderbolt.should ==
    [0xD6, 0x84, 0x10, 0x85, 0xB2, 0x11, 0x0F];

    // annotation
    [0x87, 0x88, 0x84, 0x10, 0x85, 0x11, 0x0F, 0xB2, 0x89, 0x11, 0xD8, 0x82, 0xEB].thunderbolt.should ==
    [0xEB, 0x82, 0x87, 0x88, 0xD8, 0x84, 0x10, 0x85, 0xB2, 0x11, 0x0F, 0x89, 0x11];
}

    import mir.stdio;
    import mir.format;


// pure nothrow @nogc
ThunderboltStatus thunderbolt(
           ubyte* ion,
    const(ubyte)* joy,
           size_t length
)
    in (ion + 16     <= joy  // 16 bytes are enough
     || joy + length <= ion)
{
    ThunderboltStackMember[ThunderboltStackDepth] stack = void;
    size_t stackLength;

    debug auto f = tout;
            debug f.printHexArray!(char, AssumeNothrowFile, ubyte)(joy[0 .. length]);
            debug tout << endl;

    ion += length;
    joy += length;

    auto current = ThunderboltStackMember(IonTypeCode.null_, length, ion);

    for(;;)
    {
        debug tout << joy << current << endl;
        if (current.position < ion)
        {
            auto descriptorByte = *--joy;
            debug tout << descriptorByte.hexAddress << endl;

            auto descriptor = descriptorByte.IonDescriptor;
            if (descriptor.type == IonTypeCode.bool_ || descriptor.L == 0 || descriptor.L == 0xF)
            {
                *--ion = descriptorByte;
                if (current.type == IonTypeCode.struct_)
                    ion.ionPutVarUIntR(joy.parseVarUIntUnsafeR);
                continue;
            }
            if (descriptor.type < IonTypeCode.list)
            {
                if (descriptor.L < 0xE)
                {
                    // (ion - 16)[0 .. 16] = (joy - 16)[0 .. 16];
                    (ion - descriptor.L)[0 .. descriptor.L] = (joy - descriptor.L)[0 .. descriptor.L];
                    ion -= descriptor.L;
                    joy -= descriptor.L;
                    *--ion = descriptorByte;
                    if (current.type == IonTypeCode.struct_)
                        ion.ionPutVarUIntR(joy.parseVarUIntUnsafeR);
                    continue;
                }
                auto currentLength = joy.parseVarUIntUnsafeR;
                debug tout << "scalar length = " << currentLength << endl;
                ion -= currentLength;
                joy -= currentLength;
                memmove(ion, joy, currentLength);
                ion.ionPutVarUIntR(currentLength);
                *--ion = descriptorByte;
                if (current.type == IonTypeCode.struct_)
                    ion.ionPutVarUIntR(joy.parseVarUIntUnsafeR);
                continue;
            }
            stack[stackLength++] = current;
            size_t currentLength = descriptor.L;
            if (descriptor.L == 0xE)
                currentLength = joy.parseVarUIntUnsafeR;
            if (descriptor.type <= IonTypeCode.struct_)
            {
                current = descriptor.type.ThunderboltStackMember(currentLength, ion);
                continue;
            }
            assert(descriptor.type == IonTypeCode.annotations);
            size_t annotationsLength = joy.parseVarUIntUnsafeR;
            current = descriptor.type.ThunderboltStackMember(currentLength, ion, annotationsLength);
            continue;
        }
        if (current.type != IonTypeCode.null_)
        {
            assert(stackLength);
            assert(current.position == ion);
            if (current.type == IonTypeCode.annotations)
            {
                auto targetIon = current.position - current.annotationsLength;
                assert(current.annotationsLength);
                do ion.ionPutVarUIntR(joy.parseVarUIntUnsafeR);
                while(targetIon < ion);
                assert(targetIon == ion);
                ion.ionPutVarUIntR(current.annotationsLength);
            }
            if (current.length < 0xE)
            {
                *--ion = cast(ubyte) ((current.type << 4) | current.length);
                current = stack[--stackLength];
                if (current.type == IonTypeCode.struct_)
                    ion.ionPutVarUIntR(joy.parseVarUIntUnsafeR);
                continue;
            }
            ion.ionPutVarUIntR(current.length);
            *--ion = cast(ubyte) ((current.type << 4) | 0xE);
            current = stack[--stackLength];
            if (current.type == IonTypeCode.struct_)
                ion.ionPutVarUIntR(joy.parseVarUIntUnsafeR);
            continue;
        }
        assert(current.position <= ion);
        assert(current.position >= ion);
        return ThunderboltStatus.success;
    }
}


package size_t parseVarUIntUnsafeR(ref inout(ubyte)* s)
    pure nothrow @nogc
{
    size_t result;
    version (LDC) pragma(inline, true);
    for(;;)
    {
        byte b = *--s;
        result <<= 7;
        result |= b & 0x7F;
        debug tout << "  b " << ubyte(b).hexAddress << " temp var len = " << result << endl;
        if (b < 0)
            return result;
    }
}

private void ionPutVarUIntR(ref ubyte* ptr, size_t value)
    pure nothrow @nogc
{
    do *--ptr = value & 0x7F;
    while (value >>>= 7);
    *ptr |= 0x80;
}
