// Expressions: what `${ … }` holds, and the condition of `$if`.
//
//     expr    = value { "??" value }
//     value   = ref | literal | call
//     ref     = root { "." name | "[" integer "]" | "[" string "]" }
//     root    = "method" | "path" | "query" | "header" | "body" | "bodyText"
//             | "env" | "loop" | loop variable
//     call    = function "(" [ expr { "," expr } ] ")"
//     cond    = [ "!" ] expr [ ( "==" | "!=" ) literal ]
//     literal = string | number | "true" | "false" | "null"
//     string  = "'" … "'" | '"' … '"'      (with \' \" \\ escapes)
//
// Everything a reference can name, every helper and the arguments it
// takes are checked when the template is parsed, so that a template that
// parses can only fail on what the request brings.

///|
/// An expression, parsed.
priv enum Expr {
  /// A literal: a string, a number, true, false or null.
  Literal(Json)
  /// A reference to a request field, a listed environment variable,
  /// `loop.index` or a loop variable, with its source text.
  Ref(Root, Array[Step], String)
  /// A call of a helper, with its arguments.
  Call(Helper, Array[Expr])
  /// `a ?? b ?? …`: the first of them that is present.
  Fallback(Array[Expr])
}

///|
/// What a reference starts from.
priv enum Root {
  Method
  Path
  Query
  Header
  Body
  BodyText
  /// `env.NAME`: the value of a listed variable, read when the template was
  /// parsed, or `None` when it is unset.
  Env(Json?)
  LoopIndex
  /// A loop variable, by its name.
  Var(String)
}

///|
/// One step of a reference into a value.
priv enum Step {
  /// `.name` or `['name']`: a member of an object.
  Name(String)
  /// `[n]`: an element of an array, or a segment of the path.
  Index(Int)
}

///|
/// A helper, with the literal arguments it was checked to take.
priv enum Helper {
  Uuid
  Int(Int64, Int64)
  Decimal(Int64, Int64, Int)
  Bool
  Pick(Array[Json])
  Hex(Int)
  Word
  Words(Int)
  FirstName
  LastName
  Name
  Email
  /// `now(s)`: seconds to add.
  Now(Int64)
  /// `nowMillis(s)`: seconds to add.
  NowMillis(Int64)
  /// `number(x)`, which takes any expression.
  Number
  /// `range(a, b)`, whose arguments are integer literals or `number(…)`.
  Range
  /// `json(x)`: text templates only.
  JsonText
  /// `raw(x)`: text templates only.
  Raw
}

///|
/// The condition of `$if`: an expression, maybe compared with a literal,
/// maybe negated.
priv struct Cond {
  negated : Bool
  expr : Expr
  /// `== literal` (true) or `!= literal` (false).
  compare : (Bool, Json)?
}

///|
/// A problem found while parsing: the index of the character it is at, in
/// the template's text, and what it is.
priv suberror Syntax {
  Syntax(Int, String)
}

///|
/// The words an expression cannot use as a name.
let reserved : Array[String] = ["for", "if", "else", "end", "each", "params"]

///|
/// The names of request fields, `env` and `loop`, which a loop variable
/// cannot take.
let root_names : Array[String] = [
  "method", "path", "query", "header", "body", "bodyText", "env", "loop",
]

///|
/// The largest integer a helper takes, 2^53 - 1: a JSON number holds every
/// integer up to it exactly.
let max_integer : Int64 = 9_007_199_254_740_991L

///|
/// Parses expressions in `chars`, from `i` on.
priv struct Parser {
  chars : Array[Char]
  mut i : Int
  /// The loop variables in scope, innermost last.
  vars : Array[String]
  /// Whether the expression is inside a `$each`, where `loop.index` is.
  in_loop : Bool
  /// Whether `json()` and `raw()` are allowed: in text templates only.
  text : Bool
  /// The environment variables `env.NAME` may read.
  env : Env
}

