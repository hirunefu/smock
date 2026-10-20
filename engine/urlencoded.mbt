// Parsing application/x-www-form-urlencoded bytes, as the WHATWG URL
// Standard does, for query parameters and form bodies alike: the bytes are
// split on `&`, and each piece at its first `=`; `+` stands for a space and
// a percent-escape for the byte it writes; the decoded bytes are read as
// UTF-8, with U+FFFD for invalid sequences, as `@utf8.decode_lossy` reads
// them.
//
// A form body is kept as where its fields start. A name or a value is
// decoded only when a condition compares it, and an exact text is compared
// with the encoded bytes in place, with no allocation.

///|
/// The (name, value) pairs of `input`, application/x-www-form-urlencoded
/// bytes, decoded, in order. A piece without `=` is a name with the empty
/// value; empty pieces, as between `&&`, are skipped.
fn urlencoded(input : BytesView) -> Array[(String, String)] {
  let out = []
  let mut start = 0
  while start < input.length() {
    let end = piece_end(input, start)
    if end > start {
      let equals = name_end(input, start, end)
      out.push(
        (
          form_decode(input[start:equals]),
          form_decode(field_value(input, equals, end)),
        ),
      )
    }
    start = end + 1
  }
  out
}

///|
/// Where each field of `input`, application/x-www-form-urlencoded bytes,
/// starts, in order: the fields are the pieces between `&`, empty pieces
/// skipped. A field's name runs to its first `=`, as `name_end` finds it,
/// and its value from there to the field's end, as `piece_end` finds it.
fn field_starts(input : BytesView) -> FixedArray[Int] {
  // Counted first, so that the array takes no more room than it needs.
  let mut count = 0
  let mut start = 0
  while start < input.length() {
    let end = piece_end(input, start)
    if end > start {
      count += 1
    }
    start = end + 1
  }
  let starts = FixedArray::make(count, 0)
  let mut i = 0
  start = 0
  while start < input.length() {
    let end = piece_end(input, start)
    if end > start {
      starts[i] = start
      i += 1
    }
    start = end + 1
  }
  starts
}

///|
/// The end of the piece of `input` that starts at `start`: the index of the
/// next `&`, or the length of `input`.
fn piece_end(input : BytesView, start : Int) -> Int {
  let mut end = start
  while end < input.length() && input[end] != b'&' {
    end += 1
  }
  end
}

///|
/// The end of the name of the piece `input[start:end]`: the index of its
/// first `=`, or `end`.
fn name_end(input : BytesView, start : Int, end : Int) -> Int {
  let mut equals = start
  while equals < end && input[equals] != b'=' {
    equals += 1
  }
  equals
}

///|
/// The value of the piece of `input` whose name ends at `equals` and that
/// ends at `end`: the bytes after the `=`, none without one.
fn field_value(input : BytesView, equals : Int, end : Int) -> BytesView {
  if equals < end {
    input[equals + 1:end]
  } else {
    input[end:end]
  }
}

///|
/// Decodes a name or a value of application/x-www-form-urlencoded bytes:
/// `+` is a space, `%` and two hexadecimal digits are the byte they write,
/// and every other byte, a `%` that starts no escape included, is itself.
/// The decoded bytes are read as UTF-8, with U+FFFD for invalid sequences.
fn form_decode(bytes : BytesView) -> String {
  // An empty value, as many fields have, shares the empty string.
  if bytes.length() == 0 {
    return ""
  }
  let mut plain = true
  for i in 0..<bytes.length() {
    if bytes[i] is (b'+' | b'%') {
      plain = false
      break
    }
  }
  if plain {
    return @utf8.decode_lossy(bytes)
  }
  let decoded = StringBuilder(size_hint=bytes.length())
  let mut i = 0
  while i < bytes.length() {
    let c = form_char(bytes, i)
    decoded.write_char(char_of(c).unsafe_to_char())
    i = next_of(c)
  }
  decoded.to_string()
}

///|
/// A name or a value of application/x-www-form-urlencoded bytes, decoded
/// as `form_decode` decodes it, in UTF-8: `bytes` themselves when they are
/// ASCII with no `+` or `%`, which decoding leaves as they are, and new
/// bytes otherwise.
fn form_utf8(bytes : BytesView) -> BytesView {
  let mut plain = true
  for i in 0..<bytes.length() {
    if bytes[i] is (b'+' | b'%' | b'\x80'..=b'\xFF') {
      plain = false
      break
    }
  }
  if plain {
    return bytes
  }
  let decoded = @buffer.Buffer(size_hint=bytes.length())
  let mut i = 0
  while i < bytes.length() {
    let c = form_char(bytes, i)
    decoded.write_char_utf8(char_of(c).unsafe_to_char())
    i = next_of(c)
  }
  decoded.to_bytes()
}

