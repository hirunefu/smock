///|
/// The values of the nodes that `path` selects in the document, in
/// document order. There are none when the path selects nothing.
///
/// The path's first step selects the root element, when it has that local
/// name. Each further step selects the children of the elements selected
/// so far that have that local name. A final attribute step selects the
/// attributes of those elements that have that local name. Namespace
/// declarations (`xmlns` and `xmlns:*`) are not attributes here.
///
/// An element's value is its XPath string-value, all the text in it and in
/// its descendants (CDATA included), trimmed of XML whitespace (space, tab,
/// line feed and carriage return). An attribute's value is its value after
/// XML's attribute-value normalisation (XML 1.0 §3.3.3): each literal
/// whitespace character in it is a space.
///
/// Selecting takes time linear in the size of the document, and a binary
/// search among the elements for each element whose attributes it
/// selects. To read the values without this array and these strings, walk
/// the same nodes with `first_node` and `next_node`, and read each with
/// `value_is` or `utf8_value`.
pub fn Document::select(self : Document, path : Path) -> Array[String] {
  let values = []
  let mut node = self.first_node(path)
  while node >= 0 {
    values.push(@utf8.decode_lossy(self.utf8_value(path, node)))
    node = self.next_node(path, node)
  }
  values
}

///|
/// The first node that `path` selects in the document, in document order,
/// as `select` selects them, or -1 when it selects none.
///
/// A node is a number that only `next_node`, `value_is` and `utf8_value`
/// read, with the same document and path. With them, a caller walks the
/// nodes one at a time, and stops when it has what it needs. Walking
/// allocates nothing, and neither does `value_is`.
pub fn Document::first_node(self : Document, path : Path) -> Int32 {
  self.node_from(path, 0, 0)
}

///|
/// The node that `path` selects after `node`, a node that it selects, in
/// document order, or -1 when `node` is the last.
pub fn Document::next_node(self : Document, path : Path, node : Int32) -> Int32 {
  let steps = path.elements.length()
  match path.attribute {
    // An element node is the element's index.
    None => self.node_from(path, node + 1, steps)
    // An attribute node is where the quote that opens its value is.
    Some(name) => {
      let next = self.attribute_from(value_end(self.input, node) + 1, name)
      if next >= 0 {
        return next
      }
      self.node_from(path, self.element_at(node) + 1, steps)
    }
  }
}

///|
/// Whether the value of `node`, a node that `path` selects, is `text`, as
/// `select` reads the value. It is compared in place, with no allocation.
pub fn Document::value_is(
  self : Document,
  path : Path,
  node : Int32,
  text : StringView,
) -> Bool {
  match path.attribute {
    None => self.element_value_is(node, text)
    Some(_) => attribute_value_is(self.input, node, text)
  }
}

///|
/// The value of `node`, a node that `path` selects, in UTF-8, as `select`
/// reads it. It is a view of the input when the input holds the value as
/// it is, as it does for an element that holds only text without
/// references or carriage returns, and for an attribute without
/// references or whitespace other than spaces. Otherwise it is decoded
/// into new bytes.
pub fn Document::utf8_value(
  self : Document,
  path : Path,
  node : Int32,
) -> BytesView {
  match path.attribute {
    None => self.element_utf8(node)
    Some(_) => attribute_utf8(self.input, node)
  }
}

///|
/// The first node that `path` selects among the elements from the one at
/// index `element` on, or -1. `matched` is how many steps the latest
/// elements before it at depths 1, 2 and so on meet, in turn: none before
/// the root element, and every step after an element that the path's
/// element steps select.
fn Document::node_from(
  self : Document,
  path : Path,
  element : Int32,
  matched : Int32,
) -> Int32 {
  // Plain loops, with no closure or iterator, since a request may be
  // matched against many paths. The elements come in document order, each
  // after its ancestors, so the ancestors of an element are the latest
  // elements before it at each smaller depth.
  let steps = path.elements.length()
  let mut matched = matched
  for i in element..<self.name_starts.length() {
    let depth = self.depths[i].to_int() + 1
    // Below the last step, or below an element that does not meet its
    // step, no element is selected.
    if depth > steps || matched < depth - 1 {
      continue
    }
    matched = depth - 1
    if !self.name_is(self.name_starts[i], path.elements[depth - 1]) {
      continue
    }
    matched = depth
    if depth < steps {
      continue
    }
    match path.attribute {
      None => return i
      Some(name) => {
        let start = name_end(self.input, self.name_starts[i])
        let node = self.attribute_from(start, name)
        if node >= 0 {
          return node
        }
      }
    }
  }
  -1
}

