// gRPC's messages on the wire: each message of a call or a reply is framed
// with a 5-octet prefix, a flag octet, 1 when the message is compressed,
// then the message's length in 4 octets, big-endian
// (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md).

///|
/// The length of a message's prefix, in octets.
pub let prefix_length : Int32 = 5

///|
/// What comes next in a request or reply body made of framed messages.
#derive(Eq, Debug)
pub(all) enum Framed {
  /// The body ends here: every message has been taken.
  Done
  /// A whole message: the flag of its prefix, 0 for a message as it is and
  /// 1 for a compressed one, though any octet is passed on, the message's
  /// octets, and the octets after it.
  Message(flag~ : Byte, message~ : BytesView, rest~ : BytesView)
  /// The body ends inside a prefix.
  InPrefix
  /// The body ends inside a message: its prefix announces `length` octets,
  /// and fewer follow.
  InMessage(length~ : UInt32)
}

///|
/// The message at the start of `input`, a body made of framed messages, or
/// how the body ends instead. The message and the rest are views of
/// `input`, so nothing is copied. A length is read whole, as an unsigned
/// number, and compared with the octets left before anything is taken.
pub fn next_message(input : BytesView) -> Framed {
  if input.length() == 0 {
    return Done
  }
  if input.length() < prefix_length {
    return InPrefix
  }
  let length = (input[1].to_uint() << 24) |
    (input[2].to_uint() << 16) |
    (input[3].to_uint() << 8) |
    input[4].to_uint()
  let left = (input.length() - prefix_length).reinterpret_as_uint()
  if length > left {
    return InMessage(length~)
  }
  let end = prefix_length + length.reinterpret_as_int()
  Message(flag=input[0], message=input[prefix_length:end], rest=input[end:])
}

///|
/// `message` framed as it is, uncompressed: flag 0, its length, then its
/// octets.
pub fn frame(message : BytesView) -> Bytes {
  let length = message.length()
  let out = FixedArray::make(prefix_length + length, b'\x00')
  out[1] = (length >> 24).to_byte()
  out[2] = (length >> 16).to_byte()
  out[3] = (length >> 8).to_byte()
  out[4] = length.to_byte()
  out.blit_from_bytesview(prefix_length, message)
  out.unsafe_reinterpret_as_bytes()
}
