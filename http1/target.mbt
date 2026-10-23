///|
/// Whether `target` is a request target, for the method `meth`, in one of
/// the four forms of RFC 9112, section 3.2: origin-form (`/users/1?x=y`),
/// absolute-form (`http://a.example/users/1`), authority-form
/// (`a.example:443`) or asterisk-form (`*`). A fragment (`#`) is part of
/// none of them.
///
/// The form must suit the method (RFC 9112, sections 3.2.3 and 3.2.4):
/// authority-form is only for CONNECT, which takes no other form, and
/// asterisk-form only for OPTIONS. A target that has the shape of
/// authority-form is read as authority-form, even when it could also be an
/// absolute-URI, such as `a.example:80` with the scheme `a.example`.
///
/// Only the form is checked. The characters of a path or a query are only
/// checked to be visible ASCII (`is_visible_ascii`), which the head scan
/// does: clients send some that RFC 3986 leaves out, such as `|` and `^`.
fn is_request_target(target : StringView, meth~ : StringView) -> Bool {
  // Neither is authority-form: a registered name holds no `/`, and `*`
  // has no port.
  if target.has_prefix("/") || target == "*" {
    return is_origin_or_asterisk_form(target, meth~)
  }
  if target.contains_char('#') {
    return false
  }
  let authority_form = is_host_and_port(target, port_required=true)
  if meth == "CONNECT" || authority_form {
    return meth == "CONNECT" && authority_form
  }
  has_scheme(target)
}

///|
/// Whether `target` is a request target, for the method `meth`, in
/// origin-form (`/users/1?x=y`), or is `*`, the asterisk-form, for OPTIONS
/// (RFC 9112, sections 3.2.1 and 3.2.4). These are the forms of HTTP/2's
/// `:path` (RFC 9113, section 8.3.1). A fragment (`#`) is part of neither,
/// and CONNECT takes neither.
///
/// Only the form is checked, as by the parser: `is_visible_ascii` checks
/// the characters.
///
/// ```mbt check
/// test {
///   inspect(
///     @http1.is_origin_or_asterisk_form("/users/1?x=y", meth="GET"),
///     content="true",
///   )
///   inspect(
///     @http1.is_origin_or_asterisk_form("*", meth="OPTIONS"),
///     content="true",
///   )
///   inspect(@http1.is_origin_or_asterisk_form("*", meth="GET"), content="false")
///   inspect(
///     @http1.is_origin_or_asterisk_form("http://a.example/", meth="GET"),
///     content="false",
///   )
/// }
/// ```
pub fn is_origin_or_asterisk_form(
  target : StringView,
  meth~ : StringView,
) -> Bool {
  if target.has_prefix("/") {
    meth != "CONNECT" && !target.contains_char('#')
  } else {
    target == "*" && meth == "OPTIONS"
  }
}

///|
/// Whether `s` holds only visible ASCII characters, 0x21 to 0x7E: no space,
/// no control character, no DEL and nothing beyond ASCII. The parser
/// answers 400 to a request whose target holds any other byte, and HTTP/2's
/// `:path` follows the same rule. Every visible character passes, even
/// those RFC 3986 leaves out of a URI, such as `|` and `^`, since clients
/// send them. An empty `s` passes; an empty target is in no form of a
/// request target.
///
/// ```mbt check
/// test {
///   inspect(@http1.is_visible_ascii("/users/1?q=a|b"), content="true")
///   inspect(@http1.is_visible_ascii("/users 1"), content="false")
///   inspect(@http1.is_visible_ascii("/users/\t1"), content="false")
///   inspect(@http1.is_visible_ascii("/caf\u{e9}"), content="false")
/// }
/// ```
pub fn is_visible_ascii(s : StringView) -> Bool {
  for i in 0..<s.length() {
    // Each code unit of a character beyond ASCII is 0x80 or above.
    let c = s[i]
    if c >= 0x80 || !is_visible_byte(c.to_byte()) {
      return false
    }
  }
  true
}

///|
/// Whether `target` starts with a URI scheme and its `:` (RFC 3986,
/// section 3.1), as an absolute-form target does.
fn has_scheme(target : StringView) -> Bool {
  guard target.find(":") is Some(colon) && colon > 0 else { return false }
  for i, c in target[:colon] {
    let ok = c.is_ascii_alphabetic() ||
      (i > 0 && (c.is_ascii_digit() || c is ('+' | '-' | '.')))
    if !ok {
      return false
    }
  }
  true
}

///|
/// Whether `s` can be the value of a Host field (RFC 9110, section 7.2):
/// `uri-host [":" port]` (RFC 3986, sections 3.2.2 and 3.2.3), where an
/// IPv6 address is in brackets. The host and the port may be empty. The
/// parser answers 400 to a request whose Host field is not one.
///
/// ```mbt check
/// test {
///   inspect(@http1.is_host_value("users.example.com:8080"), content="true")
///   inspect(@http1.is_host_value("[::1]:8080"), content="true")
///   inspect(@http1.is_host_value("users:http"), content="false")
///   inspect(@http1.is_host_value("[::1]x"), content="false")
/// }
/// ```
pub fn is_host_value(s : StringView) -> Bool {
  is_host_and_port(s, port_required=false)
}