///|
/// The index of the element whose start tag holds byte `i` of the input,
/// after the element's name: the last element whose local name starts
/// before it.
fn Document::element_at(self : Document, i : Int32) -> Int32 {
  // The local names start in document order, which is the order of the
  // bytes, so a binary search finds it. name_starts[low] < i, and
  // name_starts[high] >= i when high is an index.
  let mut low = 0
  let mut high = self.name_starts.length()
  while high - low > 1 {
    let middle = low + (high - low) / 2
    if self.name_starts[middle] < i {
      low = middle
    } else {
      high = middle
    }
  }
  low
}

///|
/// Whether the name that starts at byte `start` of the input, the local
/// name of an element or of an attribute, is `name`, in UTF-8.
fn Document::name_is(self : Document, start : Int32, name : Bytes) -> Bool {
  let end = start + name.length()
  end <= self.input.length() &&
  self.input[start:end] == name[:] &&
  (end == self.input.length() || !is_name_byte(self.input[end]))
}

///|
/// The first attribute named `name`, by its local name, in the start tag
/// that holds byte `i` of the input, from byte `i` on, where an attribute
/// or the end of the tag may start: the index of the quote that opens its
/// value, or -1 when none has that name. Namespace declarations are not
/// attributes here.
fn Document::attribute_from(self : Document, i : Int32, name : Bytes) -> Int32 {
  let input = self.input
  let mut i = i
  while true {
    i = skip_spaces(input, i)
    if input[i] is (b'>' | b'/') {
      break
    }
    let qname = i
    i = name_end(input, i)
    let qname_end = i
    // The `=`, then the quoted value.
    i = skip_spaces(input, skip_spaces(input, i) + 1)
    if !is_namespace_declaration(input[qname:qname_end]) &&
      self.name_is(local_start(input, qname, qname_end), name) {
      return i
    }
    i = value_end(input, i) + 1
  }
  -1
}

///|
/// Whether the value of the element at index `element` is `text`: its
/// XPath string-value, trimmed of XML whitespace, compared one character
/// at a time.
fn Document::element_value_is(
  self : Document,
  element : Int32,
  text : StringView,
) -> Bool {
  // The value is trimmed, so it neither starts nor ends with whitespace.
  let length = text.length()
  if length > 0 &&
    (is_space(text[0].to_int()) || is_space(text[length - 1].to_int())) {
    return false
  }
  let input = self.input
  let content = tag_end(input, self.name_starts[element])
  let end = content_end(input, content)
  // How much of `text` the characters read so far match, in UTF-16 code
  // units, whitespace before the first character left out.
  let mut matched = 0
  let mut cursor = content
  while true {
    let c = text_char(input, cursor, end)
    let code_point = char_of(c)
    if code_point < 0 {
      break
    }
    cursor = next_of(c)
    if matched == length {
      // Only whitespace may follow the text.
      if !is_space(code_point) {
        return false
      }
    } else if matched > 0 || !is_space(code_point) {
      matched = text_continues(text, matched, code_point)
      if matched < 0 {
        return false
      }
    }
  }
  matched == length
}

