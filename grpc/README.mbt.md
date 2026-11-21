# smock/grpc

gRPC's wire rules for MoonBit: the content type of gRPC calls, the 5-octet
prefix that frames each message, read as a body arrives, the
`grpc-timeout` a client gives a call, gRPC's seventeen status codes with
their names, the percent-encoding of a status message, and the rules of
reply metadata. smock serves gRPC unary calls with it, beside
`smock/protobuf`, which encodes the messages. The module does no I/O and
depends only on `moonbitlang/core`. It builds for every MoonBit target and
is tested on native and `wasm-gc`.

## Content type

A gRPC call is an HTTP/2 request whose `content-type` is
`application/grpc`, alone or followed by `+` or `;`. The text after `+`, up
to any `;`, is the call's content subtype, which names the codec of its
messages: none, or `proto`, for protobuf.

- `@grpc.content_subtype(value)` gives the subtype of a call whose
  `content-type` has the value `value`, empty when there is none, or `None`
  when the value makes no gRPC call. It copies nothing.
- `@grpc.content_type` is `application/grpc`, the content type of replies.

```mbt check
///|
test "tell a gRPC call by its content type" {
  guard @grpc.content_subtype(b"application/grpc+proto;v=1"[:]) is Some(subtype) else {
    fail("not a call")
  }
  inspect(subtype == b"proto"[:], content="true")
  guard @grpc.content_subtype(b"application/grpc;v=1"[:]) is Some(none) else {
    fail("not a call")
  }
  inspect(none.length(), content="0")
  inspect(
    @grpc.content_subtype(b"application/grpc-web"[:]) is None,
    content="true",
  )
}
```

## Messages

The body of a gRPC call, and the body of its reply, are messages, each
after a 5-octet prefix: a flag octet, 1 when the message is
compressed, then the message's length in 4 octets, big-endian
([gRPC over HTTP/2](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md)).

- `@grpc.Deframer()` reads a body as it arrives, in pieces split
  anywhere. `take(piece)` tells the next prefix the piece ends, with its
  flag, its message's length, the length of the body through that message
  and the octets of the piece after it; or `All` when the piece ends no
  prefix. Each prefix is known as soon as its last octet arrives, so a
  length over a limit can be refused before the message arrives.
  `ending()` tells how the body ends: after `Whole(messages~)` messages,
  `InPrefix` or `InMessage(length~)`. `whole_messages()` counts the
  messages that have arrived whole so far, so the first message of a
  stream that the client keeps open can be read before the body ends. It
  copies nothing and keeps no octet of a message.
- `@grpc.frame(message)` frames a message, uncompressed.

```mbt check
///|
test "read the one message of a call's body as it arrives" {
  // HelloRequest { name: "Tom" }, framed, in two pieces.
  let deframer = @grpc.Deframer()
  inspect(deframer.take(b"\x00\x00\x00"[:]) is All, content="true")
  guard deframer.take(b"\x00\x05\x0a\x03Tom"[:])
    is Prefix(flag~, length~, body_length~, rest~) else {
    fail("no prefix")
  }
  inspect(flag, content="b'\\x00'")
  inspect(length, content="5")
  inspect(body_length, content="10")
  inspect(deframer.whole_messages(), content="0")
  inspect(deframer.take(rest) is All, content="true")
  inspect(deframer.whole_messages(), content="1")
  debug_inspect(deframer.ending(), content="Whole(messages=1)")
}

///|
test "a body that ends early is told apart" {
  let deframer = @grpc.Deframer()
  let _ = deframer.take(b"\x00\x00\x00"[:])
  debug_inspect(deframer.ending(), content="InPrefix")
  let _ = deframer.take(b"\x00\x05\x0a"[:])
  debug_inspect(deframer.ending(), content="InMessage(length=5)")
}

///|
test "frame a reply's message" {
  inspect(
    @grpc.frame(b"\x0a\x03Tom"[:]) == b"\x00\x00\x00\x00\x05\x0a\x03Tom",
    content="true",
  )
}
```

## Timeouts

