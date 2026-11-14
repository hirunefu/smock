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

///|
test "a oneof member prints only when the message holds it, even at its default, and a later member replaces an earlier one" {
  let choice = (write : (@protobuf.Writer) -> Unit) => {
    collected("Choice", nested(write))
  }
  inspect(
    choice(w => string_field(w, 1, "none")),
    content=(
      #|{"label":"none"}
    ),
  )
  inspect(
    choice(w => string_field(w, 2, "")),
    content=(
      #|{"label":"","word":""}
    ),
  )
  inspect(
    choice(w => varint_field(w, 3, 0)),
    content=(
      #|{"label":"","number":0}
    ),
  )
  // Every member in turn: the last, the message, stays.
  inspect(
    choice(w => {
      string_field(w, 2, "w")
      varint_field(w, 3, 3)
      message_field(w, 4, nested(w => string_field(w, 1, "pen")))
    }),
    content=(
      #|{"label":"","item":{"name":"pen","sizes":[],"stock":{}}}
    ),
  )
  // The message, then the string: the string stays.
  inspect(
    choice(w => {
      message_field(w, 4, nested(w => string_field(w, 1, "pen")))
      string_field(w, 2, "w")
    }),
    content=(
      #|{"label":"","word":"w"}
    ),
  )
}

///|
test "two values of a oneof's message member are merged, unless another member comes between them" {
  let size = (n : UInt64) => nested(w => varint_field(w, 2, n))
  let choice = (write : (@protobuf.Writer) -> Unit) => {
    collected("Choice", nested(write))
  }
  inspect(
    choice(w => {
      message_field(w, 4, size(1))
      message_field(w, 4, size(2))
    }),
    content=(
      #|{"label":"","item":{"name":"","sizes":[1,2],"stock":{}}}
    ),
  )
  inspect(
    choice(w => {
      message_field(w, 4, size(1))
      varint_field(w, 3, 7)
      message_field(w, 4, size(2))
    }),
    content=(
      #|{"label":"","item":{"name":"","sizes":[2],"stock":{}}}
    ),
  )
  // A member with another wire type than its type's is skipped, so it
  // replaces nothing.
  inspect(
    choice(w => {
      varint_field(w, 3, 7)
      varint_field(w, 2, 1)
    }),
    content=(
      #|{"label":"","number":7}
    ),
  )
}

///|
test "the values of a message field are merged: the last value of a scalar wins, repeated fields are joined and maps merged, the last entry of a key winning" {
  let stock = (key : String, value : UInt64) => {
    nested(w => {
      string_field(w, 1, key)
      varint_field(w, 2, value)
    })
  }
  let first = nested(w => {
    string_field(w, 1, "pen")
    varint_field(w, 2, 1)
    message_field(w, 3, stock("a", 1))
    message_field(w, 3, stock("c", 3))
  })
  let second = nested(w => {
    varint_field(w, 2, 2)
    message_field(w, 3, stock("a", 2))
    message_field(w, 3, stock("b", 5))
  })
  inspect(
    collected(
      "Choice",
      nested(w => {
        message_field(w, 5, first)
        string_field(w, 1, "boxed")
        message_field(w, 5, second)
      }),
    ),
    content=(
      #|{"label":"boxed","box":{"name":"pen","sizes":[1,2],"stock":{"a":2,"b":5,"c":3}}}
    ),
  )
}

///|
test "a repeated field or a map that does not parse is an error at the octet where it breaks" {
  let lists = (write : (@protobuf.Writer) -> Unit) => {
    collected("Lists", nested(write))
  }
  // A packed record that ends inside a varint, and one of fixed32 values
  // that ends inside one.
  inspect(
    lists(w => {
      w.tag(1, Len)
      w.length_delimited(b"\x01\x80")
    }),
    content="error: octet 3: the input ends inside a varint",
  )
  inspect(
    lists(w => {
      w.tag(3, Len)
      w.length_delimited(b"\x01\x00\x00\x00\x02")
    }),
    content="error: octet 6: the input ends inside a fixed 32-bit value",
  )
  // Strings that are not UTF-8: in a list, a map key, and the value of a
  // map entry that a later one replaces.
  inspect(
    lists(w => {
      string_field(w, 8, "ok")
      w.tag(8, Len)
      w.length_delimited(b"\xff")
    }),
    content="error: octet 5: the field words holds octets that are not UTF-8",
  )
  let maps = (write : (@protobuf.Writer) -> Unit) => {
    collected("Maps", nested(write))
  }
  inspect(
    maps(w => {
      message_field(
        w,
        5,
        nested(w => {
          w.tag(1, Len)
          w.length_delimited(b"\xc3\x28")
        }),
      )
    }),
    content="error: octet 3: the field key holds octets that are not UTF-8",
  )
  inspect(
    maps(w => {
      message_field(
        w,
        1,
        nested(w => {
          varint_field(w, 1, 1)
          w.tag(2, Len)
          w.length_delimited(b"\xc3")
        }),
      )
      message_field(w, 1, named(1, "later"))
    }),
    content="error: octet 5: the field value holds octets that are not UTF-8",
  )
  // A map entry that ends inside its value.
  inspect(
    maps(w => message_field(w, 1, b"\x08\x01\x12\x05ab")),
    content="error: octet 5: a length of 5 runs past the end of the input, which has 2 octets left",
  )
}