///|
/// The value of the element at index `element` in UTF-8: its XPath
/// string-value, trimmed of XML whitespace.
fn Document::element_utf8(self : Document, element : Int32) -> BytesView {
  let input = self.input
  let content = tag_end(input, self.name_starts[element])
  let end = content_end(input, content)
  // Most elements that a path selects hold only text, with no reference
  // or line end to decode: their value is that text, trimmed, in place.
  let mut i = content
  while i < end && !(input[i] is (b'<' | b'&' | b'\r')) {
    i += 1
  }
  if i == end {
    return trimmed(input, content, end)
  }
  let value = @buffer.Buffer(size_hint=end - content)
  let mut cursor = content
  while true {
    let c = text_char(input, cursor, end)
    if char_of(c) < 0 {
      break
    }
    value.write_char_utf8(char_of(c).unsafe_to_char())
    cursor = next_of(c)
  }
  let value = value.to_bytes()
  trimmed(value, 0, value.length())
}

///|
/// `input[start:end]` without the XML whitespace at its start and end.
fn trimmed(input : BytesView, start : Int32, end : Int32) -> BytesView {
  let mut start = start
  let mut end = end
  while start < end && is_space(input[start].to_int()) {
    start += 1
  }
  while end > start && is_space(input[end - 1].to_int()) {
    end -= 1
  }
  input[start:end]
}

///|
/// Where the content that starts at byte `start` of `input` ends: the
/// index of the end tag that closes it, in a well-formed document. The
/// content of an empty-element tag, which `start` follows, ends where it
/// starts.
fn content_end(input : BytesView, start : Int32) -> Int32 {
  if input[start - 2] == b'/' {
    return start
  }
  // How many elements are open, the one whose content this is included.
  let mut open = 1
  let mut i = start
  while true {
    if input[i] != b'<' {
      i += 1
      continue
    }
    let next = markup_end(input, i)
    match input[i + 1] {
      b'/' => {
        open -= 1
        if open == 0 {
          break
        }
      }
      // A comment, a CDATA section or a processing instruction.
      b'!' | b'?' => ()
      // A start tag, or an empty-element tag, which ends in `/>`.
      _ => if input[next - 2] != b'/' { open += 1 }
    }
    i = next
  }
  i
}

///|
/// The index after the markup that starts at byte `i` of `input`, a `<` in
/// the content of an element of a well-formed document: a start tag or an
/// empty-element tag, an end tag, a comment, a CDATA section or a
/// processing instruction.
fn markup_end(input : BytesView, i : Int32) -> Int32 {
  match input[i + 1] {
    b'/' => skip_past(input, i, b'>')
    b'?' => skip_past_literal(input, i + 2, b"?>")
    b'!' =>
      if input[i + 2] == b'-' {
        skip_past_literal(input, i + 4, b"-->")
      } else {
        skip_past_literal(input, i + 9, b"]]>")
      }
    _ => tag_end(input, i + 1)
  }
}

///|
/// The character of the text of an element's content at `cursor`, and the
/// cursor after it, packed as `char_of` and `next_of` read them. The code
/// point is -1 when the text ends at `end`, the end tag that closes the
/// element.
///
/// A cursor is the index of a byte of `input`, where the content's
/// character data, references and markup are read: a reference stands for
/// its character, a line end (CR LF, or a lone CR) for a line feed, and
/// markup other than CDATA for nothing. Inside a CDATA section, whose
/// characters are text as they are written but for line ends, the cursor
/// is -1 less the index, so that it says where it is with no allocation.
fn text_char(input : BytesView, cursor : Int32, end : Int32) -> Int64 {
  let mut cdata = cursor < 0
  let mut i = if cdata { -cursor - 1 } else { cursor }
  while i < end {
    if cdata {
      if looking_at(input, i, b"]]>") {
        cdata = false
        i += 3
        continue
      }
      let c = line_char(input, i)
      return packed_char(char_of(c), -next_of(c) - 1)
    }
    match input[i] {
      b'<' =>
        if looking_at(input, i, b"<![CDATA[") {
          cdata = true
          i += 9
        } else {
          i = markup_end(input, i)
        }
      b'&' => return reference_char(input, i)
      _ => return line_char(input, i)
    }
  }
  packed_char(-1, end)
}

