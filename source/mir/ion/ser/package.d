/++
$(H4 High level serialization API)

Macros:
IONREF = $(REF_ALTTEXT $(TT $2), $2, mir, ion, $1)$(NBSP)
+/
module mir.ion.ser;

import mir.bignum.integer: BigInt;
import mir.bignum.decimal: Decimal;
import mir.ion.deser;
import mir.ion.deser.low_level: isNullable;
import mir.reflection;
import std.bigint;
import std.format: FormatSpec;
import std.meta;
import std.range.primitives;
import std.traits;
public import mir.serde;
import mir.conv;


private auto assumePure(T)(T t) @trusted
    // if (isFunctionPointer!T || isDelegate!T)
{
    import std.traits;
    enum attrs = (functionAttributes!T | FunctionAttribute.pure_) & ~FunctionAttribute.system;
    return cast(SetFunctionAttributes!(T, functionLinkage!T, attrs)) t;
}


/// JSON serialization function.
string serializeJson(V)(auto ref V value)
{
    return serializeJsonPretty!""(value);
}

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


/// JSON serialization function with pretty formatting.
string serializeJsonPretty(string sep = "\t", V)(auto ref V value)
{
    import std.array: appender;
    import std.functional: forward;

    auto app = appender!(char[]);
    serializeJsonPretty!sep(forward!value, app);
    return cast(string) app.data;
}

///
unittest
{
    static struct S { int a; }
    assert(S(4).serializeJsonPretty == "{\n\t\"a\": 4\n}");
}

/// JSON serialization function with pretty formatting and custom output range.
void serializeJsonPretty(string sep = "\t", V, Appender)(auto ref V value, ref Appender appender)
    if(isOutputRange!(Appender, const(char)[]))
{
    auto ser = jsonSerializer!sep(&appender);
    ser.serializeValue(value);
}

///
unittest
{

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
    assert(cake.serializeJson == `{"slices":8,"flavor":1.0,"dec":{"candles":0,"fluff":"inf"}}`);
    assert(cake.dec.serializeJson == `{"candles":0,"fluff":"inf"}`);
    
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
    assert(D(S(A(null, 0))).serializeJson == `{"s":{"a":{"str":null,"i":0}}}`);
    
    static struct F
    {
        D d;
    }
    assert(F.init.serializeJson == `{"d":{"s":{}}}`);
}

///
unittest
{

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
    import mir.ion.deser;

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

    import std.range;
    import std.uuid;

    static struct S
    {
        private int count;
        @serdeLikeList
        auto numbers() @property // uses `foreach`
        {
            return iota(count);
        }

        @serdeLikeList
        @serdeProxy!string // input element type of
        @serdeIgnoreOut
        Appender!(string[]) strings; //`put` method is used
    }

    assert(S(5).serializeJson == `{"numbers":[0,1,2,3,4]}`);
    // assert(`{"strings":["a","b"]}`.deserializeJson!S.strings.data == ["a","b"]);
}

///
unittest
{

    static struct M
    {
        private int sum;

        // opApply is used for serialization
        int opApply(int delegate(scope const char[] key, int val) pure dg) pure
        {
            if(auto r = dg("a", 1)) return r;
            if(auto r = dg("b", 2)) return r;
            if(auto r = dg("c", 3)) return r;
            return 0;
        }

        // opIndexAssign for deserialization
        void opIndexAssign(int val, string key) pure
        {
            sum += val;
        }
    }

    static struct S
    {
        @serdeLikeStruct
        @serdeProxy!int
        M obj;
    }

    assert(S.init.serializeJson == `{"obj":{"a":1,"b":2,"c":3}}`);
    // assert(`{"obj":{"a":1,"b":2,"c":9}}`.deserializeJson!S.obj.sum == 12);
}

///
unittest
{
    import mir.ion.deser;
    import std.range;
    import std.algorithm;
    import std.conv;

    static struct S
    {
        @serdeTransformIn!"a += 2"
        @serdeTransformOut!(a =>"str".repeat.take(a).joiner("_").to!string)
        int a;
    }

    auto s = deserializeJson!S(`{"a":3}`);
    assert(s.a == 5);
    assert(serializeJson(s) == `{"a":"str_str_str_str_str"}`);
}

/++
Object serialization wrapper.
+/
struct ObjectSerializer(Serializer)
{
    /// Serializer pointer
    Serializer* serializer;
    /// Object start serializer state
    Serializer.State state;

    /// Starts object serialization
    this(ref Serializer serializer)
    {
        this.serializer = &serializer;
        this.state = this.serializer.objectBegin;
    }

