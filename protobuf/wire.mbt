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
/// How a record's value is encoded, as its tag says.
#derive(Eq, Debug)
pub(all) enum WireType {
  /// A varint: `int32`, `int64`, `uint32`, `uint64`, `sint32`, `sint64`,
  /// `bool` and enums.
  Varint
  /// 8 octets: `fixed64`, `sfixed64` and `double`.
  I64
  /// A length, then that many octets: strings, bytes, messages and packed
  /// repeated fields.
  Len
  /// The start of a group, a deprecated proto2 form of a message field.
  StartGroup
  /// The end of a group.
  EndGroup
  /// 4 octets: `fixed32`, `sfixed32` and `float`.
  I32
}

///|
/// Shows the wire type by its name in protobuf's documentation: `VARINT`,
/// `I64`, `LEN`, `SGROUP`, `EGROUP` or `I32`.
pub impl Show for WireType with fn output(self, logger) {
  logger.write_string(
    match self {
      Varint => "VARINT"
      I64 => "I64"
      Len => "LEN"
      StartGroup => "SGROUP"
      EndGroup => "EGROUP"
      I32 => "I32"
    },
  )
}

///|
/// The largest field number, 2^29 - 1.
let max_field_number : Int32 = 536870911

///|
/// Reads protobuf's wire format from bytes, one value at a time. It reads
/// in place: a length-delimited value is a view of the input, not a copy.
///
/// A message is read a record at a time: `tag` reads the record's tag and
/// returns its field number, then one of `varint`, `fixed64`,
/// `length_delimited` or `fixed32` reads its value, as `wire_type` says, or
/// `skip` skips it.
pub struct Reader {
  /// The bytes being read.
  priv input : BytesView
  /// Where the next value starts in `input`.
  priv mut pos : Int32
  /// Where the last tag read starts in `input`.
  priv mut tag_at : Int32
  /// The field number of the last tag read, or 0 before the first.
  priv mut field : Int32
  /// The wire type of the last tag read.
  priv mut wire_type : WireType
}

