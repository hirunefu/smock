///|
/// Reads a document from its bytes, one construct at a time.
priv struct Parser {
  input : BytesView
  /// The byte offset of the next byte to read.
  mut pos : Int
  /// The qualified names of the attributes of the start tag being read.
  names : Array[String]
  /// Where each of `names` starts, in the same order.
  offsets : Array[Int]
}

///|
/// An element whose end tag is not read yet.
priv struct Open {
  /// The qualified name, which the end tag repeats.
  qname : String
  /// Where its start tag begins.
  start : Int
  element : Element
  /// Whether it is an empty-element tag, which has no end tag.
  empty : Bool
}

///|
/// How deep elements may nest, the root element being at depth 1. A deeper
/// document is refused, so that selection, which recurses into elements,
/// stays within a bounded stack.
let max_depth = 256

///|
/// Why a document with a DOCTYPE is refused. A DTD could declare entities,
/// whose expansion can read files or exhaust memory, so none is read.
let doctype_message = "a DOCTYPE is not allowed"

///|
/// Why bytes are refused that are not well-formed UTF-8.
let not_utf8_message = "the input is not UTF-8"

///|
/// Raises a `ParseError` at byte offset `position`.
fn[T] fail_at(position : Int, message : String) -> T raise ParseError {
  raise ParseError(position~, message~)
}

///|
/// The next byte as an `Int`, or -1 at the end of the input.
fn Parser::peek(self : Parser) -> Int {
  if self.pos < self.input.length() {
    self.input[self.pos].to_int()
  } else {
    -1
  }
}

///|
/// Reads the character at the next byte and returns its code point.
/// Raises an error when the bytes there are not well-formed UTF-8, or not
/// a character XML allows (XML 1.0 §2.2).
fn Parser::char(self : Parser) -> Int raise ParseError {
  let decoded = decode(self.input, self.pos)
  if decoded < 0 {
    fail_at(self.pos, not_utf8_message)
  }
  let c = code_point(decoded)
  let length = byte_length(decoded)
  if !is_char(c) {
    let hex = c.to_string(radix=16).to_upper().pad_start(4, '0')
    fail_at(self.pos, "U+\{hex} is not a character XML allows")
  }
  self.pos += length
  c
}

///|
/// Whether the input continues with `literal`, which is ASCII.
fn Parser::looking_at(self : Parser, literal : Bytes) -> Bool {
  if self.pos + literal.length() > self.input.length() {
    return false
  }
  for i in 0..<literal.length() {
    if self.input[self.pos + i] != literal[i] {
      return false
    }
  }
  true
}

///|
/// Reads the whole document and returns its root element.
fn Parser::document(self : Parser) -> Element raise ParseError {
  if self.looking_at(b"\xEF\xBB\xBF") {
    self.pos += 3
  }
  if self.looking_at(b"<?xml") &&
    self.pos + 5 < self.input.length() &&
    (
      is_space(self.input[self.pos + 5].to_int()) ||
      self.input[self.pos + 5] == b'?'
    ) {
    self.declaration()
  }
  self.misc()
  if self.looking_at(b"<!DOCTYPE") {
    fail_at(self.pos, doctype_message)
  }
  match self.peek() {
    '<' => ()
    -1 => fail_at(self.pos, "no root element")
    _ => {
      let start = self.pos
      self.char() |> ignore
      fail_at(start, "text is not allowed before the root element")
    }
  }
  let root = self.root()
  self.misc()
  if self.peek() >= 0 {
    let start = self.pos
    if self.peek() != '<' {
      self.char() |> ignore
    }
    fail_at(
      start, "only comments, processing instructions and whitespace may follow the root element",
    )
  }
  root
}