///|
fn Parser::peek(self : Parser, offset? : Int = 0) -> Char? {
  let at = self.i + offset
  if at < self.chars.length() {
    Some(self.chars[at])
  } else {
    None
  }
}

///|
fn Parser::skip_space(self : Parser) -> Unit {
  while self.peek() is Some(' ' | '\t' | '\n' | '\r') {
    self.i += 1
  }
}

///|
/// Whether the text from `i` on starts with `s`, which it then skips.
fn Parser::eat(self : Parser, s : String) -> Bool {
  for k, c in s {
    if self.peek(offset=k) != Some(c) {
      return false
    }
  }
  self.i += s.length()
  true
}

///|
fn Parser::expect(
  self : Parser,
  s : String,
  what : String,
) -> Unit raise Syntax {
  self.skip_space()
  if !self.eat(s) {
    raise Syntax(self.i, "expected \{what}, found \{self.found()}")
  }
}

///|
/// What is at `i`, for a message.
fn Parser::found(self : Parser) -> String {
  match self.peek() {
    None => "the end"
    Some(c) => c.to_string().escape()
  }
}

///|
fn is_name_char(c : Char) -> Bool {
  c.is_ascii_alphabetic() || c.is_ascii_digit() || c == '_' || c == '-'
}

///|
fn is_name_start(c : Char) -> Bool {
  c.is_ascii_alphabetic() || c == '_'
}

///|
/// Whether `name` can be a loop variable or the name of a step: letters,
/// digits, `_` and `-`, starting with a letter or `_`.
fn is_identifier(name : String) -> Bool {
  name != "" &&
  is_name_start(name[0].unsafe_to_char()) &&
  name.iter().all(is_name_char)
}

///|
/// Reads a name: letters, digits, `_` and `-`.
fn Parser::name(self : Parser) -> String {
  let start = self.i
  while self.peek() is Some(c) && is_name_char(c) {
    self.i += 1
  }
  String::from_array(self.chars[start:self.i])
}

///|
/// Parses `expr`.
fn Parser::expr(self : Parser) -> Expr raise Syntax {
  let first = self.value()
  let alternatives = [first]
  for ;; {
    self.skip_space()
    if !self.eat("??") {
      break
    }
    alternatives.push(self.value())
  }
  if alternatives.length() == 1 {
    first
  } else {
    Fallback(alternatives)
  }
}

///|
/// Parses `cond`.
fn Parser::cond(self : Parser) -> Cond raise Syntax {
  self.skip_space()
  let negated = self.peek() == Some('!') && self.peek(offset=1) != Some('=')
  if negated {
    self.i += 1
  }
  let expr = self.expr()
  self.skip_space()
  let compare = if self.eat("==") {
    Some((true, self.literal_only("==")))
  } else if self.eat("!=") {
    Some((false, self.literal_only("!=")))
  } else {
    None
  }
  { negated, expr, compare, }
}

///|
/// Parses the literal after `==` or `!=`.
fn Parser::literal_only(self : Parser, operator : String) -> Json raise Syntax {
  self.skip_space()
  let at = self.i
  match self.value() {
    Literal(json) => json
    _ =>
      raise Syntax(
        at,
        "\{operator} compares with a literal: a string, a number, true, false or null",
      )
  }
}

///|
/// Parses `value`.
fn Parser::value(self : Parser) -> Expr raise Syntax {
  self.skip_space()
  let start = self.i
  match self.peek() {
    None => raise Syntax(start, "expected a value, found the end")
    Some('\'' | '"') => Literal(Json::string(self.string()))
    Some(c) if c == '-' || c.is_ascii_digit() => Literal(self.number())
    Some(c) if is_name_start(c) => self.named(start)
    Some('!') | Some('=') =>
      raise Syntax(
        start, "!, == and != are allowed only in the condition of $if",
      )
    Some(_) => raise Syntax(start, "expected a value, found \{self.found()}")
  }
}

