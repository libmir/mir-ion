/++
$(H4 High level serialization API)

Macros:
IONREF = $(REF_ALTTEXT $(TT $2), $2, mir, ion, $1)$(NBSP)
Authros: Ilya Yaroshenko
+/
module mir.ser;

import mir.conv;
import mir.deser;
import mir.ion.internal.basic_types;
import mir.ion.type_code;
import mir.reflection;
import std.meta;
import std.traits;

public import mir.serde;

static immutable cannotSerializeVoidMsg = "Can't serialize none (void) value of the algebraic type";
version (D_Exceptions)
    private static immutable cannotSerializeVoid = new Exception(cannotSerializeVoidMsg);

private noreturn throwCannotSerializeVoid() @safe pure @nogc
{
    version (D_Exceptions)
        throw cannotSerializeVoid;
    else
        assert(0, cannotSerializeVoidMsg);
}

/// `null` value serialization
void serializeValue(S)(scope ref S serializer, typeof(null))
{
    serializer.putValue(null);
}

///
version(mir_ion_test)
unittest
{
    import mir.ser.json: serializeJson;
    assert(serializeJson(null) == `null`, serializeJson(null));
}

/// Number serialization
void serializeValue(S, V)(scope ref S serializer, auto ref const V value)
    if (isNumeric!V && !is(V == enum))
{
    serializer.putValue(value);
}

///
version(mir_ion_test)
unittest
{
    import mir.ser.json: serializeJson;

    assert(serializeJson(2.40f) == `2.4`);
    assert(serializeJson(float.nan) == `"nan"`);
    assert(serializeJson(float.infinity) == `"+inf"`);
    assert(serializeJson(-float.infinity) == `"-inf"`);
}

/// Boolean serialization
void serializeValue(S, V)(scope ref S serializer, const V value)
    if (is(V == bool) && !is(V == enum))
{
    serializer.putValue(value);
}

/// Char serialization
void serializeValue(S, V : char)(scope ref S serializer, const V value)
    if (is(V == char) && !is(V == enum))
{
    char[1] v = value;
    serializer.putValue(v[]);
}

///
version(mir_ion_test)
unittest
{
    import mir.ser.json: serializeJson;
    assert(serializeJson(true) == `true`);
}

/// Enum serialization
void serializeValue(S, V)(scope ref S serializer, in V value)
    if(is(V == enum))
{
    static if (hasUDA!(V, serdeProxy))
    {
        serializer.serializeWithProxy!(serdeGetProxy!V)(value);
    }
    else
    {
        serializer.putSymbol(serdeGetKeyOut(value));
    }
}

///
version(mir_ion_test)
unittest
{
    import mir.ser.json: serializeJson;
    import mir.ser.ion: serializeIon;
    import mir.ser.text: serializeText;
    import mir.deser.ion: deserializeIon;
    import mir.small_string;
    import mir.rc.array;
    enum Key { bar, @serdeKeys("FOO", "foo") foo }
    assert(serializeJson(Key.foo) == `"FOO"`);
    assert(serializeText(Key.foo) == `FOO`);
    assert(serializeIon(Key.foo).deserializeIon!Key == Key.foo);
    assert(serializeIon(Key.foo).deserializeIon!string == "FOO");
    assert(serializeIon(Key.foo).deserializeIon!(SmallString!32) == "FOO");
    auto rcstring = serializeIon(Key.foo).deserializeIon!(RCArray!char);
    assert(rcstring[] == "FOO");
}

/// String serialization
void serializeValue(S)(scope ref S serializer, scope const(char)[] value)
{
    if(value is null)
    {
        serializer.putNull(IonTypeCode.string);
        return;
    }
    serializer.putValue(value);
}

///
version(mir_ion_test)
unittest
{
    import mir.ser.json: serializeJson;
    assert(serializeJson("\t \" \\") == `"\t \" \\"`, serializeJson("\t \" \\"));
}

/// Array serialization
void serializeValue(S, T)(scope ref S serializer, T[] value)
    if(!isSomeChar!T)
{
    if(value is null)
    {
        serializer.putNull(IonTypeCode.list);
        return;
    }
    auto state = serializer.beginList(value);
    foreach (ref elem; value)
    {
        serializer.elemBegin;
        serializer.serializeValue(elem);
    }
    serializer.listEnd(state);
}

