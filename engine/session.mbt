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
  let header = header.to_lower()
  let mut found = None
  for field in headers {
    if !is_name(field.0, header) {
      continue
    }
    for list_member in field.1.split(",") {
      if trim_ows(list_member).is_empty() {
        continue
      }
      let key_value = match list_member.find(";") {
        Some(i) => list_member[:i]
        None => list_member
      }
      guard key_value.find("=") is Some(i) else { return None }
      let key = trim_ows(key_value[:i])
      let value = trim_ows(key_value[i + 1:])
      if !is_baggage_key(key) || !is_baggage_value(value) {
        return None
      }
      if found is None && key == member_name {
        found = Some(value)
      }
    }
  }
  match found {
    Some(value) if !value.is_empty() => Some(@percent.decode_lossy(value))
    _ => None
  }
}

///|
/// `s` without the optional whitespace, spaces and tabs, around it.
fn trim_ows(s : StringView) -> StringView {
  s.trim(chars=" \t")
}

///|
/// Whether `s` is a W3C Baggage key: an HTTP token.
fn is_baggage_key(s : StringView) -> Bool {
  !s.is_empty() &&
  s
  .iter()
  .all(c => {
    (c >= 'a' && c <= 'z') ||
    (c >= 'A' && c <= 'Z') ||
    (c >= '0' && c <= '9') ||
    "!#$%&'*+-.^_`|~".contains_char(c)
  })
}

///|
/// Whether `s` is a W3C Baggage value: printable ASCII other than space,
/// `"`, `,`, `;` and `\`, where each `%` starts a percent-encoded byte.
fn is_baggage_value(s : StringView) -> Bool {
  for i, c in s {
    let allowed = c > ' ' && c <= '~' && !"\",;\\".contains_char(c)
    if !allowed {
      return false
    }
    if c == '%' && !(i + 2 < s.length() && is_hex(s[i + 1]) && is_hex(s[i + 2])) {
      return false
    }
  }
  true
}

///|
fn is_hex(c : UInt16) -> Bool {
  (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}
