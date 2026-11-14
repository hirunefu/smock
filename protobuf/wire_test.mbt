// The wire codec through its public interface: varints, fixed 32- and
// 64-bit values, length-delimited values, tags and skipping, each at its
// limits and with input that ends early or breaks the encoding. Expected
// values come from the encoding as protobuf's documentation gives it.

///|
/// What `read` gives on a reader of `input`, or the error it raises.
fn outcome(
  input : Bytes,
  read : (@protobuf.Reader) -> String raise @protobuf.DecodeError,
) -> String {
  let reader = @protobuf.Reader(input[:])
  read(reader) catch {
    err => "error: \{err}"
  }
}

///|
test "a varint is read from its 7-bit groups, least significant first" {
  let read = (reader : @protobuf.Reader) => reader.varint().to_string()
  inspect(outcome(b"\x00", read), content="0")
  inspect(outcome(b"\x01", read), content="1")
  inspect(outcome(b"\x96\x01", read), content="150")
  inspect(
    outcome(b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01", read),
    content="18446744073709551615",
  )
}

///|
test "a varint that the input ends inside, or that runs past 10 octets, is an error at its first octet" {
  let read = (reader : @protobuf.Reader) => reader.varint().to_string()
  inspect(outcome(b"", read), content="error: octet 0: the input ends inside a varint")
  inspect(outcome(b"\x96", read), content="error: octet 0: the input ends inside a varint")
  inspect(
    outcome(b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x81\x00", read),
    content="error: octet 0: a varint is longer than 10 octets",
  )
  // Bits past the 64th are dropped, as protobuf's parsers drop them.
  inspect(
    outcome(b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x7f", read),
    content="18446744073709551615",
  )
}

///|
test "a reader of a view reports offsets in the bytes it is a view of" {
  let input = b"\x08\x96"
  let reader = @protobuf.Reader(input[1:])
  let message = try reader.varint() catch {
    err => err.to_string()
  } noraise {
    value => value.to_string()
  }
  inspect(message, content="octet 1: the input ends inside a varint")
}

///|
test "fixed 32- and 64-bit values are read little-endian" {
  let fixed32 = (reader : @protobuf.Reader) => reader.fixed32().to_string()
  let fixed64 = (reader : @protobuf.Reader) => reader.fixed64().to_string()
  inspect(outcome(b"\x01\x02\x03\x04", fixed32), content="67305985")
  inspect(outcome(b"\xff\xff\xff\xff", fixed32), content="4294967295")
  inspect(
    outcome(b"\x01\x02\x03\x04\x05\x06\x07\x08", fixed64),
    content="578437695752307201",
  )
  inspect(
    outcome(b"\xff\xff\xff\xff\xff\xff\xff\xff", fixed64),
    content="18446744073709551615",
  )
  inspect(
    outcome(b"\x01\x02\x03", fixed32),
    content="error: octet 0: the input ends inside a fixed 32-bit value",
  )
  inspect(
    outcome(b"\x01\x02\x03\x04\x05\x06\x07", fixed64),
    content="error: octet 0: the input ends inside a fixed 64-bit value",
  )
}

///|
test "a length-delimited value is its length, then that many octets, read as a view" {
  let read = (reader : @protobuf.Reader) => {
    let value = reader.length_delimited()
    "\{value.to_owned()}, then at end: \{reader.at_end()}"
  }
  inspect(outcome(b"\x00", read), content="b\"\", then at end: true")
  inspect(
    outcome(b"\x03Tom", read),
    content=(
      #|b"Tom", then at end: true
    ),
  )
  inspect(
    outcome(b"\x02Tom", read),
    content=(
      #|b"To", then at end: false
    ),
  )
}

///|
test "a length that runs past the input, or that the input ends inside, is an error at the length" {
  let read = (reader : @protobuf.Reader) => {
    reader.length_delimited() |> ignore
    "read"
  }
  inspect(
    outcome(b"\x04Tom", read),
    content="error: octet 0: a length of 4 runs past the end of the input, which has 3 octets left",
  )
  inspect(
    outcome(b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01", read),
    content="error: octet 0: a length of 18446744073709551615 runs past the end of the input, which has 0 octets left",
  )
  inspect(
    outcome(b"\x80", read),
    content="error: octet 0: the input ends inside a varint",
  )
}