///|
/// Parses a string literal.
fn Parser::string(self : Parser) -> String raise Syntax {
  let start = self.i
  guard self.peek() is Some(quote) else {
    raise Syntax(start, "expected a string")
  }
  self.i += 1
  let out = StringBuilder()
  for ;; {
    match self.peek() {
      None => raise Syntax(start, "the string is not closed")
      Some(c) if c == quote => {
        self.i += 1
        break
      }
      Some('\\') =>
        match self.peek(offset=1) {
          Some('\'' | '"' | '\\' as escaped) => {
            out.write_char(escaped)
            self.i += 2
          }
          _ =>
            raise Syntax(
              self.i,
              "a string has only the escapes \\', \\\" and \\\\",
            )
        }
      Some(c) => {
        out.write_char(c)
        self.i += 1
      }
    }
  }
  out.to_string()
}

///|
/// Parses a number literal, written as in JSON.
fn Parser::number(self : Parser) -> Json raise Syntax {
  let start = self.i
  let digits = () => {
    let from = self.i
    while self.peek() is Some(c) && c.is_ascii_digit() {
      self.i += 1
    }
    self.i > from
  }
  ignore(self.eat("-"))
  let int_start = self.i
  if !digits() {
    raise Syntax(start, "expected a number")
  }
  if self.chars[int_start] == '0' && self.i - int_start > 1 {
    raise Syntax(start, "a number has no leading zeros")
  }
  if self.eat(".") && !digits() {
    raise Syntax(start, "expected digits after the decimal point")
  }
  if self.peek() is Some('e' | 'E') {
    self.i += 1
    if self.peek() is Some('+' | '-') {
      self.i += 1
    }
    if !digits() {
      raise Syntax(start, "expected digits in the exponent")
    }
  }
  if self.peek() is Some(c) && is_name_char(c) {
    raise Syntax(self.i, "expected the number to end, found \{self.found()}")
  }
  let text = String::from_array(self.chars[start:self.i])
  @json.parse(text) catch {
    _ => raise Syntax(start, "not a number")
  }
}

///|
/// Parses what starts with a name: `true`, `false`, `null`, a reference or
/// a call.
fn Parser::named(self : Parser, start : Int) -> Expr raise Syntax {
  let first = self.name()
  match first {
    "true" => return Literal(Json::boolean(true))
    "false" => return Literal(Json::boolean(false))
    "null" => return Literal(Json::null())
    _ => ()
  }
  if reserved.contains(first) {
    raise Syntax(start, "\{first} is reserved")
  }
  // A dotted name followed by `(` is a call.
  let dotted = [first]
  let mut j = self.i
  while j < self.chars.length() && self.chars[j] == '.' {
    let mut k = j + 1
    while k < self.chars.length() && is_name_char(self.chars[k]) {
      k += 1
    }
    if k == j + 1 {
      break
    }
    dotted.push(String::from_array(self.chars[j + 1:k]))
    j = k
  }
  let mut after = j
  while after < self.chars.length() && self.chars[after] is (' ' | '\t') {
    after += 1
  }
  if after < self.chars.length() && self.chars[after] == '(' {
    self.i = after + 1
    return self.call(dotted.join("."), start)
  }
  self.reference(first, start)
}

