// gRPC's content type: a request whose `content-type` is `application/grpc`,
// alone or followed by `+` or `;`, is a gRPC call, and the text after `+`,
// up to any `;`, is its content subtype, which names the codec of its
// messages: none, or `proto`, for protobuf
// (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md).

///|
/// The content type of gRPC calls and of their replies.
pub let content_type : String = "application/grpc"

///|
/// The octets of `content_type`.
let content_type_octets : Bytes = b"application/grpc"

///|
/// The content subtype of the request whose `content-type` field has the
/// value `value`, when that value makes the request a gRPC call: when it is
/// `application/grpc`, alone or followed by `+` or `;`. The subtype is the
/// text after `+`, up to any `;`, such as `proto` for
/// `application/grpc+proto;v=1`, and is empty when there is none, as for
/// `application/grpc` and `application/grpc;v=1`. `None` when `value`
/// makes no gRPC call, as `application/grpc-web` and `application/json`
/// do. The value is compared as sent, in its case, as gRPC's servers
/// compare it. The subtype is a view of `value`, so nothing is copied.
pub fn content_subtype(value : BytesView) -> BytesView? {
  let base = content_type_octets.length()
  if value.length() < base {
    return None
  }
  for i in 0..<base {
    if value[i] != content_type_octets[i] {
      return None
    }
  }
  if value.length() == base {
    return Some(value[base:base])
  }
  match value[base] {
    b';' => Some(value[base:base])
    b'+' => {
      let start = base + 1
      for i in start..<value.length() {
        if value[i] == b';' {
          return Some(value[start:i])
        }
      }
      Some(value[start:])
    }
    _ => None
  }
}
