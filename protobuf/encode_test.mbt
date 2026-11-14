// Replies encoded from ProtoJSON through the public interface, for every
// proto3 field type but the well-known types. The bytes they are compared
// with are protoc's encodings of the same messages, written in protobuf's
// text format (fixtures/protobuf/replies/), so the encoder is never
// checked against itself.

///|
/// The Descriptor set of fixtures/protobuf/replies/replies.proto.
fn replies() -> @protobuf.DescriptorSet {
  @protobuf.read_descriptor_set(fixture(replies_set)) catch {
    err => abort("not a set: \{err}")
  }
}

///|
/// `json` encoded as a message of `name`, a type of fixtures/protobuf/
/// replies/replies.proto, in hex, or the error that stops it.
fn reply(name : String, json : Json) -> String {
  let set = replies()
  guard set.find_message("replies.\{name}") is Some(message) else {
    abort("no message \{name}")
  }
  @hex.encode(set.encode_json(message, json)) catch {
    err => "error: \{err}"
  }
}

///|
test "a reply with an int64 written as a string, an enum by its number and a repeated string has protoc's bytes" {
  assert_eq(
    reply("User", { "user_id": "42", "status": 1, "tags": ["a", "b"] }),
    @hex.encode(fixture(user_reply)),
  )
  assert_eq(
    reply("User", { "userId": 42, "status": "ACTIVE", "tags": ["a", "b"] }),
    @hex.encode(fixture(user_reply)),
  )
}

///|
/// `text`, JSON text, encoded as a message of `name`, a type of
/// fixtures/protobuf/replies/replies.proto, in hex, or the error that stops
/// it. JSON text keeps the digits of an integer that a double does not
/// hold, as a template's rendered reply does.
fn reply_text(name : String, text : String) -> String {
  let json = @json.parse(text) catch { err => abort("not JSON: \{err}") }
  reply(name, json)
}

///|
test "every scalar type at its largest value, in either spelling and either form of a number, has protoc's bytes" {
  let expected = @hex.encode(fixture(everything_maxima))
  assert_eq(
    reply_text(
      "Everything",
      (
        #|{"aDouble": 1.7976931348623157e308, "aFloat": 3.4028235e38,
        #| "anInt32": 2147483647, "anInt64": "9223372036854775807",
        #| "aUint32": 4294967295, "aUint64": "18446744073709551615",
        #| "aSint32": 2147483647, "aSint64": "9223372036854775807",
        #| "aFixed32": 4294967295, "aFixed64": "18446744073709551615",
        #| "anSfixed32": 2147483647, "anSfixed64": "9223372036854775807",
        #| "aBool": true, "aString": "\"\\ é ☺ 😈", "someBytes": "AAH7/w==",
        #| "status": "SUSPENDED", "alias": "r"}
      ),
    ),
    expected,
  )
  // Proto names, numbers as strings, 64-bit integers as numbers whose
  // digits JSON text keeps, URL-safe base64 without padding, an enum by
  // its number, and fields in another order.
  assert_eq(
    reply_text(
      "Everything",
      (
        #|{"renamed": "r", "status": 2, "some_bytes": "AAH7_w",
        #| "a_string": "\"\\ é ☺ 😈", "a_bool": true,
        #| "an_sfixed64": 9223372036854775807, "an_sfixed32": "2147483647",
        #| "a_fixed64": 18446744073709551615, "a_fixed32": "4294967295",
        #| "a_sint64": 9223372036854775807, "a_sint32": "2147483647",
        #| "a_uint64": 18446744073709551615, "a_uint32": "4294967295",
        #| "an_int64": 9223372036854775807, "an_int32": "2147483647",
        #| "a_float": "3.4028235e38", "a_double": "1.7976931348623157e308"}
      ),
    ),
    expected,
  )
}

///|
test "every signed scalar type at its smallest value, and the smallest positive double and float, have protoc's bytes" {
  assert_eq(
    reply_text(
      "Everything",
      (
        #|{"aDouble": 5e-324, "aFloat": 1e-45,
        #| "anInt32": -2147483648, "anInt64": -9223372036854775808,
        #| "aSint32": "-2147483648", "aSint64": "-9223372036854775808",
        #| "anSfixed32": -2.147483648e9, "anSfixed64": "-9.223372036854775808e18"}
      ),
    ),
    @hex.encode(fixture(everything_minima)),
  )
}

///|
test "NaN, the infinities and -0 have protoc's bytes" {
  assert_eq(
    reply_text(
      "Everything",
      (
        #|{"aDouble": -0.0, "aFloat": "NaN",
        #| "doubles": ["Infinity", "NaN", "-Infinity"],
        #| "floats": ["-Infinity", 0.1, "-0", "Infinity"]}
      ),
    ),
    @hex.encode(fixture(everything_specials)),
  )
}

