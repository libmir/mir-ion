/++
+/
module mir.deser.json;

public import mir.serde;
import mir.algebraic: Algebraic;
import mir.deser.low_level: hasDiscriminatedField;
import mir.string_map: isStringMap;
import std.traits: hasUDA, isAggregateType;

version(LDC) import ldc.attributes: optStrategy;
else private struct optStrategy { string opt; }

private template isSomeMap(T)
{
    static if (__traits(hasMember, T, "_serdeRecursiveAlgebraic"))
        enum isSomeMap = true;
    else
    static if (is(T : K[V], K, V))
        enum isSomeMap = true;
    else
    static if (isStringMap!T)
        enum isSomeMap = true;
    else
    static if (is(T == Algebraic!Types, Types...))
    {
        import std.meta: anySatisfy;
        enum isSomeMap = anySatisfy!(.isSomeMap, T.AllowedTypes);
    }
    else
    static if (is(T : U[], U))
        enum isSomeMap = .isSomeMap!U;
    else
        enum isSomeMap = hasDiscriminatedField!T;
}

unittest
{
    import mir.algebraic_alias.json;
    static assert (isSomeMap!(JsonAlgebraic[]));
}

private template deserializeJsonImpl(bool file)
{
    template deserializeJsonImpl(T)
    {
        T deserializeJsonImpl()(scope const(char)[] text)
        {
            T value;
            deserializeJsonImpl(value, text);
            return value;
        }

        // @optStrategy("optsize")
        void deserializeJsonImpl(scope ref T value, scope const(char)[] text)
        {
            static if (isSomeMap!T)
            {
                static if (file)
                    static assert(0, "Can't deserialize a map-like type from a file");
                return deserializeDynamicJson(value, text);
            }
            else
            {
                import mir.deser: hasDeserializeFromIon, deserializeValue, DeserializationParams, TableKind;
                import mir.ion.exception: IonException, ionException;
                import mir.ion.exception: ionErrorMsg;
                import mir.ion.internal.data_holder;
                import mir.ion.internal.stage4_s;
                import mir.ion.value: IonDescribedValue, IonValue;
                import mir.serde: serdeGetDeserializationKeysRecurse, SerdeMirException, SerdeException;
                import mir.string_table: createTable;

                enum nMax = 4096u * 4;
                // enum nMax = 64u;
                static if (hasDeserializeFromIon!T)
                    enum keys = string[].init;
                else
                    enum keys = serdeGetDeserializationKeysRecurse!T;

                alias createTableChar = createTable!char;
                static immutable table = createTableChar!(keys, false);

                // nMax * 4 is enough. We use larger multiplier to reduce memory allocation count
                auto tapeHolder = ionTapeHolder!(nMax * 8);
                tapeHolder.initialize;
                auto errorInfo = () @trusted { return singleThreadJson!nMax(table, tapeHolder, text); } ();
                if (errorInfo.code)
                {
                    static if (__traits(compiles, () @nogc { throw new Exception(""); }))
                        throw new SerdeMirException(errorInfo.code.ionErrorMsg, ". location = ", errorInfo.location, ", last input key = ", errorInfo.key);
                    else
                        throw errorInfo.code.ionException;
                }

                IonDescribedValue ionValue;

                if (auto error = IonValue(tapeHolder.data).describe(ionValue))
                    throw error.ionException;

                auto params = DeserializationParams!(TableKind.compiletime)(ionValue); 
                if (auto exception = deserializeValue!keys(params, value))
                    throw exception;
            }
        }
    }
}

/++
Deserialize json string to a type trying to do perform less memort allocations.
+/
alias deserializeJson = deserializeJsonImpl!false;

/++
Deserialize json string to a type
+/
T deserializeDynamicJson(T)(scope const(char)[] text)
{
    T value;
    deserializeDynamicJson(value, text);
    return value;
}

///ditto
void deserializeDynamicJson(T)(scope ref T value, scope const(char)[] text)
{
    import mir.ion.conv: json2ion;
    import mir.deser.ion: deserializeIon;
    return deserializeIon!T(value, text.json2ion);
}
