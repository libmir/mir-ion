module mir.ion.internal.stage3;

import core.stdc.string: memcpy;
import mir.bitop;
import mir.ion.exception;
import mir.ion.symbol_table;
import mir.ion.tape;
import mir.ion.type_code;
import mir.primitives;
import mir.utility: _expect;
import std.meta: AliasSeq, aliasSeqOf;
import std.traits;

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

IonErrorInfo stage3(size_t nMax, SymbolTable, TapeHolder)(
    ref SymbolTable symbolTable,
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

    ulong[2][k + 2] pairedMaskBuf1 = void;
    ulong[2][k + 2] pairedMaskBuf2 = void;
    align(64) ubyte[64][k + 2] vector = void;

    bool backwardEscapeBit;

    // vector[$ - 1] = ' ';
    // pairedMask1[$ - 1] = [0UL,  0UL];
    // pairedMask2[$ - 1] = [0UL,  ulong.max];


    ubyte[] tape;
    ptrdiff_t currentTapePosition;
    ptrdiff_t index;
    ptrdiff_t n;
    ulong[2]* pairedMask1;
    ulong[2]* pairedMask2;
    const(char)* strPtr;
    const(char)[] key; // Last key, it is the reference to the tape
    size_t location;
    IonErrorCode errorCode;

    version(LDC) pragma(inline, true);

    strPtr = cast(const(char)*)vector.ptr.ptr + 64;
    pairedMask1 = pairedMaskBuf1.ptr + 1;
    pairedMask2 = pairedMaskBuf2.ptr + 1;

    void fetchNext()
    {
        version(LDC) pragma(inline, true);
        tapeHolder.extend(currentTapePosition + extendLength);

        vector[0] = vector[$ - 2];
        pairedMaskBuf1[0] = pairedMaskBuf1[$ - 2];
        pairedMaskBuf2[0] = pairedMaskBuf2[$ - 2];
        index -= n;
        location += n;

        tape = tapeHolder.allData;

        n = min(text.length, nMax);
        size_t spaceStart = n / 64 * 64;
        memcpy(cast(char*)(vector.ptr.ptr + 64), text.ptr, n);
        text = text[n .. text.length];

        if (n)
        {
            memset(vector.ptr.ptr + 64 + n, ' ', 64 - n % 64);
            auto vlen = n / 64 + (n % 64 != 0);
            stage1(vlen, cast(const) vector.ptr + 1, pairedMaskBuf1.ptr + 1, backwardEscapeBit);
            pairedMaskBuf1[vlen + 1] = 0;
            stage2(vlen, cast(const) vector.ptr + 1, pairedMaskBuf2.ptr + 1);
            pairedMaskBuf2[vlen + 1] = 0;
        }
    }

    enum stackLength = 1024;
    size_t currentTapePositionSkip;
    sizediff_t stackPos = stackLength;
    size_t[stackLength] stack = void;

    bool skipSpaces()
    {
        version(LDC) pragma(inline, true);

        assert(index <= n);
        F:
        if (_expect(index < n, true))
        {
        L:
            auto indexG = index >> 6;
            auto indexL = index & 0x3F;
            auto spacesMask = ~pairedMask2[indexG][1] >> indexL;
            if (spacesMask != 0)
            {
                auto oldIndex = index;
                index += cttz(spacesMask);
                return false;
            }
            else
            {
                index = (indexG + 1) << 6;
                goto F;
            }
        }
        else
        if (text.length == 0)
        {
            return true;
        }
        else
        {
            fetchNext;
            goto L;
        }
    }

    int readUnicode()(ref dchar d)
    {
        version(LDC) pragma(inline, true);

        uint e = 0;
        size_t i = 4;
        do
        {
            int c = uniFlags[strPtr[index++]];
            assert(c < 16);
            if (c == -1)
                return -1;
            assert(c >= 0);
            e <<= 4;
            e ^= c;
        }
        while(--i);
        d = e;
        return 0;
    }

    fetchNext;

next: for(;;)
{
    {
        auto seof = skipSpaces;
        if (stackPos == stack.length)
        {
            if (seof)
                goto ret_final;
            else
                goto value_start;
        }
        else
        {
            if (seof)
                goto next_unexpectedEnd;
        }
    }
    assert(stackPos >= 0);
    assert(stackPos < stack.length);
    auto stackValue = stack[stackPos];
    bool isStruct = stackValue & 1;
    const v = strPtr[index++];
    if (v == ',')
    {
        auto seof = skipSpaces;
        if (seof)
            goto value_unexpectedEnd;
        if (isStruct)
            goto key_start;
        else
            goto value_start;
    }
    if (v != (isStruct ? '}' : ']'))
        goto next_unexpectedValue;
    assert(stackPos >= 0);
    assert(stackPos < stack.length);
    stackValue >>= 1;
    auto aCode = isStruct ? IonTypeCode.struct_ : IonTypeCode.list;
    auto aLength = currentTapePosition - (stackValue + ionPutStartLength);
    stackPos++;
    currentTapePosition = stackValue;
    currentTapePosition += ionPutEnd(tape.ptr + currentTapePosition, aCode, aLength);
}

///////////
key_start: {
    if (strPtr[index] != '"')
        goto object_key_start_unexpectedValue;
    assert(strPtr[index] == '"', "Internal Mir Ion logic error. Please report an issue.");
    index++;
    const stringCodeStart = currentTapePosition;
    currentTapePosition += ionPutStartLength;
    for(;;) 
    {
        if (_expect(n - index < 64 && text.length, false))
        {
            fetchNext;
            assert(n - index > 0);
        }
        auto indexG = index >> 6;
        auto indexL = index & 0x3F;
        auto mask = pairedMask1[indexG];
        mask[0] >>= indexL;
        mask[1] >>= indexL;
        auto strMask = mask[0] | mask[1];
        // TODO: memcpy optimisation for DMD
        assert(currentTapePosition + 64 <= tape.length);
        *cast(ubyte[64]*)(tape.ptr + currentTapePosition) = *cast(const ubyte[64]*)(strPtr + index);
        auto value = strMask == 0 ? 64 - indexL : cttz(strMask);
        currentTapePosition += value;
        index += value;
        if (strMask == 0)
            continue;
        {
            assert(strPtr[index] == '"');
            index++;
            auto aLength = currentTapePosition - (stringCodeStart + ionPutStartLength);
            currentTapePosition = stringCodeStart;
            key = cast(const(char)[]) tape[currentTapePosition + ionPutStartLength .. currentTapePosition + ionPutStartLength + aLength];
        }
        static if (__traits(hasMember, SymbolTable, "insert"))
        {
            auto id = symbolTable.insert(key);
        }
        else // mir string table
        {
            uint id;
            if (!symbolTable.get(key, id))
                id = 0;
        }
        // TODO find id using the key
        currentTapePosition += ionPutVarUInt(tape.ptr + currentTapePosition, id);
        {
            if (skipSpaces)
                goto unexpectedEnd;
        }
        if (strPtr[index++] != ':')
            goto object_after_key_is_missing;
        {
            if (skipSpaces)
                goto unexpectedEnd;
        }
        goto value_start;
    }
}

value_start: {
    auto startC = strPtr[index];

    if (startC == '"')
    {
        assert(strPtr[index] == '"', "Internal Mir Ion logic error. Please report an issue.");
        index++;
        const stringCodeStart = currentTapePosition;
        currentTapePosition += ionPutStartLength;
        for(;;) 
        {
            if (_expect(n - index < 64 && text.length, false))
            {
                fetchNext;
                assert(n - index > 0);
            }
            auto indexG = index >> 6;
            auto indexL = index & 0x3F;
            auto mask = pairedMask1[indexG];
            mask[0] >>= indexL;
            mask[1] >>= indexL;
            auto strMask = mask[0] | mask[1];
            // TODO: memcpy optimisation for DMD
            assert(currentTapePosition + 64 <= tape.length);
            *cast(ubyte[64]*)(tape.ptr + currentTapePosition) = *cast(const ubyte[64]*)(strPtr + index);
            auto value = strMask == 0 ? 64 - indexL : cttz(strMask);
            currentTapePosition += value;
            index += value;
            if (strMask == 0)
                continue;
            if (_expect(((mask[1] >> value) & 1) == 0, true)) // no escape value
            {
                assert(strPtr[index] == '"');
                index++;
                auto stringLength = currentTapePosition - (stringCodeStart + ionPutStartLength);
                currentTapePosition = stringCodeStart;
                currentTapePosition += ionPutEnd(tape.ptr + currentTapePosition, IonTypeCode.string, stringLength);
                goto next;
            }
            else
            {
                if (n - index < 64 && text.length)
                    continue;
                --currentTapePosition;
                assert(strPtr[index - 1] == '\\', cast(string)strPtr[index .. index + 1]);
                dchar d = void;
                auto c = strPtr[index];
                index += 1;
                switch(c)
                {
                    case '/' :
                    case '\"':
                    case '\\':
                        d = cast(ubyte) c;
                        goto PutASCII;
                    case 'b' : d = '\b'; goto PutASCII;
                    case 'f' : d = '\f'; goto PutASCII;
                    case 'n' : d = '\n'; goto PutASCII;
                    case 'r' : d = '\r'; goto PutASCII;
                    case 't' : d = '\t'; goto PutASCII;
                    case 'u' :
                        if (auto r = readUnicode(d))
                            goto unexpected_escape_unicode_value; //unexpected \u
                        if (_expect(0xD800 <= d && d <= 0xDFFF, false))
                        {
                            if (d >= 0xDC00)
                                goto invalid_utf_value;
                            if (strPtr[index++] != '\\')
                                goto invalid_utf_value;
                            if (strPtr[index++] != 'u')
                                goto invalid_utf_value;
                            d = (d & 0x3FF) << 10;
                            dchar trailing = void;
                            if (auto r = readUnicode(trailing))
                                goto unexpected_escape_unicode_value; //unexpected \u
                            if (!(0xDC00 <= trailing && trailing <= 0xDFFF))
                                goto invalid_trail_surrogate;
                            {
                                d |= trailing & 0x3FF;
                                d += 0x10000;
                            }
                        }
                        if (d < 0x80)
                        {
                        PutASCII:
                            tape[currentTapePosition] = cast(ubyte) (d);
                            currentTapePosition += 1;
                            continue;
                        }
                        if (d < 0x800)
                        {
                            tape[currentTapePosition + 0] = cast(ubyte) (0xC0 | (d >> 6));
                            tape[currentTapePosition + 1] = cast(ubyte) (0x80 | (d & 0x3F));
                            currentTapePosition += 2;
                            continue;
                        }
                        if (!(d < 0xD800 || (d > 0xDFFF && d <= 0x10FFFF)))
                            goto invalid_trail_surrogate;
                        if (d < 0x10000)
                        {
                            tape[currentTapePosition + 0] = cast(ubyte) (0xE0 | (d >> 12));
                            tape[currentTapePosition + 1] = cast(ubyte) (0x80 | ((d >> 6) & 0x3F));
                            tape[currentTapePosition + 2] = cast(ubyte) (0x80 | (d & 0x3F));
                            currentTapePosition += 3;
                            continue;
                        }
                        //    assert(d < 0x200000);
                        tape[currentTapePosition + 0] = cast(ubyte) (0xF0 | (d >> 18));
                        tape[currentTapePosition + 1] = cast(ubyte) (0x80 | ((d >> 12) & 0x3F));
                        tape[currentTapePosition + 2] = cast(ubyte) (0x80 | ((d >> 6) & 0x3F));
                        tape[currentTapePosition + 3] = cast(ubyte) (0x80 | (d & 0x3F));
                        currentTapePosition += 4;
                        continue;
                    default: goto unexpected_escape_value; // unexpected escape
                }
            }
        }
    }

    if (startC <= '9')
    {
        if (startC == ',')
            goto unexpected_comma;

        if (_expect(n - index < 64 && text.length, false))
        {
            fetchNext;
            assert(n - index > 0);
        }
        auto indexG = index >> 6;
        auto indexL = index & 0x3F;
            auto endMask = (pairedMask2[indexG][0] | pairedMask2[indexG][1]) >> indexL;
        endMask |= indexL != 0 ? (pairedMask2[indexG + 1][0] | pairedMask2[indexG + 1][1]) << (64 - indexL) : 0;
        if (endMask == 0)
            goto integerOverflow;
        auto numberLength = cast(size_t)cttz(endMask);
        auto numberStringView = cast(const(char)[]) (strPtr + index)[0 .. numberLength];
        index += numberLength;

        import mir.bignum.internal.parse: parseJsonNumberImpl;
        auto result = numberStringView.parseJsonNumberImpl;
        if (!result.success)
            goto unexpected_decimal_value;

        if (!result.key) // integer
        {
            currentTapePosition += ionPut(tape.ptr + currentTapePosition, result.coefficient, result.coefficient && result.sign);
            goto next;
        }
        else
        version(MirDecimalJson)
        {
            currentTapePosition += ionPutDecimal(tape.ptr + currentTapePosition, result.sign, result.coefficient, result.exponent);
            goto next;
        }
        else
        {
            import mir.bignum.internal.dec2float: decimalToFloatImpl;
            auto fp = decimalToFloatImpl!double(result.coefficient, result.exponent);
            if (result.sign)
                fp = -fp;
            // sciencific
            currentTapePosition += ionPut(tape.ptr + currentTapePosition, fp);
            goto next;
        }
    }

    if (startC == '{')
    {
        index++;
        if (skipSpaces)
            goto next_unexpectedEnd;
        assert(stackPos <= stack.length);
        if (--stackPos < 0)
            goto stack_overflow;
        stack[stackPos] = (currentTapePosition << 1) | 1;
        currentTapePosition += ionPutStartLength;
        if (strPtr[index] != '}')
            goto key_start;
        currentTapePosition -= ionPutStartLength;
        index++;
        stackPos++;
        tape[currentTapePosition++] = IonTypeCode.struct_ << 4;
        goto next;
    }

    if (startC == '[')
    {
        index++;
        if (skipSpaces)
            goto next_unexpectedEnd;
        assert(stackPos <= stack.length);
        if (--stackPos < 0)
            goto stack_overflow;
        stack[stackPos] = (currentTapePosition << 1);
        currentTapePosition += ionPutStartLength;
        if (strPtr[index] != ']')
            goto value_start;
        currentTapePosition -= ionPutStartLength;
        index++;
        stackPos++;
        tape[currentTapePosition++] = IonTypeCode.list << 4;
        goto next;
    }

    if (_expect(n - index < 64 && text.length, false))
    {
        fetchNext;
        assert(n - index > 0);
    }
    static foreach(name; AliasSeq!("true", "false", "null"))
    {
        if (*cast(ubyte[name.length]*)(strPtr + index) == cast(ubyte[name.length]) name)
        {
            currentTapePosition += ionPut(tape.ptr + currentTapePosition, mixin(name));
            index += name.length;
            goto next;
        }
    }
    goto value_unexpectedStart;
}

ret_final:
    tapeHolder.currentTapePosition = currentTapePosition;
    location += index;
    return typeof(return)(errorCode, location, key);

errorReadingFile:
    errorCode = IonErrorCode.errorReadingFile;
    goto ret_final;
cant_insert_key:
    errorCode = IonErrorCode.symbolTableCantInsertKey;
    goto ret_final;
unexpected_comma:
    errorCode = IonErrorCode.unexpectedComma;
    goto ret_final;
unexpectedEnd:
    errorCode = IonErrorCode.jsonUnexpectedEnd;
    goto ret_final;
unexpectedValue:
    errorCode = IonErrorCode.jsonUnexpectedValue;
    goto ret_final;
integerOverflow:
    errorCode = IonErrorCode.integerOverflow;
    goto ret_final;
unexpected_decimal_value:
    // _lastError = "unexpected decimal value";
    goto unexpectedValue;
unexpected_escape_unicode_value:
    // _lastError = "unexpected escape unicode value";
    goto unexpectedValue;
unexpected_escape_value:
    // _lastError = "unexpected escape value";
    goto unexpectedValue;
object_after_key_is_missing:
    // _lastError = "expected ':' after key";
    goto unexpectedValue;
object_key_start_unexpectedValue:
    // _lastError = "expected '\"' when start parsing object key";
    goto unexpectedValue;
key_is_to_large:
    // _lastError = "key length is limited to 255 characters";
    goto unexpectedValue;
next_unexpectedEnd:
    assert(stackPos >= 0);
    assert(stackPos < stack.length);
    goto unexpectedEnd;
next_unexpectedValue:
    assert(stackPos >= 0);
    assert(stackPos < stack.length);
    goto unexpectedValue;
value_unexpectedStart:
    // _lastError = "unexpected character when start parsing JSON value";
    goto unexpectedEnd;
value_unexpectedEnd:
    // _lastError = "unexpected end when start parsing JSON value";
    goto unexpectedEnd;
number_length_unexpectedValue:
    // _lastError = "number length is limited to 255 characters";
    goto unexpectedValue;
object_first_value_start_unexpectedEnd:
    // _lastError = "unexpected end of input data after '{'";
    goto unexpectedEnd;
array_first_value_start_unexpectedEnd:
    // _lastError = "unexpected end of input data after '['";
    goto unexpectedEnd;
false_unexpectedEnd:
    // _lastError = "unexpected end when parsing 'false'";
    goto unexpectedEnd;
false_unexpectedValue:
    // _lastError = "unexpected character when parsing 'false'";
    goto unexpectedValue;
null_unexpectedEnd:
    // _lastError = "unexpected end when parsing 'null'";
    goto unexpectedEnd;
null_unexpectedValue:
    // _lastError = "unexpected character when parsing 'null'";
    goto unexpectedValue;
true_unexpectedEnd:
    // _lastError = "unexpected end when parsing 'true'";
    goto unexpectedEnd;
true_unexpectedValue:
    // _lastError = "unexpected character when parsing 'true'";
    goto unexpectedValue;
string_unexpectedEnd:
    // _lastError = "unexpected end when parsing string";
    goto unexpectedEnd;
string_unexpectedValue:
    // _lastError = "unexpected character when parsing string";
    goto unexpectedValue;
failed_to_read_after_key:
    // _lastError = "unexpected end after object key";
    goto unexpectedEnd;
unexpected_character_after_key:
    // _lastError = "unexpected character after key";
    goto unexpectedValue;
string_length_is_too_large:
    // _lastError = "string size is limited to 2^32-1";
    goto unexpectedValue;
invalid_trail_surrogate:
    // _lastError = "invalid UTF-16 trail surrogate";
    goto unexpectedValue;
invalid_utf_value:
    // _lastError = "invalid UTF value";
    goto unexpectedValue;
stack_overflow:
    // _lastError = "overflow of internal stack";
    goto unexpectedValue;
}

