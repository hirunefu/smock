// The rules for the arguments of the newer helpers, and the bound on what
// a helper gives. Such a helper takes any expression as an argument, and
// says of what kind each one must be. A value of another kind is a render
// error, and a literal of another kind a load error: the same rules decide
// both, and the messages are the same.

///|
/// What an argument of a helper must give.
priv enum Kind {
  /// A string; a number or a boolean is taken as its text.
  Text
  /// A text, or an array.
  TextOrArray
  /// An array.
  Array
  /// A number without a fraction, or a string that is one.
  Integer
  /// A number, or a string that is one.
  Numeric
  /// A date in the years 0 to 9999: an RFC 3339 date-time with an offset,
  /// a date `YYYY-MM-DD`, or a number without a fraction, read as
  /// milliseconds since the Unix epoch. When rendered, another value is
  /// missing rather than an error.
  Date
}

///|
/// What an argument of the kind must be, for a message.
fn Kind::wanted(self : Kind) -> String {
  match self {
    Text => "a string, a number or a boolean"
    TextOrArray => "a string, a number, a boolean or an array"
    Array => "an array"
    Integer => "an integer, or a string that is one"
    Numeric => "a number, or a string that is one"
    Date =>
      "a date: an RFC 3339 date-time with an offset, a date YYYY-MM-DD or epoch milliseconds, in the years 0 to 9999"
  }
}

///|
/// Whether `json` is of the kind.
fn Kind::accepts(self : Kind, json : Json) -> Bool {
  match self {
    Text => text_value(json) is Some(_)
    TextOrArray => json is Array(_) || text_value(json) is Some(_)
    Array => json is Array(_)
    Integer => integer_value(json) is Some(_)
    Numeric => numeric_value(json) is Some(_)
    Date => date_of(json) is Some(ms) && ms >= earliest && ms <= latest
  }
}

///|
/// Checks that the call has from `least` to `most` arguments, and that
/// each of its literals is of the kind of its argument: argument `k`, from
/// 0, is of the kind `kinds[k]`, or of the last of `kinds` past their end.
fn CallSite::takes(
  self : CallSite,
  kinds : Array[Kind],
  least~ : Int,
  most~ : Int,
) -> Unit raise Syntax {
  self.count_between(least~, most~)
  for k in 0..<self.args.length() {
    self.check_kind(
      k,
      kinds[if k < kinds.length() { k } else { kinds.length() - 1 }],
    )
  }
}

///|
/// Checks that each literal of argument `k`, from 0, is of the kind
/// `kind`.
fn CallSite::check_kind(
  self : CallSite,
  k : Int,
  kind : Kind,
) -> Unit raise Syntax {
  let (at, arg) = self.args[k]
  for literal in literals(arg) {
    if !kind.accepts(literal) {
      raise Syntax(at, argument_problem(self.name, k, kind, literal))
    }
  }
}

///|
/// Checks that the call has from `least` to `most` arguments.
fn CallSite::count_between(
  self : CallSite,
  least~ : Int,
  most~ : Int,
) -> Unit raise Syntax {
  let n = self.args.length()
  if least == most {
    self.count(least)
  } else if n < least || n > most {
    let what = if most == least + 1 {
      "\{least} or \{most} arguments"
    } else {
      "\{least} to \{most} arguments"
    }
    raise Syntax(self.start, "\{self.name}() takes \{what}, not \{n}")
  }
}

///|
/// What is wrong with `json`, argument `k` (from 0) of the helper `name`,
/// which is not of the kind `kind`.
fn argument_problem(name : String, k : Int, kind : Kind, json : Json) -> String {
  "\{name}(): argument \{k + 1} must be \{kind.wanted()}, not \{described(json)}"
}

///|
/// `json` as a text argument, if it is one: a string as it is, a number as
/// smock writes it, and `true` or `false` as those words.
fn text_value(json : Json) -> String? {
  match json {
    String(s) => Some(s)
    Number(n, repr~) => Some(number_text(n, repr))
    True => Some("true")
    False => Some("false")
    Null | Object(_) | Array(_) => None
  }
}

///|
/// Argument `k` (from 0) of the helper `name`, whose value is `json`, as
/// text. Raises a render error at `at` when it is not one.
fn text_argument(
  name : String,
  k : Int,
  json : Json,
  at : String,
) -> String raise RenderError {
  match text_value(json) {
    Some(text) => text
    None =>
      raise RenderError(at~, message=argument_problem(name, k, Text, json))
  }
}

///|
/// `json` as a numeric argument, if it is one: a number, or a string that
/// is a JSON number, read as `number(x)` reads it.
fn numeric_value(json : Json) -> Json? {
  match json {
    Number(_) => Some(json)
    String(text) => number_of(text)
    _ => None
  }
}

///|
/// `json` as an integer argument, if it is one: a numeric value without a
/// fraction. A number that keeps its text, such as an arithmetic result,
/// is the decimal its text writes, whose fraction its float can lose. It is
/// clamped to the range of an `Int`, which is beyond the length of any
/// text.
fn integer_value(json : Json) -> Int? {
  guard numeric_value(json) is Some(Number(n, ..)) && n == n.floor() else {
    return None
  }
  if json is Number(_, repr=Some(text)) && !writes_integer(text) {
    return None
  }
  if n >= 2147483647.0 {
    Some(2147483647)
  } else if n <= -2147483648.0 {
    Some(-2147483648)
  } else {
    Some(n.to_int())
  }
}

///|
/// Whether `text`, the JSON number a number keeps as its text, writes an
/// integer: no digit but 0 after the point, once the exponent has moved
/// the point.
fn writes_integer(text : String) -> Bool {
  // Where the digits end, and where the point is among them.
  let mut end = 0
  while end < text.length() && !(text[end] is ('e' | 'E')) {
    end += 1
  }
  let mut point = end
  for i in 0..<end {
    if text[i] == '.' {
      point = i
      break
    }
  }
  // How many places the exponent moves the point to the right. Past the
  // length of the text, a further move changes nothing.
  let mut shift = 0
  if end < text.length() {
    let mut i = end + 1
    let negative = i < text.length() && text[i] == '-'
    if i < text.length() && text[i] is ('+' | '-') {
      i += 1
    }
    while i < text.length() {
      if shift <= text.length() {
        shift = shift * 10 + (text[i].to_int() - '0'.to_int())
      }
      i += 1
    }
    if negative {
      shift = -shift
    }
  }
  // A digit k places after the point stays after it when k > shift; one k
  // places before it moves after it when k <= -shift.
  for i in (point + 1)..<end {
    if text[i] != '0' && i - point > shift {
      return false
    }
  }
  for i in 0..<point {
    if text[i] is ('1'..='9') && point - i <= -shift {
      return false
    }
  }
  true
}

///|
/// Argument `k` (from 0) of the helper `name`, whose value is `json`, as
/// an integer. Raises a render error at `at` when it is not one.
fn integer_argument(
  name : String,
  k : Int,
  json : Json,
  at : String,
) -> Int raise RenderError {
  match integer_value(json) {
    Some(n) => n
    None =>
      raise RenderError(at~, message=argument_problem(name, k, Integer, json))
  }
}

///|
/// Raises a render error at `at` when the result of the helper `name`
/// would take `bytes` bytes of UTF-8, more than 1 MiB. A helper checks this
/// before it builds its result; an array or an object counts as its
/// compact JSON.
fn check_result(
  name : String,
  bytes : Int64,
  at : String,
) -> Unit raise RenderError {
  if bytes > max_output.to_int64() {
    raise RenderError(
      at~,
      message="\{name}(): the result takes more than 1 MiB",
    )
  }
}