///|
/// A set of `tree.Tree`, a message with a map of Trees and a list of them,
/// written field by field.
fn tree_set() -> @protobuf.DescriptorSet {
  let field = (
    name : String,
    number : UInt64,
    label : UInt64,
    type_ : UInt64,
    type_name : String,
  ) => {
    nested(w => {
      string_field(w, 1, name)
      varint_field(w, 3, number)
      varint_field(w, 4, label)
      varint_field(w, 5, type_)
      if type_name != "" {
        string_field(w, 6, type_name)
      }
    })
  }
  let entry = message_proto("ChildrenEntry", body=w => {
    message_field(w, 2, field("key", 1, 1, 9, ""))
    message_field(w, 2, field("value", 2, 1, 11, ".tree.Tree"))
    // MessageOptions with map_entry true.
    message_field(w, 7, nested(w => varint_field(w, 7, 1)))
  })
  let tree = message_proto("Tree", body=w => {
    message_field(w, 2, field("children", 1, 3, 11, ".tree.Tree.ChildrenEntry"))
    message_field(w, 2, field("list", 2, 3, 11, ".tree.Tree"))
    message_field(w, 3, entry)
  })
  let file = file_proto("tree.proto", package_name="tree", body=w => {
    message_field(w, 4, tree)
  })
  @protobuf.read_descriptor_set(set_of([file])) catch {
    err => abort("not a set: \{err}")
  }
}

///|
/// `input` decoded as a `tree.Tree`, as text, or the error that stops it.
fn tree(input : Bytes) -> String {
  let set = tree_set()
  guard set.find_message("tree.Tree") is Some(message) else { abort("no Tree") }
  @utf8.decode(@protobuf.decode_json(set, message, input[:])) catch {
    err => "error: \{err}"
  }
}

///|
test "messages in lists and in maps nest 100 deep and no deeper, each map entry counting as a message" {
  // Trees `depth` deep through their lists, and through their maps, where
  // each level is an entry and a Tree.
  let listed = (depth : Int32) => {
    let mut message = b""
    for _ in 0..<depth {
      message = nested(w => message_field(w, 2, message))
    }
    message
  }
  let mapped = (levels : Int32) => {
    let mut message = b""
    for _ in 0..<levels {
      message = nested(w => {
        message_field(w, 1, nested(w => message_field(w, 2, message)))
      })
    }
    message
  }
  let outcome = (text : String) => {
    if text.has_prefix("error: ") {
      text[text.find(": messages").unwrap() + 2:].to_owned()
    } else {
      "decoded"
    }
  }
  inspect(
    [
      outcome(tree(listed(100))),
      outcome(tree(listed(101))),
      outcome(tree(mapped(50))),
      outcome(tree(mapped(51))),
    ].join("\n"),
    content=(
      #|decoded
      #|messages nest deeper than 100
      #|decoded
      #|messages nest deeper than 100
    ),
  )
  inspect(
    tree(mapped(2)),
    content=(
      #|{"children":{"":{"children":{"":{"children":{},"list":[]}},"list":[]}},"list":[]}
    ),
  )
}

///|
test "a repeated field and a map of a well-known type are not decoded yet" {
  let timestamp = file_proto(
    "google/protobuf/timestamp.proto",
    package_name="google.protobuf",
    body=w => {
      message_field(
        w,
        4,
        message_proto("Timestamp", body=w => {
          message_field(w, 2, field_proto("seconds", 1, 3))
        }),
      )
    },
  )
  let field = (name : String, number : UInt64, type_name : String) => {
    nested(w => {
      string_field(w, 1, name)
      varint_field(w, 3, number)
      varint_field(w, 4, 3)
      varint_field(w, 5, 11)
      string_field(w, 6, type_name)
    })
  }
  let stamped = file_proto(
    "stamped.proto",
    package_name="stamped",
    dependencies=["google/protobuf/timestamp.proto"],
    body=w => {
      message_field(
        w,
        4,
        message_proto("History", body=w => {
          message_field(w, 2, field("at", 1, ".google.protobuf.Timestamp"))
        }),
      )
      message_field(
        w,
        4,
        message_proto("ByName", body=w => {
          message_field(w, 2, field("at", 1, ".stamped.ByName.AtEntry"))
          message_field(
            w,
            3,
            message_proto("AtEntry", body=w => {
              message_field(w, 2, field_proto("key", 1, 9))
              message_field(
                w,
                2,
                field_proto(
                  "value",
                  2,
                  11,
                  type_name=".google.protobuf.Timestamp",
                ),
              )
              message_field(w, 7, nested(w => varint_field(w, 7, 1)))
            }),
          )
        }),
      )
    },
  )
  let set = @protobuf.read_descriptor_set(set_of([timestamp, stamped])) catch {
    err => fail("not a set: \{err}")
  }
  let errors = ["stamped.History", "stamped.ByName"].map(name => {
    guard set.find_message(name) is Some(message) else { abort("no \{name}") }
    try @protobuf.decode_json(set, message, b""[:]) catch {
      err => err.to_string()
    } noraise {
      _ => "decoded"
    }
  })
  inspect(
    errors.join("\n"),
    content=(
      #|octet 0: the field at has the well-known type google.protobuf.Timestamp, which smock does not decode yet
      #|octet 0: the field at is a map whose values have the well-known type google.protobuf.Timestamp, which smock does not decode yet
    ),
  )
}