private enum isRefIterable(T) = __traits(compiles, (ref T value) { foreach (ref elem; value) {}  });

version(mir_ion_test)
unittest
{
    static assert(isRefIterable!(double[]));
}

package template hasLikeList(T)
{
    import mir.serde: serdeLikeList;
    static if (is(T == enum) || isAggregateType!T)
        enum hasLikeList = hasUDA!(T, serdeLikeList);
    else
        enum hasLikeList = false;
}

package template hasProxy(T)
{
    import mir.serde: serdeProxy;
    static if (is(T == enum) || isAggregateType!T)
        enum hasProxy = hasUDA!(T, serdeProxy);
    else
        enum hasProxy = false;
}

package template hasFields(T)
{
    import mir.serde: serdeFields;
    static if (is(T == enum) || isAggregateType!T)
        enum hasFields = hasUDA!(T, serdeFields);
    else
        enum hasFields = false;
}

/// Input range serialization
void serializeValue(S, V)(scope ref S serializer, auto ref V value)
    if (isIterable!V &&
        (!hasProxy!V || hasLikeList!V) &&
        !isDynamicArray!V &&
        !hasFields!V &&
        !isAssociativeArray!V &&
        !isStdNullable!V)
{
    static if(is(V == interface) || is(V == class) || is(V : E[], E) && !is(V : D[N], D, size_t N))
    {
        if (value is null)
        {
            serializer.putNull(nullTypeCodeOf!V);
            return;
        }
    }
    static if (isSomeChar!(ForeachType!V))
    {
        import mir.format: stringBuf;
        auto buf = stringBuf;
        foreach (elem; value)
            buf.put(elem);
        serializer.putValue(buf.data);
    }
    else
    {
        auto state = serializer.beginList(value);
        static if (isRefIterable!V)
        {
            foreach (ref elem; value)
            {
                serializer.elemBegin;
                serializer.serializeValue(elem);
            }
        }
        else
        {
            foreach (elem; value)
            {
                serializer.elemBegin;
                serializer.serializeValue(elem);
            }
        }
        serializer.listEnd(state);
    }
}

/// input range serialization
version(mir_ion_test)
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

    import mir.ser.json: serializeJson;
    assert(serializeJson(filtered1) == `[{"i":1},{"i":3},{"i":17}]`);
    assert(serializeJson(filtered2) == `[{"i":4}]`);
}

///
unittest
{
    import mir.ser.json: serializeJson;
    uint[2] ar = [1, 2];
    assert(serializeJson(ar) == `[1,2]`);
    assert(serializeJson(ar[]) == `[1,2]`);
    assert(serializeJson(ar[0 .. 0]) == `[]`);
    assert(serializeJson((uint[]).init) == `[]`);
}

/// String-value associative array serialization
void serializeValue(S, T)(scope ref S serializer, auto ref const T[string] value)
{
    if(value is null)
    {
        serializer.putNull(IonTypeCode.struct_);
        return;
    }
    auto state = serializer.beginStruct(value);
    foreach (key, ref val; (()@trusted => cast()value)())
    {
        serializer.putKey(key);
        serializer.serializeValue(val);
    }
    serializer.structEnd(state);
}

///
version(mir_ion_test)
unittest
{
    import mir.ser.json: serializeJson;
    import mir.ser.text: serializeText;
    uint[string] ar = ["a" : 1];
    const car = ar;
    assert(serializeJson(ar) == `{"a":1}`);
    assert(serializeText(ar) == `{a:1}`);
    ar.remove("a");
    assert(serializeJson(ar) == `{}`);
    assert(serializeJson((uint[string]).init) == `{}`);
}

/// Enumeration-value associative array serialization
void serializeValue(S, V : const T[K], T, K)(scope ref S serializer, V value)
    if(is(K == enum))
{
    if(value is null)
    {
        serializer.putNull(IonTypeCode.struct_);
        return;
    }
    auto state = serializer.beginStruct(value);
    foreach (key, ref val; value)
    {
        serializer.putKey(serdeGetKeyOut(key));
        serializer.serializeValue(val);
    }
    serializer.structEnd(state);
}