    /// Ends object serialization
    ~this()
    {
        this.serializer.objectEnd(state);
    }

    @disable this(this);

    /// Serialize key-value pair
    void serializeKeyValue(T)(string key, auto ref const T value)
    {
        serializer.putKey(key);
        serializeValue(*serializer, value);
    }

    /// Serialize key-value pair for escaped keys
    void putEscapedKeyValue(T)(string key, auto ref const T value)
    {
        serializer.putEscapedKey(key);
        serializeValue(*serializer, value);
    }
}

/++
Array serialization wrapper.
+/
struct ArraySerializer(Serializer)
{
    /// Serializer pointer
    Serializer* serializer;
    /// Array start serializer state
    Serializer.State state;

    /// Starts object serialization
    this(ref Serializer serializer)
    {
        this.serializer = &serializer;
        this.state = this.serializer.arrayBegin;
    }

    /// Ends object serialization
    ~this()
    {
        this.serializer.arrayEnd(state);
    }

    @disable this(this);

    /// Serialize key-value pair
    void serializeValue(T)(auto ref const value)
    {
        serializeValue(*serializer, value);
    }
}


struct Serializer
{
    struct ArraySerializer
    {
        Serializer* serializer;

        void put(T)(auto ref const value)
        {

        }
    }
}

/// JSON serialization back-end
struct JsonSerializer(string sep, Appender)
{
    /// JSON string buffer
    Appender* appender;

    private uint state;

    static if(sep.length)
    {
        private size_t deep;

        private void putSpace()
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

    private void pushState(uint state)
    {
        this.state = state;
    }

    private uint popState()
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
    }

    /// Serialization primitives
    uint objectBegin()
    {
        static if(sep.length)
        {
            deep++;
            appender.put("{\n");
        }
        else
        {
            appender.put('{');
        }
        return popState;
    }

    ///ditto
    void objectEnd(uint state)
    {
        static if(sep.length)
        {
            deep--;
            appender.put('\n');
            putSpace;
        }
        appender.put('}');
        pushState(state);
    }

    ///ditto
    uint arrayBegin()
    {
        static if(sep.length)
        {
            deep++;
            appender.put("[\n");
        }
        else
        {
            appender.put('[');
        }
        return popState;
    }

    ///ditto
    void arrayEnd(uint state)
    {
        static if(sep.length)
        {
            deep--;
            appender.put('\n');
            putSpace;
        }
        appender.put(']');
        pushState(state);
    }

    ///ditto
    void putEscapedKey(scope const char[] key)
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

    private void putString(scope const char[] str)
    {
        import mir.utility: _expect;

        char[6] buffer = `\u0000`;
        size_t j;
        scope const(char)[] output;
        foreach (size_t i, char c; str)
        {
            if (_expect(c == '"', false))
            {
                output = `\"`;
            }
            else
            if (_expect(c == '\\', false))
            {
                output = `\\`;
            }
            else
            if (_expect(c < ' ', false))
            {
                if (c == '\t')
                {
                    output = `\t`;
                }
                else
                if (c == '\n')
                {
                    output = `\n`;
                }
                else
                if (c == '\r')
                {
                    output = `\r`;
                }
                else
                if (c == '\f')
                {
                    output = `\f`;
                }
                else
                if (c == '\b')
                {
                    output = `\b`;
                }
                else
                {
                    buffer[4] = cast(char)('0' + (c <= 0xF));
                    uint d = 0xF & c;
                    buffer[5] = cast(char)(d < 10 ? '0' + d : 'A' + (d - 10));
                    output = buffer;
                }
            }
            else
            if (_expect(i + 1 < str.length, true))
            {
                continue;
            }
            else
            {
                i += 1;
            }
            appender.put(str[j .. i]);
            appender.put(output);
            output = null;
            j = i + 1;
        }
    }

    ///ditto
    void putKey(scope const char[] key)
    {
        incState;
        static if(sep.length)
        {
            putSpace;
        }
        appender.put('\"');
        putString(key);
        static if(sep.length)
        {
            appender.put(`": `);
        }
        else
        {
            appender.put(`":`);
        }
    }

    ///ditto
    void putValue(Num)(Num num)
        if (isNumeric!Num && !is(Num == enum))
    {
        import mir.format: print;
        print(appender, num);
        return;
    }

    ///ditto
    void putValue(size_t size)(auto ref const BigInt!size num)
    {
        num.toString(appender);
    }

    ///ditto
    void putValue(size_t size)(auto ref const Decimal!size num)
    {
        num.toString(appender);
    }

    ///ditto
    void putValue(typeof(null))
    {
        appender.put("null");
    }

