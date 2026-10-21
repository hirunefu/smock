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
fn write_indented_json(out : @buffer.Buffer, json : Json, depth : Int) -> Unit {
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
fn write_line_start(out : @buffer.Buffer, depth : Int) -> Unit {
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
