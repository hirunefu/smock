// The Mockoon-equivalent lines of the `mockoon` log format: lines that copy
// what the Mockoon CLI writes, byte for byte where smock can, with `app`
// set to `smock`. Each is a string built by hand, never a JSON tree, with
// its keys in the order Mockoon's logger sorts them. The builders do no I/O
// and read no clock: the caller passes the time.

///|
/// The start of every Mockoon-equivalent line about a request the Mock
/// named `mock` answered, such as `{"app":"smock","environmentName":"users",`,
/// or, with `None`, of a line about a request no Mock answered:
/// `{"app":"smock",`. The server builds it once per Mock, when a definition
/// set loads, and every line about the Mock starts with it.
pub fn mockoon_prefix(mock : String?) -> String {
  match mock {
    Some(name) => {
      let out = StringBuilder(size_hint=name.length() + 40)
      out.write_string("{\"app\":\"smock\",\"environmentName\":")
      write_json_string(out, name, 0, name.length())
      out.write_char(',')
      out.to_string()
    }
    None => "{\"app\":\"smock\","
  }
}

///|
/// The `Server started on port <port>` line of the Mock whose prefix is
/// `prefix` (`mockoon_prefix`), with `port` the plain port smock listens
/// on, written at `at`, in milliseconds since the Unix epoch, such as
/// `{"app":"smock","environmentName":"users","level":"info","message":"Server started on port 8080","timestamp":"2026-10-31T09:00:00.105Z"}`.
pub fn started_line(prefix : String, port~ : Int32, at~ : Int64) -> String {
  let out = StringBuilder(size_hint=prefix.length() + 96)
  out.write_string(prefix)
  out.write_string("\"level\":\"info\",\"message\":\"Server started on port ")
  write_decimal(out, port.to_int64())
  out.write_string("\",\"timestamp\":\"")
  write_time(out, at)
  out.write_string("\"}")
  out.to_string()
}

///|
/// The `Server stopped` line of the Mock whose prefix is `prefix`
/// (`mockoon_prefix`), written at `at`, in milliseconds since the Unix
/// epoch, such as
/// `{"app":"smock","environmentName":"users","level":"info","message":"Server stopped","timestamp":"2026-10-31T09:10:00.004Z"}`.
pub fn stopped_line(prefix : String, at~ : Int64) -> String {
  let out = StringBuilder(size_hint=prefix.length() + 80)
  out.write_string(prefix)
  out.write_string(
    "\"level\":\"info\",\"message\":\"Server stopped\",\"timestamp\":\"",
  )
  write_time(out, at)
  out.write_string("\"}")
  out.to_string()
}

///|
/// How the request of a `Transaction recorded` line ended, as the line
/// says it: with the status of the response smock planned, which a
/// `partial` Fault writes too, or with a reset or a close Fault, which ends
/// the connection before any status is written.
pub(all) enum TransactionEnd {
  /// The response's status: `"responseStatus":<status>`.
  Status(Int32)
  /// A reset Fault: `"fault":"reset"`, and no `responseStatus`.
  Reset
  /// A close Fault: `"fault":"close"`, and no `responseStatus`.
  Close
}

///|
/// The `Transaction recorded` line of a request that `prefix`
/// (`mockoon_prefix`) says who answered, with the method `meth` and the
/// request target `target` as sent, which ended as `ended` says, written
/// at `at`, in milliseconds since the Unix epoch, such as
/// `{"app":"smock","environmentName":"users","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/users/1","requestProxied":false,"responseStatus":200,"timestamp":"2026-10-31T09:00:01.250Z"}`.
/// A reset or a close Fault puts `fault`, with the Journal's name for it,
/// between the prefix and `level`, and leaves out `responseStatus`.
pub fn transaction_line(
  prefix : String,
  meth~ : String,
  target~ : String,
  ended~ : TransactionEnd,
  at~ : Int64,
) -> String {
  let out = StringBuilder(size_hint=prefix.length() + target.length() + 192)
  out.write_string(prefix)
  match ended {
    Status(_) => ()
    Reset => out.write_string("\"fault\":\"reset\",")
    Close => out.write_string("\"fault\":\"close\",")
  }
  out.write_string(
    "\"level\":\"info\",\"message\":\"Transaction recorded\",\"requestMethod\":",
  )
  write_json_string(out, meth, 0, meth.length())
  out.write_string(",\"requestPath\":")
  let start = path_start(target)
  let end = query_start(target, start)
  if start == end {
    out.write_string("\"/\"")
  } else {
    write_json_string(out, target, start, end)
  }
  out.write_string(",\"requestProxied\":false,")
  if ended is Status(status) {
    out.write_string("\"responseStatus\":")
    write_decimal(out, status.to_int64())
    out.write_char(',')
  }
  out.write_string("\"timestamp\":\"")
  write_time(out, at)
  out.write_string("\"}")
  out.to_string()
}

