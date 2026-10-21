// The encoding helpers: base64 and base64url (RFC 4648 §4 and §5) and
// percent-encoding (RFC 3986 §2.1) of the UTF-8 bytes of a text, and their
// decoders. Each result is measured, and bounded, before it is built.

///|
/// An encoding helper.
priv enum EncodingHelper {
  /// `base64(s)`: the standard alphabet, with padding.
  Base64
  /// `base64url(s)`: the URL-safe alphabet, without padding.
  Base64Url
  /// `base64Decode(s)`: the standard alphabet, padding optional.
  Base64Decode
  /// `base64urlDecode(s)`: the URL-safe alphabet, padding optional.
  Base64UrlDecode
  /// `urlEncode(s)`: each byte percent-encoded, except the unreserved
  /// characters.
  UrlEncode
  /// `urlDecode(s)`: percent-escapes decoded, `+` kept.
  UrlDecode
}

///|
/// The helper's name, for messages.
fn EncodingHelper::name(self : EncodingHelper) -> String {
  match self {
    Base64 => "base64"
    Base64Url => "base64url"
    Base64Decode => "base64Decode"
    Base64UrlDecode => "base64urlDecode"
    UrlEncode => "urlEncode"
    UrlDecode => "urlDecode"
  }
}

///|
/// The encoding helper that `site` calls, checked. `None` when it calls a
/// helper of another family.
fn encoding_helper(site : CallSite) -> Helper? raise Syntax {
  let helper : EncodingHelper = match site.name {
    "base64" => Base64
    "base64url" => Base64Url
    "base64Decode" => Base64Decode
    "base64urlDecode" => Base64UrlDecode
    "urlEncode" => UrlEncode
    "urlDecode" => UrlDecode
    _ => return None
  }
  site.takes([Text], least=1, most=1)
  Some(Encoding(helper))
}

///|
/// What the encoding helper `helper` gives for the values of its
/// arguments, `values`, inserted at `at`.
fn encoding_value(
  helper : EncodingHelper,
  values : Array[Json],
  at : String,
) -> Json raise RenderError {
  let name = helper.name()
  match helper {
    Base64 | Base64Url => {
      let url = helper is Base64Url
      let bytes = @utf8.encode(text_argument(name, 0, values[0], at))
      Json::string(base64_encoded(bytes, url, name, at))
    }
    Base64Decode | Base64UrlDecode => {
      let url = helper is Base64UrlDecode
      let text = text_argument(name, 0, values[0], at)
      let length = base64_length(text, url) catch {
        NotDecodable(problem) =>
          raise RenderError(at~, message="\{name}(): \{problem}")
      }
      // Each decoded byte gives at least one byte of text, and a byte that
      // is not UTF-8 three, for U+FFFD. So the bytes are bounded before
      // they are decoded, and the text they give before it is built.
      check_result(name, length.to_int64(), at)
      let decoded = base64_decoded(text, url, length)
      check_result(name, lossy_utf8_length(decoded), at)
      Json::string(@utf8.decode_lossy(decoded))
    }
    UrlEncode => {
      let bytes = @utf8.encode(text_argument(name, 0, values[0], at))
      Json::string(percent_encoded(bytes, name, at))
    }
    UrlDecode => {
      let text = text_argument(name, 0, values[0], at)
      let length = percent_length(text) catch {
        NotDecodable(problem) =>
          raise RenderError(at~, message="\{name}(): \{problem}")
      }
      // Bounded as for base64Decode.
      check_result(name, length.to_int64(), at)
      let decoded = percent_decoded(text, length)
      check_result(name, lossy_utf8_length(decoded), at)
      Json::string(@utf8.decode_lossy(decoded))
    }
  }
}

///|
/// The bytes of UTF-8 that `@utf8.decode_lossy` writes for `bytes`,
/// counted without decoding them: each well-formed sequence takes its own
/// length, and each maximal subpart of an ill-formed one, which it replaces
/// with U+FFFD, takes 3. A maximal subpart is the longest start of a
/// well-formed sequence there, or else one byte.
fn lossy_utf8_length(bytes : BytesView) -> Int64 {
  let n = bytes.length()
  let mut length = 0L
  let mut i = 0
  while i < n {
    let lead = bytes[i].to_int()
    if lead < 0x80 {
      length += 1L
      i += 1
      continue
    }
    // The length of a sequence that starts with `lead`, 0 when none does,
    // and the range of its second byte.
    let mut size = 0
    let mut low = 0x80
    let mut high = 0xBF
    if lead >= 0xC2 && lead <= 0xDF {
      size = 2
    } else if lead >= 0xE0 && lead <= 0xEF {
      size = 3
      if lead == 0xE0 {
        low = 0xA0
      } else if lead == 0xED {
        high = 0x9F
      }
    } else if lead >= 0xF0 && lead <= 0xF4 {
      size = 4
      if lead == 0xF0 {
        low = 0x90
      } else if lead == 0xF4 {
        high = 0x8F
      }
    }
    let mut taken = 1
    if size > 0 &&
      i + 1 < n &&
      bytes[i + 1].to_int() >= low &&
      bytes[i + 1].to_int() <= high {
      taken = 2
      while taken < size &&
            i + taken < n &&
            bytes[i + taken].to_int() >= 0x80 &&
            bytes[i + taken].to_int() <= 0xBF {
        taken += 1
      }
    }
    length += if taken == size { size.to_int64() } else { 3L }
    i += taken
  }
  length
}

