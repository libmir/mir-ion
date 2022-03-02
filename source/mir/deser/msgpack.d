/++
$(H4 High level Msgpack deserialization API)

Macros:
IONREF = $(REF_ALTTEXT $(TT $2), $2, mir, ion, $1)$(NBSP)
+/
module mir.deser.msgpack;
import mir.algebraic : Nullable;
import mir.ser.msgpack : MessagePackFmt;
import mir.ion.exception : IonErrorCode, ionException, ionErrorMsg;
import mir.lob : Blob;

struct MsgpackExtension
{
    Blob data;
    ubyte type;
}

private static T unpackMsgPackVal(T)(scope ref const(ubyte)[] data)
{
    import std.traits : Unsigned;
    alias UT = Unsigned!T;

    if (data.length < UT.sizeof)
    {
        version (D_Exceptions)
            throw IonErrorCode.unexpectedEndOfData.ionException;
        else
            assert(0, IonErrorCode.unexpectedEndOfData.ionErrorMsg);
    }

    UT ret = (cast(UT[1])cast(ubyte[UT.sizeof])data[0 .. UT.sizeof])[0];

    version (LittleEndian)
    {
        import core.bitop : bswap, byteswap;
        static if (T.sizeof >= 4) {
            ret = bswap(ret);
        } else static if (T.sizeof == 2) {
            ret = byteswap(ret);
        }
    }

    data = data[UT.sizeof .. $];
    return cast(typeof(return))ret;
}

@safe @nogc pure
private static void advance(scope ref const(ubyte)[] data, size_t newStart) {
    if (data.length < newStart)
    {
        version (D_Exceptions)
            throw IonErrorCode.unexpectedEndOfData.ionException;
        else
            assert(0, IonErrorCode.unexpectedEndOfData.ionErrorMsg);
    }

    data = data[newStart .. $];
}

private static void readMap(S)(ref S serializer, scope ref const(ubyte)[] data, size_t length)
{
    auto state = serializer.structBegin();
    foreach(i; 0 .. length)
    {
        if (data.length < 1)
        {
            version (D_Exceptions)
                throw IonErrorCode.unexpectedEndOfData.ionException;
            else
                assert(0, IonErrorCode.unexpectedEndOfData.ionErrorMsg);
        }

        MessagePackFmt keyType = cast(MessagePackFmt)data[0];
        data.advance(1);
        uint keyLength = 0;
        sw: switch (keyType)
        {
            // fixstr
            static foreach(v; MessagePackFmt.fixstr .. MessagePackFmt.fixstr + 0x20)
            {
                case v:
                    keyLength = (v - MessagePackFmt.fixstr);
                    break sw;
            }

            case MessagePackFmt.str8:
            {
                keyLength = unpackMsgPackVal!ubyte(data);
                break sw;
            }

            case MessagePackFmt.str16:
            {
                keyLength = unpackMsgPackVal!ushort(data);
                break sw;
            }

            case MessagePackFmt.str32:
            {
                keyLength = unpackMsgPackVal!uint(data);
                break sw;
            }

            default:
                version (D_Exceptions)
                    throw IonErrorCode.expectedStringValue.ionException;
                else
                    assert(0, IonErrorCode.expectedStringValue.ionErrorMsg);
        }

        if (data.length < keyLength)
        {
            version (D_Exceptions)
                throw IonErrorCode.unexpectedEndOfData.ionException;
            else
                assert(0, IonErrorCode.unexpectedEndOfData.ionErrorMsg);
        }

        serializer.putKey((() @trusted => cast(const(char[]))data[0 .. keyLength])());
        data.advance(keyLength);

        MessagePackFmt valueType = cast(MessagePackFmt)data[0];
        data.advance(1);
        handleElement(serializer, valueType, data);
    }
    serializer.structEnd(state);
}

private static void readList(S)(ref S serializer, scope ref const(ubyte)[] data, size_t length)
{
    auto state = serializer.listBegin(length);
    foreach(i; 0 .. length)
    {
        if (data.length < 1)
        {
            version (D_Exceptions)
                throw IonErrorCode.unexpectedEndOfData.ionException;
            else
                assert(0, IonErrorCode.unexpectedEndOfData.ionErrorMsg);
        }

        MessagePackFmt type = cast(MessagePackFmt)data[0];
        data.advance(1);
        serializer.elemBegin; handleElement(serializer, type, data);
    }
    serializer.listEnd(state);
}