///|
/// The `Error while serving the content: …` line of a request whose Stub's
/// template could not be rendered or whose data write could not be
/// applied, which `prefix` (`mockoon_prefix`) says the Mock of, with the
/// error's message `message`, as the 500's body gives it, the Stub's path
/// as written `path`, and the Stub ID `stub`, written at `at`, in
/// milliseconds since the Unix epoch, such as
/// `{"app":"smock","environmentName":"shop","level":"error","message":"Error while serving the content: body.customer.name is missing","routePath":"/orders","routeUUID":"create-order","timestamp":"2026-10-31T09:00:04.000Z"}`.
/// A Stub with no path condition, `None`, gets no `routePath`. The Stub ID
/// is not a UUID, but the key keeps Mockoon's name.
pub fn serving_error_line(
  prefix : String,
  message~ : String,
  path~ : String?,
  stub~ : String,
  at~ : Int64,
) -> String {
  let out = StringBuilder(
    size_hint=prefix.length() + message.length() + stub.length() + 160,
  )
  out.write_string(prefix)
  out.write_string(
    "\"level\":\"error\",\"message\":\"Error while serving the content: ",
  )
  write_json_escaped(out, message, 0, message.length())
  out.write_string("\",")
  if path is Some(path) {
    out.write_string("\"routePath\":")
    write_json_string(out, path, 0, path.length())
    out.write_char(',')
  }
  out.write_string("\"routeUUID\":")
  write_json_string(out, stub, 0, stub.length())
  out.write_string(",\"timestamp\":\"")
  write_time(out, at)
  out.write_string("\"}")
  out.to_string()
}

///|
/// Where the path of the request target `target` starts, as the engine
/// reads it for its conditions: after the scheme and the authority of an
/// absolute-form target, at the first `/`, `?` or `#` after them, or at the
/// end when none follows; otherwise at the start.
fn path_start(target : String) -> Int32 {
  let length = target.length()
  // The first `://`, which ends the scheme of an absolute-form target.
  let mut colon = -1
  for i in 0..<(length - 2) {
    if target.unsafe_get(i) == ':' &&
      target.unsafe_get(i + 1) == '/' &&
      target.unsafe_get(i + 2) == '/' {
      colon = i
      break
    }
  }
  if colon <= 0 {
    return 0
  }
  // A scheme is a letter, then letters, digits, `+`, `-` and `.`.
  for i in 0..<colon {
    let c = target.unsafe_get(i)
    let letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    let other = (c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.'
    if !(letter || (i > 0 && other)) {
      return 0
    }
  }
  for i in (colon + 3)..<length {
    let c = target.unsafe_get(i)
    if c == '/' || c == '?' || c == '#' {
      return i
    }
  }
  length
}

///|
/// Where the query of `target` starts: at its first `?` from `from` on, or
/// at the end when it has none.
fn query_start(target : String, from : Int32) -> Int32 {
  for i in from..<target.length() {
    if target.unsafe_get(i) == '?' {
      return i
    }
  }
  target.length()
}

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
    "app": "smock",
    "level": Json::string(level),
    "message": Json::string(msg),
    "timestamp": Json::string(format_time(at)),
  }
  for key, value in fields {
    // A field never replaces the envelope's keys; it moves aside instead.
    let key = if key is ("app" | "level" | "message" | "timestamp") {
      "fields.\{key}"
    } else {
      key
    }
    entry[key] = value
  }
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

///|
/// Writes the code units of `s` from `start` to `end` as a JSON string, in
/// quotes, escaped as JavaScript's `JSON.stringify` escapes them: `"` and
/// `\` with a backslash; `\b`, `\f`, `\n`, `\r` and `\t` by name; the other
/// control characters below U+0020 as `\u00xx`, in lower-case hex. Every
/// other code unit is written as it is, `/` and non-ASCII ones included.
/// Runs that need no escape are copied whole.
fn write_json_string(
  out : StringBuilder,
  s : String,
  start : Int32,
  end : Int32,
) -> Unit {
  out.write_char('"')
  write_json_escaped(out, s, start, end)
  out.write_char('"')
}

///|
/// Writes the code units of `s` from `start` to `end` escaped as
/// `write_json_string` escapes them, without the quotes, so that they can
/// follow text of the same JSON string, such as the fixed start of the
/// error line's message. The template package writes its JSON strings
/// with it too, and counts their bytes with its own `json_char_length`,
/// which a change to the escapes must follow.
pub fn write_json_escaped(
  out : StringBuilder,
  s : String,
  start : Int32,
  end : Int32,
) -> Unit {
  let mut run = start
  for i in start..<end {
    let c = s.unsafe_get(i)
    if c >= 0x20 && c != '"' && c != '\\' {
      continue
    }
    if run < i {
      out.write_view(s.view(start_offset=run, end_offset=i))
    }
    run = i + 1
    match c {
      '"' => out.write_string("\\\"")
      '\\' => out.write_string("\\\\")
      '\b' => out.write_string("\\b")
      '\u{0c}' => out.write_string("\\f")
      '\n' => out.write_string("\\n")
      '\r' => out.write_string("\\r")
      '\t' => out.write_string("\\t")
      _ => {
        out.write_string("\\u00")
        out.write_char(hex_digits[(c >> 4).to_int()])
        out.write_char(hex_digits[(c & 0xf).to_int()])
      }
    }
  }
  if run < end {
    out.write_view(s.view(start_offset=run, end_offset=end))
  }
}

///|
/// The lower-case hex digits, by value.
let hex_digits : FixedArray[Char] = [
  '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
]
