///|
/// A recursive-descent parser over the characters of one document.
///
/// Block-level functions leave the parser at the first character of the
/// next line that has content, or at the end of the input. The column of
/// that character is the line's indentation.
priv struct Parser {
  chars : Array[Char]
  mut pos : Int
  /// Where the line `pos` is on starts.
  mut line_start : Int
  /// The JSON Pointer of the deepest node reached so far, which syntax
  /// errors name.
  mut reached : String
  /// How many collections enclose the parser's position.
  mut depth : Int
}

///|
/// How deeply collections may nest: as deeply as `@json.parse` allows by
/// default, so that every accepted document has a JSON equivalent.
const MAX_DEPTH : Int = 1024

///|
/// Enters a collection. Its parser leaves it with `self.depth -= 1`.
fn Parser::enter(self : Parser) -> Unit raise ParseError {
  self.depth += 1
  if self.depth > MAX_DEPTH {
    self.fail("nesting is deeper than \{MAX_DEPTH} levels")
  }
}

///|
/// Stands for the end of the input. The input never contains it: control
/// characters are rejected before parsing.
const EOF : Char = '\u{0}'

///|
fn Parser::new(text : StringView) -> Parser {
  let chars = []
  let mut previous = EOF
  for c in text {
    // Line breaks become `\n`; a byte order mark may start the text.
    match c {
      '\r' => chars.push('\n')
      '\n' if previous == '\r' => ()
      '\u{FEFF}' if chars.length() == 0 && previous == EOF => ()
      _ => chars.push(c)
    }
    previous = c
  }
  { chars, pos: 0, line_start: 0, reached: "", depth: 0, }
}

///|
/// What an empty value, which YAML reads as null, is rejected with.
const EMPTY_VALUE : String = "empty value: write null, or \"\" for an empty string"

///|
/// Rejects characters YAML does not allow, and line breaks that only
/// YAML 1.1 reads as line breaks.
fn Parser::check_characters(self : Parser) -> Unit raise ParseError {
  for c in self.chars {
    let code = c.to_int()
    let problem = if code == 0x85 || code == 0x2028 || code == 0x2029 {
      Some("is a line break in YAML 1.1 only")
    } else if (code < 0x20 && !(c is ('\t' | '\n'))) ||
      (code >= 0x7F && code <= 0x9F) ||
      code == 0xFFFE ||
      code == 0xFFFF {
      Some("is a control character")
    } else {
      None
    }
    if problem is Some(problem) {
      let hex = code.to_string(radix=16).to_upper()
      let padded = "0".repeat(4 - hex.length()) + hex
      self.fail(
        "U+\{padded} \{problem}; write it as an escape in a double-quoted value",
        pointer="",
      )
    }
  }
}

///|
fn Parser::peek(self : Parser, offset? : Int = 0) -> Char {
  let i = self.pos + offset
  if i < self.chars.length() {
    self.chars[i]
  } else {
    EOF
  }
}

///|
fn Parser::bump(self : Parser) -> Unit {
  if self.chars[self.pos] == '\n' {
    self.line_start = self.pos + 1
  }
  self.pos += 1
}

///|
fn Parser::column(self : Parser) -> Int {
  self.pos - self.line_start
}

///|
fn Parser::at_eof(self : Parser) -> Bool {
  self.pos >= self.chars.length()
}

///|
/// Fails at the deepest node reached, or at `pointer`.
fn[T] Parser::fail(
  self : Parser,
  message : String,
  pointer? : String,
) -> T raise ParseError {
  raise ParseError(pointer=pointer.unwrap_or(self.reached), message~)
}

///|
fn Parser::skip_space(self : Parser) -> Unit {
  while self.peek() is (' ' | '\t') {
    self.bump()
  }
}

///|
fn Parser::skip_comment(self : Parser) -> Unit {
  if self.peek() == '#' {
    while !(self.peek() is ('\n' | EOF)) {
      self.bump()
    }
  }
}

///|
/// Skips blank and comment lines from the start of a line. Returns whether
/// a line with content follows; the parser is then at its first character.
fn Parser::from_line_start(self : Parser) -> Bool raise ParseError {
  for ;; {
    while self.peek() == ' ' {
      self.bump()
    }
    if self.peek() == '\t' {
      self.skip_space()
      if !(self.peek() is ('\n' | '#' | EOF)) {
        self.fail("tabs are not allowed in indentation")
      }
    }
    self.skip_comment()
    if self.at_eof() {
      return false
    }
    if self.peek() != '\n' {
      return true
    }
    self.bump()
  }
}