///|
/// The character at byte `i` of `input`, well-formed UTF-8, and the index
/// after it, packed as `char_of` and `next_of` read them. A line end (CR
/// LF, or a lone CR) is a line feed.
fn line_char(input : BytesView, i : Int32) -> Int64 {
  if input[i] == b'\r' {
    let next = if i + 1 < input.length() && input[i + 1] == b'\n' {
      i + 2
    } else {
      i + 1
    }
    return packed_char('\n', next)
  }
  let decoded = decode(input, i)
  packed_char(code_point(decoded), i + byte_length(decoded))
}

///|
/// Whether the value of the attribute whose value the quote at byte
/// `quote` of `input` opens is `text`, after XML's attribute-value
/// normalisation, compared one character at a time.
fn attribute_value_is(
  input : BytesView,
  quote : Int32,
  text : StringView,
) -> Bool {
  let end = value_end(input, quote)
  let mut matched = 0
  let mut i = quote + 1
  while i < end {
    let c = attribute_char(input, i)
    matched = text_continues(text, matched, char_of(c))
    if matched < 0 {
      return false
    }
    i = next_of(c)
  }
  matched == text.length()
}

///|
/// The value of the attribute whose value the quote at byte `quote` of
/// `input` opens, in UTF-8, after XML's attribute-value normalisation
/// (XML 1.0 §3.3.3): each literal whitespace character is a space, a line
/// end (CR LF) is one space, and references are decoded.
fn attribute_utf8(input : BytesView, quote : Int32) -> BytesView {
  let end = value_end(input, quote)
  let mut plain = true
  for i in (quote + 1)..<end {
    if input[i] is (b'&' | b'\t' | b'\n' | b'\r') {
      plain = false
      break
    }
  }
  if plain {
    return input[quote + 1:end]
  }
  let value = @buffer.Buffer(size_hint=end - quote)
  let mut i = quote + 1
  while i < end {
    let c = attribute_char(input, i)
    value.write_char_utf8(char_of(c).unsafe_to_char())
    i = next_of(c)
  }
  value.to_bytes()
}

///|
/// The character of an attribute's value at byte `i` of `input`, inside
/// the quotes of a well-formed document, after XML's attribute-value
/// normalisation, and the index after it, packed as `char_of` and
/// `next_of` read them.
fn attribute_char(input : BytesView, i : Int32) -> Int64 {
  match input[i] {
    b'&' => reference_char(input, i)
    b'\t' | b'\n' => packed_char(' ', i + 1)
    // The closing quote follows, so `i + 1` is in the input.
    b'\r' => packed_char(' ', if input[i + 1] == b'\n' { i + 2 } else { i + 1 })
    _ => {
      let decoded = decode(input, i)
      packed_char(code_point(decoded), i + byte_length(decoded))
    }
  }
}

///|
/// The index of the quote that closes the attribute value that the quote
/// at byte `quote` of `input` opens.
fn value_end(input : BytesView, quote : Int32) -> Int32 {
  let mut i = quote + 1
  while input[i] != input[quote] {
    i += 1
  }
  i
}

///|
/// Where `text` continues after the character `code_point`, when `text`
/// has it at UTF-16 code unit `i`: the index after it, or -1 when `text`
/// has another character there, or ends before.
fn text_continues(text : StringView, i : Int32, code_point : Int32) -> Int32 {
  if code_point < 0x10000 {
    return if i < text.length() && text[i].to_int() == code_point {
      i + 1
    } else {
      -1
    }
  }
  // A character outside the BMP is a surrogate pair in `text`.
  let high = 0xD800 + ((code_point - 0x10000) >> 10)
  let low = 0xDC00 + ((code_point - 0x10000) & 0x3FF)
  if i + 1 < text.length() &&
    text[i].to_int() == high &&
    text[i + 1].to_int() == low {
    i + 2
  } else {
    -1
  }
}

///|
/// Whether `input` continues with `literal` at byte `i`.
fn looking_at(input : BytesView, i : Int32, literal : Bytes) -> Bool {
  i + literal.length() <= input.length() &&
  input[i:i + literal.length()] == literal[:]
}