///|
/// Whether `s` is `uri-host [":" port]` (RFC 3986, sections 3.2.2 and
/// 3.2.3), as the value of a Host field is (RFC 9110, section 7.2). With
/// `port_required`, it is `uri-host ":" port`, the authority-form of a
/// request target. The host and the port may be empty.
fn is_host_and_port(s : StringView, port_required~ : Bool) -> Bool {
  // An IP literal holds colons; a registered name holds none.
  let host_end = if s.has_prefix("[") {
    match s.find("]") {
      Some(close) => close + 1
      None => return false
    }
  } else {
    s.find(":").unwrap_or(s.length())
  }
  let host = s[:host_end]
  let rest = s[host_end:]
  let port_ok = if rest.is_empty() {
    !port_required
  } else {
    rest.has_prefix(":") && rest[1:].iter().all(c => c.is_ascii_digit())
  }
  port_ok && is_uri_host(host)
}

///|
/// Whether `host` is an IP literal in brackets, an IPv4 address or a
/// registered name (RFC 3986, section 3.2.2). A registered name may be
/// empty.
fn is_uri_host(host : StringView) -> Bool {
  if host.has_prefix("[") {
    host.length() >= 2 &&
    host.has_suffix("]") &&
    (
      is_ipv6(host[1:host.length() - 1]) ||
      is_ip_future(host[1:host.length() - 1])
    )
  } else {
    // An IPv4 address is also a registered name.
    is_reg_name(host)
  }
}

///|
/// Whether `s` is a registered name: unreserved characters, sub-delims and
/// percent-encoded octets (RFC 3986, section 3.2.2).
fn is_reg_name(s : StringView) -> Bool {
  // How many hexadecimal digits of a percent-encoded octet are still due.
  let mut hex_due = 0
  for c in s {
    if hex_due > 0 {
      if !c.is_ascii_hexdigit() {
        return false
      }
      hex_due -= 1
    } else if c == '%' {
      hex_due = 2
    } else if !(is_unreserved(c) || is_sub_delim(c)) {
      return false
    }
  }
  hex_due == 0
}

///|
/// Whether `s` is an IPv6 address (RFC 3986, section 3.2.2): eight groups
/// of one to four hexadecimal digits separated by `:`, where an IPv4
/// address may stand for the last two, and one `::` for one or more groups
/// of zeros.
fn is_ipv6(s : StringView) -> Bool {
  match s.split("::").collect() {
    [whole] => ipv6_groups(whole, ipv4_last=true) == Some(8)
    [before, after] =>
      match
        (
          ipv6_groups(before, ipv4_last=false),
          ipv6_groups(after, ipv4_last=true),
        ) {
        (Some(before), Some(after)) => before + after <= 7
        _ => false
      }
    _ => false
  }
}

///|
/// How many 16-bit groups `s` stands for, when it is groups of one to four
/// hexadecimal digits separated by `:`, and, with `ipv4_last`, an IPv4
/// address in place of the last one, which stands for two. An empty `s`
/// stands for none.
fn ipv6_groups(s : StringView, ipv4_last~ : Bool) -> Int? {
  if s.is_empty() {
    return Some(0)
  }
  let parts = s.split(":").collect()
  let mut groups = 0
  for i, part in parts {
    if ipv4_last && i == parts.length() - 1 && part.contains_char('.') {
      guard is_ipv4(part) else { return None }
      groups += 2
    } else {
      guard part.length() is (1..=4) &&
        part.iter().all(c => c.is_ascii_hexdigit()) else {
        return None
      }
      groups += 1
    }
  }
  Some(groups)
}

///|
/// Whether `s` is an IPv4 address: four decimal numbers from 0 to 255,
/// without leading zeros, separated by `.`.
fn is_ipv4(s : StringView) -> Bool {
  let octets = s.split(".").collect()
  octets.length() == 4 &&
  octets
  .iter()
  .all(octet => {
    octet.length() is (1..=3) &&
    octet.iter().all(c => c.is_ascii_digit()) &&
    !(octet.length() > 1 && octet.has_prefix("0")) &&
    octet.iter().fold(init=0, (n, c) => n * 10 + (c.to_int() - '0'.to_int())) <=
    255
  })
}

///|
/// Whether `s` is an IP literal of a future version: `v`, a hexadecimal
/// version, `.`, then unreserved characters, sub-delims and colons
/// (RFC 3986, section 3.2.2).
fn is_ip_future(s : StringView) -> Bool {
  guard (s.has_prefix("v") || s.has_prefix("V")) &&
    s.find(".") is Some(dot) &&
    dot > 1 &&
    dot + 1 < s.length() else {
    return false
  }
  s[1:dot].iter().all(c => c.is_ascii_hexdigit()) &&
  s[dot + 1:].iter().all(c => is_unreserved(c) || is_sub_delim(c) || c == ':')
}

///|
fn is_unreserved(c : Char) -> Bool {
  c.is_ascii_alphabetic() || c.is_ascii_digit() || c is ('-' | '.' | '_' | '~')
}

///|
fn is_sub_delim(c : Char) -> Bool {
  c is ('!' | '$' | '&' | '\'' | '(' | ')' | '*' | '+' | ',' | ';' | '=')
}