private static void readExt(S)(ref S serializer, scope ref const(ubyte)[] data, size_t length)
{
    if (data.length < (length + 1)) 
    {
        version (D_Exceptions)
            throw IonErrorCode.unexpectedEndOfData.ionException;
        else
            assert(0, IonErrorCode.unexpectedEndOfData.ionErrorMsg);
    }
    
    ubyte ext_type = data[0];
    data.advance(1);

    if (ext_type == cast(ubyte)-1)
    {
        import mir.timestamp : Timestamp;
        if (length == 4)
        {
            uint unixTime = unpackMsgPackVal!uint(data);
            serializer.putValue(Timestamp.fromUnixTime(unixTime));
        }
        else if (length == 8)
        {
            ulong packedUnixTime = unpackMsgPackVal!ulong(data);
            ulong nanosecs = packedUnixTime >> 34;
            ulong seconds = packedUnixTime & 0x3ffffffff;
            auto time = Timestamp.fromUnixTime(seconds);
            time.fractionExponent = -9;
            time.fractionCoefficient = nanosecs;
            time.precision = Timestamp.Precision.fraction;
            serializer.putValue(time);
        }
        else if (length == 12)
        {
            uint nanosecs = unpackMsgPackVal!uint(data);
            long seconds = unpackMsgPackVal!long(data);
            auto time = Timestamp.fromUnixTime(seconds);
            time.fractionExponent = -9;
            time.fractionCoefficient = nanosecs;
            time.precision = Timestamp.Precision.fraction;
            serializer.putValue(time);
        }
    }
    else
    {
        // XXX: How do we want to serialize exts that we don't recognize?
        if (data.length < length)
        {
            version (D_Exceptions)
                throw IonErrorCode.unexpectedEndOfData.ionException;
            else
                assert(0, IonErrorCode.unexpectedEndOfData.ionErrorMsg);
        }
        auto state = serializer.structBegin();
        serializer.putKey("type");
        serializer.putValue(ext_type);
        serializer.putKey("data");
        serializer.putValue(Blob(data[0 .. length]));
        serializer.structEnd(state);
        data.advance(length);
    }
}

private static void readStr(S)(ref S serializer, scope ref const(ubyte)[] data, size_t length)
{
    if (data.length < length) 
    {
        version (D_Exceptions)
            throw IonErrorCode.unexpectedEndOfData.ionException;
        else
            assert(0, IonErrorCode.unexpectedEndOfData.ionErrorMsg);
    }
    serializer.putValue((() @trusted => cast(const(char)[])data[0 .. length])());
    data.advance(length);
}

private static void readBin(S)(ref S serializer, scope ref const(ubyte)[] data, size_t length)
{
    if (data.length < length)
    {
        version (D_Exceptions)
            throw IonErrorCode.unexpectedEndOfData.ionException;
        else
            assert(0, IonErrorCode.unexpectedEndOfData.ionErrorMsg);
    }
    serializer.putValue(Blob(data[0 .. length]));
    data.advance(length);
}

private static void readFloat(S)(ref S serializer, scope ref const(ubyte)[] data, size_t length)
{
    import core.bitop : bswap;

    if (data.length < length)
    {
        version (D_Exceptions)
            throw IonErrorCode.unexpectedEndOfData.ionException;
        else
            assert(0, IonErrorCode.unexpectedEndOfData.ionErrorMsg);
    }

    assert(length == 4 || length == 8);

    if (length == 4)
    {
        uint v = unpackMsgPackVal!uint(data);
        serializer.putValue((() @trusted => *cast(float*)&v)());
    }
    else if (length == 8)
    {
        // manually construct the ulong
        ulong v = unpackMsgPackVal!ulong(data);
        serializer.putValue((() @trusted => *cast(double*)&v)());
    }
}

