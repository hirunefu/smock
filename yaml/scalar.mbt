///|
/// What a plain scalar means.
priv enum Plain {
  /// `true`, `false`, `null` and JSON-syntax numbers, typed as
  /// `@json.parse` types them, and every other string.
  Value(Json)
  /// A scalar that YAML 1.1 or 1.2 would give another type, named here,
  /// such as "a boolean". It must be quoted.
  Ambiguous(String)
}

///|
fn resolve(text : String) -> Plain {
  match text {
    "true" => return Value(Json::boolean(true))
    "false" => return Value(Json::boolean(false))
    "null" => return Value(Json::null())
    _ => ()
  }
  if is_json_number(text) {
    return Value(@json.parse(text)) catch { _ => Ambiguous("a number") }
  }
  match text.to_lower() {
    "y" | "n" | "yes" | "no" | "on" | "off" | "true" | "false" =>
      return Ambiguous("a boolean")
    "null" => return Ambiguous("null")
    _ => ()
  }
  match text {
    "~" => Ambiguous("null")
    "<<" => Ambiguous("a merge key")
    "=" => Ambiguous("a value key")
    _ if is_yaml_number(text) => Ambiguous("a number")
    _ if is_timestamp(text) => Ambiguous("a timestamp")
    _ => Value(Json::string(text))
  }
}

///|
/// Whether `text` is a number in JSON syntax:
/// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?`.
fn is_json_number(text : String) -> Bool {
  let s = Scan(text)
  let _ = s.char('-')
  if !s.char('0') && !(s.one(is_nonzero_digit) && s.skip_while(is_digit)) {
    return false
  }
  if s.char('.') && s.run(is_digit) == 0 {
    return false
  }
  if s.char('e') || s.char('E') {
    let _ = s.char('+') || s.char('-')
    if s.run(is_digit) == 0 {
      return false
    }
  }
  s.done()
}

///|
/// Whether YAML 1.1 or the YAML 1.2 core schema reads `text` as an integer
/// or a float.
fn is_yaml_number(text : String) -> Bool {
  let signed = text.has_prefix("+") || text.has_prefix("-")
  let body = if signed { text[1:].to_owned() } else { text }
  let matches = (pattern : (Scan) -> Bool) => {
    let s = Scan(body)
    pattern(s) && s.done()
  }
  body is (".inf" | ".Inf" | ".INF") ||
  (!signed && body is (".nan" | ".NaN" | ".NAN")) ||
  // YAML 1.2: 0o17
  (!signed && matches(s => s.str("0o") && s.run(is_octal_digit) > 0)) ||
  // YAML 1.1: 0b1010, 0x_1F, 017, 1_000
  matches(s => s.str("0b") && s.run(c => c is ('0' | '1' | '_')) > 0) ||
  matches(s => s.str("0x") && s.run(c => is_hex_digit(c) || c == '_') > 0) ||
  matches(s => s.char('0') && s.run(c => is_octal_digit(c) || c == '_') > 0) ||
  matches(s => s.one(is_nonzero_digit) && s.skip_while(is_digit_or_underscore)) ||
  // YAML 1.2: 08
  matches(s => s.run(is_digit) > 0) ||
  // YAML 1.1 sexagesimal: 190:20:30, 190:20:30.15
  matches(s => {
    s.one(is_nonzero_digit) &&
    s.skip_while(is_digit_or_underscore) &&
    s.sexagesimal()
  }) ||
  matches(s => {
    s.one(is_digit) &&
    s.skip_while(is_digit_or_underscore) &&
    s.sexagesimal() &&
    s.char('.') &&
    s.skip_while(is_digit_or_underscore)
  }) ||
  // YAML 1.1 float: 1_000.5, .5, 1.2.3, 1.5e+3
  matches(s => {
    let before = s.run(is_digit_or_underscore)
    if before > 0 && !is_digit(s.chars[0]) {
      return false
    }
    if !s.char('.') {
      return false
    }
    let after = s.i
    let _ = s.run(c => is_digit(c) || c == '.')
    (before > 0 || s.chars[after:s.i].iter().any(is_digit)) &&
    (
      !(s.char('e') || s.char('E')) ||
      ((s.char('+') || s.char('-')) && s.run(is_digit) > 0)
    )
  }) ||
  // YAML 1.2 float: .5, 1., 1.e3, 09.5
  matches(s => {
    (if s.char('.') {
      s.run(is_digit) > 0
    } else {
      s.run(is_digit) > 0 && (!s.char('.') || s.skip_while(is_digit))
    }) &&
    (
      !(s.char('e') || s.char('E')) ||
      (s.optional_sign() && s.run(is_digit) > 0)
    )
  })
}

