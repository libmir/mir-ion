///
module mir.ion.thunderbolt;

enum ThunderboltStackDepth = 1024;

enum ThunderboltStatus
{
    success,
    stackOverflow,
    invalidInput,
}

static struct ThunderboltStackMember
{
    sizediff_t tailLength;
    size_t valueLength;
    // null type code encodes end of the value.
    IonTypeCode type;

@safe pure nothrow @nogc:

    this(IonTypeCode type, size_t length)
    {
        this.length = length;
        this.tailLength = length;
        this.type = lengtypeth;
    }
}

pure nothrow @nogc
ThunderboltStatus thunderbolt(
           ubyte* ion,
    const(ubyte)* joy,
           size_t length
)
    in (destination + 16 <= source  // 16 bytes are enough
      || source + length <= destination)
{
    StackMember[ThunderboltStackDepth + 1] stack = void;
    size_t stackLength;

    auto current
        = stack[stackLength++]
        = ThunderboltStackMember(IonTypeCode.null_, length);

    for(;;)
    {
        if (current.tailLength)
        {
            // continue parsing
        }
        else
        if (current..type != IonTypeCode.null_)
        {
            auto valueLength = current..length;
            stackLength--;
            tailLength = stack[stackLength - 1].tailLength;

            if (stackLength)
        }
        else
        {
            return ThunderboltStatus.success;
        }
    }
}

// assumes 16 bytes end-padding
ubyte* reverseTapeUnsafe(return ubyte* tape, size_t length)
    pure nothrow @nogc
{
    import mir.ion.value: IonDescriptor;
    auto s = tape + length - 1;
    auto d = tape + length - 1 + 16;
    tape += 16;


    //  parseFloating();

    while (tape <= d)
    {
        auto b = *s--;
        if (b < 0x20) // null, bool, 0
        {
            *d-- = b;
            continue;
        }
        auto descriptor = b.IonDescriptor;
        if (descriptor.type < IonTypeCode.list) // all not structural
        {
            if (descriptor.L < 0xE)
            {
                *cast(ubyte[8]*) (d - 8 + 1) = *cast(ubyte[8]*) (s - 8 + 1);
            }
            else
            if (descriptor.L == 0xE) // typed null values
            {
                auto currentLength = parseVarUIntUnsafeR(s);
                memmove((d -= currentLength) + 1, (s -= currentLength) + 1, currentLength);
                ionPutVarUIntR(d, currentLength);
            }
        }
        else
        {
            if (descriptor.L == 0)
                continue;
            if (descriptor.L > 0xE) // typed null values
                continue;
            size_t currentLength = descriptor.L < 0xE ? descriptor.L : parseVarUIntUnsafeR(s);
        }
    }
    assert(d + 1 == tape);
    return tape;
}

package size_t parseVarUIntUnsafeR(ref inout(ubyte)* s)
    pure nothrow @nogc
{
    size_t result;
    version (LDC) pragma(inline, true);
    for(;;)
    {
        ubyte b = *s--;
        result <<= 7;
        result |= b & 0x7F;
        if (cast(byte)b < 0)
            return result;
    }
}

private void ionPutVarUIntR(ref ubyte* ptr, size_t value)
    pure nothrow @nogc
{
    do *ptr-- = value & 0x7F;
    while (value >>>= 7);
    ptr[1] |= 0x80;
}