///
version(mir_ion_test)
unittest
{
    import mir.ser.json: serializeJson;
    enum E { a, b }
    uint[E] ar = [E.a : 1];
    assert(serializeJson(ar) == `{"a":1}`);
    ar.remove(E.a);
    assert(serializeJson(ar) == `{}`);
    assert(serializeJson((uint[string]).init) == `{}`);
}

/// integral typed value associative array serialization
void serializeValue(S,  V : const T[K], T, K)(scope ref S serializer, V value)
    if (isIntegral!K && !is(K == enum))
{
    if(value is null)
    {
        serializer.putNull(IonTypeCode.struct_);
        return;
    }
    auto state = serializer.beginStruct(value);
    foreach (key, ref val; value)
    {
        import mir.format: print;
        import mir.small_string : SmallString;
        SmallString!32 buffer;
        print(buffer, key);
        serializer.putKey(buffer[]);
        .serializeValue(serializer, val);
    }
    serializer.structEnd(state);
}

///
version(mir_ion_test)
unittest
{
    import mir.ser.json: serializeJson;
    uint[short] ar = [256 : 1];
    assert(serializeJson(ar) == `{"256":1}`);
    ar.remove(256);
    assert(serializeJson(ar) == `{}`);
    assert(serializeJson((uint[string]).init) == `{}`);
    // assert(deserializeJson!(uint[short])(`{"256":1}`) == cast(uint[short]) [256 : 1]);
}


private IonTypeCode nullTypeCodeOf(T)()
{
    import mir.algebraic: isVariant, visit;
    import mir.serde: serdeGetFinalProxy;

    IonTypeCode code;

    static if (is(T == bool))
        code = IonTypeCode.bool_;
    else
    static if (isUnsigned!T)
        code = IonTypeCode.uInt;
    else
    static if (isIntegral!T || isBigInt!T)
        code = IonTypeCode.nInt;
    else
    static if (isFloatingPoint!T)
        code = IonTypeCode.float_;
    else
    static if (isDecimal!T)
        code = IonTypeCode.decimal;
    else
    static if (isClob!T)
        code = IonTypeCode.clob;
    else
    static if (isBlob!T)
        code = IonTypeCode.blob;
    else
    static if (isSomeString!T)
        code = IonTypeCode.string;
    else
    static if (!isVariant!T && isAggregateType!T)
    {
        static if (hasUDA!(T, serdeProxy))
            code = .nullTypeCodeOf!(serdeGetFinalProxy!T);
        else
        static if (isIterable!T && !hasFields!T)
            code = IonTypeCode.list;
        else
            code = IonTypeCode.struct_;
    }
    else
    static if (isIterable!T && !hasFields!T)
        code = IonTypeCode.list;

    return code;
}

version(mir_ion_test)
unittest
{
    static assert(nullTypeCodeOf!long == IonTypeCode.nInt);
}

private void serializeAnnotatedValue(S, V)(scope ref S serializer, auto ref V value, size_t annotationsState, size_t wrapperState)
{
    import mir.algebraic: isVariant;
    static if (serdeGetAnnotationMembersOut!V.length)
    {
        static foreach (annotationMember; serdeGetAnnotationMembersOut!V)
        {
            static if (is(typeof(__traits(getMember, value, annotationMember)) == enum))
                serializer.putAnnotation(serdeGetKeyOut(__traits(getMember, value, annotationMember)));
            else
            static if (__traits(compiles, serializer.putAnnotation(__traits(getMember, value, annotationMember)[])))
                serializer.putAnnotation(__traits(getMember, value, annotationMember)[]);
            else
                foreach (annotation; __traits(getMember, value, annotationMember))
                    serializer.putAnnotation(annotation);
        }
    }

    static if (isAlgebraicAliasThis!V || isAnnotated!V)
    {
        static if (__traits(getAliasThis, V).length == 1)
            enum aliasThisMember = __traits(getAliasThis, V)[0];
        else
            enum aliasThisMember = "value";
        serializeAnnotatedValue(serializer, __traits(getMember, value, aliasThisMember), annotationsState, wrapperState);
    }
    else
    static if (isVariant!V)
    {
        import mir.algebraic: visit;
        value.visit!(
            (auto ref v) {
                alias A = typeof(v);
                static if (serdeIsComplexVariant!V && serdeHasAlgebraicAnnotation!A)
                {
                    static if (__traits(hasMember, S, "putCompiletimeAnnotation"))
                        serializer.putCompiletimeAnnotation!(serdeGetAlgebraicAnnotation!A);
                    else
                    static if (__traits(hasMember, S, "putAnnotationPtr"))
                        serializer.putAnnotationPtr(serdeGetAlgebraicAnnotation!A.ptr);
                    else
                        serializer.putAnnotation(serdeGetAlgebraicAnnotation!A);
                }
                serializeAnnotatedValue(serializer, v, annotationsState, wrapperState);
            },
            throwCannotSerializeVoid,
        );
    }
    else
    {
        serializer.annotationsEnd(annotationsState);
        static if (serdeGetAnnotationMembersOut!V.length)
            serializeValueImpl(serializer, value);
        else
            serializeValue(serializer, value);
        serializer.annotationWrapperEnd(wrapperState);
    }
}

