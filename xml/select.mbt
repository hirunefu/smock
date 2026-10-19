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
/// Selecting takes time linear in the size of the document.
pub fn Document::select(self : Document, path : Path) -> Array[String] {
  // Plain loops, with no closure or iterator, since a request may be
  // matched against many paths. The elements come in document order, each
  // after its ancestors, so the ancestors of an element are the latest
  // elements before it at each smaller depth. `matched` is how many steps
  // the latest elements at depths 1, 2 and so on meet, in turn.
  let values = []
  let steps = path.elements.length()
  let mut matched = 0
  for i in 0..<self.names.length() {
    let depth = self.depths[i].to_int() + 1
    // Below the last step, or below an element that does not meet its
    // step, no element is selected.
    if depth > steps || matched < depth - 1 {
      continue
    }
    matched = depth - 1
    if !self.name_is(self.names[i], path.elements[depth - 1]) {
      continue
    }
    matched = depth
    if depth == steps {
      match path.attribute {
        Some(name) => self.attribute_values(self.names[i], name, values)
        None => values.push(self.element_value(self.names[i]))
      }
    }
  }
  values
}

///|
/// Whether the name that starts at byte `start` of the input, the local
/// name of an element or of an attribute, is `name`, in UTF-8.
fn Document::name_is(self : Document, start : Int, name : Bytes) -> Bool {
  let end = start + name.length()
  end <= self.input.length() &&
  self.input[start:end] == name[:] &&
  (end == self.input.length() || !is_name_byte(self.input[end]))
}

///|
/// Pushes to `values` the value of each attribute named `name`, by its
/// local name, in the start tag of the element whose local name starts at
/// byte `start` of the input. Namespace declarations are not attributes
/// here.
fn Document::attribute_values(
  self : Document,
  start : Int,
  name : Bytes,
  values : Array[String],
) -> Unit {
  let input = self.input
  let mut i = name_end(input, start)
  while true {
    i = skip_spaces(input, i)
    if input[i] is (b'>' | b'/') {
      break
    }
    let qname = i
    i = name_end(input, i)
    let qname_end = i
    i = skip_spaces(input, i)
    // The `=`, then the quoted value.
    i = skip_spaces(input, i + 1)
    let quote = input[i]
    let value = i + 1
    i = value
    while input[i] != quote {
      i += 1
    }
    if !is_namespace_declaration(input[qname:qname_end]) &&
      self.name_is(local_start(input, qname, qname_end), name) {
      values.push(attribute_value(input[value:i]))
    }
    i += 1
  }
}

///|
/// The element's value, for the element whose local name starts at byte
/// `start` of the input: its XPath string-value (its text and the text of
/// every descendant, in document order), trimmed of XML whitespace.
fn Document::element_value(self : Document, start : Int) -> String {
  let input = self.input
  let content = tag_end(input, start)
  if input[content - 2] == b'/' {
    // An empty-element tag has no content.
    return ""
  }
  // Most elements that a path selects hold only text, with no reference
  // or line end to decode: their value is that text, trimmed.
  let mut i = content
  while !(input[i] is (b'<' | b'&' | b'\r')) {
    i += 1
  }
  if input[i] == b'<' && input[i + 1] == b'/' {
    let mut first = content
    let mut last = i
    while first < last && is_space(input[first].to_int()) {
      first += 1
    }
    while last > first && is_space(input[last - 1].to_int()) {
      last -= 1
    }
    return @utf8.decode_lossy(input[first:last])
  }
  let text = StringBuilder()
  write_text(input, content, text)
  text.to_string().trim(chars=" \t\n\r").to_owned()
}