///|
/// Skips the rest of the current line, which may hold only white space and
/// a comment, then blank and comment lines. Returns whether a line with
/// content follows.
fn Parser::next_content(self : Parser) -> Bool raise ParseError {
  self.skip_space()
  self.skip_comment()
  match self.peek() {
    EOF => false
    '\n' => {
      self.bump()
      self.from_line_start()
    }
    _ => self.fail("unexpected text after the value")
  }
}

///|
fn Parser::document(self : Parser) -> Json raise ParseError {
  self.check_characters()
  let mut content = self.from_line_start()
  if content && self.column() == 0 && self.peek() == '%' {
    self.fail("directives (%) are not supported", pointer="")
  }
  let mut inline = false
  if content && self.at_marker('-') {
    self.pos += 3
    self.skip_space()
    if self.peek() is ('\n' | '#' | EOF) {
      content = self.next_content()
    } else {
      inline = true
    }
  }
  if !content || self.at_marker('.') {
    self.fail("the document is empty", pointer="")
  }
  let root = self.block_node(-1, "", inline~)
  if self.at_marker('.') {
    self.pos += 3
    if self.next_content() {
      self.fail("multiple documents are not supported", pointer="")
    }
  } else if self.at_marker('-') {
    self.fail("multiple documents are not supported", pointer="")
  } else if !self.at_eof() {
    self.fail("unexpected content; check the indentation")
  }
  root
}

///|
/// Whether the parser is at a `---` (`c` is `-`) or `...` (`c` is `.`)
/// document marker.
fn Parser::at_marker(self : Parser, c : Char) -> Bool {
  self.column() == 0 && self.peek() == c && self.document_marker_at(self.pos)
}

///|
/// Parses the node at the current position, which has content. `parent` is
/// the indentation of the enclosing block collection (-1 at the top).
/// An `inline` node shares its line with a key or `---`, so it cannot be a
/// block collection.
fn Parser::block_node(
  self : Parser,
  parent : Int,
  pointer : String,
  inline? : Bool = false,
) -> Json raise ParseError {
  self.reached = pointer
  let column = self.column()
  if self.at_sequence_item() {
    if inline {
      self.fail("a block sequence must start on its own line")
    }
    return self.block_sequence(column, pointer)
  }
  if self.peek() is ('|' | '>') {
    return self.block_scalar(parent)
  }
  if self.peek() is ('[' | '{') {
    let value = self.flow_node(parent, pointer)
    self.skip_space()
    if self.at_key_indicator() {
      self.fail("a key must be a plain or quoted scalar")
    }
    let _ = self.next_content()
    return value
  }
  self.check_node_start(flow=false)
  let scalar = self.scalar(parent)
  self.skip_space()
  if self.at_key_indicator() {
    if inline {
      self.fail(
        "unexpected ':' after a value; a nested mapping must start on its own line",
      )
    }
    return self.block_mapping(column, pointer, scalar)
  }
  let _ = self.next_content()
  if scalar.quoted {
    Json::string(scalar.text)
  } else {
    self.plain_value(scalar.text)
  }
}

///|
/// Rejects what cannot start a scalar here: anchors, aliases, tags and
/// other indicators.
fn Parser::check_node_start(
  self : Parser,
  flow~ : Bool,
) -> Unit raise ParseError {
  let c = self.peek()
  let next = self.peek(offset=1)
  let separated = is_blank_or_eof(next) || (flow && is_flow_indicator(next))
  match c {
    '&' =>
      self.fail("anchors (&) are not supported; quote the value if it is text")
    '*' =>
      self.fail("aliases (*) are not supported; quote the value if it is text")
    '!' =>
      self.fail("tags (!) are not supported; quote the value if it is text")
    '?' if separated => self.fail("explicit keys (?) are not supported")
    ':' if separated => self.fail("a key must not be empty")
    '-' if separated =>
      self.fail("a block sequence cannot be inside a flow collection")
    ',' | '[' | ']' | '{' | '}' | '#' | '|' | '>' | '%' | '@' | '`' =>
      self.fail("a plain value cannot start with \{c}; quote this value")
    _ => ()
  }
}

