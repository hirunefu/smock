// Messages decoded into smock's decoded form, and encoded from JSON, through
// the public interface, for types whose fields are singular string, bool
// and int32 fields. The messages are protoc-encoded fixtures
// (scripts/gen-protobuf-fixtures.sh), so the codec is never checked against
// itself.

///|
/// The top-level message `name` of the set in `hex`, a set the script wrote
/// in hex.
fn message_type(hex : String, name : String) -> @protobuf.MessageDescriptor {
  let set = @protobuf.read_descriptor_set(
    @hex.decode(hex.replace_all(old="\n", new="")) catch {
      _ => abort("not hex")
    },
  ) catch {
    err => abort("not a set: \{err}")
  }
  for file in set.files {
    for message in file.messages {
      if message.name == name {
        return message
      }
    }
  }
  abort("no message \{name}")
}

///|
/// The bytes of a fixture the script wrote in hex.
fn fixture(hex : String) -> Bytes {
  @hex.decode(hex.replace_all(old="\n", new="")) catch {
    _ => abort("not hex")
  }
}

///|
/// `input` decoded as a message of the type `message`, as text, or the
/// error that stops it.
fn decoded(message : @protobuf.MessageDescriptor, input : Bytes) -> String {
  @utf8.decode(@protobuf.decode_json(message, input[:])) catch {
    err => "error: \{err}"
  }
}

///|
test "a message is decoded into compact JSON, each field under its JSON name" {
  let request = message_type(greeter_set, "HelloRequest")
  inspect(
    decoded(request, fixture(hello_request)),
    content="{\"name\":\"Tom\"}",
  )
  // in_stock's JSON name is inStock, as protoc writes it in the set.
  let count = message_type(catalog_set, "CountRequest")
  inspect(
    decoded(count, fixture(count_request)),
    content=(
      #|{"shelf":"A\"1\\é\n","inStock":true}
    ),
  )
}

///|
test "an int32 is a number, a negative one read from its 10-octet varint, and a bool true or false" {
  let reply = message_type(catalog_set, "CountReply")
  inspect(
    decoded(reply, fixture(count_reply)),
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
    decoded(reply, message),
    content=(
      #|{"count":7,"exact":true,"shelf":""}
    ),
  )
}

///|
test "fields the message leaves out are printed at their defaults, in field-number order" {
  let reply = message_type(catalog_set, "CountReply")
  inspect(
    decoded(reply, b""),
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
    decoded(reply, message),
    content=(
      #|{"count":4,"exact":false,"shelf":"B2"}
    ),
  )
}

///|
test "the last value of a field wins, and unknown fields, and fields sent with another wire type, are skipped" {
  let request = message_type(greeter_set, "HelloRequest")
  let message = nested(w => {
    string_field(w, 1, "Ann")
    varint_field(w, 9, 1)
    // Field 1 as a varint: protobuf keeps it as an unknown field.
    varint_field(w, 1, 5)
    string_field(w, 1, "Tom")
    w.tag(2, I32)
    w.fixed32(0)
  })
  inspect(decoded(request, message), content="{\"name\":\"Tom\"}")
}

///|
test "control characters are escaped as JSON escapes them" {
  let request = message_type(greeter_set, "HelloRequest")
  let message = nested(w => string_field(w, 1, "a\u{0}\u{1f}\t\r\u{8}\u{c}/z"))
  inspect(
    decoded(request, message),
    content=(
      #|{"name":"a\u0000\u001f\t\r\b\f/z"}
    ),
  )
}

///|
test "a message that does not parse is an error at the octet where it breaks" {
  let request = message_type(greeter_set, "HelloRequest")
  inspect(
    decoded(request, b"\x0a\x05Tom"),
    content="error: octet 1: a length of 5 runs past the end of the input, which has 3 octets left",
  )
  inspect(
    decoded(request, b"\x0a\x02\xc3\x28"),
    content="error: octet 1: the field name holds octets that are not UTF-8",
  )
  inspect(
    decoded(request, b"\x02\x00"),
    content="error: octet 0: field number 0 is not a field number",
  )
  inspect(
    decoded(request, b"\x0f"),
    content="error: octet 0: wire type 7 is not a protobuf wire type",
  )
}

///|
test "a type with a field that is not a singular string, bool or int32 is not decoded yet" {
  let item = message_type(catalog_set, "Item")
  inspect(
    decoded(item, b""),
    content="error: octet 0: the field price has the type int64, which smock does not decode yet",
  )
}

///|
/// `json` encoded as a message of the type `message`, in hex, or the error
/// that stops it.
fn encoded(message : @protobuf.MessageDescriptor, json : Json) -> String {
  @hex.encode(@protobuf.encode_json(message, json)) catch {
    err => "error: \{err}"
  }
}

///|
test "a message encoded from JSON has protoc's bytes" {
  let reply = message_type(greeter_set, "HelloReply")
  assert_eq(
    encoded(reply, { "message": "Hello Tom" }),
    @hex.encode(fixture(hello_reply)),
  )
  let count = message_type(catalog_set, "CountReply")
  assert_eq(
    encoded(count, { "count": -5, "exact": true, "shelf": "A1" }),
    @hex.encode(fixture(count_reply)),
  )
  // Keys in another order give the same bytes: fields go out in
  // field-number order.
  assert_eq(
    encoded(count, { "shelf": "A1", "exact": true, "count": -5 }),
    @hex.encode(fixture(count_reply)),
  )
}

///|
test "a field at its default is not written, and an empty object is an empty message" {
  let count = message_type(catalog_set, "CountReply")
  inspect(
    encoded(count, { "count": 0, "exact": false, "shelf": "" }),
    content="",
  )
  inspect(encoded(count, {}), content="")
}

///|
test "a field may be written with its proto name or its JSON name" {
  let request = message_type(catalog_set, "CountRequest")
  inspect(encoded(request, { "in_stock": true }), content="1001")
  inspect(encoded(request, { "inStock": true }), content="1001")
}

///|
test "JSON that is not a message of the type is an error at its JSON Pointer" {
  let count = message_type(catalog_set, "CountReply")
  inspect(
    encoded(count, [1]),
    content="error: must be an object: the message is a CountReply",
  )
  inspect(
    encoded(count, { "cuont": 1 }),
    content="error: /cuont: is not a field of CountReply",
  )
  inspect(
    encoded(count, { "shelf": 1 }),
    content="error: /shelf: must be a string: the field shelf is a string",
  )
  inspect(
    encoded(count, { "exact": "yes" }),
    content="error: /exact: must be true or false: the field exact is a bool",
  )
  inspect(
    encoded(count, { "count": 2147483648.0 }),
    content="error: /count: must be an integer from -2147483648 to 2147483647: the field count is an int32",
  )
  inspect(
    encoded(count, { "count": 1.5 }),
    content="error: /count: must be an integer from -2147483648 to 2147483647: the field count is an int32",
  )
}

///|
test "a type with a field that is not a singular string, bool or int32 is not encoded yet" {
  let item = message_type(catalog_set, "Item")
  inspect(
    encoded(item, {}),
    content="error: the field price has the type int64, which smock does not encode yet",
  )
}
