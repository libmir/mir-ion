/++
$(H4 High level JSON serialization API)

Macros:
IONREF = $(REF_ALTTEXT $(TT $2), $2, mir, ion, $1)$(NBSP)
+/
module mir.ser.json;

public import mir.serde;
import mir.ion.exception: IonException;

version(D_Exceptions) private static immutable jsonAnnotationException = new IonException("JSON can store exactly one annotation.");
version(D_Exceptions) private static immutable jsonClobSerializationIsntImplemented = new IonException("JSON CLOB serialization isn't implemented.");
version(D_Exceptions) private static immutable jsonBlobSerializationIsntImplemented = new IonException("JSON BLOB serialization isn't implemented.");

/++
JSON serialization back-end
+/
struct JsonSerializer(string sep, Appender)
{
    import mir.bignum.decimal: Decimal;
    import mir.bignum.integer: BigInt;
    import mir.ion.type_code;
    import mir.lob;
    import mir.timestamp;
    import std.traits: isNumeric;

    /++
    JSON string buffer
    +/
    Appender* appender;

    /// Mutable value used to choose format specidied or user-defined serialization specializations
    int serdeTarget = SerdeTarget.json;
    private bool _annotation;
    private size_t state;

    static if(sep.length)
    {
        private size_t deep;

        private void putSpace() scope
        {
            for(auto k = deep; k; k--)
            {
                static if(sep.length == 1)
                {
                    appender.put(sep[0]);
                }
                else
                {
                    appender.put(sep);
                }
            }
        }
    }

scope:

    private void pushState(size_t state)
    {
        this.state = state;
    }

    private size_t popState()
    {
        auto ret = state;
        state = 0;
        return ret;
    }

    private void incState()
    {
        if(state++)
        {
            static if(sep.length)
            {
                appender.put(",\n");
            }
            else
            {
                appender.put(',');
            }
        }
        else
        {
            static if(sep.length)
            {
                appender.put('\n');
            }
        }
    }

    private void putEscapedKey(scope const char[] key)
    {
        incState;
        static if(sep.length)
        {
            putSpace;
        }
        appender.put('\"');
        appender.put(key);
        static if(sep.length)
        {
            appender.put(`": `);
        }
        else
        {
            appender.put(`":`);
        }
    }

    ///
    size_t stringBegin()
    {
        appender.put('\"');
        return 0;
    }

    /++
    Puts string part. The implementation allows to split string unicode points.
    +/
    void putStringPart(scope const(char)[] value)
    {
        import mir.format: printEscaped, EscapeFormat;
        printEscaped!(char, EscapeFormat.json)(appender, value);
    }

    ///
    void stringEnd(size_t)
    {
        appender.put('\"');
    }

    ///
    size_t structBegin(size_t length = size_t.max)
    {
        static if(sep.length)
        {
            deep++;
        }
        appender.put('{');
        return popState;
    }

    ///
    void structEnd(size_t state)
    {
        static if(sep.length)
        {
            deep--;
            if (this.state)
            {
                appender.put('\n');
                putSpace;
            }
        }
        appender.put('}');
        pushState(state);
    }

    ///
    size_t listBegin(size_t length = size_t.max)
    {
        static if(sep.length)
        {
            deep++;
        }
        appender.put('[');
        return popState;
    }

    ///
    void listEnd(size_t state)
    {
        static if(sep.length)
        {
            deep--;
            if (this.state)
            {
                appender.put('\n');
                putSpace;
            }
        }
        appender.put(']');
        pushState(state);
    }

    ///
    alias sexpBegin = listBegin;

    ///
    alias sexpEnd = listEnd;

    ///
    void putSymbol(scope const char[] symbol)
    {
        putValue(symbol);
    }

    ///
    void putAnnotation(scope const(char)[] annotation)
    {
        if (_annotation)
            throw jsonAnnotationException;
        _annotation = true;
        putKey(annotation);
    }

    ///
    auto annotationsEnd(size_t state)
    {
        bool _annotation = false;
        return state;
    }

    ///
    alias annotationWrapperBegin = structBegin;

    ///
    void annotationWrapperEnd(size_t annotationsState, size_t state)
    {
        return structEnd(state);
    }

    ///
    void nextTopLevelValue()
    {
        appender.put('\n');
    }

    ///
    void putCompiletimeKey(string key)()
    {
        import mir.algorithm.iteration: any;
        static if (key.any!(c => c == '"' || c == '\\' || c < ' '))
            putKey(key);
        else
            putEscapedKey(key);
    }

    ///
    void putKey(scope const char[] key)
    {
        import mir.format: printEscaped, EscapeFormat;

        incState;
        static if(sep.length)
        {
            putSpace;
        }
        appender.put('\"');
        printEscaped!(char, EscapeFormat.json)(appender, key);
        static if(sep.length)
        {
            appender.put(`": `);
        }
        else
        {
            appender.put(`":`);
        }
    }

