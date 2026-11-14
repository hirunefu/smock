# smock/protobuf

Protobuf for MoonBit: the wire format, a reader of Descriptor sets
(FileDescriptorSets), the compiled form of `.proto` files that
`protoc --include_imports -o` and `buf build -o` write, and messages
decoded into JSON and encoded from it with their types from a set. smock
reads a Mock's Descriptor set with it, and decodes and encodes the
messages of gRPC calls. The module does no I/O and depends only on
`moonbitlang/core`. It builds for every MoonBit target and is tested on
native and `wasm-gc`.

## The wire format

A message is a sequence of records. Each is a tag, which holds a field
number and a wire type, then a value encoded as the wire type says
([Encoding](https://protobuf.dev/programming-guides/encoding/)).

- `@protobuf.Reader(input)` reads a message in place, a record at a time:
  `tag()` reads a tag and returns its field number, and `wire_type()`
  gives its wire type. Then `varint()`, `fixed64()`, `length_delimited()`
  or `fixed32()` reads the value, or `skip()` skips it, groups included.
  `expect(wire_type)` checks the tag's wire type before a value is read.
  `at_end()` tells when every record is read.
- `@protobuf.Writer()` writes the same: `tag(field, wire_type)`, then the
  value, and `to_bytes()` gives what it wrote.

```mbt check
///|
test "read a message a record at a time" {
  // Field 1 holds the varint 150, and field 2 the string "Tom".
  let reader = @protobuf.Reader(b"\x08\x96\x01\x12\x03Tom"[:])
  let out = []
  while !reader.at_end() {
    match reader.tag() {
      1 => {
        reader.expect(Varint)
        out.push("1: \{reader.varint()}")
      }
      2 => {
        reader.expect(Len)
        out.push("2: \{reader.length_delimited().length()} octets")
      }
      _ => reader.skip()
    }
  }
  inspect(out.join(", "), content="1: 150, 2: 3 octets")
}

///|
test "write the same message" {
  let writer = @protobuf.Writer()
  writer.tag(1, Varint)
  writer.varint(150)
  writer.tag(2, Len)
  writer.length_delimited(b"Tom"[:])
  inspect(writer.to_bytes() == b"\x08\x96\x01\x12\x03Tom", content="true")
}
```

A length-delimited value is a view of the input, so reading allocates
nothing for it. Every length is checked against the octets left before
anything is read. Input that is not protobuf raises `DecodeError`, which
shows as `octet <n>: <message>`:

- a varint, a fixed value or a length that the input ends inside, and a
  varint longer than 10 octets;
- a tag longer than 5 octets, field number 0 or one over 2^29 - 1, and wire
  types 6 and 7;
- a tag whose wire type is not the one `expect` asks for;
- when skipping, a group that the input ends inside, that ends with the
  end tag of another field, that ends where none started, or that nests
  deeper than 100.

The offset is in the bytes the reader's input is a view of, so a reader of
a nested message, made from a view, reports where the problem is in the
whole input.

```mbt check
///|
test "errors say at which octet the input breaks" {
  let message = (input : Bytes, read : (@protobuf.Reader) -> Unit raise) => {
    try read(@protobuf.Reader(input[:])) catch {
      e => e.to_string()
    } noraise {
      _ => "read"
    }
  }
  inspect(
    message(b"\x08\x96", reader => {
      reader.tag() |> ignore
      reader.varint() |> ignore
    }),
    content="octet 1: the input ends inside a varint",
  )
  inspect(
    message(b"\x12\x05Tom", reader => {
      reader.tag() |> ignore
      reader.length_delimited() |> ignore
    }),
    content="octet 1: a length of 5 runs past the end of the input, which has 3 octets left",
  )
  inspect(
    message(b"\x10\x01", reader => {
      reader.tag() |> ignore
      reader.expect(Len)
    }),
    content="octet 0: field 2 has wire type VARINT, not LEN",
  )
}
```

## Descriptor sets

`@protobuf.read_descriptor_set(input)` reads a FileDescriptorSet, as
`protoc --include_imports -o` and `buf build -o` write it, and checks
that it is self-contained. It keeps the descriptor model:

- each file's name, package, syntax (proto2, proto3 or editions) and
  dependencies;
- its messages, nested ones included, with their full names, fields,
  oneofs and extension ranges, and the options `map_entry` and
  `message_set_wire_format`;
- its enums and their values, aliases included;
- its extensions, top-level and nested, and its services and methods,
  with their streaming flags;
- of a field: its number, label, type, type name, extendee, JSON name,
  oneof, proto3 `optional` and the option `packed`.

A field's JSON name is its `json_name`, or else its name in
lowerCamelCase, as protoc computes it. The reader skips every other field
of the set, such as source info, other options and Buf's image
extensions, so a set built with `buf build`'s defaults reads as it is.

It raises `DescriptorSetError`:

- `NotDecoded(DecodeError)` when the input is not protobuf, when a field
  it keeps has another wire type than `descriptor.proto` gives it, when a
  string it keeps is not UTF-8, when a syntax, a label or a type is not
  one that `descriptor.proto` defines, and when messages nest deeper than
  100;
- `Invalid(problems)`, with every problem, when a file is in the set more
  than once or imports one that is not in it, when a full name is defined
  twice, when a message uses a field number twice or names a oneof it
  does not have, when a type that a field, a method or an extension names
  is not in the set, and when an extension's number is not one its
  message declares for extensions, or is taken by another extension.
  Types are checked once every import is in the set and every name is
  defined once, so a missing import gives no other problem. A set whose
  full names would take more than 16 MiB is refused too, as soon as they
  do.

```mbt check
///|
test "read a Descriptor set" {
  // One file, a.proto, in package demo, with syntax "proto3".
  let set = @protobuf.read_descriptor_set(
    b"\x0a\x17\x0a\x07a.proto\x12\x04demo\x62\x06proto3"[:],
  )
  let file = set.files[0]
  inspect(
    "\{file.name} \{file.package_name} \{file.syntax == Proto3}",
    content="a.proto demo true",
  )
}

///|
test "a set that lacks an import is refused" {
  // The file a.proto, which imports b.proto.
  let input = b"\x0a\x12\x0a\x07a.proto\x1a\x07b.proto"
  let problems = try @protobuf.read_descriptor_set(input[:]) catch {
    Invalid(problems) => problems.join("\n")
    NotDecoded(err) => "\{err}"
  } noraise {
    _ => "read"
  }
  inspect(
    problems,
    content="a.proto imports b.proto, which is not in the set; build the set with protoc --include_imports, or with buf build",
  )
}
```

## Lookups

Decoding, encoding and conditions share these lookups. Each reads an
index built when the set is read, so none walks the set.

- `set.find_method(path)`: a method by the path gRPC calls it by, such as
  `/helloworld.Greeter/SayHello`; `set.input_of(method)` and
  `set.output_of(method)` give its types.
- `set.find_message(full_name)`, `set.find_enum(full_name)` and
  `set.find_extension(full_name)`: by a full name without a leading dot,
  such as `helloworld.HelloRequest` or `shop.priority`.
- `set.message_of(field)` and `set.enum_of(field)`: a field's message,
  group or enum type.
- `message.find_field_by_name(name)`,
  `message.find_field_by_json_name(name)` and
  `message.find_field_by_number(number)`: a field by its proto name, its
  JSON name or its number. `message.find_extension(number)`: the extension
  of the set that extends the message with that number.
- `enum.find_value_by_name(name)` and `enum.find_value_by_number(number)`:
  a value by its name, or by its number, which gives its first name when
  aliases share the number.

```mbt check
///|
test "find a method, its input type and a field" {
  // greeter.proto: package g, a message Req with the field user_name, and
  // a service Greeter with the method Hi from Req to Req.
  let set = @protobuf.read_descriptor_set(
    b"\x0a\x53\x0a\x0dgreeter.proto\x12\x01g\x22\x16\x0a\x03Req\x12\x0f\x0a\x09user_name\x18\x01\x28\x09\x32\x1f\x0a\x07Greeter\x12\x14\x0a\x02Hi\x12\x06.g.Req\x1a\x06.g.Req\x62\x06proto3"[:],
  )
  guard set.find_method("/g.Greeter/Hi") is Some(hi) else { fail("no Hi") }
  let input = set.input_of(hi)
  guard input.find_field_by_json_name("userName") is Some(field) else {
    fail("no userName")
  }
  inspect(
    "\{input.full_name}: \{field.name} = \{field.number}",
    content="g.Req: user_name = 1",
  )
}
```

## Messages

`@protobuf.decode_json(set, message, input)` decodes a message of the
type `message`, a `MessageDescriptor` of `set`, into smock's decoded form:
compact JSON text in UTF-8, with one member per field, in field-number
order, under the field's JSON name, as `json_name` gives it.

- 64-bit integers are JSON numbers, exact at any size, and so are 32-bit
  integers. A double is printed as `Double::to_string` prints it, and a
  float in the shortest form that reads back as the same 32-bit float, so
  0.1f prints `0.1`. NaN and the infinities are the strings `"NaN"`,
  `"Infinity"` and `"-Infinity"`.
- bytes are standard base64 with padding. An enum value is printed by its
  name, the first one of an alias, or by its number when the enum does not
  define it. A nested message is an object.
- A field without presence that the message leaves out is printed at its
  default. A proto3 `optional` field and a message field are printed only
  when the message holds them.

It reads the message as protobuf's parsers read it: the last value of a
scalar field wins, the values of a message field are merged, and unknown
fields are skipped. It raises `DecodeError` when the input is not
protobuf, a string is not UTF-8, or messages nest deeper than 100. It
does not decode repeated fields, maps, oneofs, groups and the well-known
types yet, and raises its error for a message that has one.

`set.encode_json(message, json)` encodes JSON, a message of the type
`message`, a type of `set`, as ProtoJSON writes it, the way protoc encodes
it: fields in field-number order, a field without presence left out at its
default, repeated scalars packed unless the field says `packed = false`,
and map entries sorted by key. It reads JSON as ProtoJSON reads it: a key
may be the field's proto name or its JSON name, `null` leaves a field
unset, an enum is a name or a number, a 64-bit integer a number or a
string, exact at any size, a float `"NaN"`, `"Infinity"` or `"-Infinity"`
too, and bytes are base64, standard or URL-safe, with or without padding.
It raises `EncodeError`, which names the JSON Pointer of the value at
fault, for JSON that is not a message of the type, and for the types it
does not encode yet: the well-known types, such as
`google.protobuf.Timestamp`, and types of files that are not proto3.
`@protobuf.is_well_known(full_name)` tells the well-known types.

```mbt check
///|
test "decode a message, and encode one" {
  // message CountRequest { string shelf = 1; bool in_stock = 2; }
  let set = @protobuf.read_descriptor_set(
    b"\x0a\x48\x0a\x07a.proto\x12\x04demo\x22\x2f\x0a\x0cCountRequest\x12\x0d\x0a\x05shelf\x18\x01\x20\x01\x28\x09\x12\x10\x0a\x08in_stock\x18\x02\x20\x01\x28\x08\x62\x06proto3"[:],
  )
  let count = set.files[0].messages[0]
  let json = @protobuf.decode_json(set, count, b"\x0a\x02A1\x10\x01"[:])
  inspect(@utf8.decode(json), content="{\"shelf\":\"A1\",\"inStock\":true}")
  inspect(
    set.encode_json(count, { "in_stock": true, "shelf": "A1" }) ==
    b"\x0a\x02A1\x10\x01",
    content="true",
  )
}
```
