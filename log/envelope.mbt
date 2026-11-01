// The envelope of smock's own entries in the `mockoon` log format: a JSON
// tree with Mockoon's keys and the entry's fields, written with the keys
// sorted at every depth, as Mockoon's logger sorts them.

///|
/// The entry `msg` at `level`, with `fields`, written at `at`, in
/// milliseconds since the Unix epoch, in Mockoon's envelope: one JSON
/// object with `app` (`"smock"`), `level`, `message` and `timestamp` and the
/// fields beside them, with the keys sorted at every depth. A field named
/// `app`, `level`, `message` or `timestamp` is written as `fields.<name>`.
fn mockoon_entry(
  level : String,
  msg : String,
  fields : Map[String, Json],
  at : Int64,
) -> String {
  let entry : Map[String, Json] = {
    "app": Json::string(app_name),
    "level": Json::string(level),
    "message": Json::string(msg),
    "timestamp": Json::string(format_time(at)),
  }
  add_fields(entry, fields, Mockoon)
  let out = StringBuilder()
  write_sorted(out, Json::object(entry))
  out.to_string()
}

///|
/// Writes `value` to `out` as compact JSON, with the keys of every object
/// in it sorted in UTF-16 code-unit order and arrays in their own order:
/// strings escaped as `write_json_string` escapes them, and numbers, `true`,
/// `false` and `null` as `Json::stringify` writes them, so that a number
/// with its own text, such as a large seed, keeps every digit.
fn write_sorted(out : StringBuilder, value : Json) -> Unit {
  match value {
    Object(members) => {
      let members = members.to_array()
      members.sort_by((a, b) => code_unit_order(a.0, b.0))
      out.write_char('{')
      for i, pair in members {
        if i > 0 {
          out.write_char(',')
        }
        let (key, value) = pair
        write_json_string(out, key, 0, key.length())
        out.write_char(':')
        write_sorted(out, value)
      }
      out.write_char('}')
    }
    Array(items) => {
      out.write_char('[')
      for i, item in items {
        if i > 0 {
          out.write_char(',')
        }
        write_sorted(out, item)
      }
      out.write_char(']')
    }
    String(s) => write_json_string(out, s, 0, s.length())
    _ => out.write_string(value.stringify())
  }
}

///|
/// How `a` and `b` compare in UTF-16 code-unit order, as JavaScript
/// compares strings: by their first differing code unit, or, when one is
/// the start of the other, the shorter first. Upper-case ASCII letters
/// sort before lower-case ones.
fn code_unit_order(a : String, b : String) -> Int32 {
  let length = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<length {
    let x = a.unsafe_get(i)
    let y = b.unsafe_get(i)
    if x != y {
      return x.compare(y)
    }
  }
  a.length().compare(b.length())
}