///|
/// Reads the XML declaration, which begins at the next byte, `<?xml`
/// (XML 1.0 §2.8 [23]-[26], §4.3.3 [80]-[81], §2.9 [32]).
fn Parser::declaration(self : Parser) -> Unit raise ParseError {
  self.pos += 5
  self.skip_space() |> ignore
  if !self.looking_at(b"version") {
    fail_at(self.pos, "expected version in the XML declaration")
  }
  self.pos += 7
  self.equals()
  let at = self.pos + 1
  let version = self.quoted()
  // A 1.0 processor reads any version 1.x as 1.0 (XML 1.0 §2.8 [26]).
  guard version.strip_prefix("1.") is Some(minor) &&
    minor != "" &&
    is_digits(minor) else {
    fail_at(at, "XML version \{version} is not supported")
  }
  let mut spaced = self.skip_space()
  if spaced && self.looking_at(b"encoding") {
    self.pos += 8
    self.equals()
    let at = self.pos + 1
    let encoding = self.quoted()
    // Encoding names are compared case-insensitively (XML 1.0 §4.3.3).
    if encoding.to_lower() != "utf-8" {
      fail_at(
        at,
        "encoding \{encoding} is not supported; the input must be UTF-8",
      )
    }
    spaced = self.skip_space()
  }
  if spaced && self.looking_at(b"standalone") {
    self.pos += 10
    self.equals()
    let at = self.pos + 1
    let standalone = self.quoted()
    if standalone != "yes" && standalone != "no" {
      fail_at(at, "standalone must be yes or no")
    }
    self.skip_space() |> ignore
  }
  if !self.looking_at(b"?>") {
    fail_at(self.pos, "expected ?> to end the XML declaration")
  }
  self.pos += 2
}

///|
/// Reads `=` with optional whitespace around it (XML 1.0 §2.3 [25]).
fn Parser::equals(self : Parser) -> Unit raise ParseError {
  self.skip_space() |> ignore
  if self.peek() != '=' {
    fail_at(self.pos, "expected =")
  }
  self.pos += 1
  self.skip_space() |> ignore
}

///|
/// Whether `text` is all ASCII digits.
fn is_digits(text : StringView) -> Bool {
  for c in text {
    if !(c is ('0'..='9')) {
      return false
    }
  }
  true
}

///|
/// Reads a value of the XML declaration, in single or double quotes, and
/// returns it. The value starts one byte after where it is read from.
fn Parser::quoted(self : Parser) -> String raise ParseError {
  let quote = self.peek()
  if quote != '"' && quote != '\'' {
    fail_at(self.pos, "expected a quoted value")
  }
  let open = self.pos
  self.pos += 1
  let value = StringBuilder()
  while self.peek() != quote {
    if self.peek() < 0 {
      fail_at(open, "a quoted value is not closed")
    }
    value.write_char(self.char().unsafe_to_char())
  }
  self.pos += 1
  value.to_string()
}

///|
/// Skips what may come before and after the root element: whitespace,
/// comments and processing instructions (XML 1.0 §2.8 [27]).
fn Parser::misc(self : Parser) -> Unit raise ParseError {
  while true {
    self.skip_space() |> ignore
    if self.looking_at(b"<!--") {
      self.comment()
    } else if self.looking_at(b"<?") {
      self.processing_instruction()
    } else {
      break
    }
  }
}

///|
/// Skips a comment that begins at the next byte, `<!--`. A comment holds
/// no `--` but the one that ends it (XML 1.0 §2.5).
fn Parser::comment(self : Parser) -> Unit raise ParseError {
  let start = self.pos
  self.pos += 4
  while true {
    match self.peek() {
      -1 => fail_at(start, "a comment is not closed")
      '-' if self.looking_at(b"--") => {
        if !self.looking_at(b"-->") {
          fail_at(self.pos, "-- is not allowed in a comment")
        }
        self.pos += 3
        break
      }
      _ => self.char() |> ignore
    }
  }
}