///|
test "repeated fields are packed, unless a field says packed = false, and strings, bytes and messages are not" {
  assert_eq(
    reply_text(
      "Everything",
      (
        #|{"int32s": [1, -1, 300], "unpackedInt32s": [1, -2],
        #| "doubles": [0.5, 1e100], "floats": [0.1, 9.99],
        #| "int64s": ["9223372036854775807", -1],
        #| "uint64s": [18446744073709551615, "0"],
        #| "sint32s": [-1, 1, -2147483648],
        #| "sint64s": ["-9223372036854775808"],
        #| "fixed32s": [1, 4294967295], "sfixed64s": [-1],
        #| "bools": [true, false, true],
        #| "statuses": ["ACTIVE", 0, "SUSPENDED", 7],
        #| "strings": ["", "x"], "byteStrings": ["/w==", ""],
        #| "nesteds": [{"label": "a"}, {}]}
      ),
    ),
    @hex.encode(fixture(everything_lists)),
  )
  inspect(reply("Everything", { "int32s": [], "strings": [] }), content="")
}

///|
test "map entries are sorted by key, each with its key and its value, as protoc writes them" {
  assert_eq(
    reply_text(
      "Everything",
      (
        #|{"counts": {"b": 2, "a": 1, "": 0},
        #| "names": {"10": "ten", "-1": "minus one", "2": ""},
        #| "byFlag": {"true": {"label": "yes"}, "false": {}},
        #| "byId": {"7": "STATUS_UNSPECIFIED", "-9223372036854775808": "ACTIVE"},
        #| "blobs": {"18446744073709551615": "AQ=="},
        #| "bySint": {"-2": 1.5}, "byFixed": {"1": true}}
      ),
    ),
    @hex.encode(fixture(everything_maps)),
  )
  inspect(reply("Everything", { "counts": {} }), content="")
}

///|
test "a message, a proto3 optional field and a oneof member are written at their defaults, and null leaves a field unset" {
  assert_eq(
    reply("Everything", { "nested": {}, "maybe": 0, "word": "" }),
    @hex.encode(fixture(everything_choice)),
  )
  assert_eq(
    reply("Everything", {
      "nested": {},
      "maybe": 0,
      "number": null,
      "word": "",
      "aString": null,
      "strings": null,
    }),
    @hex.encode(fixture(everything_choice)),
  )
  // Fields without presence are left out at their defaults.
  inspect(
    reply("Everything", {
      "aDouble": 0,
      "aString": "",
      "someBytes": "",
      "aBool": false,
      "status": "STATUS_UNSPECIFIED",
      "anInt64": "0",
    }),
    content="",
  )
}

///|
test "a oneof member that is a message holds a message of the type that holds it" {
  assert_eq(
    reply("Everything", {
      "inner": {
        "label": "outer",
        "recursive": { "anInt32": 1, "inner": { "label": "inner" } },
      },
    }),
    @hex.encode(fixture(everything_inner)),
  )
}

///|
/// `json` encoded as a message of `name`, a type of the set in `hex`, a
/// set the script wrote in hex, in hex, or the error that stops it.
fn encoded(hex : String, name : String, json : Json) -> String {
  let set = @protobuf.read_descriptor_set(fixture(hex)) catch {
    err => abort("not a set: \{err}")
  }
  guard set.find_message(name) is Some(message) else {
    abort("no message \{name}")
  }
  @hex.encode(set.encode_json(message, json)) catch {
    err => "error: \{err}"
  }
}

///|
test "messages of other sets have protoc's bytes, whatever the order of their keys" {
  assert_eq(
    encoded(greeter_set, "helloworld.HelloReply", { "message": "Hello Tom" }),
    @hex.encode(fixture(hello_reply)),
  )
  assert_eq(
    encoded(catalog_set, "catalog.CountReply", {
      "count": -5,
      "exact": true,
      "shelf": "A1",
    }),
    @hex.encode(fixture(count_reply)),
  )
  assert_eq(
    encoded(catalog_set, "catalog.CountReply", {
      "shelf": "A1",
      "exact": true,
      "count": -5,
    }),
    @hex.encode(fixture(count_reply)),
  )
  inspect(
    encoded(catalog_set, "catalog.CountRequest", { "in_stock": true }),
    content="1001",
  )
  inspect(
    encoded(catalog_set, "catalog.CountRequest", { "inStock": true }),
    content="1001",
  )
}