    ///
    void putValue(Num)(const Num value)
        if (isNumeric!Num && !is(Num == enum))
    {
        import mir.format: print;
        import mir.internal.utility: isFloatingPoint;

        static if (isFloatingPoint!Num)
        {
            import mir.math.common: fabs;

            if (value.fabs < value.infinity)
                print(appender, value);
            else if (value == Num.infinity)
                appender.put(`"+inf"`);
            else if (value == -Num.infinity)
                appender.put(`"-inf"`);
            else
                appender.put(`"nan"`);
        }
        else
            print(appender, value);
    }

    ///
    void putValue(size_t size)(auto ref const BigInt!size num)
    {
        num.toString(appender);
    }

    ///
    void putValue(size_t size)(auto ref const Decimal!size num)
    {
        num.toString(appender);
    }

    ///
    void putValue(typeof(null))
    {
        appender.put("null");
    }

    /// ditto 
    void putNull(IonTypeCode code)
    {
        appender.put(code.nullStringJsonAlternative);
    }

    ///
    void putValue(bool b)
    {
        appender.put(b ? "true" : "false");
    }

    ///
    void putValue(scope const char[] value)
    {
        auto state = stringBegin;
        putStringPart(value);
        stringEnd(state);
    }

    ///
    void putValue(Clob value)
    {
        throw jsonClobSerializationIsntImplemented;
    }

    ///
    void putValue(Blob value)
    {
        throw jsonBlobSerializationIsntImplemented;
    }

    ///
    void putValue(Timestamp value)
    {
        appender.put('\"');
        value.toISOExtString(appender);
        appender.put('\"');
    }

    ///
    void elemBegin()
    {
        incState;
        static if(sep.length)
        {
            putSpace;
        }
    }

    ///
    alias sexpElemBegin = elemBegin;
}

/++
JSON serialization function.
+/
alias serializeJson = serializeJsonPretty!"";

///
unittest
{
    struct S
    {
        string foo;
        uint bar;
    }

    assert(serializeJson(S("str", 4)) == `{"foo":"str","bar":4}`);
}

unittest
{
    import mir.ser.json: serializeJson;
    import mir.format: stringBuf;
    import mir.small_string;

    SmallString!8 smll = SmallString!8("ciaociao");
    auto buffer = stringBuf;

    serializeJson(buffer, smll);
    assert(buffer.data == `"ciaociao"`);
}

///
unittest
{
    import mir.serde: serdeIgnoreDefault;

    static struct Decor
    {
        int candles; // 0
        float fluff = float.infinity; // inf 
    }
    
    static struct Cake
    {
        @serdeIgnoreDefault
        string name = "Chocolate Cake";
        int slices = 8;
        float flavor = 1;
        @serdeIgnoreDefault
        Decor dec = Decor(20); // { 20, inf }
    }
    
    assert(Cake("Normal Cake").serializeJson == `{"name":"Normal Cake","slices":8,"flavor":1.0}`);
    auto cake = Cake.init;
    cake.dec = Decor.init;
    assert(cake.serializeJson == `{"slices":8,"flavor":1.0,"dec":{"candles":0,"fluff":"+inf"}}`);
    assert(cake.dec.serializeJson == `{"candles":0,"fluff":"+inf"}`);
    
    static struct A
    {
        @serdeIgnoreDefault
        string str = "Banana";
        int i = 1;
    }
    assert(A.init.serializeJson == `{"i":1}`);
    
    static struct S
    {
        @serdeIgnoreDefault
        A a;
    }
    assert(S.init.serializeJson == `{}`);
    assert(S(A("Berry")).serializeJson == `{"a":{"str":"Berry","i":1}}`);
    
    static struct D
    {
        S s;
    }
    assert(D.init.serializeJson == `{"s":{}}`);
    assert(D(S(A("Berry"))).serializeJson == `{"s":{"a":{"str":"Berry","i":1}}}`);
    assert(D(S(A(null, 0))).serializeJson == `{"s":{"a":{"str":"","i":0}}}`);
    
    static struct F
    {
        D d;
    }
    assert(F.init.serializeJson == `{"d":{"s":{}}}`);
}

///
unittest
{
    import mir.serde: serdeIgnoreIn;

    static struct S
    {
        @serdeIgnoreIn
        string s;
    }
    // assert(`{"s":"d"}`.deserializeJson!S.s == null, `{"s":"d"}`.deserializeJson!S.s);
    assert(S("d").serializeJson == `{"s":"d"}`);
}

///
unittest
{
    import mir.deser.json;

    static struct S
    {
        @serdeIgnoreOut
        string s;
    }
    assert(`{"s":"d"}`.deserializeJson!S.s == "d");
    assert(S("d").serializeJson == `{}`);
}

///
unittest
{
    import mir.serde: serdeIgnoreOutIf;

    static struct S
    {
        @serdeIgnoreOutIf!`a < 0`
        int a;
    }

    assert(serializeJson(S(3)) == `{"a":3}`, serializeJson(S(3)));
    assert(serializeJson(S(-3)) == `{}`);
}