///|
/// Skips a processing instruction that begins at the next byte, `<?`
/// (XML 1.0 §2.6). Its target may not be `xml` in any case: that is
/// reserved, and only the XML declaration, at the very start, is `<?xml`.
fn Parser::processing_instruction(self : Parser) -> Unit raise ParseError {
  let start = self.pos
  self.pos += 2
  let at = self.pos
  let target = self.name()
  if target.to_lower() == "xml" {
    if target == "xml" {
      fail_at(start, "the XML declaration must come first")
    }
    fail_at(at, "processing instruction target \{target} is reserved")
  }
  if !self.skip_space() && !self.looking_at(b"?>") {
    fail_at(self.pos, "expected whitespace or ?>")
  }
  while !self.looking_at(b"?>") {
    if self.peek() < 0 {
      fail_at(start, "a processing instruction is not closed")
    }
    self.char() |> ignore
  }
  self.pos += 2
}

///|
/// Reads a CDATA section that begins at the next byte, `<![CDATA[`, and
/// writes its text to `out`, with line ends as line feeds (XML 1.0 §2.7).
fn Parser::cdata(self : Parser, out : StringBuilder) -> Unit raise ParseError {
  let start = self.pos
  self.pos += 9
  while !self.looking_at(b"]]>") {
    match self.peek() {
      -1 => fail_at(start, "a CDATA section is not closed")
      '\r' => {
        self.line_end()
        out.write_char('\n')
      }
      _ => out.write_char(self.char().unsafe_to_char())
    }
  }
  self.pos += 3
}

///|
/// Reads the root element, which starts at the next byte, with everything
/// in it. Open elements are kept on a stack rather than in recursive calls.
fn Parser::root(self : Parser) -> Element raise ParseError {
  let stack : Array[Open] = []
  let text = StringBuilder()
  let root = self.start_tag()
  if !root.empty {
    stack.push(root)
  }
  while stack.last() is Some(open) {
    match self.peek() {
      -1 => fail_at(open.start, "element \{open.qname} is not closed")
      '<' =>
        if self.looking_at(b"<!--") {
          self.comment()
        } else if self.looking_at(b"<![CDATA[") {
          self.cdata(text)
        } else if self.looking_at(b"<!DOCTYPE") {
          fail_at(self.pos, doctype_message)
        } else if self.looking_at(b"<!") {
          fail_at(self.pos, "expected a comment or a CDATA section after <!")
        } else if self.looking_at(b"<?") {
          self.processing_instruction()
        } else {
          if !text.is_empty() {
            open.element.children.push(Text(text.to_string()))
            text.reset()
          }
          if self.looking_at(b"</") {
            self.end_tag(open)
            stack.pop() |> ignore
          } else {
            if stack.length() == max_depth {
              fail_at(self.pos, "elements nest deeper than \{max_depth}")
            }
            let child = self.start_tag()
            open.element.children.push(Child(child.element))
            if !child.empty {
              stack.push(child)
            }
          }
        }
      ']' if self.looking_at(b"]]>") =>
        fail_at(self.pos, "]]> is not allowed in text")
      '&' => self.reference(text)
      '\r' => {
        self.line_end()
        text.write_char('\n')
      }
      _ => text.write_char(self.char().unsafe_to_char())
    }
  }
  root.element
}

///|
/// Reads a start tag or an empty-element tag that begins at the next byte.
/// The element of an empty-element tag is closed: `Open::empty` is true.
fn Parser::start_tag(self : Parser) -> Open raise ParseError {
  let start = self.pos
  self.pos += 1
  let qname = self.qualified_name()
  let element = { name: local_name(qname), attributes: [], children: [], }
  self.names.clear()
  self.offsets.clear()
  let mut empty = false
  while true {
    let spaced = self.skip_space()
    match self.peek() {
      '>' => {
        self.pos += 1
        break
      }
      '/' if self.looking_at(b"/>") => {
        self.pos += 2
        empty = true
        break
      }
      _ if spaced => {
        let at = self.pos
        let name = self.qualified_name()
        self.names.push(name)
        self.offsets.push(at)
        self.equals()
        let value = self.attribute_value()
        // Namespace declarations are not attributes for selection.
        if name != "xmlns" && !name.has_prefix("xmlns:") {
          element.attributes.push({ name: local_name(name), value, })
        }
      }
      _ => fail_at(self.pos, "expected whitespace, > or />")
    }
  }
  unique(self.names, self.offsets)
  { qname, start, element, empty, }
}

