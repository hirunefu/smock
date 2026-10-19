///|
/// Reads a document from its bytes, one construct at a time. It checks the
/// whole input, and keeps of it only where each element's name starts and
/// how deep the element is: the document reads everything else from the
/// input again when a path selects it.
priv struct Parser {
  input : BytesView
  /// The byte offset of the next byte to read.
  mut pos : Int
  /// Where the qualified name of each attribute of the start tag being read
  /// starts, in order.
  attribute_starts : Array[Int]
  /// Where each of them ends, in the same order.
  attribute_ends : Array[Int]
  /// Where the local name of each element read so far starts, in document
  /// order: the order of their start tags.
  names : Array[Int]
  /// How deep each of them is, less one: 0 for the root element.
  depths : Array[Byte]
  /// Where the start tag of each open element begins, the root element's
  /// first: the elements whose end tags are not read yet.
  open_tags : Array[Int]
  /// Where the qualified name of each open element starts, which its end
  /// tag repeats.
  open_name_starts : Array[Int]
  /// Where each of those names ends.
  open_name_ends : Array[Int]
}

///|
fn Parser::new(input : BytesView) -> Parser {
  {
    input,
    pos: 0,
    attribute_starts: [],
    attribute_ends: [],
    names: [],
    depths: [],
    open_tags: [],
    open_name_starts: [],
    open_name_ends: [],
  }
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
/// Reads the whole document.
fn Parser::document(self : Parser) -> Unit raise ParseError {
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
  self.root()
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
  self.skip_name()
  if self.is_xml(at, self.pos) {
    if self.looking_back(at, b"xml") {
      fail_at(start, "the XML declaration must come first")
    }
    fail_at(
      at,
      "processing instruction target \{self.text(at, self.pos)} is reserved",
    )
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
/// Reads a CDATA section that begins at the next byte, `<![CDATA[`
/// (XML 1.0 §2.7).
fn Parser::cdata(self : Parser) -> Unit raise ParseError {
  let start = self.pos
  self.pos += 9
  while !self.looking_at(b"]]>") {
    match self.peek() {
      -1 => fail_at(start, "a CDATA section is not closed")
      '\r' => self.line_end()
      _ => self.char() |> ignore
    }
  }
  self.pos += 3
}

///|
/// Reads the root element, which starts at the next byte, with everything
/// in it. Open elements are kept on a stack rather than in recursive calls.
fn Parser::root(self : Parser) -> Unit raise ParseError {
  self.start_tag()
  while self.open_tags.length() > 0 {
    let top = self.open_tags.length() - 1
    match self.peek() {
      -1 => {
        let name = self.text(
          self.open_name_starts[top],
          self.open_name_ends[top],
        )
        fail_at(self.open_tags[top], "element \{name} is not closed")
      }
      '<' =>
        if self.looking_at(b"<!--") {
          self.comment()
        } else if self.looking_at(b"<![CDATA[") {
          self.cdata()
        } else if self.looking_at(b"<!DOCTYPE") {
          fail_at(self.pos, doctype_message)
        } else if self.looking_at(b"<!") {
          fail_at(self.pos, "expected a comment or a CDATA section after <!")
        } else if self.looking_at(b"<?") {
          self.processing_instruction()
        } else if self.looking_at(b"</") {
          self.end_tag()
        } else {
          if self.open_tags.length() == max_depth {
            fail_at(self.pos, "elements nest deeper than \{max_depth}")
          }
          self.start_tag()
        }
      ']' if self.looking_at(b"]]>") =>
        fail_at(self.pos, "]]> is not allowed in text")
      '&' => self.reference()
      '\r' => self.line_end()
      _ => self.char() |> ignore
    }
  }
}

///|
/// Reads a start tag or an empty-element tag that begins at the next byte,
/// and keeps where the element's local name starts and how deep it is. The
/// element of a start tag is open until its end tag; that of an
/// empty-element tag is closed.
fn Parser::start_tag(self : Parser) -> Unit raise ParseError {
  let start = self.pos
  self.pos += 1
  let name_start = self.pos
  self.qualified_name()
  let name_end = self.pos
  self.names.push(local_start(self.input, name_start, name_end))
  self.depths.push(self.open_tags.length().to_byte())
  self.attribute_starts.clear()
  self.attribute_ends.clear()
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
        self.qualified_name()
        self.attribute_starts.push(at)
        self.attribute_ends.push(self.pos)
        self.equals()
        self.attribute_value()
      }
      _ => fail_at(self.pos, "expected whitespace, > or />")
    }
  }
  self.unique()
  if !empty {
    self.open_tags.push(start)
    self.open_name_starts.push(name_start)
    self.open_name_ends.push(name_end)
  }
}

///|
/// Raises an error when a name repeats among the attribute names of the
/// start tag just read (XML 1.0 §3.1, WFC: Unique Att Spec). The error is
/// at the first repetition. A tag with many attributes is checked by
/// sorting rather than with a hash set, so that no set of names makes it
/// slow; a tag with a few, as most have, is checked in place, with no
/// allocation.
fn Parser::unique(self : Parser) -> Unit raise ParseError {
  let starts = self.attribute_starts
  let ends = self.attribute_ends
  let n = starts.length()
  if n <= 8 {
    for j in 1..<n {
      for i in 0..<j {
        if self.input[starts[i]:ends[i]] == self.input[starts[j]:ends[j]] {
          fail_at(
            starts[j],
            "attribute \{self.text(starts[j], ends[j])} is repeated",
          )
        }
      }
    }
    return
  }
  let sorted = Array(capacity=n)
  for i in 0..<n {
    sorted.push((self.input[starts[i]:ends[i]], starts[i]))
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
    let at = sorted[first].1
    fail_at(
      at,
      "attribute \{self.text(at, at + sorted[first].0.length())} is repeated",
    )
  }
}