///|
/// Parses the rest of a reference that starts with `root`.
fn Parser::reference(
  self : Parser,
  root : String,
  start : Int,
) -> Expr raise Syntax {
  let steps = []
  for ;; {
    if self.eat(".") {
      let at = self.i
      let name = self.name()
      if name == "" {
        raise Syntax(at, "expected a name after .")
      }
      steps.push(Step::Name(name))
    } else if self.peek() == Some('[') {
      self.i += 1
      self.skip_space()
      let at = self.i
      match self.peek() {
        Some('\'' | '"') => steps.push(Step::Name(self.string()))
        Some(c) if c.is_ascii_digit() => {
          let from = self.i
          while self.peek() is Some(c) && c.is_ascii_digit() {
            self.i += 1
          }
          let digits = String::from_array(self.chars[from:self.i])
          if digits.length() > 9 || (digits.length() > 1 && digits[0] == '0') {
            raise Syntax(at, "an index is an integer from 0 to 999999999")
          }
          let mut index = 0
          for d in digits {
            index = index * 10 + (d.to_int() - '0'.to_int())
          }
          steps.push(Step::Index(index))
        }
        _ =>
          raise Syntax(
            at,
            "expected an index or a quoted name in [ ], found \{self.found()}",
          )
      }
      self.expect("]", "]")
    } else {
      break
    }
  }
  let text = String::from_array(self.chars[start:self.i])
  let with_name = (root : Root) => {
    match steps {
      [Name(_)] => Ref(root, steps, text)
      _ =>
        raise Syntax(
          start,
          "\{text}: \{root_word(root)} takes exactly one name, such as \{root_word(root)}.x or \{root_word(root)}['x y']",
        )
    }
  }
  let alone = (root : Root) => {
    if steps.length() > 0 {
      raise Syntax(start, "\{text}: \{root_word(root)} has no parts to name")
    }
    Ref(root, steps, text)
  }
  if self.vars.contains(root) {
    return Ref(Var(root), steps, text)
  }
  match root {
    "method" => alone(Method)
    "bodyText" => alone(BodyText)
    "body" => Ref(Body, steps, text)
    "env" =>
      match steps {
        [Name(name)] =>
          match self.env.values.get(name) {
            Some(value) => Ref(Env(value.map(Json::string)), steps, text)
            None =>
              raise Syntax(
                start,
                "\{text}: the environment variable \{name.escape()} is not listed in --template-env",
              )
          }
        _ =>
          raise Syntax(
            start,
            "\{text}: env takes exactly one name, such as env.REGION",
          )
      }
    "query" => with_name(Query)
    "header" => with_name(Header)
    "path" =>
      match steps {
        [] | [Index(_)] => Ref(Path, steps, text)
        _ =>
          raise Syntax(
            start,
            "\{text}: path takes a segment number only, such as path[1]",
          )
      }
    "loop" => {
      if !self.in_loop {
        raise Syntax(start, "loop.index is only inside $each")
      }
      match steps {
        [Name("index")] => Ref(LoopIndex, steps, text)
        _ => raise Syntax(start, "\{text}: loop has only loop.index")
      }
    }
    _ =>
      raise Syntax(
        start,
        "unknown name \{root.escape()}: not a request field, a loop variable or a helper",
      )
  }
}

///|
/// How a root is written.
fn root_word(root : Root) -> String {
  match root {
    Method => "method"
    Path => "path"
    Query => "query"
    Header => "header"
    Body => "body"
    BodyText => "bodyText"
    Env(_) => "env"
    LoopIndex => "loop"
    Var(name) => name
  }
}

