/++
$(H4 High level CBOR serialization API)

Macros:
IONREF = $(REF_ALTTEXT $(TT $2), $2, mir, ion, $1)$(NBSP)
+/
module mir.ser.cbor;

import mir.ion.exception: IonException;
import mir.serde: SerdeTarget;

version(D_Exceptions) {
    import mir.exception: toMutable;
    private static immutable bigIntConvException = new IonException("Overflow when converting BigInt");
    private static immutable cborAnnotationException = new IonException("Cbor can store exactly one annotation.");
}

/++
CBOR support
+/
enum CborMajorFmt : ubyte
{
    unsigned,
    negative,
    blob,
    string,
    array,
    map,
    tag,
    specialOrFloat,
}

enum CborSpecialOrFloat : ubyte
{
    false_ = 0xf4,
    true_ = 0xf5,
    null_ = 0xf6,
    undefined = 0xf7,
    float16 = 0xf9,
    float32 = 0xfa,
    float64 = 0xfb,
    break_ = 0xff,
}

/++
Cbor serialization back-end
+/
struct CborSerializer(Appender)
{
        import mir.bignum.decimal: Decimal;
        import mir.bignum.integer: BigInt;
        import mir.ion.type_code;
        import mir.lob;
        import mir.serde: SerdeTarget;
        import mir.timestamp: Timestamp;
        import mir.utility: _expect;
        import std.traits: isNumeric;

        Appender* buffer;

        /// Mutable value used to choose format specidied or user-defined serialization specializations
        int serdeTarget = SerdeTarget.cbor;
        private bool _annotation;

        @safe pure:

        this(Appender* app) @trusted
        {
            this.buffer = app;
        }

scope:

        ///
        auto structBegin(size_t size = size_t.max)
        {
            if (size < size_t.max)
            {
                putNImpl(size, CborMajorFmt.map);
                return 0;
            }
            buffer.put(cast(ubyte)(CborMajorFmt.map << 5 | 31)); //indefinite
            return 1;
        }

        ///
        @trusted
        void structEnd(size_t state)
        {
            if (state)
                buffer.put(CborSpecialOrFloat.break_);
        }

        ///
        auto listBegin(size_t size = size_t.max)
        {
            if (size < size_t.max)
            {
                putNImpl(size, CborMajorFmt.array);
                return 0;
            }
            buffer.put(cast(ubyte)(CborMajorFmt.array << 5 | 31)); //indefinite
            return 1;
        }
        
        ///
        alias listEnd = structEnd;

        ///
        alias sexpBegin = listBegin;

        ///
        alias sexpEnd = listEnd;

        ///
        size_t stringBegin()
        {
            buffer.put(cast(ubyte)(CborMajorFmt.string << 5 | 31)); //indefinite
            return 1;
        }

        /++
        Puts string part. The implementation allows to split string unicode points.
        +/
        void putStringPart(scope const(char)[] str)
        {
            putValue(str);
        }

        ///
        alias stringEnd = structEnd;


        ///
        auto annotationsEnd(size_t state)
        {
            _annotation = false;
            return 0;
        }

        ///
        size_t annotationWrapperBegin()
        {
            return structBegin(1);
        }

        ///
        void annotationWrapperEnd(size_t, size_t state)
        {
            return structEnd(state);
        }

        ///
        void putKey(scope const char[] key)
        {
            elemBegin;
            putValue(key);
        }

        ///
        void putAnnotation(scope const(char)[] annotation)
        {
            if (_annotation)
            {
                version (D_Exceptions)
                    throw cborAnnotationException.toMutable;
                else
                    assert(0, "CBOR can store exactly one annotation.");
            }
            _annotation = true;
            putKey(annotation);
        }

        ///
        void putSymbol(scope const char[] symbol)
        {
            putValue(symbol);
        }

        private void putNImpl(ubyte n, CborMajorFmt fmt)
        {
            if (n <= 23)
            {
                buffer.put(cast(ubyte)(fmt << 5 | n));
                return;
            }
            buffer.put(cast(ubyte)(fmt << 5 | 24));
            buffer.put(n);
        }

        private void putNImpl(ushort n, CborMajorFmt fmt)
        {
            if (n == cast(ubyte)n)
            {
                putNImpl(cast(ubyte)n, fmt);
                return;
            }

            buffer.put(cast(ubyte)(fmt << 5 | 25));
            buffer.put(packCborExt(n));
        }

        private void putNImpl(uint n, CborMajorFmt fmt)
        {
            if (n == cast(ushort)n)
            {
                putNImpl(cast(ushort)n, fmt);
                return;
            }

            buffer.put(cast(ubyte)(fmt << 5 | 26));
            buffer.put(packCborExt(n));
        }

