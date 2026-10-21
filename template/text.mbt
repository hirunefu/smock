// Text templates: a header value, a body, or a field of a Server-Sent
// Event. `${ expr }` inserts a value, written as text, and `$${` writes a
// literal `${`. Text templates have no loops and no conditionals.

///|
/// A problem in a template, found when it is parsed: a JSON Pointer to the
/// field it is in, within the Stub, and a message that starts with
/// `template:`. In a text template of several lines, the message gives the
/// line and the column (from 1) of the problem, and in a one-line string
/// its column.
pub(all) struct Problem {
  pointer : String
  message : String
} derive(Debug, Eq)

///|
/// What a text template is for: how its values are written, and what
/// becomes of its output.
pub(all) enum TextKind {
  /// A body, `body` or `bodyFile`: values are escaped as `Escaping` says,
  /// and the output counts toward the bound of a rendered body.
  Body(Escaping)
  /// A header value: after rendering, every control character except tab
  /// becomes a space, so that no value can put a line break into the head.
  HeaderValue
  /// The `data` of a Server-Sent Event, written as rendered. It counts
  /// toward the bound of all events together.
  EventData
  /// The `id` or `event` of a Server-Sent Event: after rendering, every
  /// control character becomes a space. It counts toward the bound of all
  /// events together.
  EventLine
} derive(Debug, Eq)

///|
/// How the values inserted into a text body are escaped, by the media type
/// of the response's `Content-Type`.
pub(all) enum Escaping {
  /// Not at all.
  Plain
  /// As the content of a JSON string, for `application/json` and
  /// `*/*+json`.
  JsonString
  /// `&`, `<`, `>`, `"` and `'` as character references, for `text/html`,
  /// `text/xml`, `application/xml` and `*/*+xml`.
  Markup
} derive(Debug, Eq)

///|
/// How values inserted into a text body are escaped for the response's
/// `Content-Type`, `content_type`, if it has one: by its media type,
/// compared case-insensitively, with its parameters ignored.
pub fn escaping_for(content_type : String?) -> Escaping {
  guard content_type is Some(value) else { return Plain }
  let media_type = match value.find(";") {
    Some(i) => value[:i]
    None => value[:]
  }
  let media_type = media_type.trim(chars=" \t").to_owned().to_lower()
  guard media_type.find("/") is Some(slash) else { return Plain }
  let subtype = media_type[slash + 1:]
  if media_type == "application/json" || subtype.has_suffix("+json") {
    JsonString
  } else if media_type is ("text/html" | "text/xml" | "application/xml") ||
    subtype.has_suffix("+xml") {
    Markup
  } else {
    Plain
  }
}

///|
/// One part of a text template.
priv enum Part {
  /// Text written as it is.
  Verbatim(String)
  /// `${ expr }`.
  Insert(Expr)
}

///|
/// A text template, parsed.
pub struct Text {
  /// The template as written.
  source : String
  /// The JSON Pointer to the field, within the Stub.
  pointer : String
  kind : TextKind
  priv parts : Array[Part]
  /// Whether an expression of the template reads the `vars` root.
  priv vars_read : Bool
}

///|
/// Text templates are equal when they are written the same, for the same
/// field and kind.
pub impl Eq for Text with fn equal(self, other) {
  self.source == other.source &&
  self.pointer == other.pointer &&
  self.kind == other.kind
}

///|
/// Shows the template as it is written.
pub impl Debug for Text with fn to_repr(self) {
  Repr::ctor("Text", [(None, Repr::string(self.source))])
}

///|
/// Whether the template reads Variables: whether one of its expressions
/// reads the `vars` root, wherever it is. One that does not renders the
/// same whatever Variables it is given.
pub fn Text::reads_vars(self : Text) -> Bool {
  self.vars_read
}

///|
/// Whether the text template inserts no value: it is literal text.
pub fn Text::is_literal(self : Text) -> Bool {
  self.parts.iter().all(part => part is Verbatim(_))
}

///|
/// Parses `source` as a text template of the kind `kind`, for the field at
/// `pointer`, within the Stub. `env` holds the environment variables it may
/// read, and `buckets` the Data buckets; by default, none.
pub fn Text::parse(
  source : String,
  pointer~ : String,
  kind~ : TextKind,
  env? : Env = no_env,
  buckets? : Buckets = no_buckets,
) -> Result[Text, Problem] {
  let chars = source.iter().collect()
  let scope = {
    vars: [],
    in_loop: false,
    text: true,
    env,
    buckets,
    reads_vars: Ref(false),
  }
  try parse_parts(chars, scope) catch {
    Syntax(at, message) =>
      Err({ pointer, message: "template: \{position(chars, at)}\{message}", })
  } noraise {
    parts =>
      Ok({ source, pointer, kind, parts, vars_read: scope.reads_vars.val, })
  }
}

///|
/// Where the character at `at` is in `chars`: `line L, column C: ` when the
/// text has several lines, otherwise `column C: `.
fn position(chars : Array[Char], at : Int) -> String {
  let mut line = 1
  let mut column = 1
  let mut lines = 1
  for i, c in chars {
    if c == '\n' {
      lines += 1
      if i < at {
        line += 1
        column = 1
      }
    } else if i < at {
      column += 1
    }
  }
  if lines > 1 {
    "line \{line}, column \{column}: "
  } else {
    "column \{column}: "
  }
}

