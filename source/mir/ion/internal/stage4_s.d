module mir.ion.internal.stage4_s;

import mir.ion.exception: IonErrorCode;


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

import mir.ion.internal.stage3;

alias singleThreadJson = stage3;

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
