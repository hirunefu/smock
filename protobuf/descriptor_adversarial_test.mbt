// Adversarial Descriptor sets, through the public interface: truncated
// and corrupted sets, wrong wire types and lengths in every part of the
// model, and nesting without end. Each is read or refused, and none
// crashes.

///|
/// How reading `bytes` ends: `read`, `not decoded` or `invalid`.
fn set_outcome(bytes : BytesView) -> String {
  try @protobuf.read_descriptor_set(bytes) catch {
    NotDecoded(_) => "not decoded"
    Invalid(_) => "invalid"
  } noraise {
    _ => "read"
  }
}

///|
/// How many of `outcomes` are each outcome.
fn tally(outcomes : Array[String]) -> String {
  let counts : Map[String, Int32] = Map([])
  for outcome in outcomes {
    counts[outcome] = counts.get(outcome).unwrap_or(0) + 1
  }
  counts.iter().map(entry => "\{entry.0}: \{entry.1}").collect().join(", ")
}

///|
test "every prefix of a protoc-built set is read or refused" {
  let bytes = @hex.decode(shop_set.replace_all(old="\n", new=""))
  let outcomes = []
  for length in 0..<bytes.length() {
    outcomes.push(set_outcome(bytes[:length]))
  }
  outcomes.push(set_outcome(bytes[:]))
  // The empty set, the prefix that ends after common.proto, and the whole
  // set read; the prefix that also holds legacy.proto reads too.
  inspect(tally(outcomes), content="read: 4, not decoded: 1309")
}

///|
test "every octet of a protoc-built set changed to 0x00, 0x7f or 0xff is read or refused" {
  let bytes = @hex.decode(shop_set.replace_all(old="\n", new=""))
  let outcomes = []
  for at in 0..<bytes.length() {
    for octet in [b'\x00', b'\x7f', b'\xff'] {
      let changed = bytes.to_array()
      changed[at] = octet
      outcomes.push(set_outcome(Bytes::from_array(changed)[:]))
    }
  }
  inspect(
    tally(outcomes),
    content=(
      #|not decoded: 2237, invalid: 859, read: 840
    ),
  )
}

///|
test "a field the model keeps, at any depth, with another wire type than descriptor.proto gives it is refused at its tag" {
  // Each case: a file, holding a message, holding what the case writes.
  let message_with = (write : (@protobuf.Writer) -> Unit) => {
    nested(w => {
      message_field(
        w,
        1,
        nested(w => {
          string_field(w, 1, "a.proto")
          message_field(
            w,
            4,
            nested(w => {
              string_field(w, 1, "M")
              write(w)
            }),
          )
        }),
      )
    })
  }
  let cases : Array[(String, (@protobuf.Writer) -> Unit)] = [
    ("a nested message as a varint", w => varint_field(w, 3, 1)),
    ("an enum as a varint", w => varint_field(w, 4, 1)),
    ("an extension range as a varint", w => varint_field(w, 5, 1)),
    ("an extension as a varint", w => varint_field(w, 6, 1)),
    ("a oneof as a varint", w => varint_field(w, 8, 1)),
    (
      "an extension range's start as a string",
      w => message_field(w, 5, nested(w => string_field(w, 1, "1"))),
    ),
    (
      "map_entry as a string",
      w => message_field(w, 7, nested(w => string_field(w, 7, "1"))),
    ),
    (
      "a oneof's name as a varint",
      w => message_field(w, 8, nested(w => varint_field(w, 1, 1))),
    ),
    (
      "a field's extendee as a varint",
      w => message_field(w, 2, nested(w => varint_field(w, 2, 1))),
    ),
    (
      "a field's packed as a string",
      w => {
        message_field(
          w,
          2,
          nested(w => message_field(w, 8, nested(w => string_field(w, 2, "")))),
        )
      },
    ),
    (
      "a field's oneof_index as a string",
      w => message_field(w, 2, nested(w => string_field(w, 9, "0"))),
    ),
    (
      "a field's json_name as a varint",
      w => message_field(w, 2, nested(w => varint_field(w, 10, 1))),
    ),
    (
      "a field's proto3_optional as a string",
      w => message_field(w, 2, nested(w => string_field(w, 17, ""))),
    ),
    (
      "an enum value as a varint",
      w => message_field(w, 4, nested(w => varint_field(w, 2, 1))),
    ),
    (
      "an enum value's number as a string",
      w => {
        message_field(
          w,
          4,
          nested(w => message_field(w, 2, nested(w => string_field(w, 2, "1")))),
        )
      },
    ),
  ]
  let out = []
  for case in cases {
    let (name, write) = case
    out.push("\{name}: \{read(message_with(write))}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|a nested message as a varint: error: octet 16: field 3 has wire type VARINT, not LEN
      #|an enum as a varint: error: octet 16: field 4 has wire type VARINT, not LEN
      #|an extension range as a varint: error: octet 16: field 5 has wire type VARINT, not LEN
      #|an extension as a varint: error: octet 16: field 6 has wire type VARINT, not LEN
      #|a oneof as a varint: error: octet 16: field 8 has wire type VARINT, not LEN
      #|an extension range's start as a string: error: octet 18: field 1 has wire type LEN, not VARINT
      #|map_entry as a string: error: octet 18: field 7 has wire type LEN, not VARINT
      #|a oneof's name as a varint: error: octet 18: field 1 has wire type VARINT, not LEN
      #|a field's extendee as a varint: error: octet 18: field 2 has wire type VARINT, not LEN
      #|a field's packed as a string: error: octet 20: field 2 has wire type LEN, not VARINT
      #|a field's oneof_index as a string: error: octet 18: field 9 has wire type LEN, not VARINT
      #|a field's json_name as a varint: error: octet 18: field 10 has wire type VARINT, not LEN
      #|a field's proto3_optional as a string: error: octet 18: field 17 has wire type LEN, not VARINT
      #|an enum value as a varint: error: octet 18: field 2 has wire type VARINT, not LEN
      #|an enum value's number as a string: error: octet 20: field 2 has wire type LEN, not VARINT
    ),
  )
}