///|
/// The index after the first `byte` at or after byte `i` of `input`.
fn skip_past(input : BytesView, i : Int32, byte : Byte) -> Int32 {
  let mut i = i
  while input[i] != byte {
    i += 1
  }
  i + 1
}

///|
/// The index after the first `literal` at or after byte `i` of `input`.
fn skip_past_literal(input : BytesView, i : Int32, literal : Bytes) -> Int32 {
  let mut i = i
  while !looking_at(input, i, literal) {
    i += 1
  }
  i + literal.length()
}

///|
/// The index after the start tag or empty-element tag of a well-formed
/// document that byte `i` of `input` is in, before its first attribute.
/// An empty-element tag ends in `/>`. Quoted attribute values are skipped,
/// since they may hold `>` and `/`.
fn tag_end(input : BytesView, i : Int32) -> Int32 {
  let mut i = i
  while true {
    match input[i] {
      b'"' | b'\'' as quote => i = skip_past(input, i + 1, quote)
      b'>' => return i + 1
      _ => i += 1
    }
  }
  i
}

///|
/// The end of the name that starts at byte `i` of `input`, in a tag of a
/// well-formed document: the first byte that no name holds after it.
fn name_end(input : BytesView, i : Int32) -> Int32 {
  let mut i = i
  while i < input.length() && is_name_byte(input[i]) {
    i += 1
  }
  i
}

///|
/// Whether `byte` may be part of a name in a tag: a name ends at
/// whitespace, `/`, `>` or `=`.
fn is_name_byte(byte : Byte) -> Bool {
  !(byte is (b' ' | b'\t' | b'\n' | b'\r' | b'/' | b'>' | b'='))
}

///|
/// The index of the first byte at or after byte `i` of `input` that is not
/// XML whitespace.
fn skip_spaces(input : BytesView, i : Int32) -> Int32 {
  let mut i = i
  while i < input.length() && is_space(input[i].to_int()) {
    i += 1
  }
  i
}

///|
/// Whether `qname`, the qualified name of an attribute, declares a
/// namespace: it is `xmlns` or `xmlns:` and a prefix.
fn is_namespace_declaration(qname : BytesView) -> Bool {
  qname == b"xmlns"[:] || (qname.length() > 6 && qname[:6] == b"xmlns:"[:])
}

///|
/// The character that the reference at byte `i` of `input`, a well-formed
/// document, stands for, and the index after the reference, packed as
/// `char_of` and `next_of` read them.
fn reference_char(input : BytesView, i : Int32) -> Int64 {
  let mut j = i + 1
  if input[j] == b'#' {
    j += 1
    let hex = input[j] == b'x'
    if hex {
      j += 1
    }
    let mut code = 0
    while input[j] != b';' {
      let b = input[j].to_int()
      code = if hex {
        code * 16 +
        (match input[j] {
          b'0'..<=b'9' => b - '0'
          b'a'..<=b'f' => b - 'a' + 10
          _ => b - 'A' + 10
        })
      } else {
        code * 10 + (b - '0')
      }
      // Past U+10FFFF, the value no longer matters; a well-formed document
      // has none.
      code = @cmp.minimum(code, 0x110000)
      j += 1
    }
    return packed_char(code, j + 1)
  }
  let name = j
  while input[j] != b';' {
    j += 1
  }
  packed_char(predefined_entity(input[name:j]), j + 1)
}

///|
/// A character and the index or cursor after it, packed in one `Int64`,
/// rather than a tuple, so that reading a value allocates nothing. Either
/// may be negative.
fn packed_char(code_point : Int32, next : Int32) -> Int64 {
  (code_point.to_int64() << 32) | (next.to_int64() & 0xFFFFFFFFL)
}

///|
/// The code point of what `packed_char` packed.
fn char_of(c : Int64) -> Int32 {
  (c >> 32).to_int()
}

///|
/// The index or cursor after the character that `packed_char` packed.
fn next_of(c : Int64) -> Int32 {
  (c & 0xFFFFFFFFL).to_int()
}