@safe pure
private static void handleElement(S)(ref S serializer, MessagePackFmt type, scope ref const(ubyte)[] data)
{
    import mir.bignum.integer : BigInt;
    sw: switch (type) 
    {
        // fixint
        static foreach(v; MessagePackFmt.fixint .. (1 << 7))
        {
            case v:
                // work around a weird bug -- passing v will
                // cause some weird shenanigans to happen here
                serializer.putValue(cast(ubyte)type);
                break sw;
        }

        // fixnint
        static foreach(v; MessagePackFmt.fixnint .. 0x100)
        {
            case v:
                // but of course, passing v here Just Werks (TM)
                serializer.putValue(cast(byte)v);
                break sw;
        }

        // fixmap
        static foreach(v; MessagePackFmt.fixmap .. MessagePackFmt.fixmap + 0x10)
        {
            case v:
                readMap(serializer, data, v & 0x0F);
                break sw;
        }

        // fixarray
        static foreach(v; MessagePackFmt.fixarray ..  MessagePackFmt.fixarray + 0x10)
        {
            case v:
                readList(serializer, data, (v - MessagePackFmt.fixarray));
                break sw;
        }
        
        // fixext
        static foreach(v; MessagePackFmt.fixext1 .. MessagePackFmt.fixext16 + 1)
        {
            case v:
                readExt(serializer, data, 1 << (v - MessagePackFmt.fixext1));
                break sw;
        }

        // fixstr
        static foreach(v; MessagePackFmt.fixstr .. MessagePackFmt.fixstr + 0x20)
        {
            case v:
                readStr(serializer, data, (v - MessagePackFmt.fixstr));
                break sw;
        }


        case MessagePackFmt.uint8:
            serializer.putValue(data[0]);
            data.advance(1);
            break sw;
        
        case MessagePackFmt.uint16:
            serializer.putValue(unpackMsgPackVal!ushort(data));
            break sw;

        case MessagePackFmt.uint32:
            serializer.putValue(unpackMsgPackVal!uint(data));
            break sw;
        
        case MessagePackFmt.uint64:
            serializer.putValue(unpackMsgPackVal!ulong(data));
            break sw;

        case MessagePackFmt.int8:
            serializer.putValue(cast(byte)data[0]);
            data.advance(1);
            break sw;
        
        case MessagePackFmt.int16:
            serializer.putValue(unpackMsgPackVal!short(data));
            break sw;

        case MessagePackFmt.int32:
            serializer.putValue(unpackMsgPackVal!int(data));
            break sw;

        case MessagePackFmt.int64:
            serializer.putValue(unpackMsgPackVal!long(data));
            break sw;

        case MessagePackFmt.map16:
            ushort mapLength = unpackMsgPackVal!ushort(data);
            readMap(serializer, data, mapLength);
            break sw;
        
        case MessagePackFmt.map32:
            uint mapLength = unpackMsgPackVal!uint(data);
            readMap(serializer, data, mapLength);
            break sw;

        case MessagePackFmt.array16:
            ushort arrayLength = unpackMsgPackVal!ushort(data);
            readList(serializer, data, arrayLength);
            break sw;

        case MessagePackFmt.array32:
            uint arrayLength = unpackMsgPackVal!uint(data);
            readList(serializer, data, arrayLength);
            break sw;

        case MessagePackFmt.str8:
            ubyte strLength = data[0];
            data.advance(1);
            readStr(serializer, data, strLength);
            break sw;
        
        case MessagePackFmt.str16:
            ushort strLength = unpackMsgPackVal!ushort(data);
            readStr(serializer, data, strLength);
            break sw;

        case MessagePackFmt.str32:
            uint strLength = unpackMsgPackVal!uint(data);
            readStr(serializer, data, strLength);
            break sw;

        case MessagePackFmt.nil:
            serializer.putValue(null);
            break sw;

        case MessagePackFmt.true_:
        case MessagePackFmt.false_:
            serializer.putValue(type == MessagePackFmt.true_ ? true : false);
            break sw;

        case MessagePackFmt.bin8:
            ubyte binLength = data[0];
            data.advance(1);
            readBin(serializer, data, binLength);
            break sw;

        case MessagePackFmt.bin16:
            ushort binLength = unpackMsgPackVal!ushort(data);
            readBin(serializer, data, binLength);
            break sw;

        case MessagePackFmt.bin32:
            uint binLength = unpackMsgPackVal!uint(data);
            readBin(serializer, data, binLength);
            break sw;
            
        case MessagePackFmt.ext8:
            ubyte extLength = data[0];
            data.advance(1);
            readExt(serializer, data, extLength);
            break sw;

        case MessagePackFmt.ext16:
            ushort extLength = unpackMsgPackVal!ushort(data);
            readExt(serializer, data, extLength);
            break sw;

        case MessagePackFmt.ext32:
            uint extLength = unpackMsgPackVal!uint(data);
            readExt(serializer, data, extLength);
            break sw;

        case MessagePackFmt.float32:
        case MessagePackFmt.float64:
            readFloat(serializer, data, type == MessagePackFmt.float32 ? 4 : 8);
            break sw;

        default:
            version (D_Exceptions)
                throw IonErrorCode.cantParseValueStream.ionException;
            else
                assert(0, IonErrorCode.cantParseValueStream.ionErrorMsg);
    }
}