///|
/// Whether YAML 1.1 reads `text` as a timestamp, such as `2001-12-14` or
/// `2001-12-14 21:59:43.10 -5`.
fn is_timestamp(text : String) -> Bool {
  let date = (s : Scan, short : Bool) => {
    let min = if short { 1 } else { 2 }
    s.digits(4, 4) &&
    s.char('-') &&
    s.digits(min, 2) &&
    s.char('-') &&
    s.digits(min, 2)
  }
  let s = Scan(text)
  if date(s, false) && s.done() {
    return true
  }
  let s = Scan(text)
  date(s, true) &&
  (s.char('T') || s.char('t') || s.run(is_blank) > 0) &&
  s.digits(1, 2) &&
  s.char(':') &&
  s.digits(2, 2) &&
  s.char(':') &&
  s.digits(2, 2) &&
  (!s.char('.') || s.skip_while(is_digit)) &&
  s.skip_while(is_blank) &&
  (
    s.done() ||
    s.char('Z') ||
    (
      (s.char('+') || s.char('-')) &&
      s.digits(1, 2) &&
      (!s.char(':') || s.digits(2, 2))
    )
  ) &&
  s.done()
}

///|
/// A cursor over the characters of a scalar, for matching its syntax.
priv struct Scan {
  chars : Array[Char]
  mut i : Int
}

///|
fn Scan::Scan(text : String) -> Scan {
  { chars: text.to_array(), i: 0, }
}

///|
/// Consumes `c` if it comes next.
fn Scan::char(self : Scan, c : Char) -> Bool {
  self.one(next => next == c)
}

///|
/// Consumes the next character if it satisfies `pred`.
fn Scan::one(self : Scan, pred : (Char) -> Bool) -> Bool {
  if self.i < self.chars.length() && pred(self.chars[self.i]) {
    self.i += 1
    true
  } else {
    false
  }
}

///|
/// Consumes `s` if it comes next.
fn Scan::str(self : Scan, s : String) -> Bool {
  let start = self.i
  for c in s {
    if !self.char(c) {
      self.i = start
      return false
    }
  }
  true
}

///|
/// Consumes the characters that satisfy `pred` and returns how many.
fn Scan::run(self : Scan, pred : (Char) -> Bool) -> Int {
  let start = self.i
  while self.one(pred) {

  }
  self.i - start
}

///|
/// Consumes the characters that satisfy `pred`, if any. Like `*` in a
/// regular expression, it always matches, so it returns `true`, to chain
/// with `&&`.
fn Scan::skip_while(self : Scan, pred : (Char) -> Bool) -> Bool {
  let _ = self.run(pred)
  true
}

///|
/// Consumes a `+` or `-`, if one comes next. Like `[+-]?` in a regular
/// expression, it always matches, so it returns `true`, to chain with `&&`.
fn Scan::optional_sign(self : Scan) -> Bool {
  let _ = self.char('+') || self.char('-')
  true
}

///|
/// Consumes `min` to `max` decimal digits.
fn Scan::digits(self : Scan, min : Int, max : Int) -> Bool {
  let start = self.i
  while self.i - start < max && self.one(is_digit) {

  }
  if self.i - start >= min {
    true
  } else {
    self.i = start
    false
  }
}

///|
/// Consumes one or more `:[0-5]?[0-9]` groups.
fn Scan::sexagesimal(self : Scan) -> Bool {
  let mut groups = 0
  while self.char(':') {
    let start = self.i
    if !(self.one(c => c is ('0'..='5')) && self.one(is_digit)) {
      self.i = start
      if !self.one(is_digit) {
        return false
      }
    }
    groups += 1
  }
  groups > 0
}

///|
fn Scan::done(self : Scan) -> Bool {
  self.i == self.chars.length()
}

///|
fn is_digit(c : Char) -> Bool {
  c is ('0'..='9')
}

///|
fn is_nonzero_digit(c : Char) -> Bool {
  c is ('1'..='9')
}

///|
fn is_digit_or_underscore(c : Char) -> Bool {
  is_digit(c) || c == '_'
}

///|
fn is_octal_digit(c : Char) -> Bool {
  c is ('0'..='7')
}

///|
fn is_hex_digit(c : Char) -> Bool {
  c is ('0'..='9' | 'a'..='f' | 'A'..='F')
}

///|
fn is_blank(c : Char) -> Bool {
  c is (' ' | '\t')
}
