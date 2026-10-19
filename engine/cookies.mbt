// Cookie conditions: the cookies of a request, read from every `Cookie`
// field. RFC 6265 gives a server no algorithm for this, so each field is
// split on `;`, each part is trimmed of spaces and tabs, and the first `=`
// of a part separates the name from the value. Values stay as sent: quotes
// are part of them, as RFC 6265bis says, and nothing is percent-decoded.
// The fields are scanned in place, with no list of cookies built per
// request, and a value is copied, once, only for a pattern to match it.

///|
/// Whether `condition`, on the cookie with this name, holds for the
/// request, as `query_meets` says for a query parameter. Names are compared
/// exactly, case and all, and the cookies of every `Cookie` field count.
fn Incoming::cookie_meets(
  self : Incoming,
  condition : (String, @definitions.ValueCondition),
) -> Bool {
  let (name, value) = condition
  let wanted = value.value_test()
  let headers = self.request.headers
  let mut found = false
  for i in 0..<headers.length() {
    let header = headers[i]
    if is_name(header.0, "cookie") && has_cookie(header.1, name, wanted) {
      found = true
      break
    }
  }
  value.holds(found~)
}

///|
/// Whether `field`, the value of a `Cookie` field, has a cookie named
/// `name` whose value passes `wanted`. An exact value and `$exists` are
/// compared in place; only a pattern needs the value, in UTF-8.
fn has_cookie(
  field : String,
  name : String,
  wanted : @definitions.ValueTest,
) -> Bool {
  for start = 0; start <= field.length(); {
    let end = part_end(field, start)
    let last = trimmed_end(field, start, end)
    let value = cookie_value_start(field, start, last, name)
    if value >= 0 {
      let meets = match wanted {
        Any => true
        Exact(text) => field[value:last] == text
        Pattern(pattern) => pattern.matches(@utf8.encode(field[value:last]))
      }
      if meets {
        return true
      }
    }
    continue end + 1
  }
  false
}

///|
/// The values of the cookies named `name` in `headers`, the header fields
/// of a request, from every `Cookie` field, in order.
fn cookie_values(
  headers : Array[(String, String)],
  name : String,
) -> Array[String] {
  let out = []
  for header in headers {
    guard is_name(header.0, "cookie") else { continue }
    let field = header.1
    for start = 0; start <= field.length(); {
      let end = part_end(field, start)
      let last = trimmed_end(field, start, end)
      let value = cookie_value_start(field, start, last, name)
      if value >= 0 {
        out.push(field[value:last].to_owned())
      }
      continue end + 1
    }
  }
  out
}

///|
/// The end of the part of `field`, a `Cookie` field value, that starts at
/// `start`: the index of the next `;`, or the length of `field`.
fn part_end(field : String, start : Int) -> Int {
  let mut i = start
  while i < field.length() && field[i] != ';' {
    i += 1
  }
  i
}

///|
/// The end of `field[start:end]`, one part of a `Cookie` field value,
/// trimmed of spaces and tabs.
fn trimmed_end(field : String, start : Int, end : Int) -> Int {
  let mut end = end
  while end > start && is_blank(field[end - 1]) {
    end -= 1
  }
  end
}

///|
/// Where the value of the cookie in `field[start:end]` starts, if its name
/// is `name`, or -1. The part, one part of a `Cookie` field value whose end
/// is trimmed, is trimmed of spaces and tabs at its start too, and its
/// first `=` separates the name from the value, which runs to `end`. A part
/// without `=` has no cookie.
///
/// It returns an index, rather than an optional view, so that no part
/// allocates.
fn cookie_value_start(
  field : String,
  start : Int,
  end : Int,
  name : String,
) -> Int {
  let mut start = start
  while start < end && is_blank(field[start]) {
    start += 1
  }
  let mut equals = start
  while equals < end && field[equals] != '=' {
    equals += 1
  }
  if equals == end || equals - start != name.length() {
    return -1
  }
  for i in 0..<name.length() {
    if field[start + i] != name[i] {
      return -1
    }
  }
  equals + 1
}

///|
/// Whether `c` is a space or a tab.
fn is_blank(c : UInt16) -> Bool {
  c == ' ' || c == '\t'
}