    ///ditto
    void putValue(bool b)
    {
        appender.put(b ? "true" : "false");
    }

    ///ditto
    void putEscapedValue(scope const char[] value)
    {
        appender.put('\"');
        appender.put(value);
        appender.put('\"');
    }

    ///ditto
    void putValue(scope const char[] value)
    {
        appender.put('\"');
        putString(value);
        appender.put('\"');
    }

    ///ditto
    void elemBegin()
    {
        incState;
        static if(sep.length)
        {
            putSpace;
        }
    }
}

/++
Creates JSON serialization back-end.
Use `sep` equal to `"\t"` or `"    "` for pretty formatting.
+/
auto jsonSerializer(string sep = "", Appender)(return Appender* appender)
{
    return JsonSerializer!(sep, Appender)(appender);
}

///
unittest
{

    import std.array;
    import mir.bignum.integer;

    auto app = appender!string;
    auto ser = jsonSerializer(&app);
    auto state0 = ser.objectBegin;

        ser.putEscapedKey("null");
        ser.putValue(null);

        ser.putEscapedKey("array");
        auto state1 = ser.arrayBegin();
            ser.elemBegin; ser.putValue(null);
            ser.elemBegin; ser.putValue(123);
            ser.elemBegin; ser.putValue(12300000.123);
            ser.elemBegin; ser.putValue("\t");
            ser.elemBegin; ser.putValue("\r");
            ser.elemBegin; ser.putValue("\n");
            ser.elemBegin; ser.putValue(BigInt!2("1234567890"));
        ser.arrayEnd(state1);

    ser.objectEnd(state0);

    assert(app.data == `{"null":null,"array":[null,123,1.2300000123e7,"\t","\r","\n",1234567890]}`, app.data);
}

unittest
{
    import std.array;
    import std.bigint;
    import std.format: singleSpec;

    auto app = appender!string;
    auto ser = jsonSerializer!"    "(&app);
    auto state0 = ser.objectBegin;

        ser.putEscapedKey("null");
        ser.putValue(null);

        ser.putEscapedKey("array");
        auto state1 = ser.arrayBegin();
            ser.elemBegin; ser.putValue(null);
            ser.elemBegin; ser.putValue(123);
            ser.elemBegin; ser.putValue(12300000.123);
            ser.elemBegin; ser.putValue("\t");
            ser.elemBegin; ser.putValue("\r");
            ser.elemBegin; ser.putValue("\n");
            ser.elemBegin; ser.putValue(BigInt!2("1234567890"));
        ser.arrayEnd(state1);

    ser.objectEnd(state0);

    assert(app.data ==
`{
    "null": null,
    "array": [
        null,
        123,
        1.2300000123e7,
        "\t",
        "\r",
        "\n",
        1234567890
    ]
}`);
}


/// `null` value serialization
void serializeValue(S)(ref S serializer, typeof(null))
{
    serializer.putValue(null);
}

///
unittest
{

    assert(serializeJson(null) == `null`);
}

/// Number serialization
void serializeValue(S, V)(ref S serializer, auto ref const V value)
    if ((isNumeric!V && !is(V == enum)) || is(V == BigInt!size0, size_t size0) || is(V == Decimal!size1, size_t size1))
{
    static if (isFloatingPoint!V)
    {
        import std.math : isNaN, isFinite, signbit;

        if (isFinite(value))
            serializer.putValue(value);
        else if (value.isNaN)
            serializer.putValue(signbit(value) ? "-nan" : "nan");
        else if (value == V.infinity)
            serializer.putValue("inf");
        else if (value == -V.infinity)
            serializer.putValue("-inf");
    }
    else
        serializer.putValue(value);
}

///
unittest
{
    import mir.bignum.integer;

    assert(serializeJson(BigInt!2(123)) == `123`);
    assert(serializeJson(2.40f) == `2.4`);
    assert(serializeJson(float.nan) == `"nan"`);
    assert(serializeJson(float.infinity) == `"inf"`);
    assert(serializeJson(-float.infinity) == `"-inf"`);
}

/// Boolean serialization
void serializeValue(S, V)(ref S serializer, const V value)
    if (is(V == bool) && !is(V == enum))
{
    serializer.putValue(value);
}

/// Char serialization
void serializeValue(S, V : char)(ref S serializer, const V value)
    if (is(V == char) && !is(V == enum))
{
    auto v = cast(char[1])value;
    serializer.putValue(v[]);
}

///
unittest
{
    assert(serializeJson(true) == `true`);
}