A client gives a call its time in `grpc-timeout`: 1 to 8 digits, then
the unit, `H` hours, `M` minutes, `S` seconds, `m` milliseconds, `u`
microseconds or `n` nanoseconds.
`@grpc.timeout_ns(value)` reads that value as nanoseconds, or gives `None`
when it is malformed. A timeout of 0 is read, in any unit. Eight digits of
hours are more nanoseconds than an `Int64` holds, so they saturate at
`0x7FFF_FFFF_FFFF_FFFF` rather than wrap. PROTOCOL-HTTP2 gives only the
value's form, so that saturated value, 9,223,372,036,855 ms in whole
milliseconds, is the module's own: the maintainer confirmed it on
2026-11-21 (#327).

```mbt check
///|
test "read a call's timeout" {
  debug_inspect(@grpc.timeout_ns("250m"), content="Some(250000000)")
  debug_inspect(@grpc.timeout_ns("0n"), content="Some(0)")
  debug_inspect(
    @grpc.timeout_ns("99999999H"),
    content="Some(9223372036854775807)",
  )
  debug_inspect(@grpc.timeout_ns("1x"), content="None")
}
```

`@grpc.timeout_ms(value)` gives the same timeout in whole milliseconds,
rounded up, so that a timeout above 0 is never 0 ms: `1n` is 1 ms. The
maintainer confirmed that rounding on 2026-11-21 (#327). A server that
keeps time in milliseconds counts a call's deadline with it.

```mbt check
///|
test "read a call's timeout in milliseconds" {
  debug_inspect(@grpc.timeout_ms("5S"), content="Some(5000)")
  debug_inspect(@grpc.timeout_ms("1n"), content="Some(1)")
  debug_inspect(@grpc.timeout_ms("0m"), content="Some(0)")
  debug_inspect(@grpc.timeout_ms("99999999H"), content="Some(9223372036855)")
  debug_inspect(@grpc.timeout_ms("1x"), content="None")
}
```

## Status codes

`@grpc.Status` has gRPC's seventeen status codes
([Status codes](https://grpc.github.io/grpc/core/md_doc_statuscodes.html)),
from `Ok`, 0, to `Unauthenticated`, 16. `code()` gives the number that
`grpc-status` carries, and `name()` the name, such as `NOT_FOUND`.
`Status::from_code` and `Status::from_name` read them back.

```mbt check
///|
test "a status by its number and by its name" {
  let status = @grpc.Status::NotFound
  inspect(status.code(), content="5")
  inspect(status.name(), content="NOT_FOUND")
  debug_inspect(@grpc.Status::from_name("INTERNAL"), content="Some(Internal)")
  debug_inspect(@grpc.Status::from_code(17), content="None")
}
```

## Status messages

A reply's status message goes in `grpc-message`, percent-encoded, so that
any Unicode text fits in an HTTP/2 field value.
`@grpc.percent_encode(text)` gives that value: the text's UTF-8 octets,
each from 0x20 to 0x7E other than `%` as it is, and every other octet as
`%` and two upper-case hex digits. A space at either end becomes `%20`
too, since HTTP/2 refuses a field value with a space at either end.

```mbt check
///|
test "percent-encode a status message" {
  inspect(
    @grpc.percent_encode(" try again ☺ ") == b"%20try again %E2%98%BA%20",
    content="true",
  )
}
```

## Metadata

A reply's metadata, in its HEADERS and its trailers, follows gRPC's
grammar. A name holds one or more of `0-9`, `a-z`, `_`, `-` and `.`, and
gRPC keeps `content-type`, `te` and every name that starts with `grpc-` for
itself. The value of ASCII metadata holds characters from 0x20 to 0x7E.
Binary metadata has a name that ends with `-bin`, and its value is
standard base64, padded or not, which gRPC sends without its padding. A
call's binary metadata loses its padding too, so that padded and unpadded
clients look alike.

- `@grpc.is_metadata_name(name)` tells a name of the grammar, given in
  lower case; `@grpc.is_reserved_name(name)` one that gRPC keeps.
- `@grpc.is_binary_name(name)` tells the name of binary metadata.
- `@grpc.is_ascii_value(value)` tells the value of ASCII metadata.
- `@grpc.unpadded_base64(value)` gives the value of binary metadata without
  its padding, or `None` when it is not base64. It copies nothing.
- `@grpc.unpadded_elements(value)` gives the value of binary metadata as a
  call carries it without the padding that ends each comma-separated
  element, since a proxy may join repeated fields with commas. It checks
  nothing and decodes nothing, and gives `value` itself when there is no
  padding.

```mbt check
///|
test "check reply metadata" {
  inspect(@grpc.is_metadata_name("x-trace"), content="true")
  inspect(@grpc.is_metadata_name("x(trace)"), content="false")
  inspect(@grpc.is_reserved_name("grpc-foo"), content="true")
  inspect(@grpc.is_ascii_value("caf\u{e9}"), content="false")
  inspect(@grpc.is_binary_name("trace-bin"), content="true")
  guard @grpc.unpadded_base64("AAE=") is Some(value) else { fail("not base64") }
  inspect(value, content="AAE")
  inspect(@grpc.unpadded_base64("AA=") is None, content="true")
  inspect(@grpc.unpadded_elements("AAA=,BBB="), content="AAA,BBB")
}
```
