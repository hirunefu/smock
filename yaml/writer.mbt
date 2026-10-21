///|
/// Where a tree is written to.
priv struct Writer {
  out : @buffer.Buffer
  /// How many collections enclose the writer's position.
  mut depth : Int
  /// The comments to write before items of sequences, by JSON Pointer.
  item_comments : Map[String, Array[String]]
  /// Every pointer in `item_comments`, and every pointer that encloses one.
  /// The writer follows the pointer of a value only when it is here.
  commented : @set.Set[String]
  /// The pointers in `item_comments` whose comment is written.
  used : @set.Set[String]
}

///|
/// A writer of a document whose sequence items have `item_comments`.
fn Writer::Writer(item_comments : Map[String, Array[String]]) -> Writer {
  let commented = @set.Set([])
  for pointer, _ in item_comments {
    commented.add(pointer)
    for i in 1..<pointer.length() {
      if pointer.unsafe_get(i) == '/' {
        commented.add(pointer[:i].to_owned())
      }
    }
  }
  {
    out: @buffer.Buffer(),
    depth: 0,
    item_comments,
    commented,
    used: @set.Set([]),
  }
}

///|
/// Writes the document: the lines of `comment`, then `value`.
fn Writer::document(
  self : Writer,
  value : Json,
  comment : Array[String],
) -> Bytes raise WriteError {
  self.comment(comment, 0)
  self.root(value, if self.item_comments.is_empty() { None } else { Some("") })
  if self.used.length() < self.item_comments.length() {
    for pointer, _ in self.item_comments {
      if !self.used.contains(pointer) {
        raise WriteError(pointer~, message="no sequence item for this comment")
      }
    }
  }
  self.out.to_bytes()
}

///|
/// Enters a collection, which may not nest deeper than the parser accepts.
/// The writer leaves it with `self.depth -= 1`.
fn Writer::enter(self : Writer) -> Unit raise WriteError {
  self.depth += 1
  if self.depth > MAX_DEPTH {
    raise WriteError(
      pointer="",
      message="nesting is deeper than \{MAX_DEPTH} levels",
    )
  }
}

///|
/// The pointer to the member `key` of the mapping at `pointer`, when it is
/// or encloses an item with a comment; otherwise `None`, as for every value
/// inside one whose pointer is `None`.
fn Writer::member_pointer(
  self : Writer,
  pointer : String?,
  key : String,
) -> String? {
  guard pointer is Some(pointer) else { None }
  let pointer = child(pointer, key)
  if self.commented.contains(pointer) {
    Some(pointer)
  } else {
    None
  }
}

///|
/// The pointer to item `i` of the sequence at `pointer`, as
/// `member_pointer` gives it.
fn Writer::item_pointer(self : Writer, pointer : String?, i : Int) -> String? {
  guard pointer is Some(_) else { None }
  self.member_pointer(pointer, i.to_string())
}

///|
/// The comment for the sequence item at `pointer`, if there is one.
fn Writer::item_comment(self : Writer, pointer : String?) -> Array[String]? {
  guard pointer is Some(pointer) else { None }
  self.item_comments.get(pointer)
}

///|
/// Writes `lines` as comment lines indented by `indent` spaces. Characters
/// that are not printable become spaces, and trailing spaces are dropped, so
/// that each line stays one comment line.
fn Writer::comment(self : Writer, lines : Array[String], indent : Int) -> Unit {
  for line in lines {
    let text = StringBuilder()
    for c in line {
      text.write_char(if is_printable(c.to_int()) { c } else { ' ' })
    }
    let text = text.to_string().trim_end(chars=" ")
    self.indent(indent)
    self.out.write_byte(b'#')
    if !text.is_empty() {
      self.out.write_byte(b' ')
      self.out.write_string_utf8(text)
    }
    self.out.write_byte(b'\n')
  }
}