///|
test "JSON that is not a message of the type is an error at the JSON Pointer of the value at fault" {
  inspect(
    reply("User", [1]),
    content=(
      #|error: must be an object: the message is a replies.User
    ),
  )
  inspect(
    reply("User", { "userid": 1 }),
    content=(
      #|error: /userid: is not a field of replies.User
    ),
  )
  inspect(
    reply("User", { "user_id": 1, "userId": 2 }),
    content=(
      #|error: /userId: names the field user_id of replies.User, as "user_id" does: give a field once, by its proto name or its JSON name
    ),
  )
  inspect(
    reply("Everything", { "word": "a", "number": 1 }),
    content=(
      #|error: /number: sets the oneof choice of replies.Everything, as "word" does: give one member of a oneof at most
    ),
  )
  inspect(
    reply("User", { "tags": ["a", null] }),
    content=(
      #|error: /tags/1: cannot be null: it is an element of the repeated field tags of replies.User
    ),
  )
  inspect(
    reply("Everything", { "counts": { "a": null } }),
    content=(
      #|error: /counts/a: cannot be null: it is a value of the map field counts of replies.Everything
    ),
  )
  inspect(
    reply("Everything", { "nesteds": [{ "lable": "a" }] }),
    content=(
      #|error: /nesteds/0/lable: is not a field of replies.Everything.Nested
    ),
  )
  inspect(
    reply("Everything", { "byFlag": { "true": { "label": 1 } } }),
    content=(
      #|error: /byFlag/true/label: must be a string of Unicode text: the field label of replies.Everything.Nested has the type string
    ),
  )
  inspect(
    reply("Everything", { "nested": "a" }),
    content=(
      #|error: /nested: must be an object: the field nested of replies.Everything has the type replies.Everything.Nested
    ),
  )
  inspect(
    reply("User", { "tags": "a" }),
    content=(
      #|error: /tags: must be an array: the field tags of replies.User is repeated
    ),
  )
  inspect(
    reply("Everything", { "counts": [] }),
    content=(
      #|error: /counts: must be an object: the field counts of replies.Everything is a map
    ),
  )
}

///|
test "null does not count as a member of a oneof" {
  inspect(
    reply("Everything", { "word": null, "number": 1 }),
    content=(
      #|980301
    ),
  )
}

