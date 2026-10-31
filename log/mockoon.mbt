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
    write_padded(out, status.to_int64(), 1)
    out.write_char(',')
  }
  out.write_string("\"timestamp\":\"")
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
  out.write_char('"')
}

///|
/// The lower-case hex digits, by value.
let hex_digits : FixedArray[Char] = [
  '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
]
