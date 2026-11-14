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

`@protobuf.read_descriptor_set(input)` reads a FileDescriptorSet. It keeps
each file's name, package, syntax and dependencies; its top-level messages,
with their fields (name, number, label, type and type name) and whether
they set `message_set_wire_format`; and its services and methods, with
their input and output types and streaming flags. It skips every other
field of the set, such as source info, options and Buf's image extensions.

It raises `DecodeError` when the input is not protobuf, when a field it
keeps has another wire type than `descriptor.proto` gives it, when a string
it keeps is not UTF-8, and when a syntax, a label or a type is not one that
`descriptor.proto` defines. It checks nothing more: files may repeat, and
type names need not resolve.

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
```

## Messages

`@protobuf.decode_json(message, input)` decodes a message of the type
`message`, a `MessageDescriptor` of a set, into smock's decoded form:
compact JSON text in UTF-8, with one member per field, in field-number
order, under the field's JSON name, its name in lowerCamelCase as protoc
computes it. A field the message leaves out is printed at its default. It
reads the message as protobuf's parsers read it: the last value of a field
wins, and unknown fields are skipped. It raises `DecodeError` when the
input is not protobuf, or a string is not UTF-8.

`@protobuf.encode_json(message, json)` encodes JSON, as ProtoJSON writes a
message, the way protoc encodes it: fields in field-number order, each left
out at its default. A key may be the field's proto name or its JSON name.
It raises `EncodeError`, which names the JSON Pointer of the value at
fault, for JSON that is not a message of the type.

Both serve types whose fields are singular `string`, `bool` and `int32`
fields for now, and raise their error for a type with any other field.

```mbt check
///|
test "decode a message, and encode one" {
  // message CountRequest { string shelf = 1; bool in_stock = 2; }
  let set = @protobuf.read_descriptor_set(
    b"\x0a\x48\x0a\x07a.proto\x12\x04demo\x22\x2f\x0a\x0cCountRequest\x12\x0d\x0a\x05shelf\x18\x01\x20\x01\x28\x09\x12\x10\x0a\x08in_stock\x18\x02\x20\x01\x28\x08\x62\x06proto3"[:],
  )
  let count = set.files[0].messages[0]
  let json = @protobuf.decode_json(count, b"\x0a\x02A1\x10\x01"[:])
  inspect(@utf8.decode(json), content="{\"shelf\":\"A1\",\"inStock\":true}")
  inspect(
    @protobuf.encode_json(count, { "in_stock": true, "shelf": "A1" }) ==
    b"\x0a\x02A1\x10\x01",
    content="true",
  )
}
```