///|
/// A reader of `input`, from its start.
pub fn Reader::Reader(input : BytesView) -> Reader {
  { input, pos: 0, tag_at: 0, field: 0, wire_type: Varint }
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

///|
/// Whether every octet of the input has been read.
pub fn Reader::at_end(self : Reader) -> Bool {
  self.pos >= self.input.length()
}

///|
/// Reads `n` octets as a little-endian unsigned integer, or raises
/// `DecodeError` naming `what` when the input ends first.
fn Reader::little_endian(
  self : Reader,
  n : Int32,
  what : String,
) -> UInt64 raise DecodeError {
  if self.input.length() - self.pos < n {
    raise self.error(self.pos, "the input ends inside \{what}")
  }
  let mut value = 0UL
  for i = n - 1; i >= 0; i = i - 1 {
    value = (value << 8) | self.input[self.pos + i].to_uint64()
  }
  self.pos = self.pos + n
  value
}

///|
/// Reads a fixed 32-bit value: 4 octets, little-endian, as protobuf
/// encodes `fixed32`, `sfixed32` and `float`. Raises `DecodeError` when the
/// input ends first.
pub fn Reader::fixed32(self : Reader) -> UInt raise DecodeError {
  self.little_endian(4, "a fixed 32-bit value").to_uint()
}

///|
/// Reads a fixed 64-bit value: 8 octets, little-endian, as protobuf
/// encodes `fixed64`, `sfixed64` and `double`. Raises `DecodeError` when
/// the input ends first.
pub fn Reader::fixed64(self : Reader) -> UInt64 raise DecodeError {
  self.little_endian(8, "a fixed 64-bit value")
}

///|
/// Reads a length-delimited value: a varint length, then that many octets,
/// which it returns as a view of the input. Raises `DecodeError` when the
/// length runs past the end of the input, before anything is allocated.
pub fn Reader::length_delimited(self : Reader) -> BytesView raise DecodeError {
  let start = self.pos
  let length = self.varint()
  let left = self.input.length() - self.pos
  if length > left.to_uint64() {
    raise self.error(
      start,
      "a length of \{length} runs past the end of the input, which has \{left} octets left",
    )
  }
  let value = self.input[self.pos:self.pos + length.to_int()]
  self.pos = self.pos + length.to_int()
  value
}

///|
/// Reads a record's tag, a varint of at most 5 octets that holds the field
/// number and the wire type, and returns the field number. `wire_type` then
/// gives the wire type. Raises `DecodeError` for field number 0, one past
/// 2^29 - 1, and wire types 6 and 7, which protobuf does not define.
pub fn Reader::tag(self : Reader) -> Int32 raise DecodeError {
  let start = self.pos
  let tag = self.varint()
  if self.pos - start > 5 {
    raise self.error(start, "a tag is longer than 5 octets")
  }
  let field = tag >> 3
  if field == 0 {
    raise self.error(start, "field number 0 is not a field number")
  }
  if field > max_field_number.to_uint64() {
    raise self.error(
      start,
      "field number \{field} is over the largest, \{max_field_number}",
    )
  }
  self.wire_type = match tag & 7 {
    0 => Varint
    1 => I64
    2 => Len
    3 => StartGroup
    4 => EndGroup
    5 => I32
    other =>
      raise self.error(
        start,
        "wire type \{other} is not a protobuf wire type",
      )
  }
  self.tag_at = start
  self.field = field.to_int()
  self.field
}

///|
/// The wire type of the last tag read.
pub fn Reader::wire_type(self : Reader) -> WireType {
  self.wire_type
}

///|
/// Raises `DecodeError` unless the last tag read has the wire type
/// `wire_type`, as a field of a known type must.
pub fn Reader::expect(
  self : Reader,
  wire_type : WireType,
) -> Unit raise DecodeError {
  if self.wire_type != wire_type {
    raise self.error(
      self.tag_at,
      "field \{self.field} has wire type \{self.wire_type}, not \{wire_type}",
    )
  }
}

///|
/// How deep groups may nest, as protobuf's C++ and Java parsers bound
/// messages by default.
let max_depth : Int32 = 100

///|
/// Skips the value of the last tag read, as its wire type says. A group is
/// skipped with every record in it, up to the end of the group with its
/// field number, groups inside it included.
///
/// Raises `DecodeError` when the input ends inside the value, when a group
/// ends with the tag of another field number, when a group ends where none
/// started, and when groups nest deeper than 100.
pub fn Reader::skip(self : Reader) -> Unit raise DecodeError {
  match self.wire_type {
    Varint => ignore(self.varint())
    I64 => ignore(self.fixed64())
    Len => ignore(self.length_delimited())
    I32 => ignore(self.fixed32())
    StartGroup => self.skip_group(self.field, self.tag_at, 1)
    EndGroup =>
      raise self.error(
        self.tag_at,
        "the group of field \{self.field} ends where none started",
      )
  }
}

///|
/// Skips the rest of the group of field `field`, whose start tag is at
/// `at`, `depth` groups deep, up to and including its end tag.
fn Reader::skip_group(
  self : Reader,
  field : Int32,
  at : Int32,
  depth : Int32,
) -> Unit raise DecodeError {
  if depth > max_depth {
    raise self.error(at, "groups nest deeper than \{max_depth}")
  }
  for ;; {
    if self.at_end() {
      raise self.error(
        at,
        "the input ends inside the group of field \{field}",
      )
    }
    let inner = self.tag()
    match self.wire_type {
      EndGroup if inner == field => return
      EndGroup =>
        raise self.error(
          self.tag_at,
          "the group of field \{field} ends with the tag of field \{inner}",
        )
      StartGroup => self.skip_group(inner, self.tag_at, depth + 1)
      _ => self.skip()
    }
  }
}
