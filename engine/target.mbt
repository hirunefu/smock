// Reading the request target: the path and the query parameters that Stub
// conditions are compared with. Decoding follows the WHATWG URL Standard:
// percent-decoding leaves a `%` that does not start an escape as it is, the
// decoded bytes are read as UTF-8, with U+FFFD for invalid sequences, and
// query parameters are parsed as application/x-www-form-urlencoded, where
// `+` stands for a space.

///|
/// The percent-decoded path of a request target: everything before the
/// query.
fn decoded_path(target : String) -> String {
  let path = match target.find("?") {
    Some(i) => target[:i]
    None => target[:]
  }
  percent_decode(path, plus_is_space=false)
}

///|
/// The query parameters of a request target, as decoded (name, value)
/// pairs, in order. A parameter without `=` has the empty value; empty
/// parameters, as between `&&`, are skipped.
fn query_parameters(target : String) -> Array[(String, String)] {
  let out = []
  guard target.find("?") is Some(i) else { return out }
  for parameter in target[i + 1:].split("&") {
    if parameter.is_empty() {
      continue
    }
    let (name, value) = match parameter.find("=") {
      Some(j) => (parameter[:j], parameter[j + 1:])
      None => (parameter, "")
    }
    out.push(
      (
        percent_decode(name, plus_is_space=true),
        percent_decode(value, plus_is_space=true),
      ),
    )
  }
  out
}

///|
/// Percent-decodes `s`. With `plus_is_space`, `+` stands for a space.
fn percent_decode(s : StringView, plus_is_space~ : Bool) -> String {
  guard s.contains_char('%') || (plus_is_space && s.contains_char('+')) else {
    return s.to_owned()
  }
  let bytes = @utf8.encode(s)
  let out = @buffer.Buffer(size_hint=bytes.length())
  let mut i = 0
  while i < bytes.length() {
    if bytes[i] == b'%' &&
      i + 2 < bytes.length() &&
      hex_digit(bytes[i + 1]) is Some(high) &&
      hex_digit(bytes[i + 2]) is Some(low) {
      out.write_byte((high * 16 + low).to_byte())
      i += 3
    } else if plus_is_space && bytes[i] == b'+' {
      out.write_byte(b' ')
      i += 1
    } else {
      out.write_byte(bytes[i])
      i += 1
    }
  }
  @utf8.decode_lossy(out.to_bytes())
}

///|
/// The value of the hexadecimal digit `b`, if it is one.
fn hex_digit(b : Byte) -> Int? {
  match b {
    b'0'..=b'9' => Some(b.to_int() - 0x30)
    b'a'..=b'f' => Some(b.to_int() - 0x61 + 10)
    b'A'..=b'F' => Some(b.to_int() - 0x41 + 10)
    _ => None
  }
}