/// Enum serialization
void serializeValue(S, V)(ref S serializer, in V value)
    if(is(V == enum))
{
    static if (hasUDA!(V, serdeProxy))
    {
        serializer.serializeValue(value.to!(serdeGetProxy!V));
    }
    else
    {
        serializer.putValue(serdeGetKeyOut(value));
    }
}

///
unittest
{
    enum Key { @serdeKeys("FOO", "foo") foo }
    assert(serializeJson(Key.foo) == `"FOO"`);
}

/// String serialization
void serializeValue(S)(ref S serializer, in char[] value)
{
    if(value is null)
    {
        serializer.putValue(null);
        return;
    }
    serializer.putValue(value);
}

///
unittest
{
    assert(serializeJson("\t \" \\") == `"\t \" \\"`, serializeJson("\t \" \\"));
}

/// Array serialization
void serializeValue(S, T)(ref S serializer, T[] value)
    if(!isSomeChar!T)
{
    if(value is null)
    {
        serializer.putValue(null);
        return;
    }
    auto state = serializer.arrayBegin();
    foreach (ref elem; value)
    {
        serializer.elemBegin;
        serializer.serializeValue(elem);
    }
    serializer.arrayEnd(state);
}

/// Input range serialization
void serializeValue(S, R)(ref S serializer, R value)
    if ((isInputRange!R) &&
        !isSomeChar!(ElementType!R) &&
        !isDynamicArray!R &&
        !isNullable!R)
{
    auto state = serializer.arrayBegin();
    foreach (ref elem; value)
    {
        serializer.elemBegin;
        serializer.serializeValue(elem);
    }
    serializer.arrayEnd(state);
}

/// input range serialization
unittest
{
    import std.algorithm : filter;

    struct Foo
    {
        int i;
    }

    auto ar = [Foo(1), Foo(3), Foo(4), Foo(17)];

    auto filtered1 = ar.filter!"a.i & 1";
    auto filtered2 = ar.filter!"!(a.i & 1)";

    assert(serializeJson(filtered1) == `[{"i":1},{"i":3},{"i":17}]`);
    assert(serializeJson(filtered2) == `[{"i":4}]`);
}

///
unittest
{
    uint[2] ar = [1, 2];
    assert(serializeJson(ar) == `[1,2]`);
    assert(serializeJson(ar[]) == `[1,2]`);
    assert(serializeJson(ar[0 .. 0]) == `[]`);
    assert(serializeJson((uint[]).init) == `null`);
}

/// String-value associative array serialization
void serializeValue(S, T)(ref S serializer, auto ref T[string] value)
{
    if(value is null)
    {
        serializer.putValue(null);
        return;
    }
    auto state = serializer.objectBegin();
    foreach (key, ref val; value)
    {
        serializer.putKey(key);
        serializer.serializeValue(val);
    }
    serializer.objectEnd(state);
}

///
unittest
{
    uint[string] ar = ["a" : 1];
    assert(serializeJson(ar) == `{"a":1}`);
    ar.remove("a");
    assert(serializeJson(ar) == `{}`);
    assert(serializeJson((uint[string]).init) == `null`);
}

/// Enumeration-value associative array serialization
void serializeValue(S, V : const T[K], T, K)(ref S serializer, V value)
    if(is(K == enum))
{
    if(value is null)
    {
        serializer.putValue(null);
        return;
    }
    auto state = serializer.objectBegin();
    foreach (key, ref val; value)
    {
        serializer.putEscapedKey(key.to!string);
        serializer.putValue(val);
    }
    serializer.objectEnd(state);
}

///
unittest
{
    enum E { a, b }
    uint[E] ar = [E.a : 1];
    assert(serializeJson(ar) == `{"a":1}`);
    ar.remove(E.a);
    assert(serializeJson(ar) == `{}`);
    assert(serializeJson((uint[string]).init) == `null`);
}

/// integral typed value associative array serialization
void serializeValue(S,  V : const T[K], T, K)(ref S serializer, V value)
    if((isIntegral!K) && !is(K == enum))
{
    if(value is null)
    {
        serializer.putValue(null);
        return;
    }
    char[40] buffer = void;
    auto state = serializer.objectBegin();
    foreach (key, ref val; value)
    {
        import std.format : sformat;
        auto str = sformat(buffer[], "%d", key);
        serializer.putEscapedKey(str);
        .serializeValue(serializer, val);
    }
    serializer.objectEnd(state);
}

///
unittest
{
    uint[short] ar = [256 : 1];
    assert(serializeJson(ar) == `{"256":1}`);
    ar.remove(256);
    assert(serializeJson(ar) == `{}`);
    assert(serializeJson((uint[string]).init) == `null`);
    // assert(deserializeJson!(uint[short])(`{"256":1}`) == cast(uint[short]) [256 : 1]);
}