///
unittest
{
    import mir.rc.array;
    auto ar = rcarray!int(1, 2, 4);
    assert(ar.serializeJson == "[1,2,4]");
}

///
unittest
{
    import mir.deser.json;
    import std.range;
    import std.algorithm;
    import std.conv;
    import mir.test;

    static struct S
    {
        @serdeTransformIn!"a += 2"
        @serdeTransformOut!(a =>"str".repeat.take(a).joiner("_").to!string)
        int a;
    }

    auto s = deserializeJson!S(`{"a":3}`);
    s.a.should == 5;
    assert(serializeJson(s) == `{"a":"str_str_str_str_str"}`);
}

/++
JSON serialization for custom outputt range.
+/
@safe pure nothrow @nogc
unittest
{
    import mir.format: stringBuf;
    auto buffer = stringBuf;
    static struct S { int a; }
    serializeJson(buffer, S(4));
    assert(buffer.data == `{"a":4}`);
}

/++
JSON serialization function with pretty formatting and custom output range.
+/
template serializeJsonPretty(string sep = "\t")
{
    import mir.primitives: isOutputRange;
    ///
    void serializeJsonPretty(Appender, V)(ref Appender appender, auto ref V value, int serdeTarget = SerdeTarget.json)
        if (isOutputRange!(Appender, const(char)[]) && isOutputRange!(Appender, char))
    {
        import mir.ser: serializeValue;
        auto serializer = jsonSerializer!sep((()@trusted => &appender)(), serdeTarget);
        serializeValue(serializer, value);
    }

    /++
    JSON serialization function with pretty formatting.
    +/
    string serializeJsonPretty(V)(auto ref V value, int serdeTarget = SerdeTarget.json)
    {
        import std.array: appender;
        import mir.functional: forward;

        auto app = appender!(char[]);
        serializeJsonPretty(app, forward!value, serdeTarget);
        return (()@trusted => cast(string) app.data)();
    }
}

///
unittest
{
    static struct S { int a; }
    assert(S(4).serializeJsonPretty!"    " == "{\n    \"a\": 4\n}");
}

///
@safe pure nothrow @nogc
unittest
{
    import mir.format: stringBuf;
    auto buffer = stringBuf;
    static struct S { int a; }
    serializeJsonPretty!"    "(buffer, S(4));
    assert(buffer.data == "{\n    \"a\": 4\n}");
}

/++
Creates JSON serialization back-end.
Use `sep` equal to `"\t"` or `"    "` for pretty formatting.
+/
template jsonSerializer(string sep = "")
{
    ///
    auto jsonSerializer(Appender)(return Appender* appender, int serdeTarget = SerdeTarget.json)
    {
        return JsonSerializer!(sep, Appender)(appender, serdeTarget);
    }
}

///
@safe pure nothrow @nogc unittest
{
    import mir.format: stringBuf;
    import mir.bignum.integer;

    auto buffer = stringBuf;
    auto ser = jsonSerializer((()@trusted=>&buffer)(), 3);
    auto state0 = ser.structBegin;

        ser.putKey("null");
        ser.putValue(null);

        ser.putKey("array");
        auto state1 = ser.listBegin();
            ser.elemBegin; ser.putValue(null);
            ser.elemBegin; ser.putValue(123);
            ser.elemBegin; ser.putValue(12300000.123);
            ser.elemBegin; ser.putValue("\t");
            ser.elemBegin; ser.putValue("\r");
            ser.elemBegin; ser.putValue("\n");
            ser.elemBegin; ser.putValue(BigInt!2(1234567890));
        ser.listEnd(state1);

    ser.structEnd(state0);

    assert(buffer.data == `{"null":null,"array":[null,123,1.2300000123e+7,"\t","\r","\n",1234567890]}`);
}

///
unittest
{
    import std.array;
    import mir.bignum.integer;

    auto app = appender!string;
    auto ser = jsonSerializer!"    "(&app);
    auto state0 = ser.structBegin;

        ser.putKey("null");
        ser.putValue(null);

        ser.putKey("array");
        auto state1 = ser.listBegin();
            ser.elemBegin; ser.putValue(null);
            ser.elemBegin; ser.putValue(123);
            ser.elemBegin; ser.putValue(12300000.123);
            ser.elemBegin; ser.putValue("\t");
            ser.elemBegin; ser.putValue("\r");
            ser.elemBegin; ser.putValue("\n");
            ser.elemBegin; ser.putValue(BigInt!2("1234567890"));
        ser.listEnd(state1);

    ser.structEnd(state0);

    assert(app.data ==
`{
    "null": null,
    "array": [
        null,
        123,
        1.2300000123e+7,
        "\t",
        "\r",
        "\n",
        1234567890
    ]
}`, app.data);
}