///|
/// Writes the document's value. `pointer` is `Some("")` when items have
/// comments, else `None`.
fn Writer::root(
  self : Writer,
  value : Json,
  pointer : String?,
) -> Unit raise WriteError {
  match value {
    Object(members) if !members.is_empty() =>
      self.mapping(members, 0, inline=false, pointer)
    Array(items) if !items.is_empty() =>
      self.sequence(items, 0, inline=false, pointer)
    _ => {
      self.scalar(value, column_zero=true)
      self.out.write_byte(b'\n')
    }
  }
}

///|
/// Writes the members of a mapping, each on its own line, with the keys
/// indented by `indent` spaces. When `inline`, the writer is already at the
/// column of the keys, after a sequence item's `- `, and the first key goes
/// there. `pointer` is the mapping's, or `None` (see `member_pointer`).
fn Writer::mapping(
  self : Writer,
  members : Map[String, Json],
  indent : Int,
  inline~ : Bool,
  pointer : String?,
) -> Unit raise WriteError {
  self.enter()
  let mut first = true
  for key, value in members {
    let pointer = self.member_pointer(pointer, key)
    self.pair(key, value, indent, inline=first && inline, pointer) catch {
      error => raise within(key, error)
    }
    first = false
  }
  self.depth -= 1
}

///|
/// Writes one member of a mapping whose keys are indented by `indent`
/// spaces, on a line of its own unless `inline`. `pointer` is the value's.
fn Writer::pair(
  self : Writer,
  key : String,
  value : Json,
  indent : Int,
  inline~ : Bool,
  pointer : String?,
) -> Unit raise WriteError {
  if !inline {
    self.indent(indent)
  }
  self.string(key, key=true, column_zero=indent == 0)
  self.out.write_byte(b':')
  match value {
    Object(members) if !members.is_empty() => {
      self.out.write_byte(b'\n')
      self.mapping(members, indent + 2, inline=false, pointer)
    }
    Array(items) if !items.is_empty() => {
      self.out.write_byte(b'\n')
      self.sequence(items, indent + 2, inline=false, pointer)
    }
    _ => {
      self.out.write_byte(b' ')
      self.scalar(value, column_zero=false)
      self.out.write_byte(b'\n')
    }
  }
}

///|
/// Writes the items of a sequence, each on its own line, with their `-`
/// indented by `indent` spaces. When `inline`, the writer is already at
/// that column, after an enclosing item's `- `, and the first item goes
/// there; it then has no comment. `pointer` is the sequence's.
fn Writer::sequence(
  self : Writer,
  items : Array[Json],
  indent : Int,
  inline~ : Bool,
  pointer : String?,
) -> Unit raise WriteError {
  self.enter()
  for i, item in items {
    let pointer = self.item_pointer(pointer, i)
    self.item(item, indent, inline=i == 0 && inline, pointer) catch {
      error => raise within(i.to_string(), error)
    }
  }
  self.depth -= 1
}

///|
/// Writes one item of a sequence whose `-` are indented by `indent` spaces,
/// after its comment, on a line of its own unless `inline`. `pointer` is
/// the item's.
fn Writer::item(
  self : Writer,
  item : Json,
  indent : Int,
  inline~ : Bool,
  pointer : String?,
) -> Unit raise WriteError {
  if self.item_comment(pointer) is Some(lines) {
    self.comment(lines, indent)
    self.used.add(pointer.unwrap())
  }
  if !inline {
    self.indent(indent)
  }
  self.out.write_byte(b'-')
  match item {
    Object(members) if !members.is_empty() => {
      self.out.write_byte(b' ')
      self.mapping(members, indent + 2, inline=true, pointer)
    }
    Array(items) if !items.is_empty() => {
      // A sequence starts on the line of the `-`, unless its first item
      // has a comment, which needs a line of its own.
      let inline = self.item_comment(self.item_pointer(pointer, 0)) is None
      self.out.write_byte(if inline { b' ' } else { b'\n' })
      self.sequence(items, indent + 2, inline~, pointer)
    }
    _ => {
      self.out.write_byte(b' ')
      self.scalar(item, column_zero=false)
      self.out.write_byte(b'\n')
    }
  }
}

