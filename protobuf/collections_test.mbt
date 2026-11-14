// Repeated fields, maps and oneofs decoded into smock's decoded form,
// through the public interface. The set is
// fixtures/protobuf/collections/collections.proto; some messages are what
// protoc encodes from the .txtpb files beside it, and others are written
// record by record, in orders protoc never writes.

///|
/// `input` decoded as a message of the type `collections.<name>`, as text,
/// or the error that stops it.
fn collected(name : String, input : Bytes) -> String {
  decoded(collections_set, "collections.\{name}", input)
}

///|
/// A map entry whose key and value are the varints `key` and `value`.
fn entry(key : UInt64, value : UInt64) -> Bytes {
  nested(w => {
    varint_field(w, 1, key)
    varint_field(w, 2, value)
  })
}

///|
test "the ticket's example: two encodings of one message, one with its fields in reverse order and its map entries shuffled, print one text" {
  let text = collected("Tagged", fixture(tagged))
  inspect(
    text,
    content=(
      #|{"tags":["a","b"],"counts":{"1":3,"2":5,"10":1}}
    ),
  )
  let reversed = nested(w => {
    message_field(w, 2, entry(10, 1))
    message_field(w, 2, entry(1, 3))
    message_field(w, 2, entry(2, 5))
    string_field(w, 1, "a")
    string_field(w, 1, "b")
  })
  assert_eq(collected("Tagged", reversed), text)
}

///|
test "repeated fields print as arrays: packed and unpacked scalars alike, strings, bytes and messages, each in order" {
  let text = collected("Lists", fixture(lists))
  inspect(
    text,
    content=(
      #|{"numbers":[1,-2,300],"offsets":[-1,64],"codes":[7,4294967295],"ratios":[0.5,-1e+300],"weights":[0.1,9.99],"flags":[true,false,true],"kinds":["BOOK","DISC",9],"words":["x","Kyōto"],"blobs":["AP8="],"items":[{"name":"pen","sizes":[1,2],"stock":{"a":1}},{"name":"","sizes":[],"stock":{}}]}
    ),
  )
  // The same values, each scalar in a record of its own.
  assert_eq(collected("Lists", fixture(lists_on_the_wire)), text)
}

///|
test "an empty repeated field prints [], and an empty map {}" {
  inspect(
    collected("Lists", b""),
    content=(
      #|{"numbers":[],"offsets":[],"codes":[],"ratios":[],"weights":[],"flags":[],"kinds":[],"words":[],"blobs":[],"items":[]}
    ),
  )
  inspect(
    collected("Maps", b""),
    content=(
      #|{"byId":{},"byCode":{},"byOffset":{},"byFlag":{},"byName":{}}
    ),
  )
}

///|
test "the records of a repeated scalar are joined in order, packed or not, wherever they come in the message" {
  let packed = (field : Int32, values : Array[UInt64]) => {
    let w = @protobuf.Writer()
    for value in values {
      w.varint(value)
    }
    let octets = w.to_bytes()
    (writer : @protobuf.Writer) => {
      writer.tag(field, Len)
      writer.length_delimited(octets)
    }
  }
  let message = nested(w => {
    packed(1, [1, 2])(w)
    string_field(w, 8, "between")
    varint_field(w, 1, 3)
    packed(1, [4])(w)
    // An empty packed record adds nothing.
    packed(1, [])(w)
    varint_field(w, 1, 5)
  })
  inspect(
    member_text(collected("Lists", message), "numbers"),
    content="[1,2,3,4,5]",
  )
  // Fixed-width values, packed and not.
  let fixed = nested(w => {
    w.tag(3, Len)
    w.length_delimited(b"\x01\x00\x00\x00\x02\x00\x00\x00")
    w.tag(3, I32)
    w.fixed32(3)
    w.tag(4, I64)
    w.fixed64(0.25.reinterpret_as_uint64())
    w.tag(4, Len)
    w.length_delimited(b"\x00\x00\x00\x00\x00\x00\xf0\x3f")
  })
  let text = collected("Lists", fixed)
  inspect(
    member_text(text, "codes") + " " + member_text(text, "ratios"),
    content="[1,2,3] [0.25,1]",
  )
}

///|
test "a record of a repeated field with another wire type than its type's is skipped" {
  let message = nested(w => {
    // A string as a varint, a number as a fixed 64-bit value, and a
    // message as a varint.
    varint_field(w, 8, 1)
    w.tag(1, I64)
    w.fixed64(1)
    varint_field(w, 10, 1)
    string_field(w, 8, "kept")
  })
  let text = collected("Lists", message)
  inspect(
    member_text(text, "words") + " " + member_text(text, "numbers"),
    content=(
      #|["kept"] []
    ),
  )
  inspect(text[text.find("\"items\"").unwrap():], content="\"items\":[]}")
}