///|
/// The JSON Pointer to the member `key` of the mapping at `pointer`, which
/// holds `map` so far. Rejects merge keys, duplicate keys and plain keys
/// that are not strings in every YAML version.
fn Parser::key_pointer(
  self : Parser,
  map : Map[String, Json],
  pointer : String,
  key : Scalar,
) -> String raise ParseError {
  let key_pointer = child(pointer, key.text)
  let problem = if key.multiline {
    Some("a key must be on a single line")
  } else if !key.quoted && key.text == "<<" {
    Some("merge keys (<<) are not supported")
  } else if map.contains(key.text) {
    Some("duplicate key")
  } else if key.quoted {
    None
  } else {
    let quoted = key.text.escape()
    match resolve(key.text) {
      Value(String(_)) => None
      Ambiguous(kind) =>
        Some("\{quoted} may be read as \{kind}; quote this key")
      Value(Number(_)) => Some("\{quoted} is read as a number; quote this key")
      Value(Null) => Some("\{quoted} is read as null; quote this key")
      Value(_) => Some("\{quoted} is read as a boolean; quote this key")
    }
  }
  if problem is Some(message) {
    self.fail(message, pointer=key_pointer)
  }
  key_pointer
}

///|
/// The value of a plain scalar. Rejects one that is not a string in every
/// YAML version and is not typed here.
fn Parser::plain_value(self : Parser, text : String) -> Json raise ParseError {
  match resolve(text) {
    Value(value) => value
    Ambiguous(kind) =>
      self.fail("\{text.escape()} may be read as \{kind}; quote this value")
  }
}

///|
/// Whether the parser is at the `:` that ends a key in a block mapping.
fn Parser::at_key_indicator(self : Parser) -> Bool {
  self.peek() == ':' && is_blank_or_eof(self.peek(offset=1))
}

///|
/// A scalar as written: plain or quoted.
priv struct Scalar {
  text : String
  quoted : Bool
  /// Whether it spans more than one line.
  multiline : Bool
}

///|
/// Scans the scalar at the current position. Its continuation lines must
/// be indented more than `parent`.
fn Parser::scalar(self : Parser, parent : Int) -> Scalar raise ParseError {
  if self.peek() is ('"' | '\'') {
    let (text, multiline) = self.quoted(parent)
    { text, quoted: true, multiline, }
  } else {
    let (text, multiline) = self.plain(parent)
    { text, quoted: false, multiline, }
  }
}

///|
/// Scans a quoted scalar from its opening quote.
fn Parser::quoted(
  self : Parser,
  parent : Int,
) -> (String, Bool) raise ParseError {
  let quote = self.peek()
  let double = quote == '"'
  let what = if double { "double-quoted" } else { "single-quoted" }
  self.bump()
  let out = StringBuilder()
  let mut multiline = false
  // Where the white space just scanned starts. It is part of the text
  // unless a line break follows it.
  let mut blank_start = -1
  for ;; {
    let c = self.peek()
    match c {
      EOF => self.fail("unterminated \{what} value")
      ' ' | '\t' => {
        if blank_start < 0 {
          blank_start = self.pos
        }
        self.bump()
        continue
      }
      '\n' => {
        blank_start = -1
        multiline = true
        let breaks = self.next_quoted_line(parent, what)
        if breaks == 0 {
          out.write_char(' ')
        } else {
          for _ in 0..<breaks {
            out.write_char('\n')
          }
        }
        continue
      }
      _ => ()
    }
    if blank_start >= 0 {
      for i in blank_start..<self.pos {
        out.write_char(self.chars[i])
      }
      blank_start = -1
    }
    if c == quote {
      self.bump()
      if double || self.peek() != '\'' {
        break
      }
      out.write_char('\'')
      self.bump()
    } else if double && c == '\\' {
      self.bump()
      if self.peek() == '\n' {
        // An escaped line break joins the lines without a space.
        multiline = true
        for _ in 0..<self.next_quoted_line(parent, what) {
          out.write_char('\n')
        }
      } else {
        self.escape(out)
      }
    } else {
      out.write_char(c)
      self.bump()
    }
  }
  (out.to_string(), multiline)
}

