// Messages decoded into smock's decoded form through the public interface,
// for singular fields of every scalar type, enums and nested messages. The
// messages are protoc-encoded fixtures (scripts/gen-protobuf-fixtures.sh),
// so the codec is never checked against itself.

///|
/// The bytes of a fixture the script wrote in hex.
fn fixture(hex : String) -> Bytes {
  @hex.decode(hex.replace_all(old="\n", new="")) catch {
    _ => abort("not hex")
  }
}

///|
/// The set the script wrote in `hex`.
fn hex_set(hex : String) -> @protobuf.DescriptorSet {
  @protobuf.read_descriptor_set(fixture(hex)) catch {
    err => abort("not a set: \{err}")
  }
}

///|
/// `input` decoded as a message of the type whose full name is `name` in
/// the set the script wrote in `hex`, as text, or the error that stops it.
fn decoded(hex : String, name : String, input : Bytes) -> String {
  let set = hex_set(hex)
  guard set.find_message(name) is Some(message) else {
    abort("no message \{name}")
  }
  @utf8.decode(@protobuf.decode_json(set, message, input[:])) catch {
    err => "error: \{err}"
  }
}

///|
test "the ticket's example: an int64, a float, an enum, an empty string and a nested message" {
  inspect(
    decoded(scalars_set, "scalars.Order", fixture(order)),
    content=(
      #|{"id":9223372036854775807,"price":9.99,"status":"ACTIVE","note":"","address":{"city":"Kyoto"}}
    ),
  )
}

///|
test "each scalar type at its largest value, and the enum through its alias" {
  inspect(
    decoded(scalars_set, "scalars.Every", fixture(every_max)),
    content=(
      #|{"aDouble":1.7976931348623157e+308,"aFloat":3.4028235e+38,"anInt64":9223372036854775807,"aUint64":18446744073709551615,"anInt32":2147483647,"aFixed64":18446744073709551615,"aFixed32":4294967295,"aBool":true,"aString":"Kyōto \"quoted\"\n","aBytes":"AAH7/w==","aUint32":4294967295,"anSfixed32":2147483647,"anSfixed64":9223372036854775807,"anSint32":2147483647,"anSint64":9223372036854775807,"aStatus":"ACTIVE"}
    ),
  )
}

///|
test "each signed scalar type at its smallest value, and the others at their defaults" {
  inspect(
    decoded(scalars_set, "scalars.Every", fixture(every_min)),
    content=(
      #|{"aDouble":-1.7976931348623157e+308,"aFloat":-3.4028235e+38,"anInt64":-9223372036854775808,"aUint64":0,"anInt32":-2147483648,"aFixed64":0,"aFixed32":0,"aBool":false,"aString":"","aBytes":"YQ==","aUint32":0,"anSfixed32":-2147483648,"anSfixed64":-9223372036854775808,"anSint32":-2147483648,"anSint64":-9223372036854775808,"aStatus":"STATUS_UNSPECIFIED"}
    ),
  )
}

///|
test "fields without presence are printed at their defaults, an enum as its value 0; proto3 optional and message fields only when set" {
  inspect(
    decoded(scalars_set, "scalars.Every", b""),
    content=(
      #|{"aDouble":0,"aFloat":0,"anInt64":0,"aUint64":0,"anInt32":0,"aFixed64":0,"aFixed32":0,"aBool":false,"aString":"","aBytes":"","aUint32":0,"anSfixed32":0,"anSfixed64":0,"anSint32":0,"anSint64":0,"aStatus":"STATUS_UNSPECIFIED"}
    ),
  )
  // The nested message and the two optional fields set, each at its
  // default.
  let message = nested(w => {
    message_field(w, 21, b"")
    varint_field(w, 22, 0)
    string_field(w, 23, "")
  })
  let text = decoded(scalars_set, "scalars.Every", message)
  inspect(
    text[text.find(",\"aStatus\"").unwrap():],
    content=(
      #|,"aStatus":"STATUS_UNSPECIFIED","anAddress":{"city":""},"maybeCount":0,"maybeName":""}
    ),
  )
}