///
struct MsgpackValueStream
{
    const(ubyte)[] data;

    // private alias DG = int delegate(IonErrorCode error, MsgpackDescribedValue value) @safe pure nothrow @nogc;
    // private alias EDG = int delegate(MsgpackDescribedValue value) @safe pure @nogc;

    void serialize(S)(ref S serializer)
    {
        auto window = data;
        while (window.length)
        {
            MessagePackFmt type = cast(MessagePackFmt)window[0];
            window = window[1 .. $];
            handleElement(serializer, type, window);
        }
    }
}

///
void deserializeMsgpack(T)(ref T value, scope const(ubyte)[] data)
{
    import mir.deser.ion : deserializeIon;
    import mir.ion.conv : msgpack2ion;
    auto ion = msgpack2ion(data);
    return deserializeIon!T(value, ion);
}

///
T deserializeMsgpack(T)(scope const(ubyte)[] data)
{
    T value;
    deserializeMsgpack!T(value, data);
    return value;
}

/// Test round-trip serialization/deserialization of signed integral types
@safe pure
version (mir_ion_test)
unittest
{
    import mir.ser.msgpack : serializeMsgpack;

    // Bytes
    assert(serializeMsgpack(byte.min).deserializeMsgpack!byte == byte.min);
    assert(serializeMsgpack(byte.max).deserializeMsgpack!byte == byte.max);
    assert(serializeMsgpack(byte(-32)).deserializeMsgpack!byte == -32);

    // Shorts
    assert(serializeMsgpack(short.min).deserializeMsgpack!short == short.min);
    assert(serializeMsgpack(short.max).deserializeMsgpack!short == short.max);

    // Integers
    assert(serializeMsgpack(int.min).deserializeMsgpack!int == int.min);
    assert(serializeMsgpack(int.max).deserializeMsgpack!int == int.max);

    // Longs
    assert(serializeMsgpack(long.min).deserializeMsgpack!long == long.min);
    assert(serializeMsgpack(long.max).deserializeMsgpack!long == long.max);
}

/// Test round-trip serialization/deserialization of unsigned integral types
@safe pure
version (mir_ion_test)
unittest
{
    import mir.ser.msgpack : serializeMsgpack;

    // Unsigned bytes
    assert(serializeMsgpack(ubyte.min).deserializeMsgpack!ubyte == ubyte.min);
    assert(serializeMsgpack(ubyte.max).deserializeMsgpack!ubyte == ubyte.max);

    // Unsigned shorts
    assert(serializeMsgpack(ushort.min).deserializeMsgpack!ushort == ushort.min);
    assert(serializeMsgpack(ushort.max).deserializeMsgpack!ushort == ushort.max);

    // Unsigned integers
    assert(serializeMsgpack(uint.min).deserializeMsgpack!uint == uint.min);
    assert(serializeMsgpack(uint.max).deserializeMsgpack!uint == uint.max);

    // Unsigned logns
    assert(serializeMsgpack(ulong.min).deserializeMsgpack!ulong == ulong.min);
    assert(serializeMsgpack(ulong.max).deserializeMsgpack!ulong == ulong.max);

    // BigInt
    import mir.bignum.integer : BigInt;
    assert(serializeMsgpack(BigInt!2(0xDEADBEEF)).deserializeMsgpack!long == 0xDEADBEEF);
}

/// Test round-trip serialization/deserialization of null
@safe pure
version (mir_ion_test)
unittest
{
    import mir.ser.msgpack : serializeMsgpack;

    assert(serializeMsgpack(null).deserializeMsgpack!(typeof(null)) == null);
}

/// Test round-trip serialization/deserialization of booleans
@safe pure
version (mir_ion_test)
unittest
{
    import mir.ser.msgpack : serializeMsgpack;

    assert(serializeMsgpack(true).deserializeMsgpack!bool == true);
    assert(serializeMsgpack(false).deserializeMsgpack!bool == false);
}

/// Test round-trip serialization/deserialization of strings
@safe pure
version (mir_ion_test)
unittest
{
    import std.array : replicate;
    import mir.ser.msgpack : serializeMsgpack;

    assert("foobar".serializeMsgpack.deserializeMsgpack!string == "foobar");
    assert("bazfoo".serializeMsgpack.deserializeMsgpack!string == "bazfoo");

    {
        auto str = "a".replicate(32);
        assert(serializeMsgpack(str).deserializeMsgpack!string == str);
    }

    {
        auto str = "a".replicate(ushort.max);
        assert(serializeMsgpack(str).deserializeMsgpack!string == str);
    }

    {
        auto str = "a".replicate(ushort.max + 1);
        assert(serializeMsgpack(str).deserializeMsgpack!string == str);
    }
}