///|
/// The base64 alphabet, RFC 4648 §4.
let base64_alphabet : String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

///|
/// The base64url alphabet, RFC 4648 §5.
let base64url_alphabet : String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

///|
/// `bytes` in base64 with padding, or in base64url without, as the helper
/// `name` inserted at `at` gives them, bounded before they are written.
fn base64_encoded(
  bytes : Bytes,
  url : Bool,
  name : String,
  at : String,
) -> String raise RenderError {
  let n = bytes.length().to_int64()
  // Four characters for each whole group of three bytes; for the last one
  // or two bytes, two or three characters, then padding to four.
  let length = if url { (n * 4L + 2L) / 3L } else { (n + 2L) / 3L * 4L }
  check_result(name, length, at)
  let alphabet = if url { base64url_alphabet } else { base64_alphabet }
  let out = StringBuilder(size_hint=length.to_int())
  let mut i = 0
  while i + 2 < bytes.length() {
    let group = (bytes[i].to_int() << 16) |
      (bytes[i + 1].to_int() << 8) |
      bytes[i + 2].to_int()
    out.write_char(alphabet[(group >> 18) & 63].unsafe_to_char())
    out.write_char(alphabet[(group >> 12) & 63].unsafe_to_char())
    out.write_char(alphabet[(group >> 6) & 63].unsafe_to_char())
    out.write_char(alphabet[group & 63].unsafe_to_char())
    i += 3
  }
  let rest = bytes.length() - i
  if rest > 0 {
    let group = (bytes[i].to_int() << 16) |
      (if rest == 2 { bytes[i + 1].to_int() << 8 } else { 0 })
    out.write_char(alphabet[(group >> 18) & 63].unsafe_to_char())
    out.write_char(alphabet[(group >> 12) & 63].unsafe_to_char())
    if rest == 2 {
      out.write_char(alphabet[(group >> 6) & 63].unsafe_to_char())
    }
    if !url {
      out.write_string(if rest == 2 { "=" } else { "==" })
    }
  }
  out.to_string()
}

///|
/// Why a text cannot be decoded, for a message.
priv suberror NotDecodable {
  NotDecodable(String)
}

///|
/// The value of the character `c` in the base64 alphabet, or in the
/// base64url one, or -1 when it is not in it.
fn base64_value(c : Char, url : Bool) -> Int {
  match c {
    'A'..='Z' => c.to_int() - 'A'.to_int()
    'a'..='z' => c.to_int() - 'a'.to_int() + 26
    '0'..='9' => c.to_int() - '0'.to_int() + 52
    '+' if !url => 62
    '/' if !url => 63
    '-' if url => 62
    '_' if url => 63
    _ => -1
  }
}

///|
/// How many bytes `text` decodes to, in base64, or in base64url. Raises
/// `NotDecodable` when `text` has a character outside the alphabet,
/// whitespace included, padding before the end, or the wrong number of
/// `=`: a last group of 2 characters takes 2 or none, a last group of 3
/// takes 1 or none, and whole groups of 4 take none. Bits beyond the last
/// byte are ignored.
fn base64_length(text : StringView, url : Bool) -> Int raise NotDecodable {
  let alphabet = if url { "base64url" } else { "base64" }
  // Characters of the alphabet, `=` after them, and where the first `=`
  // is, counted in characters from 1.
  let mut digits = 0
  let mut padding = 0
  let mut first_pad = 0
  let mut k = 0
  for c in text {
    k += 1
    if c == '=' {
      if padding == 0 {
        first_pad = k
      }
      padding += 1
    } else if base64_value(c, url) < 0 {
      raise NotDecodable(
        "character \{k}, \{c.to_string().escape()}, is not in the \{alphabet} alphabet",
      )
    } else if padding > 0 {
      raise NotDecodable(
        "character \{first_pad}, \"=\", is padding before the end",
      )
    } else {
      digits += 1
    }
  }
  let last = digits % 4
  if last == 1 {
    raise NotDecodable("the last group has 1 character, too few for a byte")
  }
  if padding > 0 {
    let takes = match last {
      2 =>
        if padding == 2 {
          None
        } else {
          Some("a last group of 2 characters takes 2 or none")
        }
      3 =>
        if padding == 1 {
          None
        } else {
          Some("a last group of 3 characters takes 1 or none")
        }
      _ => Some("whole groups of 4 characters take none")
    }
    if takes is Some(rule) {
      raise NotDecodable("the padding has \{padding} \"=\", but \{rule}")
    }
  }
  digits / 4 * 3 + (if last == 0 { 0 } else { last - 1 })
}