///|
/// `error`, raised inside the member or item `segment` of a collection,
/// with its pointer made to start at the collection.
fn within(segment : String, error : WriteError) -> WriteError {
  let WriteError(pointer~, message~) = error
  WriteError(pointer=child("", segment) + pointer, message~)
}

///|
/// Writes `spaces` spaces.
fn Writer::indent(self : Writer, spaces : Int) -> Unit {
  for _ in 0..<spaces {
    self.out.write_byte(b' ')
  }
}

///|
/// Writes a scalar, or an empty collection as `{}` or `[]`.
fn Writer::scalar(
  self : Writer,
  value : Json,
  column_zero~ : Bool,
) -> Unit raise WriteError {
  match value {
    Null => self.out.write_string_utf8("null")
    True => self.out.write_string_utf8("true")
    False => self.out.write_string_utf8("false")
    Number(n, repr~) => self.out.write_string_utf8(number_text(n, repr))
    String(s) => self.string(s, key=false, column_zero~)
    Object(_) => self.empty_collection("{}")
    Array(_) => self.empty_collection("[]")
  }
}

///|
/// Writes an empty collection as `text`, `{}` or `[]`, a flow collection
/// that counts as a level of nesting.
fn Writer::empty_collection(
  self : Writer,
  text : String,
) -> Unit raise WriteError {
  self.enter()
  self.depth -= 1
  self.out.write_string_utf8(text)
}

///|
/// A number as JSON writes it, which the parser reads back as the same
/// number: `repr`, the text it was read from, when it has one, otherwise
/// the shortest form that reads back as the same 64-bit float.
fn number_text(n : Double, repr : String?) -> String raise WriteError {
  match repr {
    Some(text) if is_json_number(text) => text
    Some(text) =>
      raise WriteError(
        pointer="",
        message="\{text.escape()} is not a number in JSON syntax",
      )
    None if n.is_nan() || n.is_inf() =>
      raise WriteError(
        pointer="",
        message="a number must be finite, or keep the text it was read from",
      )
    None => n.to_string()
  }
}

///|
/// Writes a string, plain when the parser reads it back as `s` (see
/// `is_plain_safe`), else double-quoted.
fn Writer::string(
  self : Writer,
  s : String,
  key~ : Bool,
  column_zero~ : Bool,
) -> Unit raise WriteError {
  if is_plain_safe(s, key~, column_zero~) {
    self.out.write_string_utf8(s)
    return
  }
  self.out.write_byte(b'"')
  for c in s {
    let escape = match c {
      '"' => "\\\""
      '\\' => "\\\\"
      '\u{0}' => "\\0"
      '\u{7}' => "\\a"
      '\u{8}' => "\\b"
      '\t' => "\\t"
      '\n' => "\\n"
      '\u{b}' => "\\v"
      '\u{c}' => "\\f"
      '\r' => "\\r"
      '\u{1b}' => "\\e"
      '\u{85}' => "\\N"
      '\u{2028}' => "\\L"
      '\u{2029}' => "\\P"
      _ => ""
    }
    let code = c.to_int()
    if code >= 0xD800 && code <= 0xDFFF {
      let hex = code.to_string(radix=16).to_upper()
      raise WriteError(
        pointer="",
        message="U+\{hex} is half of a surrogate pair; UTF-8 cannot hold it alone",
      )
    }
    if escape != "" {
      self.out.write_string_utf8(escape)
    } else if is_printable(code) {
      self.out.write_char_utf8(c)
    } else if code <= 0xFF {
      self.out.write_string_utf8("\\x")
      self.hex(code, 2)
    } else {
      self.out.write_string_utf8("\\u")
      self.hex(code, 4)
    }
  }
  self.out.write_byte(b'"')
}