/// Test round-trip serializing/deserialization blobs / clobs
@safe pure
version(mir_ion_test)
unittest
{
    import mir.lob : Blob, Clob;
    import mir.ser.msgpack : serializeMsgpack;
    import std.array : replicate;

    // Blobs
    // These need to be trusted because we cast const(char)[] to ubyte[] (which is fine here!)
    () @trusted {
        auto de = "\xde".replicate(32);
        auto blob = Blob(cast(ubyte[])de);
        assert(serializeMsgpack(blob).deserializeMsgpack!Blob == blob);
    } ();
    
    () @trusted {
        auto de = "\xde".replicate(ushort.max);
        auto blob = Blob(cast(ubyte[])de);
        assert(serializeMsgpack(blob).deserializeMsgpack!Blob == blob);
    } ();

    () @trusted {
        auto de = "\xde".replicate(ushort.max + 1);
        auto blob = Blob(cast(ubyte[])de);
        assert(serializeMsgpack(blob).deserializeMsgpack!Blob == blob);
    } ();

    // Clobs (serialized just as regular strings here)
    () @trusted {
        auto de = "\xde".replicate(32);
        auto clob = Clob(de);
        assert(serializeMsgpack(clob).deserializeMsgpack!string == clob.data);
    } ();
}

/// Test round-trip serialization/deserialization of arrays
@safe pure
version (mir_ion_test)
unittest
{
    import mir.ser.msgpack : serializeMsgpack;

    {
        auto arr = [["foo"], ["bar"], ["baz"]];
        assert(serializeMsgpack(arr).deserializeMsgpack!(typeof(arr)) == arr);
    }

    {
        auto arr = [0xDEADBEEF, 0xCAFEBABE, 0xAAAA_AAAA];
        assert(serializeMsgpack(arr).deserializeMsgpack!(typeof(arr)) == arr);
    }

    {
        auto arr = ["foo", "bar", "baz"];
        assert(serializeMsgpack(arr).deserializeMsgpack!(typeof(arr)) == arr);
    }

    {
        auto arr = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17];
        assert(serializeMsgpack(arr).deserializeMsgpack!(typeof(arr)) == arr);
    }
}

@safe pure
version (mir_ion_test)
unittest
{
    import mir.ser.msgpack : serializeMsgpack;
    assert((0.0f).serializeMsgpack.deserializeMsgpack!(float) == 0.0f);
    assert((0.0).serializeMsgpack.deserializeMsgpack!(double) == 0.0);

    assert((float.min_normal).serializeMsgpack.deserializeMsgpack!(float) == float.min_normal);
    assert((float.max).serializeMsgpack.deserializeMsgpack!(float) == float.max);
    assert((double.min_normal).serializeMsgpack.deserializeMsgpack!(double) == double.min_normal);
    assert((double.max).serializeMsgpack.deserializeMsgpack!(double) == double.max);
}

@safe pure
version (mir_ion_test)
unittest
{
    import mir.ser.msgpack : serializeMsgpack;
    import mir.timestamp : Timestamp;
    assert(Timestamp(2022, 2, 14).serializeMsgpack.deserializeMsgpack!(Timestamp) == Timestamp(2022, 2, 14, 0, 0, 0));
    assert(Timestamp(2038, 1, 19, 3, 14, 7).serializeMsgpack.deserializeMsgpack!Timestamp == Timestamp(2038, 1, 19, 3, 14, 7));
    assert(Timestamp(2299, 12, 31, 23, 59, 59).serializeMsgpack.deserializeMsgpack!Timestamp == Timestamp(2299, 12, 31, 23, 59, 59, -9, 0));
    assert(Timestamp(2514, 5, 30, 1, 53, 5).serializeMsgpack.deserializeMsgpack!Timestamp == Timestamp(2514, 5, 30, 1, 53, 5, -9, 0));
    assert(Timestamp(2000, 7, 8, 2, 3, 4, -3, 16).serializeMsgpack.deserializeMsgpack!(Timestamp) == Timestamp(2000, 7, 8, 2, 3, 4, -9, 16000000));
}

