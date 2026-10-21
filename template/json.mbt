// Writing JSON. smock writes every JSON body and every number itself, so
// that the bytes are the same on every target:
//
// - Compact: no space, members in the order written, strings in UTF-8.
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
/// A number as smock writes it: `repr`, the text it kept, when it has one,
/// otherwise the shortest form that reads back as the same 64-bit float.
fn number_text(n : Double, repr : String?) -> String {
  match repr {
    Some(text) => text
    None => n.to_string()
  }
}

///|
/// Writes `s` as the content of a JSON string: `"` and `\` escaped, and
/// control characters as escapes.
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
  mut i : Int
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
            let high = hex_digit(bytes[self.i + 2])
            let low = hex_digit(bytes[self.i + 3])
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

///|
/// The value of the hexadecimal digit `byte`, written in lower case as
/// `write_json_string_content` writes it.
fn hex_digit(byte : Byte) -> Int {
  let c = byte.to_int()
  if c >= '0'.to_int() && c <= '9'.to_int() {
    c - '0'.to_int()
  } else {
    c - 'a'.to_int() + 10
  }
}
