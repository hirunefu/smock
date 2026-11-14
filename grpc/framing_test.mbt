// gRPC's message framing through the module's public interface: the
// 5-octet prefix, a flag and a 4-octet big-endian length, before each
// message (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md),
// with input that ends inside a prefix or inside a message.

///|
/// The messages `input` holds, one per line as their flag and their octets
/// in hex, then how the input ends.
fn messages(input : Bytes) -> String {
  let out = []
  let mut rest = input[:]
  for ;; {
    match @grpc.next_message(rest) {
      Message(flag~, message~, rest=after) => {
        out.push("message flag \{flag.to_int()}: \{@hex.encode(message)}")
        rest = after
      }
      Done => {
        out.push("done")
        break
      }
      InPrefix => {
        out.push("ends inside a prefix")
        break
      }
      InMessage(length~) => {
        out.push("ends inside a message of \{length} octets")
        break
      }
    }
  }
  out.join("\n")
}

///|
test "a message is a flag, its length in 4 octets big-endian, then its octets" {
  inspect(
    messages(b"\x00\x00\x00\x00\x05\x0a\x03Tom"),
    content=(
      #|message flag 0: 0a03546f6d
      #|done
    ),
  )
}

///|
test "a body may hold several messages, empty ones and compressed ones included" {
  inspect(
    messages(b"\x00\x00\x00\x00\x00\x01\x00\x00\x00\x02ab\x00\x00\x00\x00\x01c"),
    content=(
      #|message flag 0: 
      #|message flag 1: 6162
      #|message flag 0: 63
      #|done
    ),
  )
}

///|
test "an empty body holds no message" {
  inspect(messages(b""), content="done")
}

///|
test "input that ends inside a prefix, at any octet of it, is told apart" {
  let prefix = b"\x00\x00\x00\x00\x05"
  for n in 1..<5 {
    inspect(messages(prefix[0:n].to_owned()), content="ends inside a prefix")
  }
  inspect(
    messages(b"\x00\x00\x00\x00\x01a\x00\x00"),
    content=(
      #|message flag 0: 61
      #|ends inside a prefix
    ),
  )
}

///|
test "input that ends inside a message gives the length its prefix announced" {
  inspect(
    messages(b"\x00\x00\x00\x00\x05\x0a\x03T"),
    content="ends inside a message of 5 octets",
  )
  inspect(
    messages(b"\x00\x00\x00\x00\x05"),
    content="ends inside a message of 5 octets",
  )
  // A length past any body smock takes is read whole, as an unsigned
  // number.
  inspect(
    messages(b"\x00\xff\xff\xff\xff"),
    content="ends inside a message of 4294967295 octets",
  )
}

///|
test "a flag is passed on as it is, whatever its value" {
  inspect(
    messages(b"\x80\x00\x00\x00\x00"),
    content=(
      #|message flag 128: 
      #|done
    ),
  )
}

///|
test "framing a message gives flag 0, its length and its octets, which read back" {
  let framed = @grpc.frame(b"\x0a\x03Tom"[:])
  inspect(@hex.encode(framed), content="00000000050a03546f6d")
  inspect(@hex.encode(@grpc.frame(b""[:])), content="0000000000")
  inspect(
    messages(framed),
    content=(
      #|message flag 0: 0a03546f6d
      #|done
    ),
  )
}