        private void putNImpl(ulong n, CborMajorFmt fmt)
        {
            if (n == cast(uint)n)
            {
                putNImpl(cast(uint)n, fmt);
                return;
            }

            buffer.put(cast(ubyte)(fmt << 5 | 27));
            buffer.put(packCborExt(n));
        }

        void putValue(T)(const T num)
            if (is(T == ubyte) || is(T == ushort) || is(T == uint) || is(T == ulong))
        {
            putNImpl(num, CborMajorFmt.unsigned);
        }

        void putValue(T)(const T num)
            if (is(T == byte) || is(T == short) || is(T == int) || is(T == long))
        {
            import std.traits: Unsigned;
            putNImpl(cast(Unsigned!T)(num < 0 ? -1 - num : num), num < 0 ? CborMajorFmt.negative : CborMajorFmt.unsigned);
        }

        void putValue(T)(const T num)
            if (is(T == float))
        {
            buffer.put(CborSpecialOrFloat.float32);
            // XXX: better way to do this?
            uint v = () @trusted {return *cast(uint*)&num;}();
            buffer.put(packCborExt(v));
        }

        void putValue(T)(const T num)
            if (is(T == double))
        {
            buffer.put(CborSpecialOrFloat.float64);
            // XXX: better way to do this?
            ulong v = () @trusted {return *cast(ulong*)&num;}();
            buffer.put(packCborExt(v));
        } 

        void putValue(T)(const T num)
            if (is(T == real))
        {
            // Cbor does not support 80-bit floating point numbers,
            // so we'll have to convert down here (and lose a fair bit of precision).
            putValue(cast(double)num);
        }

        ///
        void putValue(size_t size)(auto ref const BigInt!size num)
        {
            auto res = cast(long)num;
            if (res != num)
            {
                version(D_Exceptions)
                    throw bigIntConvException.toMutable;
                else
                    assert(0, "BigInt is too large for CBOR");
            }
            putValue(res);
        }

        ///
        void putValue(size_t size)(auto ref const Decimal!size num)
        {
            putValue(cast(double) num);
        }

        ///
        void putValue(typeof(null))
        {
            buffer.put(CborSpecialOrFloat.null_);
        }

        ///
        void putNull(IonTypeCode code)
        {
            putValue(null);
        }

        ///
        void putValue(bool b)
        {
            buffer.put(cast(ubyte)(b + CborSpecialOrFloat.false_));
        }

        ///
        void putValue(scope const(char)[] value)
        {
            putNImpl(value.length, CborMajorFmt.string);
            () @trusted { buffer.put(cast(const ubyte[])value); }();
        }

        ///
        void putValue(scope const Clob value)
        {
            putValue(value.data);
        }

        ///
        void putValue(scope const Blob value)
        {
            putNImpl(value.data.length, CborMajorFmt.blob);
            buffer.put(value.data);
        }

        private ubyte[T.sizeof] packCborExt(T)(const T num)
            if (__traits(isUnsigned, T))
        {
            T ret = num;
            version (LittleEndian)
            {
                import core.bitop : bswap, byteswap;
                static if (T.sizeof >= 4) {
                    ret = bswap(ret);
                } else static if (T.sizeof == 2) {
                    ret = byteswap(ret);
                }
            }
            return cast(typeof(return))cast(T[1])[ret];
        }

        ///
        void putValue(Timestamp value)
        {
            import mir.appender: UnsafeArrayBuffer;
            char[64] buffer = void;
            auto w = UnsafeArrayBuffer!char(buffer);
            value.toISOExtString(w);
            putValue(w.data);
        }

        ///
        void elemBegin()
        {
        }

        ///
        alias sexpElemBegin = elemBegin;

        ///
        void nextTopLevelValue()
        {
        }
}

@safe pure
version(mir_ion_test) unittest
{
    import mir.appender : ScopedBuffer;
    import mir.ser.interfaces: SerializerWrapper;
    CborSerializer!(ScopedBuffer!ubyte) serializer;
    scope s = new SerializerWrapper!(CborSerializer!(ScopedBuffer!ubyte))(serializer);
}

///
void serializeCbor(Appender, T)(scope ref Appender appender, auto ref T value, int serdeTarget = SerdeTarget.cbor)
{
    import mir.ser : serializeValue;
    auto serializer = ((()@trusted => &appender)()).CborSerializer!(Appender);
    serializer.serdeTarget = serdeTarget;
    serializeValue(serializer, value);
}