///|
test "a length that runs past the end of the message it is in is refused, however deep" {
  // A set whose file's message's nested message claims 9 octets, of which
  // the message holds 1.
  let set = b"\x0a\x0b\x0a\x01a\x22\x06\x0a\x01M\x1a\x09\x0a"
  inspect(
    read(set),
    content=(
      #|error: octet 11: a length of 9 runs past the end of the input, which has 1 octets left
    ),
  )
}

///|
/// The number of octets that `value` takes as a varint.
fn varint_length(value : Int32) -> Int32 {
  let mut length = 1
  let mut rest = value
  while rest >= 0x80 {
    rest = rest >> 7
    length = length + 1
  }
  length
}

///|
/// A set of one file holding `depth` messages, each named `M` and nested in
/// the one before, written in one pass.
fn nest(depth : Int32) -> Bytes {
  // sizes[k] is the size of a message with k messages nested in it.
  let sizes = [3]
  for k in 1..<depth {
    let inner = sizes[k - 1]
    sizes.push(3 + 1 + varint_length(inner) + inner)
  }
  let top = sizes[depth - 1]
  let file = 3 + 1 + varint_length(top) + top
  let w = @protobuf.Writer()
  w.tag(1, Len)
  w.varint(file.to_uint64())
  string_field(w, 1, "a")
  w.tag(4, Len)
  w.varint(top.to_uint64())
  for k = depth - 1; k >= 0; k = k - 1 {
    string_field(w, 1, "M")
    if k > 0 {
      w.tag(3, Len)
      w.varint(sizes[k - 1].to_uint64())
    }
  }
  w.to_bytes()
}

///|
test "messages nested deeper than 100 are refused, as protobuf's parsers refuse them" {
  inspect(set_outcome(nest(100)[:]), content="read")
  inspect(
    read(nest(101)),
    content=(
      #|error: octet 584: messages nest deeper than 100
    ),
  )
  inspect(set_outcome(nest(100000)[:]), content="not decoded")
}

///|
test "a set whose full names would take more than 16 MiB is refused as soon as they do" {
  // A message with a name of 65535 letters and fields without a name: each
  // field's full name takes 65536 characters, so the 257th field passes
  // 16 MiB.
  let fields = (count : Int32) => {
    nested(w => {
      message_field(
        w,
        1,
        nested(w => {
          string_field(w, 1, "a.proto")
          message_field(
            w,
            4,
            nested(w => {
              string_field(w, 1, String::make(65535, 'M'))
              for _ in 0..<count {
                message_field(w, 2, b"")
              }
            }),
          )
        }),
      )
    })
  }
  // A package of 8192 one-letter names, a.a.a and so on, defines a
  // package for each prefix, whose names take more than 16 MiB together.
  let package_of = (count : Int32) => {
    let package_name = Array::make(count, "a").join(".")
    nested(w => {
      message_field(
        w,
        1,
        nested(w => {
          string_field(w, 1, "a.proto")
          string_field(w, 2, package_name)
        }),
      )
    })
  }
  // At the bound, the set is read whole, and refused for its 256 fields
  // with one number and one name.
  inspect(set_outcome(fields(256)[:]), content="invalid")
  inspect(
    read(fields(257)),
    content=(
      #|error: the full names of the set take more than 16 MiB
    ),
  )
  inspect(
    set_outcome(package_of(4000)[:]),
    content=(
      #|read
    ),
  )
  inspect(
    read(package_of(8192)),
    content=(
      #|error: the full names of the set take more than 16 MiB
    ),
  )
}
