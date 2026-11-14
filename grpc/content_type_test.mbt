// gRPC's content type through the module's public interface: which values
// of a request's `content-type` field make it a gRPC call, and the call's
// content subtype
// (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md).

///|
/// What `value`, as a `content-type` field value, makes a request: `call`
/// and its subtype in quotes, or `not a call`.
fn call_of(value : Bytes) -> String {
  match @grpc.content_subtype(value[:]) {
    Some(subtype) => {
      let out = StringBuilder()
      for octet in subtype {
        out.write_char(octet.to_int().unsafe_to_char())
      }
      "call \"\{out}\""
    }
    None => "not a call"
  }
}

///|
/// Each of `values` and what it makes a request, one per line.
fn calls_of(values : Array[Bytes]) -> String {
  values
  .map(value => {
    let shown = StringBuilder()
    for octet in value {
      shown.write_char(octet.to_int().unsafe_to_char())
    }
    "\{shown}: \{call_of(value)}"
  })
  .join("\n")
}

///|
test "application/grpc, alone or followed by + or ;, makes a gRPC call, whose subtype is the text after +, up to any ;" {
  inspect(
    calls_of([
      b"application/grpc",
      b"application/grpc+proto",
      b"application/grpc;v=1",
      b"application/grpc+proto;v=1",
      b"application/grpc+proto; charset=utf-8",
      b"application/grpc+json",
      b"application/grpc+json;v=1",
      b"application/grpc+proto+json",
      b"application/grpc;subtype=+json",
    ]),
    content=(
      #|application/grpc: call ""
      #|application/grpc+proto: call "proto"
      #|application/grpc;v=1: call ""
      #|application/grpc+proto;v=1: call "proto"
      #|application/grpc+proto; charset=utf-8: call "proto"
      #|application/grpc+json: call "json"
      #|application/grpc+json;v=1: call "json"
      #|application/grpc+proto+json: call "proto+json"
      #|application/grpc;subtype=+json: call ""
    ),
  )
}

///|
test "a + or a ; with nothing after it leaves the subtype empty" {
  inspect(
    calls_of([b"application/grpc+", b"application/grpc;", b"application/grpc+;"]),
    content=(
      #|application/grpc+: call ""
      #|application/grpc;: call ""
      #|application/grpc+;: call ""
    ),
  )
}

///|
test "any other content type makes no gRPC call, gRPC-Web's and one that only begins like gRPC's included" {
  inspect(
    calls_of([
      b"application/grpc-web",
      b"application/grpc-web+proto",
      b"application/grpc-web-text",
      b"application/grpcx",
      b"application/grpc ;v=1",
      b"application/grp",
      b"application/json",
      b"",
    ]),
    content=(
      #|application/grpc-web: not a call
      #|application/grpc-web+proto: not a call
      #|application/grpc-web-text: not a call
      #|application/grpcx: not a call
      #|application/grpc ;v=1: not a call
      #|application/grp: not a call
      #|application/json: not a call
      #|: not a call
    ),
  )
}

///|
test "the content type is compared as sent, in its case" {
  inspect(
    calls_of([b"Application/gRPC", b"APPLICATION/GRPC+PROTO"]),
    content=(
      #|Application/gRPC: not a call
      #|APPLICATION/GRPC+PROTO: not a call
    ),
  )
}

///|
test "the subtype is a view of the value, which nothing copies" {
  let value = b"application/grpc+proto;v=1"
  guard @grpc.content_subtype(value[:]) is Some(subtype) else {
    fail("not a call")
  }
  inspect(subtype.start_offset(), content="17")
  inspect(subtype.length(), content="5")
}

///|
test "the content type of gRPC calls and replies is application/grpc" {
  inspect(@grpc.content_type, content="application/grpc")
}
