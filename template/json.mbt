// Writing JSON. smock writes every JSON body and every number itself, so
// that the bytes are the same on every target:
//
// - Compact: no space, members in the order written, strings in UTF-8.
// - Indented, for files: as compact, with each member and element on its
//   own line, two spaces deeper than its object or array.
// - A number in the shortest form that reads back as the same 64-bit
//   float (`1.50` as `1.5`, `1e3` as `1000`), except one that kept the text
//   it was written with: an integer beyond 2^53 keeps its digits, and a
//   helper's output, such as `fake.decimal`, keeps its decimals.

///|
/// `json` as compact JSON, its numbers written as smock writes them.
pub fn compact_json(json : Json) -> String {
  let out = @buffer.Buffer()
  write_json(out, json)
  @utf8.decode_lossy(out.to_bytes())
}

///|
/// `json` as compact JSON in UTF-8, its numbers written as smock writes
/// them: the body of a `json` response.
pub fn compact_json_bytes(json : Json) -> Bytes {
  let out = @buffer.Buffer()
  write_json(out, json)
  out.to_bytes()
}

///|
/// `json` as indented JSON in UTF-8, the form of a file: members in order,
/// each member and element on its own line, two spaces deeper per level,
/// `{}` and `[]` for empty collections, and numbers and strings as compact
/// JSON writes them. The text ends without a newline; a file adds one.
pub fn indented_json_bytes(json : Json) -> Bytes {
  let out = @buffer.Buffer()
  write_indented_json(out, json, 0)
  out.to_bytes()
}

///|
/// The bytes of UTF-8 that compact JSON of `json` takes, as smock writes
/// it, counted without writing them, plus `per_value` for each JSON value
/// in it: each object, array, string, number, boolean and null. The bound
/// on per-Session state counts a value this way.
pub fn compact_length(json : Json, per_value~ : Int64 = 0L) -> Int64 {
  per_value +
  (match json {
    Null | True => 4L
    False => 5L
    Number(n, repr~) => number_text(n, repr).length().to_int64()
    String(s) => json_string_content_length(s).to_int64() + 2L
    Array(items) => {
      let mut n = 2L
      for i, item in items {
        n += compact_length(item, per_value~) + (if i > 0 { 1L } else { 0L })
      }
      n
    }
    Object(members) => {
      let mut n = 2L
      let mut first = true
      for key, value in members {
        n += json_string_content_length(key).to_int64() +
          3L +
          compact_length(value, per_value~) +
          (if first { 0L } else { 1L })
        first = false
      }
      n
    }
  })
}

///|
/// Writes `json` as compact JSON in UTF-8.
fn write_json(out : @buffer.Buffer, json : Json) -> Unit {
  match json {
    Null => out.write_string_utf8("null")
    True => out.write_string_utf8("true")
    False => out.write_string_utf8("false")
    Number(n, repr~) => out.write_string_utf8(number_text(n, repr))
    String(s) => {
      let text = StringBuilder()
      text.write_char('"')
      write_json_string_content(text, s)
      text.write_char('"')
      out.write_string_utf8(text.to_string())
    }
    Array(items) => {
      out.write_byte(b'[')
      for i, item in items {
        if i > 0 {
          out.write_byte(b',')
        }
        write_json(out, item)
      }
      out.write_byte(b']')
    }
    Object(members) => {
      out.write_byte(b'{')
      let mut first = true
      for key, value in members {
        if !first {
          out.write_byte(b',')
        }
        first = false
        write_json(out, Json::string(key))
        out.write_byte(b':')
        write_json(out, value)
      }
      out.write_byte(b'}')
    }
  }
}

///|
/// Writes `json`, which sits `depth` levels deep, as indented JSON in UTF-8.
/// Anything but a collection with members is written as compact JSON, so
/// that numbers and strings are the same in both forms. It walks the tree
/// as `write_json` does, with line breaks; a change to how either writes
/// keys, members or scalars is made in both.
fn write_indented_json(
  out : @buffer.Buffer,
  json : Json,
  depth : Int32,
) -> Unit {
  match json {
    Array(items) if !items.is_empty() => {
      out.write_byte(b'[')
      for i, item in items {
        if i > 0 {
          out.write_byte(b',')
        }
        write_line_start(out, depth + 1)
        write_indented_json(out, item, depth + 1)
      }
      write_line_start(out, depth)
      out.write_byte(b']')
    }
    Object(members) if !members.is_empty() => {
      out.write_byte(b'{')
      let mut first = true
      for key, value in members {
        if !first {
          out.write_byte(b',')
        }
        first = false
        write_line_start(out, depth + 1)
        write_json(out, Json::string(key))
        out.write_bytes(b": ")
        write_indented_json(out, value, depth + 1)
      }
      write_line_start(out, depth)
      out.write_byte(b'}')
    }
    _ => write_json(out, json)
  }
}

///|
/// Starts a new line indented for `depth` levels.
fn write_line_start(out : @buffer.Buffer, depth : Int32) -> Unit {
  out.write_byte(b'\n')
  for _ in 0..<depth {
    out.write_bytes(b"  ")
  }
}

///|
/// A number as smock writes it: `repr`, the text it kept, when it has one,
/// otherwise the shortest form that reads back as the same 64-bit float.
/// Compact and indented JSON and text templates write numbers with it. It
/// is public so that the OpenAPI import writes them the same way.
pub fn number_text(n : Double, repr : String?) -> String {
  match repr {
    Some(text) => text
    None => n.to_string()
  }
}

