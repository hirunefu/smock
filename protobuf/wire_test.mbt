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