///|
/// Whether `bytes`, a name or a value of application/x-www-form-urlencoded
/// bytes, decodes to `text`, as `form_decode` decodes it. It is compared in
/// place, with no allocation.
fn form_text_is(bytes : BytesView, text : String) -> Bool {
  let mut i = 0
  let mut j = 0
  while i < bytes.length() {
    let c = form_char(bytes, i)
    let code_point = char_of(c)
    if code_point < 0x10000 {
      if j >= text.length() || text[j].to_int() != code_point {
        return false
      }
      j += 1
    } else {
      // A character outside the BMP is a surrogate pair in `text`.
      let high = 0xD800 + ((code_point - 0x10000) >> 10)
      let low = 0xDC00 + ((code_point - 0x10000) & 0x3FF)
      if j + 1 >= text.length() ||
        text[j].to_int() != high ||
        text[j + 1].to_int() != low {
        return false
      }
      j += 2
    }
    i = next_of(c)
  }
  j == text.length()
}

///|
/// The character that starts at byte `i` of `bytes`, which are
/// application/x-www-form-urlencoded, and the index of the byte after it,
/// packed as `char_of` and `next_of` read them. The decoded bytes are read
/// as UTF-8 (Unicode 16.0, Table 3-7): a sequence that is not well-formed
/// is U+FFFD, one for its longest start that could begin a well-formed
/// sequence, or for its first byte, as `@utf8.decode_lossy` reads it.
///
/// The result is packed, rather than a tuple, so that decoding allocates
/// nothing.
fn form_char(bytes : BytesView, i : Int) -> Int64 {
  let first = form_byte(bytes, i)
  let b0 = byte_of(first)
  let mut next = i + length_of(first)
  if b0 < 0x80 {
    return packed_char(b0, next)
  }
  // How many continuation bytes follow, and the range the first of them
  // must be in; the others are from 0x80 to 0xBF.
  let count = match b0 {
    0xC2..=0xDF => 1
    0xE0..=0xEF => 2
    0xF0..=0xF4 => 3
    _ => return packed_char(0xFFFD, next)
  }
  let lo = match b0 {
    0xE0 => 0xA0
    0xF0 => 0x90
    _ => 0x80
  }
  let hi = match b0 {
    0xED => 0x9F
    0xF4 => 0x8F
    _ => 0xBF
  }
  let mut code_point = b0 & (0x3F >> count)
  for k in 0..<count {
    if next >= bytes.length() {
      return packed_char(0xFFFD, next)
    }
    let unit = form_byte(bytes, next)
    let b = byte_of(unit)
    if b < (if k == 0 { lo } else { 0x80 }) ||
      b > (if k == 0 { hi } else { 0xBF }) {
      // The byte is not consumed: it starts what comes next.
      return packed_char(0xFFFD, next)
    }
    code_point = (code_point << 6) | (b & 0x3F)
    next += length_of(unit)
  }
  packed_char(code_point, next)
}

///|
/// A character and the index after it, packed as `form_char` returns them.
fn packed_char(code_point : Int, next : Int) -> Int64 {
  (code_point.to_int64() << 32) | next.to_int64()
}

///|
/// The code point of a character `form_char` returned.
fn char_of(c : Int64) -> Int {
  (c >> 32).to_int()
}

///|
/// The index after a character `form_char` returned.
fn next_of(c : Int64) -> Int {
  (c & 0xFFFFFFFFL).to_int()
}

///|
/// The byte that starts at byte `i` of `bytes`, which are
/// application/x-www-form-urlencoded, decoded, and how many bytes it takes,
/// packed as `byte_of` and `length_of` read them: `+` is a space, `%` and
/// two hexadecimal digits are the byte they write, and any other byte, a
/// `%` that starts no escape included, is itself.
fn form_byte(bytes : BytesView, i : Int) -> Int {
  let byte = bytes[i]
  if byte == b'+' {
    return packed_byte(' '.to_int(), 1)
  }
  if byte == b'%' && i + 2 < bytes.length() {
    let high = hex_digit(bytes[i + 1])
    let low = hex_digit(bytes[i + 2])
    if high >= 0 && low >= 0 {
      return packed_byte(high * 16 + low, 3)
    }
  }
  packed_byte(byte.to_int(), 1)
}

///|
/// A byte and its length, packed as `form_byte` returns them.
fn packed_byte(byte : Int, length : Int) -> Int {
  byte | (length << 8)
}

///|
/// The byte of what `form_byte` returned.
fn byte_of(unit : Int) -> Int {
  unit & 0xFF
}

///|
/// The length of what `form_byte` returned.
fn length_of(unit : Int) -> Int {
  unit >> 8
}

///|
/// The value of `byte` as a hexadecimal digit, in either case, or -1.
fn hex_digit(byte : Byte) -> Int {
  match byte {
    b'0'..=b'9' => byte.to_int() - '0'.to_int()
    b'a'..=b'f' => byte.to_int() - 'a'.to_int() + 10
    b'A'..=b'F' => byte.to_int() - 'A'.to_int() + 10
    _ => -1
  }
}