///|
/// Raises an error when a name repeats among `names`, the attribute names
/// of a tag, which start at `offsets` (XML 1.0 §3.1, WFC: Unique Att
/// Spec). The error is at the first repetition. A tag with many attributes
/// is checked by sorting rather than with a hash set, so that no set of
/// names makes it slow; a tag with a few, as most have, is checked in
/// place, with no allocation.
fn unique(names : Array[String], offsets : Array[Int]) -> Unit raise ParseError {
  let n = names.length()
  if n <= 8 {
    for j in 1..<n {
      for i in 0..<j {
        if names[i] == names[j] {
          fail_at(offsets[j], "attribute \{names[j]} is repeated")
        }
      }
    }
    return
  }
  let sorted = Array(capacity=n)
  for i in 0..<n {
    sorted.push((names[i], offsets[i]))
  }
  sorted.sort()
  let mut first = -1
  for i in 1..<n {
    if sorted[i].0 == sorted[i - 1].0 &&
      (first < 0 || sorted[i].1 < sorted[first].1) {
      first = i
    }
  }
  if first >= 0 {
    fail_at(sorted[first].1, "attribute \{sorted[first].0} is repeated")
  }
}

///|
/// Reads the end tag of `open`, which begins at the next byte, `</`.
fn Parser::end_tag(self : Parser, open : Open) -> Unit raise ParseError {
  let start = self.pos
  self.pos += 2
  let qname = self.name()
  if qname != open.qname {
    fail_at(
      start,
      "end tag </\{qname}> does not match start tag <\{open.qname}>",
    )
  }
  self.skip_space() |> ignore
  if self.peek() != '>' {
    fail_at(self.pos, "expected >")
  }
  self.pos += 1
}

///|
/// Reads a quoted attribute value and normalises it (XML 1.0 §3.3.3): each
/// whitespace character becomes a space, and a line end (CR LF) becomes one
/// space.
fn Parser::attribute_value(self : Parser) -> String raise ParseError {
  let quote = self.peek()
  if quote != '"' && quote != '\'' {
    fail_at(self.pos, "expected a quoted attribute value")
  }
  let start = self.pos
  self.pos += 1
  let value = StringBuilder()
  while self.peek() != quote {
    match self.peek() {
      -1 => fail_at(start, "an attribute value is not closed")
      '<' =>
        fail_at(self.pos, "< is not allowed in an attribute value; write &lt;")
      '\r' => {
        self.line_end()
        value.write_char(' ')
      }
      '\t' | '\n' => {
        self.pos += 1
        value.write_char(' ')
      }
      '&' => self.reference(value)
      _ => value.write_char(self.char().unsafe_to_char())
    }
  }
  self.pos += 1
  value.to_string()
}