///|
/// The member `key` of `json`, an object whose members are scalars, as
/// `json` writes it.
fn member_text(json : String, key : String) -> String {
  guard json.find("\"\{key}\":") is Some(start) else { return "no \{key}" }
  let rest = json[start + key.length() + 3:]
  let end = match rest.find(",\"") {
    Some(end) => end
    None => rest.length() - 1
  }
  rest[:end].to_owned()
}

///|
/// What an Every holding only `write`'s records prints for the member
/// `key`.
fn printed(key : String, write : (@protobuf.Writer) -> Unit) -> String {
  member_text(decoded(scalars_set, "scalars.Every", nested(write)), key)
}

///|
test "sint32 and sint64 are read in zigzag encoding, and a varint past 32 bits keeps its low 32 bits" {
  let sint32 = [0UL, 1, 2, 3, 0xFFFF_FFFE, 0xFFFF_FFFF].map(bits => {
    printed("anSint32", w => varint_field(w, 17, bits))
  })
  inspect(sint32.join(" "), content="0 -1 1 -2 2147483647 -2147483648")
  let sint64 = [1UL, 4, 0xFFFF_FFFF_FFFF_FFFE, 0xFFFF_FFFF_FFFF_FFFF].map(bits => {
    printed("anSint64", w => varint_field(w, 18, bits))
  })
  inspect(
    sint64.join(" "),
    content="-1 2 9223372036854775807 -9223372036854775808",
  )
  let low = 0x7_0000_0005UL
  inspect(
    [
      printed("anInt32", w => varint_field(w, 5, low)),
      printed("aUint32", w => varint_field(w, 13, 0x1_FFFF_FFFFUL)),
      printed("anSint32", w => varint_field(w, 17, low)),
      printed("anInt32", w => varint_field(w, 5, 0xFFFF_FFFF_FFFF_FFFFUL)),
    ].join(" "),
    content="5 4294967295 -3 -1",
  )
}

///|
test "a float prints in the shortest form that reads back as the same 32-bit float, a double as it prints, and NaN and the infinities as strings" {
  let floats = [
    0.1,
    9.99,
    1.0 / 3.0,
    16777217.0,
    2147483648.0,
    1.0e-7,
    1.0e21,
    1.0e-45,
    -0.0,
    -2.5,
  ].map(value => {
    printed("aFloat", w => {
      w.tag(2, I32)
      w.fixed32(Float::from_double(value).reinterpret_as_uint())
    })
  })
  inspect(
    floats.join(" "),
    content="0.1 9.99 0.33333334 16777216 2147483600 1e-7 1e+21 1e-45 0 -2.5",
  )
  let doubles = [0.1, 9.99, 1.0 / 3.0, 1.0e21, 5.0e-324, -0.0].map(value => {
    printed("aDouble", w => {
      w.tag(1, I64)
      w.fixed64(value.reinterpret_as_uint64())
    })
  })
  inspect(
    doubles.join(" "),
    content="0.1 9.99 0.3333333333333333 1e+21 5e-324 0",
  )
  let specials = [0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0]
  inspect(
    specials
    .map(value => {
      printed("aFloat", w => {
        w.tag(2, I32)
        w.fixed32(Float::from_double(value).reinterpret_as_uint())
      }) +
      " " +
      printed("aDouble", w => {
        w.tag(1, I64)
        w.fixed64(value.reinterpret_as_uint64())
      })
    })
    .join(" | "),
    content=(
      #|"NaN" "NaN" | "Infinity" "Infinity" | "-Infinity" "-Infinity"
    ),
  )
}