/// Struct and class type serialization
void serializeValueImpl(S, V)(scope ref S serializer, auto ref V value)
    if (isAggregateType!V && (!isIterable!V || hasFields!V || hasUDA!(V, serdeProxy) && !hasUDA!(V, serdeLikeList)))
{
    import mir.algebraic;
    auto state = serializer.structBegin;

    static if (hasUDA!(V, serdeDiscriminatedField))
    {{
        enum udas = getUDAs!(V, serdeDiscriminatedField);
        static assert (udas.length == 1);
        enum key = udas[0].field;

        static if (__traits(hasMember, S, "putCompiletimeKey"))
        {
            serializer.putCompiletimeKey!key;
        }
        else
        static if (__traits(hasMember, S, "putKeyPtr"))
        {
            serializer.putKeyPtr(key.ptr);
        }
        else
        {
            serializer.putKey(key);
        }

        serializer.putSymbol(udas[0].tag);
    }}

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

            static if(hasUDA!(__traits(getMember, value, member), serdeIgnoreIfAggregate))
            {
                alias pred = serdeGetIgnoreIfAggregate!(__traits(getMember, value, member));
                if (pred(value))
                    continue;
            }

            static if(hasUDA!(__traits(getMember, value, member), serdeIgnoreOutIfAggregate))
            {
                alias pred = serdeGetIgnoreOutIfAggregate!(__traits(getMember, value, member));
                if (pred(value))
                    continue;
            }

            static if(__traits(hasMember, typeof(__traits(getMember, value, member)), "serdeIgnoreOut"))
            {
                if (__traits(getMember, __traits(getMember, value, member), "serdeIgnoreOut"))
                    continue;
            }

            static if(hasUDA!(__traits(getMember, value, member), serdeTransformOut))
            {
                alias f = serdeGetTransformOut!(__traits(getMember, value, member));
                auto val = f(__traits(getMember, value, member));
                alias W  = typeof(val);
            }
            else
            static if (hasField!(V, member))
            {
                auto valPtr = &__traits(getMember, value, member);
                alias W  = typeof(*valPtr);
                ref W val() @trusted @property { return *valPtr; }
            }
            else
            {
                auto val = __traits(getMember, value, member);
                alias W  = typeof(val);
            }

            static if (__traits(hasMember, S, "putCompiletimeKey"))
            {
                serializer.putCompiletimeKey!key;
            }
            else
            static if (__traits(hasMember, S, "putKeyPtr"))
            {
                serializer.putKeyPtr(key.ptr);
            }
            else
            {
                serializer.putKey(key);
            }

            static if(hasUDA!(__traits(getMember, value, member), serdeLikeList))
            {
                static assert(0);
            }
            else
            static if(hasUDA!(__traits(getMember, value, member), serdeLikeStruct))
            {
                static if(is(W == interface) || is(W == class) || is(W : E[T], E, T))
                {
                    if(val is null)
                    {
                        serializer.putNull(IonTypeCode.struct_);
                        continue F;
                    }
                }
                auto valState = serializer.beginStruct(val);
                static if (__traits(hasMember, val, "byKeyValue"))
                {
                    foreach (keyElem; val.byKeyValue)
                    {
                        serializer.putKey(keyElem.key);
                        serializer.serializeValue(keyElem.value);
                    }
                }
                else
                {
                    foreach (key, ref elem; val)
                    {
                        serializer.putKey(key);
                        serializer.serializeValue(elem);
                    }
                }
                serializer.structEnd(valState);
            }
            else
            static if(hasUDA!(__traits(getMember, value, member), serdeProxy))
            {
                serializer.serializeWithProxy!(serdeGetProxy!(__traits(getMember, value, member)))(val);
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

    serializer.structEnd(state);
}

private template serializeWithProxy(Proxy)
{
    void serializeWithProxy(S, V)(scope ref S serializer, auto ref V value)
    {
        static if (is(Proxy == const(char)[]) || is(Proxy == string) || is(Proxy == char[]))
        {
            import mir.format: stringBuf, print, getData;
            static if (__traits(compiles, serializeValue(serializer, stringBuf() << value << getData)))
                serializeValue(serializer, stringBuf() << value << getData);
            else
            {
                serializeValue(serializer, to!Proxy(value));
            }
        }
        else
        {
            static if (isImplicitlyConvertible!(V, Proxy))
            {
                Proxy proxy = value;
                serializeValue(serializer, proxy);
            }
            else
            {
                serializeValue(serializer, to!Proxy(value));
            }
        }
    }
}

/// Struct and class type serialization
void serializeValue(S, V)(scope ref S serializer, auto ref V value)
    if (isAggregateType!V && (!isIterable!V ||  hasFields!V || hasUDA!(V, serdeProxy) && !hasUDA!(V, serdeLikeList)))
{
    import mir.algebraic: Algebraic, isVariant, isNullable, visit;
    import mir.string_map: isStringMap;
    import mir.timestamp: Timestamp;

    static if(is(V == class) || is(V == interface))
    {
        if(value is null)
        {
            serializer.putNull(nullTypeCodeOf!V);
            return;
        }
    }

    static if (isBigInt!V || isDecimal!V || isTimestamp!V || isBlob!V || isClob!V)
    {
        serializer.putValue(value);
        return;
    }
    else
    static if (isStringMap!V)
    {
        auto state = serializer.beginStruct(value);
        auto keys = value.keys;
        foreach (i, ref v; value.values)
        {
            serializer.putKey(keys[i]);
            .serializeValue(serializer, v);
        }
        serializer.structEnd(state);
    }
    else
    static if(hasUDA!(V, serdeLikeList))
    {
        static assert(0);
    }
    else
    static if(hasUDA!(V, serdeLikeStruct))
    {
        static if(is(V == interface) || is(V == class) || is(V : E[T], E, T))
        {
            if(value is null)
            {
                serializer.putNull(nullTypeCodeOf!V);
                continue F;
            }
        }
        auto valState = serializer.beginStruct(value);

        static if (__traits(hasMember, value, "byKeyValue"))
        {
            foreach (keyElem; value.byKeyValue)
            {
                serializer.putKey(keyElem.key);
                serializer.serializeValue(keyElem.value);
            }
        }
        else
        {
            foreach (key, ref elem; value)
            {
                serializer.putKey(key);
                serializer.serializeValue(elem);
            }
        }
        serializer.structEnd(valState);
    }
    else
    static if (is(Unqual!V == Algebraic!TypeSet, TypeSet...))
    {
        enum isSimpleNullable = isNullable!V && V.AllowedTypes.length == 2;
        value.visit!(
            (auto ref v) {
                alias A = typeof(v);
                static if (serdeHasAlgebraicAnnotation!A && !isSimpleNullable)
                {
                    auto wrapperState = serializer.annotationWrapperBegin;
                    auto annotationsState = serializer.annotationsBegin;
                    static if (__traits(hasMember, S, "putCompiletimeAnnotation"))
                        serializer.putCompiletimeAnnotation!(serdeGetAlgebraicAnnotation!A);
                    else
                    static if (__traits(hasMember, S, "putAnnotationPtr"))
                        serializer.putAnnotationPtr(serdeGetAlgebraicAnnotation!A.ptr);
                    else
                        serializer.putAnnotation(serdeGetAlgebraicAnnotation!A);
                    serializeAnnotatedValue(serializer, v, annotationsState, wrapperState);
                }
                else
                {
                    static if (is(immutable A == immutable typeof(null)))
                        serializer.putNull(nullTypeCodeOf!(V.AllowedTypes[1]));
                    else
                        serializeValue(serializer, v);
                }
            },
            throwCannotSerializeVoid,
        );
        return;
    }
    else
    static if(staticIndexOf!("serialize", __traits(allMembers, V)) >= 0)
    {
        alias soverloads = getSerializeOverloads!(S, V);
        static if (__traits(hasMember, soverloads, "best") || !__traits(hasMember, soverloads, "script"))
        {
            static if (__traits(compiles, value.serialize(serializer)) || !hasUDA!(V, serdeProxy))
                value.serialize(serializer);
            else
                serializeValue(serializer, to!(serdeGetProxy!V)(value));

        }
        else
        static if (__traits(hasMember, soverloads, "script"))
        {
            import mir.ser.interfaces: SerializerWrapper;
            scope wserializer = new SerializerWrapper!S(serializer);
            auto iserializer = wserializer.ISerializer;
            value.serialize(iserializer);
        }
        return;
    }
    else
    static if (hasUDA!(V, serdeProxy))
    {
        serializer.serializeWithProxy!(serdeGetProxy!V)(value);
        return;
    }
    else
    static if (is(typeof(Timestamp(V.init))))
    {
        serializer.putValue(Timestamp(value));
        return;
    }
    else
    static if (serdeGetAnnotationMembersOut!V.length)
    {
        auto wrapperState = serializer.annotationWrapperBegin;
        auto annotationsState = serializer.annotationsBegin;
        serializeAnnotatedValue(serializer, value, annotationsState, wrapperState);
        return;
    }
    else
    static if (isStdNullable!V)
    {
        if(value.isNull)
        {
            serializer.putNull(nullTypeCodeOf!(typeof(value.get())));
            return;
        }
        return serializeValue(serializer, value.get);
    }
    else
    {
        return serializeValueImpl(serializer, value);
    }
}

private template getSerializeOverloads(S, alias value)
{
    import mir.ser.interfaces: ISerializer;
    static foreach (i, so; __traits(getOverloads, value, "serialize"))
    {
        static if (!__traits(isTemplate, value.serialize))
        {
            static if (is(Parameters!so[0] == S))
            {
                enum best = i;
            }
            else
            {
                static if (is(Parameters!so[0] == ISerializer))
                {
                    enum script = i;
                }
            }
        }
    }
}

/// Mir types
version(mir_ion_test)
unittest
{
    import mir.bignum.integer;
    import mir.date;
    import mir.ser.json: serializeJson;
    import mir.ser.text: serializeText;
    assert(Date(2021, 4, 24).serializeJson == `"2021-04-24"`);
    assert(BigInt!2(123).serializeJson == `123`);
    assert(Date(2021, 4, 24).serializeText == `2021-04-24`);
    assert(BigInt!2(123).serializeText == `123`);
}

/// Alias this support
version(mir_ion_test)
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

    import mir.ser.json: serializeJson;
    assert(C(4, S(3)).serializeJson == `{"u":3,"b":4}`);
}