///|
/// Reads a reference that begins at the next byte, `&`, and writes the
/// character it stands for to `out`: a character reference (`&#N;` or
/// `&#xH;`), or one of the five predefined entities. With no DTD, no other
/// entity is declared (XML 1.0 §4.1, WFC: Entity Declared).
fn Parser::reference(
  self : Parser,
  out : StringBuilder,
) -> Unit raise ParseError {
  let start = self.pos
  self.pos += 1
  if self.peek() == '#' {
    self.pos += 1
    let hex = self.peek() == 'x'
    if hex {
      self.pos += 1
    }
    let digits = self.pos
    let mut code = 0
    while true {
      let digit = match self.peek() {
        '0'..='9' as b => b - '0'
        'a'..='f' as b if hex => b - 'a' + 10
        'A'..='F' as b if hex => b - 'A' + 10
        _ => break
      }
      // Past U+10FFFF, the value no longer matters: it is not a character.
      code = @cmp.minimum(code * (if hex { 16 } else { 10 }) + digit, 0x110000)
      self.pos += 1
    }
    if self.pos == digits {
      fail_at(
        self.pos,
        if hex {
          "expected a hexadecimal digit"
        } else {
          "expected a decimal digit"
        },
      )
    }
    self.semicolon()
    if !is_char(code) {
      fail_at(
        start,
        "\{self.ascii(start, self.pos)} is not a character XML allows",
      )
    }
    out.write_char(code.unsafe_to_char())
    return
  }
  if !(self.pos < self.input.length() &&
    is_name_start(code_point(decode(self.input, self.pos)))) {
    fail_at(start, "& starts a reference; write &amp; for &")
  }
  let name = self.name()
  self.semicolon()
  let c = match name {
    "lt" => '<'
    "gt" => '>'
    "amp" => '&'
    "apos" => '\''
    "quot" => '"'
    _ => fail_at(start, "entity &\{name}; is not declared")
  }
  out.write_char(c)
}

///|
/// Reads the `;` that ends a reference.
fn Parser::semicolon(self : Parser) -> Unit raise ParseError {
  if self.peek() != ';' {
    fail_at(self.pos, "expected ; to end the reference")
  }
  self.pos += 1
}

///|
/// The input from byte `start` to byte `end`, which are ASCII.
fn Parser::ascii(self : Parser, start : Int, end : Int) -> String {
  let text = StringBuilder()
  for i in start..<end {
    text.write_char(self.input[i].to_int().unsafe_to_char())
  }
  text.to_string()
}

///|
/// Skips a line end that begins at the next byte, a carriage return: CR LF
/// or a lone CR. Parsed text has a line feed in its place (XML 1.0 §2.11).
fn Parser::line_end(self : Parser) -> Unit {
  self.pos += 1
  if self.peek() == '\n' {
    self.pos += 1
  }
}

///|
/// Skips whitespace, and returns whether there was any.
fn Parser::skip_space(self : Parser) -> Bool {
  let start = self.pos
  while is_space(self.peek()) {
    self.pos += 1
  }
  self.pos > start
}

///|
/// The local name of a qualified name: the part after the colon, if there
/// is one (Namespaces in XML 1.0 §4).
fn local_name(qname : String) -> String {
  match qname.find(":") {
    Some(i) => qname[i + 1:].to_owned()
    None => qname
  }
}

///|
/// Reads the name of an element or an attribute: a local name, or a
/// prefix, a colon and a local name (Namespaces in XML 1.0 §4 [7]).
fn Parser::qualified_name(self : Parser) -> String raise ParseError {
  let start = self.pos
  let name = self.name()
  match name.find(":") {
    Some(0) => fail_at(start, "name \{name} has an empty prefix")
    Some(i) if i == name.length() - 1 =>
      fail_at(start, "name \{name} has an empty local name")
    Some(i) if name[i + 1:].contains(":") =>
      fail_at(start, "name \{name} has more than one colon")
    _ => name
  }
}

///|
/// Reads a name (XML 1.0 §2.3 [5]) that begins at the next byte.
fn Parser::name(self : Parser) -> String raise ParseError {
  let start = self.pos
  let name = StringBuilder()
  while self.pos < self.input.length() {
    let decoded = decode(self.input, self.pos)
    if decoded < 0 {
      fail_at(self.pos, not_utf8_message)
    }
    let c = code_point(decoded)
    if !(if self.pos == start { is_name_start(c) } else { is_name_char(c) }) {
      break
    }
    name.write_char(c.unsafe_to_char())
    self.pos += byte_length(decoded)
  }
  if self.pos == start {
    fail_at(start, "expected a name")
  }
  name.to_string()
}