///|
test "an enum prints its value's name, the first name of an alias, or the number of a value the enum does not define" {
  inspect(
    [1UL, 2, 7, 0xFFFF_FFFF_FFFF_FFFF]
    .map(bits => printed("aStatus", w => varint_field(w, 20, bits)))
    .join(" "),
    content=(
      #|"PENDING" "ACTIVE" 7 -1
    ),
  )
}

///|
test "bytes are standard base64 with padding" {
  inspect(
    [b"", b"f", b"fo", b"foo", b"foob", b"\xfb\xff\xbf"]
    .map(octets => {
      printed("aBytes", w => {
        w.tag(12, Len)
        w.length_delimited(octets)
      })
    })
    .join(" "),
    content=(
      #|"" "Zg==" "Zm8=" "Zm9v" "Zm9vYg==" "+/+/"
    ),
  )
}

///|
test "the values of a nested message are merged, its fields' last values winning" {
  let address = (city : String) => nested(w => string_field(w, 1, city))
  let order = (write : (@protobuf.Writer) -> Unit) => {
    decoded(scalars_set, "scalars.Order", nested(write))
  }
  inspect(
    order(w => {
      message_field(w, 5, address("Kyoto"))
      varint_field(w, 1, 7)
      message_field(w, 5, b"")
    }),
    content=(
      #|{"id":7,"price":0,"status":"STATUS_UNSPECIFIED","note":"","address":{"city":"Kyoto"}}
    ),
  )
  inspect(
    order(w => {
      message_field(w, 5, address("Kyoto"))
      message_field(w, 5, address("Osaka"))
    }),
    content=(
      #|{"id":0,"price":0,"status":"STATUS_UNSPECIFIED","note":"","address":{"city":"Osaka"}}
    ),
  )
}

///|
/// A Node nested `depth` deep: each holds the next as its child.
fn node(depth : Int32) -> Bytes {
  let mut message = b""
  for _ in 0..<depth {
    message = nested(w => message_field(w, 2, message))
  }
  message
}

///|
test "messages may nest 100 deep, and no deeper" {
  // 101 Nodes, each `{"name":""` and `}`, and 100 of them `,"child":`.
  let text = decoded(scalars_set, "scalars.Node", node(100))
  inspect(
    "\{text.length()} \{text[:40]}",
    content=(
      #|2011 {"name":"","child":{"name":"","child":{"
    ),
  )
  // The 101st nested Node is empty, at the end of the 239 octets: 64 tags
  // and lengths of 2 octets, then 37 of 3, once the lengths pass 127.
  inspect(
    decoded(scalars_set, "scalars.Node", node(101)),
    content="error: octet 239: messages nest deeper than 100",
  )
}

///|
test "a field of a well-known type is not decoded yet" {
  let timestamp = file_proto(
    "google/protobuf/timestamp.proto",
    package_name="google.protobuf",
    body=w => {
      message_field(
        w,
        4,
        message_proto("Timestamp", body=w => {
          message_field(w, 2, field_proto("seconds", 1, 3))
          message_field(w, 2, field_proto("nanos", 2, 5))
        }),
      )
    },
  )
  let stamped = file_proto(
    "stamped.proto",
    package_name="stamped",
    dependencies=["google/protobuf/timestamp.proto"],
    body=w => {
      message_field(
        w,
        4,
        message_proto("Stamped", body=w => {
          message_field(
            w,
            2,
            field_proto("at", 1, 11, type_name=".google.protobuf.Timestamp"),
          )
        }),
      )
    },
  )
  let set = @protobuf.read_descriptor_set(set_of([timestamp, stamped])) catch {
    err => fail("not a set: \{err}")
  }
  guard set.find_message("stamped.Stamped") is Some(message) else {
    fail("no Stamped")
  }
  let error = try @protobuf.decode_json(set, message, b""[:]) catch {
    err => err.to_string()
  } noraise {
    _ => "decoded"
  }
  inspect(
    error,
    content="octet 0: the field at has the well-known type google.protobuf.Timestamp, which smock does not decode yet",
  )
}

