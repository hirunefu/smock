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

///|
/// The member `key` of `json`, an object whose members are objects or
/// arrays, as `json` writes it.
fn nested_member(json : String, key : String) -> String {
  guard json.find("\"\{key}\":") is Some(start) else { return "no \{key}" }
  let rest = json[start + key.length() + 3:]
  let mut depth = 0
  for i, unit in rest {
    match unit {
      '{' | '[' => depth = depth + 1
      '}' | ']' => {
        depth = depth - 1
        if depth == 0 {
          return rest[:i + 1].to_owned()
        }
      }
      _ => ()
    }
  }
  "unclosed \{key}"
}

///|
/// A map entry whose key is the varint `key` and whose value is the string
/// `value`.
fn named(key : UInt64, value : String) -> Bytes {
  nested(w => {
    varint_field(w, 1, key)
    string_field(w, 2, value)
  })
}

///|
test "map entries print in key order: signed, unsigned and zigzag integers by value, bools false then true, and strings by their text" {
  // protoc's maps.binpb holds each map's entries shuffled.
  let maps = (write : (@protobuf.Writer) -> Unit) => {
    collected("Maps", nested(write))
  }
  let text = maps(w => {
    for
      key in [
        10UL, 0xFFFF_FFFF_FFFF_FFFF, 0x7FFF_FFFF_FFFF_FFFF, 2, 0x8000_0000_0000_0000,
      ] {
      message_field(w, 1, named(key, ""))
    }
    for key in [0xFFFF_FFFFUL, 10, 7] {
      message_field(w, 2, entry(key, 1))
    }
    // sint32 keys 3, -20 and -5, in zigzag encoding.
    for key in [6UL, 39, 9] {
      message_field(w, 3, entry(key, 1))
    }
    for key in [1UL, 0] {
      message_field(w, 4, entry(key, 1))
    }
    for key in ["b", "é", "a", "B", "aa", ""] {
      message_field(w, 5, nested(w => string_field(w, 1, key)))
    }
  })
  inspect(
    [
      nested_member(text, "byId"),
      nested_member(text, "byCode"),
      nested_member(text, "byOffset"),
      nested_member(text, "byFlag"),
      nested_member(text, "byName").replace_all(
        old="{\"name\":\"\",\"sizes\":[],\"stock\":{}}",
        new="{}",
      ),
    ].join("\n"),
    content=(
      #|{"-9223372036854775808":"","-1":"","2":"","10":"","9223372036854775807":""}
      #|{"7":true,"10":true,"4294967295":true}
      #|{"-20":"BOOK","-5":"BOOK","3":"BOOK"}
      #|{"false":1,"true":1}
      #|{"":{},"B":{},"a":{},"aa":{},"b":{},"é":{}}
    ),
  )
}

///|
test "a map entry without a key or a value takes the default, and of the entries with one key the last wins" {
  let maps = (write : (@protobuf.Writer) -> Unit) => {
    collected("Maps", nested(write))
  }
  let text = maps(w => {
    // byId: no key, no value, neither, and the key 7 twice.
    message_field(w, 1, nested(w => string_field(w, 2, "no key")))
    message_field(w, 1, nested(w => varint_field(w, 1, 5)))
    message_field(w, 1, named(7, "first"))
    message_field(w, 1, named(7, "second"))
    // byFlag: no key, then false again; byName: no value, then no key.
    message_field(w, 4, nested(w => varint_field(w, 2, 3)))
    message_field(w, 4, entry(0, 4))
    message_field(w, 5, nested(w => string_field(w, 1, "pen")))
    message_field(
      w,
      5,
      nested(w => message_field(w, 2, nested(w => string_field(w, 1, "no key")))),
    )
    // byOffset: an empty entry.
    message_field(w, 3, b"")
  })
  inspect(
    text,
    content=(
      #|{"byId":{"0":"no key","5":"","7":"second"},"byCode":{},"byOffset":{"0":"KIND_UNSPECIFIED"},"byFlag":{"false":4},"byName":{"":{"name":"no key","sizes":[],"stock":{}},"pen":{"name":"","sizes":[],"stock":{}}}}
    ),
  )
  // The key 0 written out and left out are one key.
  inspect(
    nested_member(
      maps(w => {
        message_field(w, 1, named(0, "written"))
        message_field(w, 1, nested(w => string_field(w, 2, "left out")))
      }),
      "byId",
    ),
    content=(
      #|{"0":"left out"}
    ),
  )
}

///|
test "a map key is read as its type reads it, so keys that differ only past their type's bits are one key, and an entry's last key and value win" {
  let maps = (write : (@protobuf.Writer) -> Unit) => {
    collected("Maps", nested(write))
  }
  // byCode's keys are uint32: 0x1_0000_0007 is 7. Tagged's are int32:
  // 0xFFFF_FFFF is -1, as 0xFFFF_FFFF_FFFF_FFFF is.
  inspect(
    nested_member(
      maps(w => {
        message_field(w, 2, entry(7, 0))
        message_field(w, 2, entry(0x1_0000_0007, 1))
      }),
      "byCode",
    ),
    content=(
      #|{"7":true}
    ),
  )
  inspect(
    collected(
      "Tagged",
      nested(w => {
        message_field(w, 2, entry(0xFFFF_FFFF, 1))
        message_field(w, 2, entry(0xFFFF_FFFF_FFFF_FFFF, 2))
      }),
    ),
    content=(
      #|{"tags":[],"counts":{"-1":2}}
    ),
  )
  // Within an entry, as within any message, the last key and the last
  // value win, unknown fields are skipped, and so is a key with another
  // wire type than its type's.
  let entry = nested(w => {
    varint_field(w, 1, 1)
    varint_field(w, 2, 10)
    varint_field(w, 9, 99)
    varint_field(w, 1, 2)
    string_field(w, 1, "not a key")
    varint_field(w, 2, 20)
  })
  inspect(
    collected("Tagged", nested(w => message_field(w, 2, entry))),
    content=(
      #|{"tags":[],"counts":{"2":20}}
    ),
  )
}

///|
test "a map's message values print in the decoded form, and two values in one entry are merged" {
  let item = (write : (@protobuf.Writer) -> Unit) => nested(write)
  let text = collected(
    "Maps",
    nested(w => {
      message_field(
        w,
        5,
        nested(w => {
          string_field(w, 1, "pen")
          message_field(
            w,
            2,
            item(w => {
              string_field(w, 1, "Pen")
              varint_field(w, 2, 1)
            }),
          )
          message_field(w, 2, item(w => varint_field(w, 2, 2)))
        }),
      )
    }),
  )
  inspect(
    nested_member(text, "byName"),
    content=(
      #|{"pen":{"name":"Pen","sizes":[1,2],"stock":{}}}
    ),
  )
}