///|
/// Moves from a line break inside a quoted scalar to the text on the next
/// line that has any, past its leading white space. Returns how many empty
/// lines were skipped.
fn Parser::next_quoted_line(
  self : Parser,
  parent : Int,
  what : String,
) -> Int raise ParseError {
  let mut empty = 0
  for ;; {
    self.bump()
    let mut spaces = 0
    while self.peek() == ' ' {
      self.bump()
      spaces += 1
    }
    let at_line_start = self.pos == self.line_start
    self.skip_space()
    match self.peek() {
      '\n' => empty += 1
      EOF => self.fail("unterminated \{what} value")
      _ => {
        if spaces <= parent ||
          (at_line_start && self.document_marker_at(self.pos)) {
          self.fail("unterminated \{what} value")
        }
        return empty
      }
    }
  }
}

///|
/// Whether a `---` or `...` document marker starts at `i`.
fn Parser::document_marker_at(self : Parser, i : Int) -> Bool {
  let chars = self.chars
  i + 3 <= chars.length() &&
  (chars[i] == '-' || chars[i] == '.') &&
  chars[i + 1] == chars[i] &&
  chars[i + 2] == chars[i] &&
  (i + 3 == chars.length() || is_blank_or_eof(chars[i + 3]))
}

///|
/// Reads the escape sequence after a `\` in a double-quoted scalar.
fn Parser::escape(self : Parser, out : StringBuilder) -> Unit raise ParseError {
  let c = self.peek()
  let simple = match c {
    '0' => Some('\u{0}')
    'a' => Some('\u{7}')
    'b' => Some('\u{8}')
    't' | '\t' => Some('\t')
    'n' => Some('\n')
    'v' => Some('\u{b}')
    'f' => Some('\u{c}')
    'r' => Some('\r')
    'e' => Some('\u{1b}')
    ' ' => Some(' ')
    '"' => Some('"')
    '/' => Some('/')
    '\\' => Some('\\')
    'N' => Some('\u{85}')
    '_' => Some('\u{a0}')
    'L' => Some('\u{2028}')
    'P' => Some('\u{2029}')
    _ => None
  }
  if simple is Some(ch) {
    out.write_char(ch)
    self.bump()
    return
  }
  let digits = match c {
    'x' => 2
    'u' => 4
    'U' => 8
    EOF => self.fail("unterminated double-quoted value")
    _ => self.fail("invalid escape \\\{c}")
  }
  self.bump()
  let mut code = self.hex(digits)
  if code >= 0xD800 && code <= 0xDBFF && c == 'u' {
    // A surrogate pair, as JSON writes characters beyond U+FFFF.
    if !(self.peek() == '\\' && self.peek(offset=1) == 'u') {
      self.fail(
        "invalid escape: a high surrogate must be followed by a low surrogate",
      )
    }
    self.bump()
    self.bump()
    let low = self.hex(4)
    if low < 0xDC00 || low > 0xDFFF {
      self.fail(
        "invalid escape: a high surrogate must be followed by a low surrogate",
      )
    }
    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
  }
  match code.to_char() {
    Some(ch) => out.write_char(ch)
    None => self.fail("invalid escape: not a Unicode character")
  }
}

///|
/// Reads `n` hexadecimal digits.
fn Parser::hex(self : Parser, n : Int) -> Int raise ParseError {
  let mut value = 0
  for _ in 0..<n {
    let c = self.peek()
    let digit = match c {
      '0'..='9' => c.to_int() - '0'.to_int()
      'a'..='f' => c.to_int() - 'a'.to_int() + 10
      'A'..='F' => c.to_int() - 'A'.to_int() + 10
      _ => self.fail("invalid escape: expected a hexadecimal digit")
    }
    value = value * 16 + digit
    self.bump()
  }
  value
}