///|
/// Parses the arguments of a call of `name` and checks them: `start` is
/// where the call starts, and `i` is just after its `(`.
fn Parser::call(self : Parser, name : String, start : Int) -> Expr raise Syntax {
  let args : Array[(Int, Expr)] = []
  self.skip_space()
  if !self.eat(")") {
    for ;; {
      self.skip_space()
      let at = self.i
      args.push((at, self.expr()))
      self.skip_space()
      if self.eat(")") {
        break
      }
      self.expect(",", ", or )")
    }
  }
  let count = (expected : Int) => {
    if args.length() != expected {
      let what = match expected {
        0 => "no arguments"
        1 => "1 argument"
        n => "\{n} arguments"
      }
      raise Syntax(start, "\{name}() takes \{what}, not \{args.length()}")
    }
  }
  let integer = (k : Int, min : Int64, max : Int64) => {
    let (at, arg) = args[k]
    match arg {
      Literal(Number(n, ..)) if n == n.floor() &&
        n >= min.to_double() &&
        n <= max.to_double() => n.to_int64()
      _ =>
        raise Syntax(
          at,
          "\{name}(): argument \{k + 1} must be an integer literal from \{min} to \{max}",
        )
    }
  }
  let ordered = (min : Int64, max : Int64) => {
    if min > max {
      raise Syntax(
        start,
        "\{name}(): the minimum \{min} exceeds the maximum \{max}",
      )
    }
  }
  let seconds = () => {
    match args.length() {
      0 => 0L
      1 => integer(0, -max_integer, max_integer)
      n => raise Syntax(start, "\{name}() takes 0 or 1 argument, not \{n}")
    }
  }
  let helper : Helper = match name {
    "fake.uuid" => {
      count(0)
      Uuid
    }
    "fake.int" => {
      count(2)
      let min = integer(0, -max_integer, max_integer)
      let max = integer(1, -max_integer, max_integer)
      ordered(min, max)
      Int(min, max)
    }
    "fake.decimal" => {
      count(3)
      let bound = 1_000_000_000L
      let min = integer(0, -bound, bound)
      let max = integer(1, -bound, bound)
      let places = integer(2, 1L, 6L).to_int()
      ordered(min, max)
      Decimal(min, max, places)
    }
    "fake.bool" => {
      count(0)
      Bool
    }
    "fake.pick" => {
      if args.length() < 1 || args.length() > 100 {
        raise Syntax(
          start,
          "fake.pick() takes 1 to 100 literals, not \{args.length()}",
        )
      }
      Pick(
        args.map(arg => {
          match arg.1 {
            Literal(json) => json
            _ =>
              raise Syntax(
                arg.0,
                "fake.pick() takes literals: strings, numbers, true, false or null",
              )
          }
        }),
      )
    }
    "fake.hex" => {
      count(1)
      Hex(integer(0, 1L, 64L).to_int())
    }
    "fake.word" => {
      count(0)
      Word
    }
    "fake.words" => {
      count(1)
      Words(integer(0, 1L, 100L).to_int())
    }
    "fake.firstName" => {
      count(0)
      FirstName
    }
    "fake.lastName" => {
      count(0)
      LastName
    }
    "fake.name" => {
      count(0)
      Name
    }
    "fake.email" => {
      count(0)
      Email
    }
    "now" => Now(seconds())
    "nowMillis" => NowMillis(seconds())
    "number" => {
      count(1)
      Number
    }
    "range" => {
      count(2)
      for arg in args {
        if !is_range_bound(arg.1) {
          raise Syntax(
            arg.0,
            "range() takes integers: integer literals, or number(…) of a request value",
          )
        }
      }
      match (args[0].1, args[1].1) {
        (Literal(_), Literal(_)) => {
          let a = integer(0, -max_integer, max_integer)
          let b = integer(1, -max_integer, max_integer)
          if b - a + 1L > max_range.to_int64() {
            raise Syntax(
              start,
              "range(\{a}, \{b}) gives \{b - a + 1L} values; range gives at most \{max_range}",
            )
          }
        }
        _ => ()
      }
      Range
    }
    "json" | "raw" => {
      if !self.text {
        raise Syntax(
          start,
          "\{name}() is for text templates; in json, smock writes and escapes every value itself",
        )
      }
      count(1)
      if name == "json" {
        JsonText
      } else {
        Raw
      }
    }
    _ =>
      raise Syntax(
        start,
        "unknown helper \{name.escape()}: not one of the helpers smock has",
      )
  }
  Call(helper, args.map(arg => arg.1))
}

///|
/// The most values `range` gives.
let max_range : Int = 1000

///|
/// Whether `expr` can bound a range: an integer literal, `number(…)`, or a
/// fallback of those.
fn is_range_bound(expr : Expr) -> Bool {
  match expr {
    Literal(Number(n, ..)) => n == n.floor()
    Call(Number, _) => true
    Fallback(alternatives) => alternatives.iter().all(is_range_bound)
    _ => false
  }
}

///|
/// The values of a literal `range(a, b)`, if `expr` is one.
fn literal_range(expr : Expr) -> Int? {
  match expr {
    Call(Range, [Literal(Number(a, ..)), Literal(Number(b, ..))]) => {
      let count = b - a + 1.0
      Some(if count < 0.0 { 0 } else { count.to_int() })
    }
    _ => None
  }
}
