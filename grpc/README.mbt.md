# smock/grpc

gRPC's wire rules for MoonBit: the content type of gRPC calls, the 5-octet
prefix that frames each message, gRPC's seventeen status codes with their
names, and the percent-encoding of a status message. smock serves gRPC unary calls with it, beside
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

- `@grpc.next_message(body)` gives the message at the start of `body`,
  with its flag and the octets after it, or tells how the body ends:
  `Done` when nothing is left, `InPrefix` when it ends inside a prefix, and
  `InMessage(length~)` when it ends inside a message. It copies nothing.
- `@grpc.frame(message)` frames a message, uncompressed.

```mbt check
///|
test "take the one message of a call's body" {
  // HelloRequest { name: "Tom" }, framed.
  let body = b"\x00\x00\x00\x00\x05\x0a\x03Tom"
  guard @grpc.next_message(body[:]) is Message(flag~, message~, rest~) else {
    fail("no message")
  }
  inspect(flag, content="b'\\x00'")
  inspect(message.length(), content="5")
  inspect(@grpc.next_message(rest) is Done, content="true")
}

///|
test "a body that ends early is told apart" {
  inspect(@grpc.next_message(b"\x00\x00\x00"[:]) is InPrefix, content="true")
  debug_inspect(
    @grpc.next_message(b"\x00\x00\x00\x00\x05\x0a"[:]),
    content="InMessage(length=5)",
  )
}

///|
test "frame a reply's message" {
  inspect(
    @grpc.frame(b"\x0a\x03Tom"[:]) == b"\x00\x00\x00\x00\x05\x0a\x03Tom",
    content="true",
  )
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
