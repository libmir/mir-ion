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
IonErrorInfo singleThreadJsonImpl(size_t nMax, alias fillBuffer, SymbolTable, TapeHolder)(
    ref SymbolTable table,
    ref TapeHolder tapeHolder,
    )
    if (nMax % 64 == 0 && nMax)
{
    version (LDC) pragma(inline, true);

    import core.stdc.string: memset;
    import mir.ion.internal.stage1;
    import mir.ion.internal.stage2;
    import mir.ion.internal.stage3;
    import mir.utility: _expect;

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

    version(measure)
    {
        import std.datetime.stopwatch;
        StopWatch sw, swt, st1, st2;
        assumePure({swt.start;})();
    }

    stage3!(() @trusted
        {
            version(LDC) pragma(inline, true);
            tapeHolder.extend(stage.currentTapePosition + extendLength);

            version(measure) assumePure({sw.start;})();
            vector[0] = vector[$ - 2];
            pairedMask1[0] = pairedMask1[$ - 2];
            pairedMask2[0] = pairedMask2[$ - 2];
            stage.index -= stage.n;
            stage.location += stage.n;

            stage.tape = tapeHolder.data;
            if (_expect(!fillBuffer(cast(char*)(vector.ptr.ptr + 64), stage.n, stage.eof), false))
                return false;
            if (stage.n)
            {
                memset(vector.ptr.ptr + 64 + stage.n, ' ', 64 - stage.n % 64);
                auto vlen = stage.n / 64 + (stage.n % 64 != 0);
            version(measure) assumePure({st1.start;})();
                stage1(vlen, cast(const) vector.ptr + 1, pairedMask1.ptr + 1, backwardEscapeBit);
            version(measure) assumePure({st1.stop;})();
                pairedMask1[vlen + 1] = 0;
            version(measure) assumePure({st2.start;})();
                stage2(vlen, cast(const) vector.ptr + 1, pairedMask2.ptr + 1);
            version(measure) assumePure({st2.stop;})();
                pairedMask2[vlen + 1] = 0;
            }
            version(measure) assumePure({sw.stop;})();
            return true;
        })(stage, table);
    version(measure)
    {
        import mir.stdio;
                assumePure({swt.stop;})();
        assumePure({
            sw.stop;
            swt.stop;
            writeln(sw.peek * 100 / swt.peek, "% || ",
            st1.peek * 100 / sw.peek, "% || ",
            st2.peek * 100 / sw.peek, "% || ",
            sw.peek, " | ", swt.peek - sw.peek);
        })();
    }
    tapeHolder.currentTapePosition = stage.currentTapePosition;
    stage.location += stage.index;
R:
    return typeof(return)(stage.errorCode, stage.location, stage.key);
}

///
IonErrorInfo singleThreadJsonText(size_t nMax, SymbolTable, TapeHolder)(
    ref SymbolTable table,
    ref TapeHolder tapeHolder,
    scope const(char)[] text,
)
    if (nMax % 64 == 0 && nMax)
{
    version(LDC) pragma(inline, true);

    return singleThreadJsonImpl!(nMax, (scope char* data, ref sizediff_t n, ref bool eof) @trusted
    {
        version (LDC) pragma(inline, true);

        import core.stdc.string: memcpy;
        import mir.utility: min;

        n = min(text.length, nMax);
        size_t spaceStart = n / 64 * 64;
        memcpy(data, text.ptr, n);
        text = text[n .. text.length];
        eof = text.length == 0;
        return true;
    })(table, tapeHolder);
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

        auto errorInfo = singleThreadJsonText!nMax(table, tapeHolder, text);
        if (errorInfo.code)
            throw new SerdeMirException(errorInfo.code.ionErrorMsg, ". location = ", errorInfo.location, ", last input key = ", errorInfo.key);

        return tapeHolder.tapeData.dup;
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