/// Nullable type serialization
void serializeValue(S, N)(ref S serializer, auto ref N value)
    if (isNullable!N)
{
    if(value.isNull)
    {
        serializer.putValue(null);
        return;
    }
    serializer.serializeValue(value.get);
}

///
unittest
{
    import std.typecons;

    struct Nested
    {
        float f;
    }

    struct T
    {
        string str;
        Nullable!Nested nested;
    }

    T t;
    assert(t.serializeJson == `{"str":null,"nested":null}`);
    t.str = "txt";
    t.nested = Nested(123);
    assert(t.serializeJson == `{"str":"txt","nested":{"f":123.0}}`);
}

/// Struct and class type serialization
void serializeValue(S, V)(ref S serializer, auto ref V value)
    if (!isNullable!V && isAggregateType!V && !is(V == BigInt!size0, size_t size0) && !isInputRange!V)
{
    static if(is(V == class) || is(V == interface))
    {
        if(value is null)
        {
            serializer.putValue(null);
            return;
        }
    }

    static if (hasUDA!(V, serdeProxy))
    {{
        serializer.serializeValue(value.to!(serdeGetProxy!V));
        return;
    }}
    else
    static if(__traits(hasMember, V, "serialize"))
    {
        value.serialize(serializer);
    }
    else
    {
        auto state = serializer.objectBegin();
        foreach(member; aliasSeqOf!(SerializableMembers!V))
        {{
            enum key = serdeGetKeyOut!(__traits(getMember, value, member));

            static if (key !is null)
            {
                static if (hasUDA!(__traits(getMember, value, member), serdeIgnoreDefault))
                {
                    if (__traits(getMember, value, member) == __traits(getMember, V.init, member))
                        continue;
                }
                
                static if(hasUDA!(__traits(getMember, value, member), serdeIgnoreOutIf))
                {
                    alias pred = serdeGetIgnoreOutIf!(__traits(getMember, value, member));
                    if (pred(__traits(getMember, value, member)))
                        continue;
                }
                static if(hasUDA!(__traits(getMember, value, member), serdeTransformOut))
                {
                    alias f = serdeGetTransformOut!(__traits(getMember, value, member));
                    auto val = f(__traits(getMember, value, member));
                }
                else
                {
                    auto val = __traits(getMember, value, member);
                }

                serializer.putEscapedKey(key);

                static if(hasUDA!(__traits(getMember, value, member), serdeLikeList))
                {
                    alias V = typeof(val);
                    static if(is(V == interface) || is(V == class) || is(V : E[], E))
                    {
                        if(val is null)
                        {
                            serializer.putValue(null);
                            continue;
                        }
                    }
                    auto valState = serializer.arrayBegin();
                    foreach (ref elem; val)
                    {
                        serializer.elemBegin;
                        serializer.serializeValue(elem);
                    }
                    serializer.arrayEnd(valState);
                }
                else
                static if(hasUDA!(__traits(getMember, value, member), serdeLikeStruct))
                {
                    static if(is(V == interface) || is(V == class) || is(V : E[T], E, T))
                    {
                        if(val is null)
                        {
                            serializer.putValue(null);
                            continue F;
                        }
                    }
                    auto valState = serializer.objectBegin();
                    foreach (key, elem; val)
                    {
                        serializer.putKey(key);
                        serializer.serializeValue(elem);
                    }
                    serializer.objectEnd(valState);
                }
                else
                static if(hasUDA!(__traits(getMember, value, member), serdeProxy))
                {
                    serializer.serializeValue(val.to!(serdeGetProxy!(__traits(getMember, value, member))));
                }
                else
                {
                    serializer.serializeValue(val);
                }
            }
        }}
        static if(__traits(hasMember, V, "finalizeSerialization"))
        {
            value.finalizeSerialization(serializer);
        }
        serializer.objectEnd(state);
    }
}

/// Alias this support
unittest
{
    struct S
    {
        int u;
    }

    struct C
    {
        int b;
        S s;
        alias s this; 
    }

    assert(C(4, S(3)).serializeJson == `{"u":3,"b":4}`);
}

/// Custom `serialize`
unittest
{
    import std.conv: to;

    struct S
    {
        void serialize(S)(ref S serializer)
        {
            auto state = serializer.objectBegin;
            serializer.putEscapedKey("foo");
            serializer.putValue("bar");
            serializer.objectEnd(state);
        }
    }
    enum json = `{"foo":"bar"}`;
    assert(serializeJson(S()) == json);
}