///|
/// Writes `code` as `digits` upper-case hexadecimal digits.
fn Writer::hex(self : Writer, code : Int, digits : Int) -> Unit {
  for i = digits - 1; i >= 0; i = i - 1 {
    let digit = (code >> (i * 4)) & 0xF
    self.out.write_byte(
      (if digit < 10 {
        '0'.to_int() + digit
      } else {
        'A'.to_int() + digit - 10
      }).to_byte(),
    )
  }
}

///|
/// Whether `s`, written plain in a block collection, reads back as `s`: as
/// a key, followed by `:`, when `key`, else as a value, followed by the end
/// of the line. `column_zero` says that it starts a line.
fn is_plain_safe(s : String, key~ : Bool, column_zero~ : Bool) -> Bool {
  let length = s.length()
  if length == 0 {
    return false
  }
  // What may not start a plain scalar: indicators, and `-` and `?` before a
  // blank (`:` is checked below, wherever it is).
  match s.unsafe_get(0) {
    ' '
    | '&'
    | '*'
    | '!'
    | ','
    | '['
    | ']'
    | '{'
    | '}'
    | '#'
    | '|'
    | '>'
    | '%'
    | '@'
    | '`'
    | '"'
    | '\'' => return false
    '-' | '?' if is_blank_unit(following(s, 1, key~)) => return false
    _ => ()
  }
  // A document marker, `---` or `...` before a blank.
  if column_zero &&
    (s.has_prefix("---") || s.has_prefix("...")) &&
    is_blank_unit(following(s, 3, key~)) {
    return false
  }
  for i in 0..<length {
    let c = s.unsafe_get(i)
    let code = c.to_int()
    let printable = if is_high_surrogate(code) {
      i + 1 < length && is_low_surrogate(s.unsafe_get(i + 1).to_int())
    } else if is_low_surrogate(code) {
      i > 0 && is_high_surrogate(s.unsafe_get(i - 1).to_int())
    } else {
      is_printable(code)
    }
    if !printable {
      return false
    }
    match c {
      // `: ` ends a key; ` #` starts a comment; trailing spaces are not
      // part of the scalar.
      ':' if is_blank_unit(following(s, i + 1, key~)) => return false
      ' ' if following(s, i + 1, key~) == '#' || i == length - 1 => return false
      _ => ()
    }
  }
  resolve(s) is Value(String(_))
}

///|
/// The UTF-16 code unit at `i` of `s` written plain, or what follows it:
/// `:` after a key, a line break after a value.
fn following(s : String, i : Int, key~ : Bool) -> UInt16 {
  if i < s.length() {
    s.unsafe_get(i)
  } else if key {
    ':'
  } else {
    '\n'
  }
}

///|
/// Whether a UTF-16 code unit is a space or a line break.
fn is_blank_unit(unit : UInt16) -> Bool {
  unit is (' ' | '\n')
}

///|
/// Whether a character is written as itself, in a plain or quoted scalar:
/// not a control character, a line break that YAML 1.1 reads, a byte order
/// mark, a noncharacter the parser rejects, or half of a surrogate pair.
fn is_printable(code : Int) -> Bool {
  !(code < 0x20 ||
  (code >= 0x7F && code <= 0x9F) ||
  code == 0x2028 ||
  code == 0x2029 ||
  (code >= 0xD800 && code <= 0xDFFF) ||
  code == 0xFEFF ||
  code == 0xFFFE ||
  code == 0xFFFF)
}

///|
/// Whether `code` is the first half of a UTF-16 surrogate pair, U+D800 to
/// U+DBFF.
fn is_high_surrogate(code : Int) -> Bool {
  code >= 0xD800 && code <= 0xDBFF
}

///|
/// Whether `code` is the second half of a UTF-16 surrogate pair, U+DC00 to
/// U+DFFF.
fn is_low_surrogate(code : Int) -> Bool {
  code >= 0xDC00 && code <= 0xDFFF
}