///|
/// Reads the end tag of the innermost open element, which begins at the
/// next byte, `</`, and closes the element.
fn Parser::end_tag(self : Parser) -> Unit raise ParseError {
  let start = self.pos
  self.pos += 2
  let name_start = self.pos
  self.skip_name()
  let top = self.open_tags.length() - 1
  let open_start = self.open_name_starts[top]
  let open_end = self.open_name_ends[top]
  if self.input[name_start:self.pos] != self.input[open_start:open_end] {
    fail_at(
      start,
      "end tag </\{self.text(name_start, self.pos)}> does not match start tag <\{self.text(open_start, open_end)}>",
    )
  }
  self.skip_space() |> ignore
  if self.peek() != '>' {
    fail_at(self.pos, "expected >")
  }
  self.pos += 1
  self.open_tags.pop() |> ignore
  self.open_name_starts.pop() |> ignore
  self.open_name_ends.pop() |> ignore
}

///|
/// Reads a quoted attribute value (XML 1.0 §3.1 [10]). Selection
/// normalises it when a path selects it.
fn Parser::attribute_value(self : Parser) -> Unit raise ParseError {
  let quote = self.peek()
  if quote != '"' && quote != '\'' {
    fail_at(self.pos, "expected a quoted attribute value")
  }
  let start = self.pos
  self.pos += 1
  while self.peek() != quote {
    match self.peek() {
      -1 => fail_at(start, "an attribute value is not closed")
      '<' =>
        fail_at(self.pos, "< is not allowed in an attribute value; write &lt;")
      '\r' => self.line_end()
      '&' => self.reference()
      _ => self.char() |> ignore
    }
  }
  self.pos += 1
}

///|
/// Reads a reference that begins at the next byte, `&`: a character
/// reference (`&#N;` or `&#xH;`), or one of the five predefined entities.
/// With no DTD, no other entity is declared (XML 1.0 §4.1, WFC: Entity
/// Declared).
fn Parser::reference(self : Parser) -> Unit raise ParseError {
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
    return
  }
  if !(self.pos < self.input.length() &&
    is_name_start(code_point(decode(self.input, self.pos)))) {
    fail_at(start, "& starts a reference; write &amp; for &")
  }
  let name = self.pos
  self.skip_name()
  let end = self.pos
  self.semicolon()
  if predefined_entity(self.input[name:end]) < 0 {
    fail_at(start, "entity &\{self.text(name, end)}; is not declared")
  }
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
/// Reads the name of an element or an attribute that begins at the next
/// byte: a local name, or a prefix, a colon and a local name (Namespaces in
/// XML 1.0 §4 [7]).
fn Parser::qualified_name(self : Parser) -> Unit raise ParseError {
  let start = self.pos
  self.skip_name()
  let end = self.pos
  let colon = find_colon(self.input, start, end)
  if colon == start {
    fail_at(start, "name \{self.text(start, end)} has an empty prefix")
  }
  if colon == end - 1 {
    fail_at(start, "name \{self.text(start, end)} has an empty local name")
  }
  if colon >= 0 && find_colon(self.input, colon + 1, end) >= 0 {
    fail_at(start, "name \{self.text(start, end)} has more than one colon")
  }
}

///|
/// Reads a name (XML 1.0 §2.3 [5]) that begins at the next byte.
fn Parser::skip_name(self : Parser) -> Unit raise ParseError {
  let start = self.pos
  while self.pos < self.input.length() {
    let decoded = decode(self.input, self.pos)
    if decoded < 0 {
      fail_at(self.pos, not_utf8_message)
    }
    let c = code_point(decoded)
    if !(if self.pos == start { is_name_start(c) } else { is_name_char(c) }) {
      break
    }
    self.pos += byte_length(decoded)
  }
  if self.pos == start {
    fail_at(start, "expected a name")
  }
}

///|
/// Whether the input from byte `start` to byte `end` is `xml` in any case,
/// which processing instruction targets may not be.
fn Parser::is_xml(self : Parser, start : Int, end : Int) -> Bool {
  // A letter's lower case is its upper case with the bit 0x20 set.
  end - start == 3 &&
  (self.input[start].to_int() | 0x20) == 'x' &&
  (self.input[start + 1].to_int() | 0x20) == 'm' &&
  (self.input[start + 2].to_int() | 0x20) == 'l'
}

///|
/// Whether the input from byte `start` is `literal`, which is ASCII.
fn Parser::looking_back(self : Parser, start : Int, literal : Bytes) -> Bool {
  self.input[start:start + literal.length()] == literal[:]
}

///|
/// The input from byte `start` to byte `end`, which are well-formed UTF-8,
/// as a string: a name, for an error message.
fn Parser::text(self : Parser, start : Int, end : Int) -> String {
  let text = StringBuilder()
  let mut i = start
  while i < end {
    let decoded = decode(self.input, i)
    text.write_char(code_point(decoded).unsafe_to_char())
    i += byte_length(decoded)
  }
  text.to_string()
}