///
immutable(ubyte)[] serializeCbor(T)(auto ref T value, int serdeTarget = SerdeTarget.cbor)
{
    import mir.appender : ScopedBuffer, scopedBuffer;
    auto app = scopedBuffer!ubyte;
    serializeCbor!(ScopedBuffer!ubyte, T)(app, value, serdeTarget);
    return (()@trusted => app.data.idup)();
}

/// Test serializing booleans
@safe pure
version(mir_ion_test) unittest
{
    assert(serializeCbor(true) == [0xf5]);
    assert(serializeCbor(false) == [0xf4]);
}

/// Test serializing nulls
@safe pure
version(mir_ion_test) unittest
{
    assert(serializeCbor(null) == [0xf6]);
}

/// Test serializing signed integral types
@safe pure
version(mir_ion_test) unittest
{
    import mir.test;
    // Bytes
    serializeCbor(byte.min).should == [0x38, 0x7F];
    serializeCbor(byte.max).should == [0x18, 0x7F];

    // Shorts
    serializeCbor(short(byte.max)).should == [0x18, 0x7F];
    serializeCbor(short(byte.max) + 1).should == [0x18, 0x80];
    serializeCbor(short.min).should == [0x39, 0x7F, 0xFF];
    serializeCbor(short.max).should == [0x19, 0x7F, 0xFF];

    // Integers
    serializeCbor(int(-32)).should == [0x38, 0x1F];
    serializeCbor(int(byte.max)).should == [0x18, 0x7F];
    serializeCbor(int(short.max)).should == [0x19, 0x7F, 0xFF];
    serializeCbor(int(short.max) + 1).should == [0x19, 0x80, 0x00];
    serializeCbor(int.min).should == [0x3A, 0x7f, 0xff, 0xff, 0xff];
    serializeCbor(int.max).should == [0x1A, 0x7f, 0xff, 0xff, 0xff];

    // Long integers
    serializeCbor(long(int.max)).should == [0x1A, 0x7f, 0xff, 0xff, 0xff];
    serializeCbor(long(int.max) + 1).should == [0x1A, 0x80, 0x00, 0x00, 0x00];
    serializeCbor(long.max).should == [0x1b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff];
    serializeCbor(long.min).should == [0x3b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff];
}

/// Test serializing unsigned integral types
@safe pure
version(mir_ion_test) unittest
{
    import mir.test;
    // Unsigned bytes
    serializeCbor(ubyte.min).should == [0x00];
    serializeCbor(ubyte((1 << 7) - 1)).should == [0x18, 0x7F];
    serializeCbor(ubyte((1 << 7))).should == [0x18, 0x80];
    serializeCbor(ubyte.max).should == [0x18, 0xff];
    
    // Unsigned shorts
    serializeCbor(ushort(ubyte.max)).should == [0x18, 0xff];
    serializeCbor(ushort(ubyte.max + 1)).should == [0x19, 0x01, 0x00];
    serializeCbor(ushort.min).should == [0x00];
    serializeCbor(ushort.max).should == [0x19, 0xff, 0xff]; 

    // Unsigned integers
    serializeCbor(uint(ubyte.max)).should == [0x18, 0xff];
    serializeCbor(uint(ushort.max)).should == [0x19, 0xff, 0xff];
    serializeCbor(uint(ushort.max + 1)).should == [0x1A, 0x00, 0x01, 0x00, 0x00];
    serializeCbor(uint.min).should == [0x00];
    serializeCbor(uint.max).should == [0x1A, 0xff, 0xff, 0xff, 0xff];

    // Long unsigned integers
    serializeCbor(ulong(ubyte.max)).should == [0x18, 0xff];
    serializeCbor(ulong(ushort.max)).should == [0x19, 0xff, 0xff];
    serializeCbor(ulong(uint.max)).should == [0x1A, 0xff, 0xff, 0xff, 0xff];
    serializeCbor(ulong(uint.max) + 1).should == [0x1B, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00];
    serializeCbor(ulong.min).should == [0x00];
    serializeCbor(ulong.max).should == [0x1B, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff];

    // Mir's BigIntView
    import mir.bignum.integer : BigInt;
    serializeCbor(BigInt!2(0xDEADBEEF)).should == [0x1A, 0xde, 0xad, 0xbe, 0xef];
}