/// Test serializing maps (structs)
@safe pure
version(mir_ion_test)
unittest
{
    import mir.ser.msgpack : serializeMsgpack;
    static struct Book
    {
        string title;
        bool wouldRecommend;
        string description;
        uint numberOfNovellas;
        double price;
        float weight;
        string[] tags;
    }

    Book book = Book("A Hero of Our Time", true, "", 5, 7.99, 6.88, ["russian", "novel", "19th century"]);

    assert(serializeMsgpack(book).deserializeMsgpack!(Book) == book);
}

/// Test round-trip serialization/deserialization of a large map
@safe pure
version(mir_ion_test)
unittest
{
    import mir.ser.msgpack : serializeMsgpack;
    static struct HugeStruct
    {
        bool a;
        bool b;
        bool c;
        bool d;
        bool e;
        string f;
        string g;
        string h;
        string i;
        string j;
        int k;
        int l;
        int m;
        int n;
        int o;
        long p;
    }

    HugeStruct s = HugeStruct(true, true, true, true, true, "", "", "", "", "", 123, 456, 789, 123, 456, 0xDEADBEEF);
    assert(serializeMsgpack(s).deserializeMsgpack!HugeStruct == s);
}

/// Test excessively large array
@safe pure
version(mir_ion_test)
unittest
{
    import mir.ser.msgpack : serializeMsgpack;
    static struct HugeArray
    {
        ubyte[] arg;

        void serialize(S)(ref S serializer) const
        {
            auto state = serializer.structBegin();
            serializer.putKey("arg");
            auto arrayState = serializer.listBegin(); 
            foreach(i; 0 .. (ushort.max + 1))
            {
                serializer.elemBegin; serializer.putValue(ubyte(0));
            }
            serializer.listEnd(arrayState);
            serializer.structEnd(state);
        }
    }

    auto arr = HugeArray();
    assert((serializeMsgpack(arr).deserializeMsgpack!HugeArray).arg.length == ushort.max + 1);
}

/// Test excessively large map
@safe pure
version(mir_ion_test)
unittest
{
    import mir.serde : serdeAllowMultiple;
    import mir.ser.msgpack : serializeMsgpack;
    static struct BFM // Big Freakin' Map
    {
        @serdeAllowMultiple
        ubyte asdf;

        void serialize(S)(ref S serializer) const
        {
            auto state = serializer.structBegin();
            foreach (i; 0 .. (ushort.max + 1))
            {
                serializer.putKey("asdf");
                serializer.putValue(ubyte(0));
            }
            serializer.structEnd(state);
        }
    }

    auto map = BFM();
    assert(serializeMsgpack(map).deserializeMsgpack!BFM == map);
}

/// Test map with varying key lengths
@safe pure
version(mir_ion_test)
unittest
{
    import mir.ser.msgpack : serializeMsgpack;
    import std.array : replicate;
    ubyte[string] map;
    map["a".replicate(32)] = 0xFF;
    map["b".replicate(ubyte.max + 1)] = 0xFF;
    map["c".replicate(ushort.max + 1)] = 0xFF;

    assert(serializeMsgpack(map).deserializeMsgpack!(typeof(map)) == map);
}

/// Test deserializing an extension type
@safe pure
version(mir_ion_test)
unittest
{
    import mir.lob : Blob;

    {
        const(ubyte)[] data = [0xc7, 0x01, 0x02, 0xff];
        MsgpackExtension ext = MsgpackExtension(Blob([0xff]), 0x02);
        assert(data.deserializeMsgpack!MsgpackExtension == ext);
    }

    {
        const(ubyte)[] data = [0xc8, 0x00, 0x01, 0x02, 0xff];
        MsgpackExtension ext = MsgpackExtension(Blob([0xff]), 0x02);
        assert(data.deserializeMsgpack!MsgpackExtension == ext);
    }

    {
        const(ubyte)[] data = [0xc9, 0x00, 0x00, 0x00, 0x01, 0x02, 0xff];
        MsgpackExtension ext = MsgpackExtension(Blob([0xff]), 0x02);
        assert(data.deserializeMsgpack!MsgpackExtension == ext);
    }
}

@safe pure
version(mir_ion_test) unittest
{
    static struct S
    {
        bool compact;
        int schema;
    }
    const(ubyte)[] data = [0x82, 0xa7, 0x63, 0x6f, 0x6d, 0x70, 0x61, 0x63, 0x74, 0xc3, 0xa6, 0x73, 0x63, 0x68, 0x65, 0x6d, 0x61, 0x04];
    assert(data.deserializeMsgpack!S == S(true, 4));
}