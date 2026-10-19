// Parsing application/x-www-form-urlencoded bytes, as the WHATWG URL
// Standard does, for query parameters and form bodies alike: the bytes are
// split on `&`, and each piece at its first `=`; `+` stands for a space and
// a percent-escape for the byte it writes; the decoded bytes are read as
// UTF-8, with U+FFFD for invalid sequences.

///|
/// The (name, value) pairs of `input`, application/x-www-form-urlencoded
/// bytes, decoded, in order. A piece without `=` is a name with the empty
/// value; empty pieces, as between `&&`, are skipped.
fn urlencoded(input : BytesView) -> Array[(String, String)] {
  let out = []
  let mut start = 0
  while start < input.length() {
    let mut end = start
    while end < input.length() && input[end] != b'&' {
      end += 1
    }
    if end > start {
      let mut equals = start
      while equals < end && input[equals] != b'=' {
        equals += 1
      }
      let value = if equals < end {
        form_decode(input[equals + 1:end])
      } else {
        ""
      }
      out.push((form_decode(input[start:equals]), value))
    }
    start = end + 1
  }
  out
}

///|
/// Decodes a name or a value of application/x-www-form-urlencoded bytes:
/// `+` is a space, `%` and two hexadecimal digits are the byte they write,
/// and every other byte, a `%` that starts no escape included, is itself.
/// The decoded bytes are read as UTF-8, with U+FFFD for invalid sequences.
fn form_decode(bytes : BytesView) -> String {
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
  let decoded = @buffer.Buffer(size_hint=bytes.length())
  let mut i = 0
  while i < bytes.length() {
    let byte = bytes[i]
    if byte == b'+' {
      decoded.write_byte(b' ')
      i += 1
      continue
    }
    if byte == b'%' && i + 2 < bytes.length() {
      let high = hex_digit(bytes[i + 1])
      let low = hex_digit(bytes[i + 2])
      if high >= 0 && low >= 0 {
        decoded.write_byte((high * 16 + low).to_byte())
        i += 3
        continue
      }
    }
    decoded.write_byte(byte)
    i += 1
  }
  @utf8.decode_lossy(decoded.to_bytes())
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
