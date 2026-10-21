// The cookies of a request, read from every `Cookie` field. RFC 6265 gives
// a server no algorithm for this, so each field is split on `;`, each part
// is trimmed of spaces and tabs, and the first `=` of a part separates the
// name from the value; a part without `=` holds no cookie. Names are
// compared exactly, case and all. Values stay as sent: quotes are part of
// them, as RFC 6265bis says, and nothing is percent-decoded.
//
// Cookie conditions, the Near miss and the `cookie` root of templates all
// read cookies here, so that what a condition matches is what a template
// inserts. Conditions scan the fields in place with `find` and
// `value_end`, which allocate nothing; the Near miss and templates take
// every cookie at once with `parse`.

///|
/// Whether a header field named `name` holds cookies: whether its name is
/// `Cookie`, in any case. Header names are ASCII.
pub fn is_field(name : StringView) -> Bool {
  let cookie = "cookie"
  if name.length() != cookie.length() {
    return false
  }
  for i in 0..<name.length() {
    let c = name[i]
    let lower = if c >= 'A' && c <= 'Z' { c + 0x20 } else { c }
    if lower != cookie[i] {
      return false
    }
  }
  true
}

///|
/// Where the value of the first cookie named `name` in `field`, the value
/// of a `Cookie` field, starts, or -1 when it has none. The search starts
/// at `from`, which is 0 or the end of a value found before, as
/// `value_end` gives it, so that the cookies of a repeated name are found
/// in order.
///
/// It returns an index, rather than an optional view, so that a search
/// allocates nothing.
pub fn find(field : String, name : String, from? : Int = 0) -> Int {
  for start = from; start <= field.length(); {
    let end = part_end(field, start)
    let first = name_start(field, start, end)
    let equals = equals_at(field, first, end)
    if equals >= 0 &&
      equals - first == name.length() &&
      same_name(field, first, name) {
      return equals + 1
    }
    continue end + 1
  }
  -1
}

///|
/// Where the value that starts at `start` in `field`, as `find` gives it,
/// ends: at the end of its part, without the spaces and tabs before it.
pub fn value_end(field : String, start : Int) -> Int {
  let mut end = part_end(field, start)
  while end > start && is_blank(field[end - 1]) {
    end -= 1
  }
  end
}

///|
/// The cookies of a request whose header fields are `headers`, from every
/// `Cookie` field: each name, in the order it first comes, with its
/// values, in order. A name that has no value is not there.
pub fn parse(headers : Array[(String, String)]) -> Map[String, Array[String]] {
  let cookies : Map[String, Array[String]] = Map([])
  for header in headers {
    guard is_field(header.0) else { continue }
    let field = header.1
    for start = 0; start <= field.length(); {
      let end = part_end(field, start)
      let first = name_start(field, start, end)
      let equals = equals_at(field, first, end)
      if equals >= 0 {
        let name = field[first:equals].to_owned()
        let value = field[equals + 1:value_end(field, equals + 1)].to_owned()
        match cookies.get(name) {
          Some(values) => values.push(value)
          None => cookies[name] = [value]
        }
      }
      continue end + 1
    }
  }
  cookies
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
/// Where the name of the part `field[start:end]` starts: after the spaces
/// and tabs at its start.
fn name_start(field : String, start : Int, end : Int) -> Int {
  let mut start = start
  while start < end && is_blank(field[start]) {
    start += 1
  }
  start
}

///|
/// The index of the first `=` in `field[start:end]`, which ends the name of
/// a cookie, or -1 when the part has none and so holds no cookie.
fn equals_at(field : String, start : Int, end : Int) -> Int {
  for i in start..<end {
    if field[i] == '=' {
      return i
    }
  }
  -1
}

///|
/// Whether `field`, from `start` on, starts with `name`, compared exactly.
/// The caller checks that `field` is long enough.
fn same_name(field : String, start : Int, name : String) -> Bool {
  for i in 0..<name.length() {
    if field[start + i] != name[i] {
      return false
    }
  }
  true
}

///|
/// Whether `c` is a space or a tab.
fn is_blank(c : UInt16) -> Bool {
  c == ' ' || c == '\t'
}
