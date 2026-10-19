// Cookie conditions: the cookies of a request, read from every `Cookie`
// field. RFC 6265 gives a server no algorithm for this, so each field is
// split on `;`, each part is trimmed of spaces and tabs, and the first `=`
// of a part separates the name from the value. Values stay as sent: quotes
// are part of them, as RFC 6265bis says, and nothing is percent-decoded.
// The fields are scanned in place, with no list of cookies built per
// request.

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
/// `name` whose value meets `wanted`.
fn has_cookie(
  field : String,
  name : String,
  wanted : @definitions.ValueCondition,
) -> Bool {
  for start = 0; start <= field.length(); {
    let end = part_end(field, start)
    if cookie_value(field, start, end, name) is Some(value) &&
      wanted.meets(value) {
      return true
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
      if cookie_value(field, start, end, name) is Some(value) {
        out.push(value)
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
/// The value of the cookie in `field[start:end]`, one part of a `Cookie`
/// field value, if its name is `name`. The part is trimmed of spaces and
/// tabs, and its first `=` separates the name from the value. A part
/// without `=` has no cookie.
fn cookie_value(
  field : String,
  start : Int,
  end : Int,
  name : String,
) -> String? {
  let mut start = start
  let mut end = end
  while start < end && is_blank(field[start]) {
    start += 1
  }
  while end > start && is_blank(field[end - 1]) {
    end -= 1
  }
  let mut equals = start
  while equals < end && field[equals] != '=' {
    equals += 1
  }
  if equals == end || equals - start != name.length() {
    return None
  }
  for i in 0..<name.length() {
    if field[start + i] != name[i] {
      return None
    }
  }
  Some(field[equals + 1:end].to_owned())
}

///|
/// Whether `c` is a space or a tab.
fn is_blank(c : UInt16) -> Bool {
  c == ' ' || c == '\t'
}
