// The Session a request carries: a member of a W3C Baggage header, by
// default the `smock-session` member of `baggage`.

///|
/// The Session key of a request with the header fields `headers`: the value
/// of the member `member_name` of the W3C Baggage header `header`.
///
/// - Every field named `header`, in any case, is combined, in order, into
///   one list, whose members are split on `,`. Empty members are skipped,
///   as in any HTTP list.
/// - A member is `key=value`, with optional whitespace around the key and
///   the value, then any properties, each after a `;`, which are ignored.
/// - The value of the first member named `member_name` is trimmed and
///   percent-decoded; escaped bytes that are not UTF-8 become U+FFFD.
///
/// A request has no Session without such a member, when its value is
/// empty, or when the combined header is not W3C Baggage: a member without
/// `=`, a key that is not a token, or a value with a character W3C Baggage
/// does not allow, such as a space, `"`, `\` or a non-ASCII character, or
/// a `%` that two hexadecimal digits do not follow.
pub fn session_of(
  headers : Array[(String, String)],
  header~ : String,
  member_name~ : String,
) -> String? {
  // The fields are read with index loops, without splitting or trimming
  // into new values, since every request is read.
  let header = header.to_lower()
  let mut found : StringView? = None
  for field in headers {
    if !is_name(field.0, header) {
      continue
    }
    let s = field.1
    let n = s.length()
    let mut start = 0
    while start <= n {
      // The list member s[start:end], up to the next comma.
      let mut end = start
      while end < n && s[end] != ',' {
        end += 1
      }
      if !is_ows_only(s, start, end) {
        // Its key and value, before any properties.
        let mut properties = start
        while properties < end && s[properties] != ';' {
          properties += 1
        }
        let mut equals = start
        while equals < properties && s[equals] != '=' {
          equals += 1
        }
        if equals == properties {
          return None
        }
        let key = trim_ows(s[start:equals])
        let value = trim_ows(s[equals + 1:properties])
        if !is_baggage_key(key) || !is_baggage_value(value) {
          return None
        }
        if found is None && key == member_name {
          found = Some(value)
        }
      }
      start = end + 1
    }
  }
  match found {
    Some(value) if !value.is_empty() => Some(percent_decode(value))
    _ => None
  }
}

///|
/// Whether `s[start:end]` is empty or only optional whitespace.
fn is_ows_only(s : String, start : Int, end : Int) -> Bool {
  for i in start..<end {
    if s[i] != ' ' && s[i] != '\t' {
      return false
    }
  }
  true
}

///|
/// `s` without the optional whitespace, spaces and tabs, around it.
fn trim_ows(s : StringView) -> StringView {
  let mut start = 0
  let mut end = s.length()
  while start < end && (s[start] == ' ' || s[start] == '\t') {
    start += 1
  }
  while end > start && (s[end - 1] == ' ' || s[end - 1] == '\t') {
    end -= 1
  }
  s[start:end]
}

///|
/// Whether `s` is a W3C Baggage key: an HTTP token, one or more ASCII
/// letters, digits and ``!#$%&'*+-.^_`|~``.
fn is_baggage_key(s : StringView) -> Bool {
  if s.is_empty() {
    return false
  }
  for i in 0..<s.length() {
    let c = s[i]
    let token = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c
      is ('!'
      | '#'
      | '$'
      | '%'
      | '&'
      | '\''
      | '*'
      | '+'
      | '-'
      | '.'
      | '^'
      | '_'
      | '`'
      | '|'
      | '~')
    if !token {
      return false
    }
  }
  true
}

///|
/// Whether `s` is a W3C Baggage value: printable ASCII other than space,
/// `"`, `,`, `;` and `\`, where each `%` starts a percent-encoded byte.
fn is_baggage_value(s : StringView) -> Bool {
  let n = s.length()
  for i in 0..<n {
    let c = s[i]
    if c <= ' ' || c > '~' || c is ('"' | ',' | ';' | '\\') {
      return false
    }
    if c == '%' && !(i + 2 < n && is_hex(s[i + 1]) && is_hex(s[i + 2])) {
      return false
    }
  }
  true
}

///|
fn is_hex(c : UInt16) -> Bool {
  (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}