///|
/// The `length` bytes that `text`, which `base64_length` has checked,
/// decodes to, in base64, or in base64url.
fn base64_decoded(text : StringView, url : Bool, length : Int) -> Bytes {
  let out = @buffer.Buffer(size_hint=length)
  let mut group = 0
  let mut count = 0
  for c in text {
    if c == '=' {
      break
    }
    group = (group << 6) | base64_value(c, url)
    count += 1
    if count == 4 {
      out.write_byte((group >> 16).to_byte())
      out.write_byte(((group >> 8) & 0xFF).to_byte())
      out.write_byte((group & 0xFF).to_byte())
      group = 0
      count = 0
    }
  }
  // A last group of 2 characters holds 12 bits, one byte and 4 more; one
  // of 3 holds 18 bits, two bytes and 2 more.
  if count == 2 {
    out.write_byte(((group >> 4) & 0xFF).to_byte())
  } else if count == 3 {
    out.write_byte(((group >> 10) & 0xFF).to_byte())
    out.write_byte(((group >> 2) & 0xFF).to_byte())
  }
  out.to_bytes()
}

///|
/// Whether the byte `b` is an unreserved character of RFC 3986 §2.3,
/// which percent-encoding leaves as it is: `A-Z a-z 0-9 - . _ ~`.
fn is_unreserved(b : Byte) -> Bool {
  b is (b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~')
}

///|
/// The hex digits of percent-encoding, upper case as RFC 3986 §2.1
/// recommends.
let upper_hex_digits : String = "0123456789ABCDEF"

///|
/// `bytes` percent-encoded, each byte but the unreserved characters as `%`
/// and two upper-case hex digits, as `urlEncode`, the helper `name`,
/// inserted at `at` gives them, bounded before they are written.
fn percent_encoded(
  bytes : Bytes,
  name : String,
  at : String,
) -> String raise RenderError {
  let mut length = 0L
  for b in bytes {
    length += if is_unreserved(b) { 1L } else { 3L }
  }
  check_result(name, length, at)
  let out = StringBuilder(size_hint=length.to_int())
  for b in bytes {
    if is_unreserved(b) {
      out.write_char(b.to_int().unsafe_to_char())
    } else {
      out.write_char('%')
      out.write_char(upper_hex_digits[b.to_int() >> 4].unsafe_to_char())
      out.write_char(upper_hex_digits[b.to_int() & 15].unsafe_to_char())
    }
  }
  out.to_string()
}

///|
/// The value of the hex digit `c`, in either case, or -1 when it is not
/// one.
fn hex_value(c : Char) -> Int {
  match c {
    '0'..='9' => c.to_int() - '0'.to_int()
    'A'..='F' => c.to_int() - 'A'.to_int() + 10
    'a'..='f' => c.to_int() - 'a'.to_int() + 10
    _ => -1
  }
}

///|
/// How many bytes `text` decodes to with its percent-escapes decoded: one
/// for each escape, and the UTF-8 of every other character, `+` included.
/// Raises `NotDecodable` at a `%` that two hex digits do not follow.
fn percent_length(text : StringView) -> Int raise NotDecodable {
  let mut length = 0
  // The hex digits still to come after a `%`, and where that `%` is,
  // counted in characters from 1.
  let mut pending = 0
  let mut escape_at = 0
  let mut k = 0
  for c in text {
    k += 1
    if pending > 0 {
      if hex_value(c) < 0 {
        break
      }
      pending -= 1
      if pending == 0 {
        length += 1
      }
    } else if c == '%' {
      pending = 2
      escape_at = k
    } else {
      length += char_utf8_length(c)
    }
  }
  if pending > 0 {
    raise NotDecodable(
      "character \{escape_at}, \"%\", is not followed by two hex digits",
    )
  }
  length
}

///|
/// The `length` bytes that `text`, which `percent_length` has checked,
/// decodes to.
fn percent_decoded(text : StringView, length : Int) -> Bytes {
  let out = @buffer.Buffer(size_hint=length)
  let mut pending = 0
  let mut value = 0
  for c in text {
    if pending > 0 {
      value = value * 16 + hex_value(c)
      pending -= 1
      if pending == 0 {
        out.write_byte(value.to_byte())
      }
    } else if c == '%' {
      pending = 2
      value = 0
    } else {
      out.write_char_utf8(c)
    }
  }
  out.to_bytes()
}