///|
/// Parses a `|` (literal) or `>` (folded) block scalar from its header.
/// Its lines must be indented more than `parent`.
fn Parser::block_scalar(self : Parser, parent : Int) -> Json raise ParseError {
  let folded = self.peek() == '>'
  self.bump()
  // Chomping: Some(false) strips the final line breaks, Some(true) keeps
  // them all, None keeps one.
  let keep = match self.peek() {
    '-' => {
      self.bump()
      Some(false)
    }
    '+' => {
      self.bump()
      Some(true)
    }
    _ => None
  }
  if self.peek() is ('0'..='9') {
    self.fail("block scalar indentation indicators are not supported")
  }
  if !is_blank_or_eof(self.peek()) {
    self.fail("invalid block scalar header")
  }
  self.skip_space()
  self.skip_comment()
  let out = StringBuilder()
  // The indentation of the content, once its first line is seen.
  let mut indent = -1
  // The most spaces on an empty line before the first line.
  let mut leading_spaces = 0
  let mut empty = 0
  let mut read_content = false
  let mut more_indented = false
  // Whether the last content line ends with a line break.
  let mut terminated = false
  while self.peek() == '\n' {
    self.bump()
    let line_start = self.pos
    if self.document_marker_at(line_start) {
      self.pos = line_start
      break
    }
    let mut spaces = 0
    while self.peek() == ' ' && (indent < 0 || spaces < indent) {
      self.bump()
      spaces += 1
    }
    if indent < 0 || spaces < indent {
      // Fewer spaces than the content: an empty line, or the end.
      let blank_end = self.pos
      self.skip_space()
      if self.peek() == '\n' {
        empty += 1
        if indent < 0 && spaces > leading_spaces {
          leading_spaces = spaces
        }
        continue
      }
      if self.at_eof() {
        break
      }
      self.pos = blank_end
      if indent >= 0 || spaces <= parent {
        self.pos = line_start
        break
      }
      // YAML versions disagree on what such a line means.
      if leading_spaces > spaces {
        self.fail(
          "a leading empty line of a block scalar has more spaces than its first line",
        )
      }
      indent = spaces
    }
    if self.peek() == '\n' {
      empty += 1
      continue
    }
    if self.at_eof() {
      break
    }
    let breaks = if !folded {
      if read_content {
        empty + 1
      } else {
        empty
      }
    } else if self.peek() is (' ' | '\t') {
      more_indented = true
      if read_content {
        empty + 1
      } else {
        empty
      }
    } else if more_indented {
      more_indented = false
      empty + 1
    } else if empty == 0 && read_content {
      out.write_char(' ')
      0
    } else {
      empty
    }
    for _ in 0..<breaks {
      out.write_char('\n')
    }
    read_content = true
    empty = 0
    while !(self.peek() is ('\n' | EOF)) {
      out.write_char(self.peek())
      self.bump()
    }
    terminated = self.peek() == '\n'
  }
  let final_breaks = match keep {
    Some(false) => 0
    None => if read_content && terminated { 1 } else { 0 }
    Some(true) => (if read_content && terminated { 1 } else { 0 }) + empty
  }
  for _ in 0..<final_breaks {
    out.write_char('\n')
  }
  // The parser is at the start of the line after the scalar.
  let _ = self.from_line_start()
  Json::string(out.to_string())
}

///|
/// Whether the parser is at the `-` that starts a block sequence item.
fn Parser::at_sequence_item(self : Parser) -> Bool {
  self.peek() == '-' && is_blank_or_eof(self.peek(offset=1))
}

///|
/// Parses a block sequence whose `-` indicators are at `column`.
fn Parser::block_sequence(
  self : Parser,
  column : Int,
  pointer : String,
) -> Json raise ParseError {
  self.enter()
  let items = []
  for ;; {
    let item_pointer = child(pointer, items.length().to_string())
    self.reached = item_pointer
    self.bump()
    self.skip_space()
    self.skip_comment()
    if self.peek() is ('\n' | EOF) {
      if !(self.next_content() && self.column() > column) {
        self.fail(EMPTY_VALUE, pointer=item_pointer)
      }
    }
    items.push(self.block_node(column, item_pointer))
    if !self.continues_block(column) || !self.at_sequence_item() {
      break
    }
  }
  self.depth -= 1
  Json::array(items)
}

///|
/// After a block collection's entry, whether the line the parser is at
/// continues the collection at `column`.
fn Parser::continues_block(
  self : Parser,
  column : Int,
) -> Bool raise ParseError {
  if self.at_eof() ||
    self.column() < column ||
    self.at_marker('-') ||
    self.at_marker('.') {
    return false
  }
  if self.column() > column {
    self.fail("bad indentation")
  }
  true
}

///|
/// Parses a block mapping whose keys are at `column`, starting at the ':'
/// after its first key.
fn Parser::block_mapping(
  self : Parser,
  column : Int,
  pointer : String,
  first_key : Scalar,
) -> Json raise ParseError {
  self.enter()
  let map : Map[String, Json] = Map([])
  let mut key = first_key
  for ;; {
    let key_pointer = self.key_pointer(map, pointer, key)
    self.bump()
    self.reached = key_pointer
    map[key.text] = self.mapping_value(column, key_pointer)
    if !self.continues_block(column) {
      break
    }
    if self.at_sequence_item() {
      self.fail("expected a key, found a sequence item; check the indentation")
    }
    if self.peek() is ('[' | '{') {
      self.fail("a key must be a plain or quoted scalar")
    }
    self.check_node_start(flow=false)
    key = self.scalar(column)
    self.skip_space()
    if !self.at_key_indicator() {
      self.fail("expected a key followed by ':'")
    }
  }
  self.depth -= 1
  Json::object(map)
}