///|
/// Writes the text of the content that starts at byte `start` of `input`,
/// a well-formed document, up to the end tag that closes it: its character
/// data and CDATA, with references decoded and line ends as line feeds,
/// and the text of every element in it. Comments and processing
/// instructions are skipped.
fn write_text(input : BytesView, start : Int, out : StringBuilder) -> Unit {
  // How many elements are open, the one whose content this is included.
  let mut open = 1
  let mut i = start
  while true {
    match input[i] {
      b'<' =>
        if input[i + 1] == b'/' {
          open -= 1
          if open == 0 {
            break
          }
          i = skip_past(input, i, b'>')
        } else if looking_at(input, i, b"<!--") {
          i += 4
          while !looking_at(input, i, b"-->") {
            i += 1
          }
          i += 3
        } else if looking_at(input, i, b"<![CDATA[") {
          i += 9
          while !looking_at(input, i, b"]]>") {
            i = write_char(input, i, out)
          }
          i += 3
        } else if input[i + 1] == b'?' {
          i += 2
          while !looking_at(input, i, b"?>") {
            i += 1
          }
          i += 2
        } else {
          let end = tag_end(input, i + 1)
          if input[end - 2] != b'/' {
            open += 1
          }
          i = end
        }
      b'&' => {
        let reference = reference_char(input, i)
        out.write_char(char_of(reference).unsafe_to_char())
        i = next_of(reference)
      }
      _ => i = write_char(input, i, out)
    }
  }
}

///|
/// Writes the character at byte `i` of `input`, well-formed UTF-8, to
/// `out`, a line end (CR LF, or a lone CR) as a line feed, and returns the
/// index after it.
fn write_char(input : BytesView, i : Int, out : StringBuilder) -> Int {
  if input[i] == b'\r' {
    out.write_char('\n')
    return if i + 1 < input.length() && input[i + 1] == b'\n' {
      i + 2
    } else {
      i + 1
    }
  }
  let decoded = decode(input, i)
  out.write_char(code_point(decoded).unsafe_to_char())
  i + byte_length(decoded)
}

///|
/// The value of an attribute, from its raw text `raw`, between the quotes
/// of a well-formed document, after XML's attribute-value normalisation
/// (XML 1.0 §3.3.3): each literal whitespace character is a space, a line
/// end (CR LF) is one space, and references are decoded.
fn attribute_value(raw : BytesView) -> String {
  let mut plain = true
  for i in 0..<raw.length() {
    if raw[i] is (b'&' | b'\t' | b'\n' | b'\r') {
      plain = false
      break
    }
  }
  if plain {
    return @utf8.decode_lossy(raw)
  }
  let value = StringBuilder()
  let mut i = 0
  while i < raw.length() {
    match raw[i] {
      b'&' => {
        let reference = reference_char(raw, i)
        value.write_char(char_of(reference).unsafe_to_char())
        i = next_of(reference)
      }
      b'\t' | b'\n' => {
        value.write_char(' ')
        i += 1
      }
      b'\r' => {
        value.write_char(' ')
        i += if i + 1 < raw.length() && raw[i + 1] == b'\n' { 2 } else { 1 }
      }
      _ => {
        let decoded = decode(raw, i)
        value.write_char(code_point(decoded).unsafe_to_char())
        i += byte_length(decoded)
      }
    }
  }
  value.to_string()
}

///|
/// Whether `input` continues with `literal` at byte `i`.
fn looking_at(input : BytesView, i : Int, literal : Bytes) -> Bool {
  i + literal.length() <= input.length() &&
  input[i:i + literal.length()] == literal[:]
}

///|
/// The index after the first `byte` at or after byte `i` of `input`.
fn skip_past(input : BytesView, i : Int, byte : Byte) -> Int {
  let mut i = i
  while input[i] != byte {
    i += 1
  }
  i + 1
}

///|
/// The index after the start tag or empty-element tag of a well-formed
/// document that byte `i` of `input` is in, before its first attribute.
/// An empty-element tag ends in `/>`. Quoted attribute values are skipped,
/// since they may hold `>` and `/`.
fn tag_end(input : BytesView, i : Int) -> Int {
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
fn name_end(input : BytesView, i : Int) -> Int {
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
fn skip_spaces(input : BytesView, i : Int) -> Int {
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
fn reference_char(input : BytesView, i : Int) -> Int64 {
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
          b'0'..=b'9' => b - '0'
          b'a'..=b'f' => b - 'a' + 10
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
/// A character and the index after it, packed as `reference_char` returns
/// them, with no allocation.
fn packed_char(code_point : Int, next : Int) -> Int64 {
  (code_point.to_int64() << 32) | next.to_int64()
}

///|
/// The code point of what `reference_char` returned.
fn char_of(c : Int64) -> Int {
  (c >> 32).to_int()
}

///|
/// The index after what `reference_char` returned.
fn next_of(c : Int64) -> Int {
  (c & 0xFFFFFFFFL).to_int()
}