/// Custom `serialize`
version(mir_ion_test)
unittest
{
    struct S
    {
        void serialize(S)(scope ref S serializer) const
        {
            auto state = serializer.structBegin(1);
            serializer.putKey("foo");
            serializer.putValue("bar");
            serializer.structEnd(state);
        }
    }

    import mir.ser.json: serializeJson;
    assert(serializeJson(S()) == `{"foo":"bar"}`);
}

/// Nullable type serialization
version(mir_ion_test)
unittest
{
    import mir.ser.json: serializeJson;
    import mir.algebraic: Nullable;

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
    assert(t.serializeJson == `{"str":"","nested":{}}`);
    t.str = "txt";
    t.nested = Nested(123);
    assert(t.serializeJson == `{"str":"txt","nested":{"f":123.0}}`);
}

///
version(mir_ion_test)
unittest
{
    import mir.algebraic;
    import mir.small_string;

    @serdeAlgebraicAnnotation("$a")
    static struct B
    {
        double number;
    }

    static struct A
    {
        @serdeAnnotation
        SmallString!32 id1;

        @serdeAnnotation
        string[] id2;

        // Alias this is transparent for members and can catch algebraic annotation
        alias c this;
        B c;

        string s;
    }


    static assert(serdeHasAlgebraicAnnotation!B);
    static assert(serdeGetAlgebraicAnnotation!B == "$a");
    static assert(serdeHasAlgebraicAnnotation!A);
    static assert(serdeGetAlgebraicAnnotation!A == "$a");

    @serdeAlgebraicAnnotation("$c")
    static struct C
    {
    }

    @serdeAlgebraicAnnotation("$E")
    enum E { e1, e2 }

    @serdeAlgebraicAnnotation("$S")
    static struct S
    {
        @serdeAnnotation
        string sid;

        @serdeAnnotation
        string sid2;

        alias Data = Nullable!(A, C, long, E);

        alias data this;

        Data data;
    }


    @serdeAlgebraicAnnotation("$S2")
    static struct S2
    {
        alias Data = Nullable!(A, C, long);

        alias data this;

        Data data;
    }


    import mir.ion.conv: ion2text;
    import mir.ser.ion: serializeIon;
    import mir.ser.text: serializeText;

    () {
        Nullable!S value = S("LIBOR", "S", S.Data(A("Rate".SmallString!32, ["USD", "GBP"])));
        static immutable text = `LIBOR::S::$a::Rate::USD::GBP::{number:nan,s:null.string}`;
        assert(value.serializeText == text);
        auto binary = value.serializeIon;
        assert(binary.ion2text == text);
        import mir.deser.ion: deserializeIon;
        assert(binary.deserializeIon!S.serializeText == text);
    } ();

    () {
        S value = S("LIBOR", "S", S.Data(E.e2));
        static immutable text = `LIBOR::S::$E::e2`;
        assert(value.serializeText == text);
        auto binary = value.serializeIon;
        assert(binary.ion2text == text);
        import mir.deser.ion: deserializeIon;
        assert(binary.deserializeIon!S.serializeText == text);
    } ();

    () {
        auto value = S2(S2.Data(A("Rate".SmallString!32, ["USD", "GBP"])));
        static immutable text = `$a::Rate::USD::GBP::{number:nan,s:null.string}`;
        auto binary = value.serializeIon;
        assert(binary.ion2text == text);
        import mir.deser.ion: deserializeIon;
        assert(binary.deserializeIon!S2.serializeText == text);
    } ();

    () {
        auto value = S("USD", "S", S.Data(3));
        static immutable text = `USD::S::3`;
        auto binary = value.serializeIon;
        assert(binary.ion2text == text, binary.ion2text);
        import mir.deser.ion: deserializeIon;
        assert(binary.deserializeIon!S.serializeText == text);
    } ();
}

/++
+/
auto beginList(S, V)(scope ref S serializer, ref V value)
{
    static if (__traits(compiles, serializer.listBegin))
    {
        return serializer.listBegin;
    }
    else
    {
        import mir.primitives: walkLength;
        return serializer.listBegin(value.walkLength);
    }
}

/++
+/
auto beginSexp(S, V)(scope ref S serializer, ref V value)
{
    static if (__traits(compiles, serializer.sexpBegin))
    {
        return serializer.sexpBegin;
    }
    else
    {
        import mir.primitives: walkLength;
        return serializer.sexpBegin(value.walkLength);
    }
}

/++
+/
auto beginStruct(S, V)(scope ref S serializer, ref V value)
{
    static if (__traits(compiles, serializer.structBegin))
    {
        return serializer.structBegin;
    }
    else
    {
        import mir.primitives: walkLength;
        return serializer.structBegin(value.walkLength);
    }
}

version (Have_mir_bloomberg)
{
    import mir.ser.bloomberg : BloombergElement;
    ///
    void serializeValue(S)(scope ref S serializer, const(BloombergElement)* value)
    {
        import mir.ser.bloomberg : impl = serializeValue;
        return impl(serializer, value);
    }
}