///|
test "a message is decoded into compact JSON, each field under its JSON name" {
  inspect(
    decoded(greeter_set, "helloworld.HelloRequest", fixture(hello_request)),
    content="{\"name\":\"Tom\"}",
  )
  // in_stock's JSON name is inStock, as protoc writes it in the set.
  inspect(
    decoded(catalog_set, "catalog.CountRequest", fixture(count_request)),
    content=(
      #|{"shelf":"A\"1\\é\n","inStock":true}
    ),
  )
}

///|
test "an int32 is a number, a negative one read from its 10-octet varint, and a bool true or false" {
  inspect(
    decoded(catalog_set, "catalog.CountReply", fixture(count_reply)),
    content=(
      #|{"count":-5,"exact":true,"shelf":"A1"}
    ),
  )
  // A varint past 32 bits keeps its low 32 bits, and any bool but 0 is
  // true, as protobuf's parsers read them.
  let message = nested(w => {
    varint_field(w, 1, 0x1_0000_0007UL)
    varint_field(w, 2, 2)
  })
  inspect(
    decoded(catalog_set, "catalog.CountReply", message),
    content=(
      #|{"count":7,"exact":true,"shelf":""}
    ),
  )
}

///|
test "fields the message leaves out are printed at their defaults, in field-number order" {
  inspect(
    decoded(catalog_set, "catalog.CountReply", b""),
    content=(
      #|{"count":0,"exact":false,"shelf":""}
    ),
  )
  // Fields written in another order still print in field-number order.
  let message = nested(w => {
    string_field(w, 3, "B2")
    varint_field(w, 1, 4)
  })
  inspect(
    decoded(catalog_set, "catalog.CountReply", message),
    content=(
      #|{"count":4,"exact":false,"shelf":"B2"}
    ),
  )
}

///|
test "the last value of a field wins, and unknown fields, and fields sent with another wire type, are skipped" {
  let message = nested(w => {
    string_field(w, 1, "Ann")
    varint_field(w, 9, 1)
    // Field 1 as a varint: protobuf keeps it as an unknown field.
    varint_field(w, 1, 5)
    string_field(w, 1, "Tom")
    w.tag(2, I32)
    w.fixed32(0)
  })
  inspect(
    decoded(greeter_set, "helloworld.HelloRequest", message),
    content="{\"name\":\"Tom\"}",
  )
}

///|
test "control characters are escaped as JSON escapes them" {
  let message = nested(w => string_field(w, 1, "a\u{0}\u{1f}\t\r\u{8}\u{c}/z"))
  inspect(
    decoded(greeter_set, "helloworld.HelloRequest", message),
    content=(
      #|{"name":"a\u0000\u001f\t\r\b\f/z"}
    ),
  )
}

///|
test "a message that does not parse is an error at the octet where it breaks" {
  let request = "helloworld.HelloRequest"
  inspect(
    decoded(greeter_set, request, b"\x0a\x05Tom"),
    content="error: octet 1: a length of 5 runs past the end of the input, which has 3 octets left",
  )
  inspect(
    decoded(greeter_set, request, b"\x0a\x02\xc3\x28"),
    content="error: octet 1: the field name holds octets that are not UTF-8",
  )
  inspect(
    decoded(greeter_set, request, b"\x02\x00"),
    content="error: octet 0: field number 0 is not a field number",
  )
  inspect(
    decoded(greeter_set, request, b"\x0f"),
    content="error: octet 0: wire type 7 is not a protobuf wire type",
  )
}

///|
test "a type with a repeated field is not decoded yet" {
  inspect(
    decoded(catalog_set, "catalog.Item", b""),
    content="error: octet 0: the field tags is repeated, which smock does not decode yet",
  )
}

///|
test "a type with a oneof is not decoded yet" {
  inspect(
    decoded(oneofs_set, "oneofs.Pick", b""),
    content="error: octet 0: the field word is in a oneof, which smock does not decode yet",
  )
}