///|
/// The length of `s` as a JSON string in UTF-8, its quotes included, as
/// compact JSON writes it with `write_json_string_content`, or a length
/// above `limit` as soon as it passes it, so that a long string is not
/// walked to its end. The OpenAPI import bounds its samples with it.
pub fn json_string_bytes(s : String, limit~ : Int32) -> Int32 {
  let mut size = 2
  for c in s {
    if size > limit {
      break
    }
    size += json_char_length(c)
  }
  size
}

///|
/// The bytes of UTF-8 that `write_json_string_content` writes for `s`.
fn json_string_content_length(s : StringView) -> Int32 {
  let mut n = 0
  for c in s {
    n += json_char_length(c)
  }
  n
}

///|
/// The bytes of UTF-8 that `write_json_string_content` writes for `c`.
fn json_char_length(c : Char) -> Int32 {
  match c {
    '"' | '\\' | '\n' | '\r' | '\t' | '\b' | '\u{0c}' => 2
    _ if c < ' ' => 6
    _ => char_utf8_length(c)
  }
}

///|
/// Writes `s` as the content of a JSON string: `"` and `\` escaped, and
/// control characters as escapes. A change to the escapes is made in
/// `json_char_length` too.
fn write_json_string_content(out : StringBuilder, s : String) -> Unit {
  for c in s {
    match c {
      '"' => out.write_string("\\\"")
      '\\' => out.write_string("\\\\")
      '\n' => out.write_string("\\n")
      '\r' => out.write_string("\\r")
      '\t' => out.write_string("\\t")
      '\b' => out.write_string("\\b")
      '\u{0c}' => out.write_string("\\f")
      _ if c < ' ' => {
        out.write_string("\\u00")
        out.write_string(c.to_int().to_string(radix=16).pad_start(2, '0'))
      }
      _ => out.write_char(c)
    }
  }
}

///|
/// Reads `bytes`, compact JSON in UTF-8 as `write_json` writes it, back
/// into a value. A number keeps its text when that is not the shortest form
/// of its value, as a helper's output or a big integer has, so the value
/// writes back as the same bytes.
fn read_compact_json(bytes : Bytes) -> Json {
  { bytes, i: 0, }.value()
}

///|
/// Reads compact JSON that smock wrote, from `i` on. It needs no checks:
/// the bytes are always valid.
priv struct CompactReader {
  bytes : Bytes
  mut i : Int32
}

///|
/// Reads the value at `i`.
fn CompactReader::value(self : CompactReader) -> Json {
  let bytes = self.bytes
  match bytes[self.i] {
    b'n' => {
      self.i += 4
      Json::null()
    }
    b't' => {
      self.i += 4
      Json::boolean(true)
    }
    b'f' => {
      self.i += 5
      Json::boolean(false)
    }
    b'"' => Json::string(self.string())
    b'[' => {
      self.i += 1
      let items = []
      if bytes[self.i] == b']' {
        self.i += 1
        return Json::array(items)
      }
      for ;; {
        items.push(self.value())
        // A `,` or the closing `]`.
        self.i += 1
        if bytes[self.i - 1] == b']' {
          break
        }
      }
      Json::array(items)
    }
    b'{' => {
      self.i += 1
      let members = Map([])
      if bytes[self.i] == b'}' {
        self.i += 1
        return Json::object(members)
      }
      for ;; {
        let key = self.string()
        // The `:`.
        self.i += 1
        members[key] = self.value()
        // A `,` or the closing `}`.
        self.i += 1
        if bytes[self.i - 1] == b'}' {
          break
        }
      }
      Json::object(members)
    }
    _ => self.number()
  }
}

///|
/// Reads the string at `i`, from its opening quote to its closing one.
fn CompactReader::string(self : CompactReader) -> String {
  let bytes = self.bytes
  let out = @buffer.Buffer()
  self.i += 1
  for ;; {
    let byte = bytes[self.i]
    self.i += 1
    match byte {
      b'"' => break
      b'\\' => {
        let escaped = bytes[self.i]
        self.i += 1
        match escaped {
          b'n' => out.write_byte(b'\n')
          b'r' => out.write_byte(b'\r')
          b't' => out.write_byte(b'\t')
          b'b' => out.write_byte(b'\x08')
          b'f' => out.write_byte(b'\x0c')
          b'u' => {
            // `\u00XX`, for a control character.
            let high = hex_value(bytes[self.i + 2].to_int().unsafe_to_char())
            let low = hex_value(bytes[self.i + 3].to_int().unsafe_to_char())
            self.i += 4
            out.write_byte((high * 16 + low).to_byte())
          }
          other => out.write_byte(other)
        }
      }
      other => out.write_byte(other)
    }
  }
  @utf8.decode_lossy(out.to_bytes())
}

///|
/// Reads the number at `i`, keeping its text when that is not the shortest
/// form of its value.
fn CompactReader::number(self : CompactReader) -> Json {
  let bytes = self.bytes
  let start = self.i
  while self.i < bytes.length() && !(bytes[self.i] is (b',' | b']' | b'}')) {
    self.i += 1
  }
  let text = @utf8.decode_lossy(bytes[start:self.i])
  let parsed = @json.parse(text) catch { _ => Json::null() }
  match parsed {
    Number(n, ..) if number_text(n, None) == text => Json::number(n)
    Number(n, ..) => Json::number(n, repr=text)
    // Written from a value that is not a JSON number, such as an infinity:
    // it keeps its text.
    _ => Json::number(0.0 / 0.0, repr=text)
  }
}