private __gshared immutable byte[256] uniFlags = [
 //  0  1  2  3  4  5  6  7    8  9  A  B  C  D  E  F
    -1,-1,-1,-1,-1,-1,-1,-1,  -1,-1,-1,-1,-1,-1,-1,-1, // 0
    -1,-1,-1,-1,-1,-1,-1,-1,  -1,-1,-1,-1,-1,-1,-1,-1, // 1
    -1,-1,-1,-1,-1,-1,-1,-1,  -1,-1,-1,-1,-1,-1,-1,-1, // 2
     0, 1, 2, 3, 4, 5, 6, 7,   8, 9,-1,-1,-1,-1,-1,-1, // 3

    -1,10,11,12,13,14,15,-1,  -1,-1,-1,-1,-1,-1,-1,-1, // 4
    -1,-1,-1,-1,-1,-1,-1,-1,  -1,-1,-1,-1,-1,-1,-1,-1, // 5
    -1,10,11,12,13,14,15,-1,  -1,-1,-1,-1,-1,-1,-1,-1, // 6
    -1,-1,-1,-1,-1,-1,-1,-1,  -1,-1,-1,-1,-1,-1,-1,-1, // 7

    -1,-1,-1,-1,-1,-1,-1,-1,  -1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,  -1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,  -1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,  -1,-1,-1,-1,-1,-1,-1,-1,

    -1,-1,-1,-1,-1,-1,-1,-1,  -1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,  -1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,  -1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,  -1,-1,-1,-1,-1,-1,-1,-1,
];

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

        auto errorInfo = stage3!nMax(table, tapeHolder, text);
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
