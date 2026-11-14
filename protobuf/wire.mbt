// The protobuf wire format: a message is a sequence of records, each a tag
// (a field number and a wire type) followed by a value encoded as the wire
// type says. https://protobuf.dev/programming-guides/encoding/

///|
/// Why bytes are not protobuf that the module accepts. `position` is the
/// offset, from 0, in the bytes the reader's input is a view of, where the
/// problem is, so a reader of a nested message reports offsets in the whole
/// input. `message` says what the problem is.
#derive(Eq, Debug)
pub(all) suberror DecodeError {
  DecodeError(position~ : Int32, message~ : String)
}

///|
/// Shows the error as `octet <n>: <message>`.
pub impl Show for DecodeError with fn output(self, logger) {
  let DecodeError(position~, message~) = self
  logger.write_string("octet \{position}: \{message}")
}

///|
/// Reads protobuf's wire format from bytes, one value at a time. It reads
/// in place: a length-delimited value is a view of the input, not a copy.
pub struct Reader {
  /// The bytes being read.
  priv input : BytesView
  /// Where the next value starts in `input`.
  priv mut pos : Int32
}

///|
/// A reader of `input`, from its start.
pub fn Reader::Reader(input : BytesView) -> Reader {
  { input, pos: 0 }
}

///|
/// The error at `at`, an offset in `input`, with `message`.
fn Reader::error(self : Reader, at : Int32, message : String) -> DecodeError {
  DecodeError(position=self.input.start_offset() + at, message~)
}

///|
/// Reads a varint: 1 to 10 octets, each giving 7 bits of the value, least
/// significant first, all but the last with the high bit set. Bits past
/// the 64th are dropped, as protobuf's parsers drop them. Raises
/// `DecodeError` when the input ends inside the varint, or when it is
/// longer than 10 octets.
pub fn Reader::varint(self : Reader) -> UInt64 raise DecodeError {
  let start = self.pos
  let mut value = 0UL
  let mut shift = 0
  for i = start; i < self.input.length(); i = i + 1 {
    let byte = self.input[i]
    if shift < 64 {
      value = value | ((byte.to_uint64() & 0x7f) << shift)
    }
    if byte < b'\x80' {
      self.pos = i + 1
      return value
    }
    shift = shift + 7
    if shift >= 70 {
      raise self.error(start, "a varint is longer than 10 octets")
    }
  }
  raise self.error(start, "the input ends inside a varint")
}
