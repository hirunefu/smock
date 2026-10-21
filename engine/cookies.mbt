// Cookie conditions: the cookies of a request, read by `@cookies` from
// every `Cookie` field, as templates read them too. The fields are scanned
// in place, with no list of cookies built per request, and a value is
// copied, once, only for a pattern to match it.

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
    if @cookies.is_field(header.0) && has_cookie(header.1, name, wanted) {
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
  for start = @cookies.find(field, name); start >= 0; {
    let end = @cookies.value_end(field, start)
    let meets = match wanted {
      Any => true
      Exact(text) => field[start:end] == text
      Pattern(pattern) => pattern.matches(@utf8.encode(field[start:end]))
    }
    if meets {
      return true
    }
    continue @cookies.find(field, name, from=end)
  }
  false
}
