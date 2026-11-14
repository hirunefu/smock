// The status message of a gRPC reply, which `grpc-message` carries
// percent-encoded, so that any Unicode text fits in an HTTP/2 field value
// (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md).

///|
/// The value of `grpc-message` for the status message `text`: its UTF-8
/// octets, each from 0x20 to 0x7E other than `%` as it is, and every other
/// octet as `%` and two upper-case hex digits. A space at either end
/// becomes `%20` too, since HTTP/2 refuses a field value with a space at
/// either end. A lone surrogate, which UTF-8 cannot hold, is encoded as
/// U+FFFD.
pub fn percent_encode(text : StringView) -> Bytes {
  let n = text.length()
  let out = @buffer.Buffer(size_hint=n)
  let mut i = 0
  while i < n {
    let start = i
    let unit = text[i].to_int()
    i += 1
    // The code point, from one code unit or a surrogate pair.
    let mut code = unit
    if unit >= 0xD800 && unit <= 0xDBFF {
      if i < n && text[i].to_int() >= 0xDC00 && text[i].to_int() <= 0xDFFF {
        code = 0x10000 + ((unit - 0xD800) << 10) + (text[i].to_int() - 0xDC00)
        i += 1
      } else {
        code = 0xFFFD
      }
    } else if unit >= 0xDC00 && unit <= 0xDFFF {
      code = 0xFFFD
    }
    if code >= 0x20 &&
      code <= 0x7E &&
      code != '%'.to_int() &&
      !(code == ' '.to_int() && (start == 0 || i == n)) {
      out.write_byte(code.to_byte())
    } else if code < 0x80 {
      escape(out, code)
    } else if code < 0x800 {
      escape(out, 0xC0 | (code >> 6))
      escape(out, 0x80 | (code & 0x3F))
    } else if code < 0x10000 {
      escape(out, 0xE0 | (code >> 12))
      escape(out, 0x80 | ((code >> 6) & 0x3F))
      escape(out, 0x80 | (code & 0x3F))
    } else {
      escape(out, 0xF0 | (code >> 18))
      escape(out, 0x80 | ((code >> 12) & 0x3F))
      escape(out, 0x80 | ((code >> 6) & 0x3F))
      escape(out, 0x80 | (code & 0x3F))
    }
  }
  out.to_bytes()
}

///|
/// Writes `octet` to `out` as `%` and two upper-case hex digits.
fn escape(out : @buffer.Buffer, octet : Int32) -> Unit {
  out.write_byte(b'%')
  out.write_byte(hex_digit(octet >> 4))
  out.write_byte(hex_digit(octet & 0xF))
}

///|
/// The upper-case hex digit of `value`, from 0 to 15.
fn hex_digit(value : Int32) -> Byte {
  if value < 10 {
    (0x30 + value).to_byte()
  } else {
    (0x41 + value - 10).to_byte()
  }
}