/// Test serializing floats / doubles / reals
@safe pure
version(mir_ion_test) unittest
{
    import mir.test;

    serializeCbor(float.min_normal).should == [0xfa, 0x00, 0x80, 0x00, 0x00];
    serializeCbor(float.max).should == [0xfa, 0x7f, 0x7f, 0xff, 0xff];
    serializeCbor(double.min_normal).should == [0xfb, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
    serializeCbor(double.max).should == [0xfb, 0x7f, 0xef, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff];
    static if (real.mant_dig == 64)
    {
        serializeCbor(real.min_normal).should == serializeCbor(double(0));
        serializeCbor(real.max).should == serializeCbor(double.infinity);
    }

    // Mir's Decimal
    import mir.bignum.decimal : Decimal;
    serializeCbor(Decimal!2("777.777")).should == [0xfb,0x40,0x88,0x4e,0x37,0x4b,0xc6,0xa7,0xf0];
    serializeCbor(Decimal!2("-777.7")).should == [0xfb,0xc0,0x88,0x4d,0x99,0x99,0x99,0x99,0x9a];
}

/// Test serializing timestamps
@safe pure
version(mir_ion_test) unittest
{
    import mir.test;
    import mir.timestamp : Timestamp;

    serializeCbor(Timestamp(1970, 1, 1)).should == [0x6a, 0x31, 0x39, 0x37, 0x30, 0x2D, 0x30, 0x31, 0x2D, 0x30, 0x31];
}

/// Test serializing strings
@safe pure
version(mir_ion_test) unittest
{
    import mir.test;
    import std.array : replicate;
    serializeCbor("a").should == [0x61, 0x61];

    // These need to be trusted because we cast const(char)[] to ubyte[] (which is fine here!)
    () @trusted {
        auto a = "a".replicate(32);
        serializeCbor(a).should == 
            cast(ubyte[])[0x78, 0x20] ~ cast(ubyte[])a;
    } ();

    () @trusted {
        auto a = "a".replicate(ushort.max);
        serializeCbor(a).should == 
            cast(ubyte[])[0x79, 0xff, 0xff] ~ cast(ubyte[])a;
    } ();

    () @trusted {
        auto a = "a".replicate(ushort.max + 1);
        serializeCbor(a).should == 
            cast(ubyte[])[0x7a, 0x00, 0x01, 0x00, 0x00] ~ cast(ubyte[])a;
    } ();
}

/// Test serializing blobs / clobs
@safe pure
version(mir_ion_test) unittest
{
    import mir.test;
    import mir.lob : Blob, Clob;
    import std.array : replicate;

    // Blobs
    // These need to be trusted because we cast const(char)[] to ubyte[] (which is fine here!)
    () @trusted {
        auto de = "\xde".replicate(32);
        serializeCbor(Blob(cast(ubyte[])de)).should ==
            cast(ubyte[])[0x58, 0x20] ~ cast(ubyte[])de;
    } ();
    
    () @trusted {
        auto de = "\xde".replicate(ushort.max);
        serializeCbor(Blob(cast(ubyte[])de)).should ==
            cast(ubyte[])[0x59, 0xff, 0xff] ~ cast(ubyte[])de;
    } ();

    () @trusted {
        auto de = "\xde".replicate(ushort.max + 1);
        serializeCbor(Blob(cast(ubyte[])de)).should ==
            cast(ubyte[])[0x5a, 0x00, 0x01, 0x00, 0x00] ~ cast(ubyte[])de;
    } ();

    // Clobs (serialized just as regular strings here)
    () @trusted {
        auto de = "\xde".replicate(32);
        serializeCbor(Clob(de)).should == 
            cast(ubyte[])[0x78, 0x20] ~ cast(ubyte[])de;
    } ();
}

/// Test serializing arrays
@safe pure
version(mir_ion_test) unittest
{
    import mir.test;
    // nested arrays
    serializeCbor([["foo"], ["bar"], ["baz"]]).should == [0x83, 0x81, 0x63, 0x66, 0x6F, 0x6F, 0x81, 0x63, 0x62, 0x61, 0x72, 0x81, 0x63, 0x62, 0x61, 0x7A];
    serializeCbor([0xDEADBEEF, 0xCAFEBABE, 0xAAAA_AAAA]).should == [0x83, 0x1A, 0xDE, 0xAD, 0xBE, 0xEF, 0x1A, 0xCA, 0xFE, 0xBA, 0xBE, 0x1A, 0xAA, 0xAA, 0xAA, 0xAA];
    serializeCbor(["foo", "bar", "baz"]).should == [0x83, 0x63, 0x66, 0x6F, 0x6F, 0x63, 0x62, 0x61, 0x72, 0x63, 0x62, 0x61, 0x7A];
    serializeCbor([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17]).should == [0x91, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11];
}

/// Test serializing enums
@safe pure
version(mir_ion_test) unittest
{
    enum Foo
    {
        Bar,
        Baz
    }

    assert(serializeCbor(Foo.Bar) == [0x63,0x42,0x61,0x72]);
    assert(serializeCbor(Foo.Baz) == [0x63,0x42,0x61,0x7a]);
}

/// Test serializing maps (structs)
@safe pure
version(mir_ion_test) unittest
{
    import mir.test;

    struct Book
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

    // This will probably break if you modify how any of the data types
    // are serialized.
    serializeCbor(book).should == [0xBF, 0x65, 0x74, 0x69, 0x74, 0x6C, 0x65, 0x72, 0x41, 0x20, 0x48, 0x65, 0x72, 0x6F, 0x20, 0x6F, 0x66, 0x20, 0x4F, 0x75, 0x72, 0x20, 0x54, 0x69, 0x6D, 0x65, 0x6E, 0x77, 0x6F, 0x75, 0x6C, 0x64, 0x52, 0x65, 0x63, 0x6F, 0x6D, 0x6D, 0x65, 0x6E, 0x64, 0xF5, 0x6B, 0x64, 0x65, 0x73, 0x63, 0x72, 0x69, 0x70, 0x74, 0x69, 0x6F, 0x6E, 0x60, 0x70, 0x6E, 0x75, 0x6D, 0x62, 0x65, 0x72, 0x4F, 0x66, 0x4E, 0x6F, 0x76, 0x65, 0x6C, 0x6C, 0x61, 0x73, 0x05, 0x65, 0x70, 0x72, 0x69, 0x63, 0x65, 0xFB, 0x40, 0x1F, 0xF5, 0xC2, 0x8F, 0x5C, 0x28, 0xF6, 0x66, 0x77, 0x65, 0x69, 0x67, 0x68, 0x74, 0xFA, 0x40, 0xDC, 0x28, 0xF6, 0x64, 0x74, 0x61, 0x67, 0x73, 0x83, 0x67, 0x72, 0x75, 0x73, 0x73, 0x69, 0x61, 0x6E, 0x65, 0x6E, 0x6F, 0x76, 0x65, 0x6C, 0x6C, 0x31, 0x39, 0x74, 0x68, 0x20, 0x63, 0x65, 0x6E, 0x74, 0x75, 0x72, 0x79, 0xFF];
}


/// Test serializing annotated structs
@safe pure
version(mir_ion_test) unittest
{
    import mir.test;
    import mir.algebraic;
    import mir.serde : serdeAlgebraicAnnotation;

    @serdeAlgebraicAnnotation("Foo")
    static struct Foo
    {
        string bar;
    }

    @serdeAlgebraicAnnotation("Fooz")
    static struct Fooz
    {
        long bar;
    }

    alias V = Variant!(Foo, Fooz);
    auto foo = V(Foo("baz"));

    serializeCbor(foo).should == [0xA1, 0x63, 0x46, 0x6F, 0x6F, 0xBF, 0x63, 0x62, 0x61, 0x72, 0x63, 0x62, 0x61, 0x7A, 0xFF];
}

/// Test custom serialize function with Cbor
@safe pure
version(mir_ion_test) unittest
{
    import mir.test;
    static class MyExampleClass
    {
        string text;

        this(string text)
        {
            this.text = text;
        }

        void serialize(S)(scope ref S serializer) scope const
        {
            auto state = serializer.stringBegin;
            serializer.putStringPart("Hello! ");
            serializer.putStringPart("String passed: ");
            serializer.putStringPart(this.text);
            serializer.stringEnd(state);
        }
    }

    serializeCbor(new MyExampleClass("foo bar baz")).should == [0x7F, 0x67, 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x21, 0x20, 0x6F, 0x53, 0x74, 0x72, 0x69, 0x6E, 0x67, 0x20, 0x70, 0x61, 0x73, 0x73, 0x65, 0x64, 0x3A, 0x20, 0x6B, 0x66, 0x6F, 0x6F, 0x20, 0x62, 0x61, 0x72, 0x20, 0x62, 0x61, 0x7A, 0xFF];
}

/// Test invalidly large BigInt
@safe pure
version(D_Exceptions)
version(mir_ion_test) unittest
{
    import mir.ion.exception : IonException;
    import mir.bignum.integer : BigInt;

    bool caught = false;
    try
    {
        serializeCbor(BigInt!4.fromHexString("c39b18a9f06fd8e962d99935cea0707f79a222050aaeaaaed17feb7aa76999d7"));
    }
    catch (IonException e)
    {
        caught = true;
    }
    assert(caught);
}