///|
test "a value of the wrong type or out of its type's range is an error" {
  inspect(
    reply("Everything", { "anInt32": 2147483648 }),
    content=(
      #|error: /anInt32: must be an integer from -2147483648 to 2147483647: the field an_int32 of replies.Everything has the type int32
    ),
  )
  inspect(
    reply("Everything", { "anInt32": 1.5 }),
    content=(
      #|error: /anInt32: must be an integer from -2147483648 to 2147483647: the field an_int32 of replies.Everything has the type int32
    ),
  )
  inspect(
    reply("Everything", { "anInt32": "1e" }),
    content=(
      #|error: /anInt32: must be an integer from -2147483648 to 2147483647: the field an_int32 of replies.Everything has the type int32
    ),
  )
  inspect(
    reply("Everything", { "anInt32": "" }),
    content=(
      #|error: /anInt32: must be an integer from -2147483648 to 2147483647: the field an_int32 of replies.Everything has the type int32
    ),
  )
  inspect(
    reply("Everything", { "anInt32": " 1" }),
    content=(
      #|error: /anInt32: must be an integer from -2147483648 to 2147483647: the field an_int32 of replies.Everything has the type int32
    ),
  )
  inspect(
    reply("Everything", { "aUint32": -1 }),
    content=(
      #|error: /aUint32: must be an integer from 0 to 4294967295: the field a_uint32 of replies.Everything has the type uint32
    ),
  )
  inspect(
    reply_text("Everything", "{\"anInt64\": 9223372036854775808}"),
    content=(
      #|error: /anInt64: must be an integer from -9223372036854775808 to 9223372036854775807: the field an_int64 of replies.Everything has the type int64
    ),
  )
  inspect(
    reply("Everything", { "anInt64": "-9223372036854775809" }),
    content=(
      #|error: /anInt64: must be an integer from -9223372036854775808 to 9223372036854775807: the field an_int64 of replies.Everything has the type int64
    ),
  )
  inspect(
    reply("Everything", { "aUint64": "18446744073709551616" }),
    content=(
      #|error: /aUint64: must be an integer from 0 to 18446744073709551615: the field a_uint64 of replies.Everything has the type uint64
    ),
  )
  inspect(
    reply("Everything", { "aFloat": 3.5e38 }),
    content=(
      #|error: /aFloat: must be a number within the range of a float, or "NaN", "Infinity" or "-Infinity": the field a_float of replies.Everything has the type float
    ),
  )
  inspect(
    reply_text("Everything", "{\"aDouble\": 1e400}"),
    content=(
      #|error: /aDouble: must be a number, or "NaN", "Infinity" or "-Infinity": the field a_double of replies.Everything has the type double
    ),
  )
  inspect(
    reply("Everything", { "aDouble": "nan" }),
    content=(
      #|error: /aDouble: must be a number, or "NaN", "Infinity" or "-Infinity": the field a_double of replies.Everything has the type double
    ),
  )
  inspect(
    reply("Everything", { "aString": 1 }),
    content=(
      #|error: /aString: must be a string of Unicode text: the field a_string of replies.Everything has the type string
    ),
  )
  inspect(
    reply("Everything", { "aBool": "true" }),
    content=(
      #|error: /aBool: must be true or false: the field a_bool of replies.Everything has the type bool
    ),
  )
  inspect(
    reply("Everything", { "someBytes": "a" }),
    content=(
      #|error: /someBytes: must be a string in base64, standard or URL-safe, with or without padding: the field some_bytes of replies.Everything has the type bytes
    ),
  )
  inspect(
    reply("Everything", { "someBytes": "a*==" }),
    content=(
      #|error: /someBytes: must be a string in base64, standard or URL-safe, with or without padding: the field some_bytes of replies.Everything has the type bytes
    ),
  )
  inspect(
    reply("Everything", { "status": "GONE" }),
    content=(
      #|error: /status: must be the name of a value of replies.Status, or an integer from -2147483648 to 2147483647: the field status of replies.Everything has the type replies.Status
    ),
  )
  inspect(
    reply("Everything", { "status": 2147483648 }),
    content=(
      #|error: /status: must be the name of a value of replies.Status, or an integer from -2147483648 to 2147483647: the field status of replies.Everything has the type replies.Status
    ),
  )
  inspect(
    reply("Everything", { "names": { "x": "a" } }),
    content=(
      #|error: /names/x: must be an integer from -2147483648 to 2147483647: the keys of the map field names of replies.Everything have the type int32
    ),
  )
  inspect(
    reply("Everything", { "byFlag": { "yes": {} } }),
    content=(
      #|error: /byFlag/yes: must be "true" or "false": the keys of the map field by_flag of replies.Everything have the type bool
    ),
  )
  inspect(
    reply("Everything", { "counts": { "a": "1x" } }),
    content=(
      #|error: /counts/a: must be an integer from -2147483648 to 2147483647: the values of the map field counts of replies.Everything have the type int32
    ),
  )
  // A surrogate that is not in a pair, which a JSON parser refuses, but a
  // string may hold.
  let lone = String::from_array([(0xD800).unsafe_to_char()])
  inspect(
    reply("Everything", { "aString": Json::string(lone) }),
    content=(
      #|error: /aString: must be a string of Unicode text: the field a_string of replies.Everything has the type string
    ),
  )
  // The key is in the error's JSON Pointer, which inspect cannot show.
  inspect(
    reply("Everything", {
      "counts": Json::object(Map::from_array([(lone, Json::number(1))])),
    }).has_suffix(
      ": must be a string of Unicode text: the keys of the map field counts of replies.Everything have the type string",
    ),
    content="true",
  )
}

///|
test "messages nest 100 deep at most" {
  /// A chain of `count` messages, each in the one before, from an
  /// Everything, whose `inner` holds a Nested, whose `recursive` holds an
  /// Everything.
  fn chain(count : Int32) -> Json {
    let mut json = Json::empty_object()
    for i in 1..<count {
      json = if (count - i) % 2 == 1 {
        { "inner": json }
      } else {
        { "recursive": json }
      }
    }
    json
  }

  inspect(reply("Everything", chain(100)).has_prefix("error"), content="false")
  let error = reply("Everything", chain(101))
  inspect(error.has_suffix(": nests messages deeper than 100"), content="true")
}

///|
test "a well-known type, and a type of a proto2 file, are not encoded yet" {
  inspect(
    encoded(shop_set, "shop.Money", {}),
    content=(
      #|error: smock does not encode shop.Money yet: it is a type of a proto2 file
    ),
  )
  // google/protobuf/empty.proto: package google.protobuf, message Empty.
  let writer = @protobuf.Writer()
  let file = @protobuf.Writer()
  file.tag(1, Len)
  file.length_delimited(@utf8.encode("google/protobuf/empty.proto"))
  file.tag(2, Len)
  file.length_delimited(@utf8.encode("google.protobuf"))
  file.tag(4, Len)
  file.length_delimited(b"\x0a\x05Empty")
  file.tag(12, Len)
  file.length_delimited(@utf8.encode("proto3"))
  writer.tag(1, Len)
  writer.length_delimited(file.to_bytes())
  inspect(
    encoded(@hex.encode(writer.to_bytes()), "google.protobuf.Empty", {}),
    content=(
      #|error: smock does not encode google.protobuf.Empty yet: it is a well-known type
    ),
  )
}