///|
/// Parses the value after the ':' of a key of a block mapping at `column`.
fn Parser::mapping_value(
  self : Parser,
  column : Int,
  pointer : String,
) -> Json raise ParseError {
  self.skip_space()
  self.skip_comment()
  if self.peek() is ('\n' | EOF) {
    if self.next_content() {
      if self.column() > column {
        return self.block_node(column, pointer)
      }
      // A sequence may sit at the indentation of its key.
      if self.column() == column && self.at_sequence_item() {
        return self.block_sequence(column, pointer)
      }
    }
    self.fail(EMPTY_VALUE, pointer~)
  }
  self.block_node(column, pointer, inline=true)
}

///|
/// Scans a plain scalar. It continues on following lines indented more
/// than `parent`, folded: one line break becomes a space, each empty line a
/// `\n`. Returns its text and whether it spans lines.
fn Parser::plain(
  self : Parser,
  parent : Int,
  flow? : Bool = false,
) -> (String, Bool) {
  let out = StringBuilder()
  let mut multiline = false
  self.plain_line(out, flow~)
  for ;; {
    // The parser is after the last character of the scalar so far.
    let (pos, line_start) = (self.pos, self.line_start)
    self.skip_space()
    let mut empty = 0
    let continues = self.peek() == '\n' &&
      (for ;; {
        self.bump()
        let mut spaces = 0
        while self.peek() == ' ' {
          self.bump()
          spaces += 1
        }
        let at_line_start = self.pos == self.line_start
        self.skip_space()
        match self.peek() {
          '\n' => empty += 1
          EOF | '#' => break false
          c =>
            break spaces > parent &&
              !(at_line_start && self.document_marker_at(self.pos)) &&
              !(flow && is_flow_indicator(c))
        }
      })
    if !continues {
      self.pos = pos
      self.line_start = line_start
      break
    }
    multiline = true
    if empty == 0 {
      out.write_char(' ')
    } else {
      for _ in 0..<empty {
        out.write_char('\n')
      }
    }
    self.plain_line(out, flow~)
  }
  (out.to_string(), multiline)
}

///|
/// Scans the part of a plain scalar on the current line. In a flow
/// collection, flow indicators also end it.
fn Parser::plain_line(self : Parser, out : StringBuilder, flow~ : Bool) -> Unit {
  for ;; {
    let c = self.peek()
    if c is ('\n' | EOF) || (flow && is_flow_indicator(c)) {
      break
    }
    if c is (' ' | '\t') {
      let mut end = self.pos
      while end < self.chars.length() && self.chars[end] is (' ' | '\t') {
        end += 1
      }
      let next = if end < self.chars.length() { self.chars[end] } else { EOF }
      if next is ('\n' | '#' | EOF) ||
        (flow && is_flow_indicator(next)) ||
        (next == ':' && self.colon_ends_plain(end + 1, flow~)) {
        break
      }
      for i in self.pos..<end {
        out.write_char(self.chars[i])
      }
      self.pos = end
      continue
    }
    if c == ':' && self.colon_ends_plain(self.pos + 1, flow~) {
      break
    }
    out.write_char(c)
    self.pos += 1
  }
}

///|
/// Whether a ':' followed by the character at `i` ends a plain scalar.
fn Parser::colon_ends_plain(self : Parser, i : Int, flow~ : Bool) -> Bool {
  i >= self.chars.length() ||
  is_blank_or_eof(self.chars[i]) ||
  (flow && is_flow_indicator(self.chars[i]))
}

///|
fn is_flow_indicator(c : Char) -> Bool {
  c is (',' | '[' | ']' | '{' | '}')
}

