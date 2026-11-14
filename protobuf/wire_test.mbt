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
  inspect(
    outcome(b"", read),
    content="error: octet 0: the input ends inside a varint",
  )
  inspect(
    outcome(b"\x96", read),
    content="error: octet 0: the input ends inside a varint",
  )
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

///|
test "a tag gives the field number, and the wire type for the value that follows" {
  let read = (reader : @protobuf.Reader) => {
    let out = []
    while !reader.at_end() {
      let field = reader.tag()
      out.push("\{field} \{reader.wire_type()}")
      reader.skip()
    }
    out.join(", ")
  }
  inspect(
    outcome(
      b"\x08\x96\x01\x11\x01\x02\x03\x04\x05\x06\x07\x08\x1a\x03Tom\x25\x01\x02\x03\x04",
      read,
    ),
    content="1 VARINT, 2 I64, 3 LEN, 4 I32",
  )
  // The largest field number, 2^29 - 1.
  inspect(
    outcome(b"\xf8\xff\xff\xff\x0f\x00", read),
    content="536870911 VARINT",
  )
}

///|
test "field number 0, a field number past 2^29 - 1 and wire types 6 and 7 are errors at the tag" {
  let read = (reader : @protobuf.Reader) => reader.tag().to_string()
  inspect(
    outcome(b"\x00", read),
    content="error: octet 0: field number 0 is not a field number",
  )
  inspect(
    outcome(b"\x80\x80\x80\x80\x10", read),
    content="error: octet 0: field number 536870912 is over the largest, 536870911",
  )
  inspect(
    outcome(b"\x80\x80\x80\x80\x80\x01", read),
    content="error: octet 0: a tag is longer than 5 octets",
  )
  inspect(
    outcome(b"\x0e", read),
    content="error: octet 0: wire type 6 is not a protobuf wire type",
  )
  inspect(
    outcome(b"\x0f", read),
    content="error: octet 0: wire type 7 is not a protobuf wire type",
  )
  inspect(
    outcome(b"\x80", read),
    content="error: octet 0: the input ends inside a varint",
  )
}

///|
test "expecting a wire type other than the tag's is an error at the tag" {
  let read = (reader : @protobuf.Reader) => {
    let field = reader.tag()
    reader.expect(Len)
    reader.length_delimited().length().to_string() + " octets in field \{field}"
  }
  inspect(outcome(b"\x0a\x01x", read), content="1 octets in field 1")
  inspect(
    outcome(b"\x10\x01", read),
    content="error: octet 0: field 2 has wire type VARINT, not LEN",
  )
  inspect(
    outcome(b"\x15\x01\x02\x03\x04", read),
    content="error: octet 0: field 2 has wire type I32, not LEN",
  )
}

///|
test "skipping a group skips every record up to the end of the group with its field number, nested groups included" {
  let read = (reader : @protobuf.Reader) => {
    let out = []
    while !reader.at_end() {
      let field = reader.tag()
      out.push("\{field} \{reader.wire_type()}")
      reader.skip()
    }
    out.join(", ")
  }
  // Field 1, a group holding a varint and a group of field 2, then field 3.
  inspect(
    outcome(b"\x0b\x08\x01\x13\x10\x05\x14\x0c\x18\x07", read),
    content="1 SGROUP, 3 VARINT",
  )
  inspect(outcome(b"\x0b\x0c", read), content="1 SGROUP")
}

///|
test "a group that the input ends inside, that ends with another field number or that was never started is an error" {
  let read = (reader : @protobuf.Reader) => {
    while !reader.at_end() {
      reader.tag() |> ignore
      reader.skip()
    }
    "read"
  }
  inspect(
    outcome(b"\x0b\x08\x01", read),
    content="error: octet 0: the input ends inside the group of field 1",
  )
  inspect(
    outcome(b"\x0b\x14", read),
    content="error: octet 1: the group of field 1 ends with the tag of field 2",
  )
  inspect(
    outcome(b"\x0b\x13\x0c", read),
    content="error: octet 2: the group of field 2 ends with the tag of field 1",
  )
  inspect(
    outcome(b"\x08\x01\x0c", read),
    content="error: octet 2: the group of field 1 ends where none started",
  )
  inspect(
    outcome(b"\x0b\x08", read),
    content="error: octet 2: the input ends inside a varint",
  )
}

///|
test "groups nested deeper than 100 are an error, and 100 deep are skipped" {
  let read = (reader : @protobuf.Reader) => {
    reader.tag() |> ignore
    reader.skip()
    "skipped"
  }
  let nested = (depth : Int32) => {
    let out = @buffer.Buffer()
    for _ in 0..<depth {
      out.write_byte(b'\x0b')
    }
    for _ in 0..<depth {
      out.write_byte(b'\x0c')
    }
    out.to_bytes()
  }
  inspect(outcome(nested(100), read), content="skipped")
  inspect(
    outcome(nested(101), read),
    content="error: octet 100: groups nest deeper than 100",
  )
}

///|
test "a writer encodes tags and values as protobuf's documentation shows them" {
  let writer = @protobuf.Writer()
  // The documentation's example: field 1 holding the varint 150.
  writer.tag(1, Varint)
  writer.varint(150)
  writer.tag(2, Len)
  writer.length_delimited(b"testing"[:])
  writer.tag(3, I32)
  writer.fixed32(0x04030201)
  writer.tag(4, I64)
  writer.fixed64(0x0807060504030201)
  writer.tag(536870911, Varint)
  writer.varint(0xffffffffffffffff)
  inspect(
    writer.to_bytes(),
    content=(
      #|b"\x08\x96\x01\x12\x07testing\x1d\x01\x02\x03\x04!\x01\x02\x03\x04\x05\x06\x07\x08\xf8\xff\xff\xff\x0f\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01"
    ),
  )
}