///|
/// Parses the parts of a template, `chars`: literal text and `${ expr }`,
/// whose expressions can name what `scope` holds.
fn parse_parts(chars : Array[Char], scope : Scope) -> Array[Part] raise Syntax {
  let parts = []
  let literal = StringBuilder()
  let parser = { chars, i: 0, scope, }
  while parser.i < chars.length() {
    if parser.eat("$${") {
      literal.write_string("${")
      continue
    }
    let start = parser.i
    if !parser.eat("${") {
      literal.write_char(chars[start])
      parser.i += 1
      continue
    }
    if literal.to_string() != "" {
      parts.push(Verbatim(literal.to_string()))
      literal.reset()
    }
    parser.skip_space()
    match parser.peek() {
      None => raise Syntax(start, "the ${ is not closed")
      Some('}') => raise Syntax(start, "the ${ } is empty")
      Some(_) => ()
    }
    let expr = parser.expr()
    parser.skip_space()
    match parser.peek() {
      Some('}') => parser.i += 1
      Some('=') | Some('!') if parser.peek(offset=1) == Some('=') =>
        raise Syntax(
          parser.i,
          "== and != are allowed only in the condition of $if",
        )
      None => raise Syntax(start, "the ${ is not closed")
      Some(_) =>
        raise Syntax(
          parser.i,
          "expected } to end the ${, found \{parser.found()}",
        )
    }
    parts.push(Insert(expr))
  }
  if literal.to_string() != "" {
    parts.push(Verbatim(literal.to_string()))
  }
  parts
}

///|
/// Renders the template for the request of `context`.
///
/// Raises `RenderError` when a value it inserts is missing, a value is of
/// a type it cannot write, or a bound is exceeded.
pub fn Text::render(self : Text, context : Context) -> String raise RenderError {
  let out = StringBuilder()
  let counted = !(self.kind is HeaderValue)
  let escaping = match self.kind {
    Body(escaping) => escaping
    _ => Plain
  }
  for part in self.parts {
    let piece = match part {
      Verbatim(text) => text
      Insert(expr) => {
        let value = context.value(expr, [], self.pointer)
        written(value, escaping, self.pointer)
      }
    }
    let piece = match self.kind {
      HeaderValue => without_controls(piece, keep_tab=true)
      EventLine => without_controls(piece, keep_tab=false)
      _ => piece
    }
    if counted {
      context.count(utf8_length(piece), self.pointer)
    }
    out.write_string(piece)
  }
  out.to_string()
}

///|
/// `value` as a text template writes it, escaped as `escaping` says.
fn written(
  value : Value,
  escaping : Escaping,
  at : String,
) -> String raise RenderError {
  match value.form {
    RawText => as_text(value.json, at, text=true)
    JsonOutput =>
      match escaping {
        Markup => markup_escaped(as_text(value.json, at, text=true))
        _ => as_text(value.json, at, text=true)
      }
    Ordinary =>
      match escaping {
        Plain => as_text(value.json, at, text=true)
        JsonString => json_escaped(as_text(value.json, at, text=true))
        Markup => markup_escaped(as_text(value.json, at, text=true))
      }
  }
}

///|
/// `value` written as text: a string as it is, a number as under
/// "Numbers", and `true`, `false` and `null` as those words. An object or
/// an array cannot be written as text.
fn as_text(value : Json, at : String, text~ : Bool) -> String raise RenderError {
  match value {
    String(s) => s
    Number(n, repr~) => number_text(n, repr)
    True => "true"
    False => "false"
    Null => "null"
    Object(_) | Array(_) => {
      let hint = if text {
        "; write it with json(…)"
      } else {
        "; give the value alone in its string to keep it"
      }
      raise RenderError(
        at~,
        message="an object or an array cannot be written as text\{hint}",
      )
    }
  }
}

///|
/// `s` with every control character, except tab when `keep_tab`, as a
/// space.
fn without_controls(s : String, keep_tab~ : Bool) -> String {
  let control = (c : Char) => {
    (c < ' ' && !(keep_tab && c == '\t')) || c == '\u{7f}'
  }
  if !s.iter().any(control) {
    return s
  }
  let out = StringBuilder()
  for c in s {
    out.write_char(if control(c) { ' ' } else { c })
  }
  out.to_string()
}

///|
/// `s` escaped as the content of a JSON string.
fn json_escaped(s : String) -> String {
  let out = StringBuilder()
  write_json_string_content(out, s)
  out.to_string()
}

///|
/// `s` with `&`, `<`, `>`, `"` and `'` as character references.
fn markup_escaped(s : String) -> String {
  if !s.contains_any(chars="&<>\"'") {
    return s
  }
  let out = StringBuilder()
  for c in s {
    match c {
      '&' => out.write_string("&amp;")
      '<' => out.write_string("&lt;")
      '>' => out.write_string("&gt;")
      '"' => out.write_string("&quot;")
      '\'' => out.write_string("&#39;")
      _ => out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// The length of `s` in UTF-8, in bytes.
fn utf8_length(s : StringView) -> Int {
  let mut n = 0
  for c in s {
    n += char_utf8_length(c)
  }
  n
}

///|
/// The length of `c` in UTF-8, in bytes.
fn char_utf8_length(c : Char) -> Int {
  let code = c.to_int()
  if code < 0x80 {
    1
  } else if code < 0x800 {
    2
  } else if code < 0x10000 {
    3
  } else {
    4
  }
}