///|
/// Parses the node at the current position inside a flow collection.
/// `parent` is the indentation of the enclosing block collection.
fn Parser::flow_node(
  self : Parser,
  parent : Int,
  pointer : String,
) -> Json raise ParseError {
  self.reached = pointer
  match self.peek() {
    '[' => self.flow_sequence(parent, pointer)
    '{' => self.flow_mapping(parent, pointer)
    '"' | '\'' => Json::string(self.quoted(parent).0)
    _ => {
      self.check_node_start(flow=true)
      self.plain_value(self.plain(parent, flow=true).0)
    }
  }
}

///|
/// Skips white space, line breaks and comments inside a flow collection.
/// Lines with content must be indented more than `parent`, unless they
/// start by closing a collection.
fn Parser::skip_flow_space(
  self : Parser,
  parent : Int,
  what : String,
) -> Unit raise ParseError {
  for ;; {
    self.skip_space()
    self.skip_comment()
    match self.peek() {
      EOF => self.fail("unterminated \{what}")
      '\n' => {
        self.bump()
        let mut spaces = 0
        while self.peek() == ' ' {
          self.bump()
          spaces += 1
        }
        let at_line_start = self.pos == self.line_start
        self.skip_space()
        match self.peek() {
          '\n' | '#' | EOF | ']' | '}' => ()
          _ =>
            if spaces <= parent ||
              (at_line_start && self.document_marker_at(self.pos)) {
              self.fail("unterminated \{what}")
            }
        }
      }
      _ => return
    }
  }
}

///|
/// Parses a flow sequence from its `[`.
fn Parser::flow_sequence(
  self : Parser,
  parent : Int,
  pointer : String,
) -> Json raise ParseError {
  let what = "flow sequence"
  self.enter()
  self.bump()
  let items = []
  for ;; {
    self.skip_flow_space(parent, what)
    if self.peek() == ']' {
      self.bump()
      break
    }
    let item_pointer = child(pointer, items.length().to_string())
    if self.peek() == ',' {
      self.fail("expected a value before ','", pointer=item_pointer)
    }
    items.push(self.flow_node(parent, item_pointer))
    self.skip_flow_space(parent, what)
    match self.peek() {
      ',' => self.bump()
      ']' => {
        self.bump()
        break
      }
      ':' => self.fail("a key: value pair in a flow sequence needs braces")
      _ => self.fail("expected , or ] in a flow sequence")
    }
  }
  self.depth -= 1
  Json::array(items)
}

///|
/// Parses a flow mapping from its `{`.
fn Parser::flow_mapping(
  self : Parser,
  parent : Int,
  pointer : String,
) -> Json raise ParseError {
  let what = "flow mapping"
  self.enter()
  self.bump()
  let map : Map[String, Json] = Map([])
  for ;; {
    self.skip_flow_space(parent, what)
    if self.peek() == '}' {
      self.bump()
      break
    }
    if self.peek() is ('[' | '{') {
      self.fail("a key must be a plain or quoted scalar")
    }
    if self.peek() == ',' {
      self.fail("expected a key before ','")
    }
    let key : Scalar = if self.peek() is ('"' | '\'') {
      let (text, multiline) = self.quoted(parent)
      { text, quoted: true, multiline, }
    } else {
      self.check_node_start(flow=true)
      let (text, multiline) = self.plain(parent, flow=true)
      { text, quoted: false, multiline, }
    }
    let key_pointer = self.key_pointer(map, pointer, key)
    self.reached = key_pointer
    self.skip_flow_space(parent, what)
    if self.peek() != ':' {
      if self.peek() is (',' | '}') {
        self.fail(EMPTY_VALUE)
      }
      self.fail("expected ':' after a key")
    }
    self.bump()
    self.skip_flow_space(parent, what)
    if self.peek() is (',' | '}') {
      self.fail(EMPTY_VALUE)
    }
    map[key.text] = self.flow_node(parent, key_pointer)
    self.skip_flow_space(parent, what)
    match self.peek() {
      ',' => self.bump()
      '}' => {
        self.bump()
        break
      }
      _ => self.fail("expected , or } in a flow mapping")
    }
  }
  self.depth -= 1
  Json::object(map)
}

///|
fn is_blank_or_eof(c : Char) -> Bool {
  c is (' ' | '\t' | '\n' | EOF)
}

///|
/// The JSON Pointer to member or element `key` of the value at `pointer`.
fn child(pointer : String, key : String) -> String {
  let escaped = key
    .replace_all(old="~", new="~0")
    .replace_all(old="/", new="~1")
  "\{pointer}/\{escaped}"
}
