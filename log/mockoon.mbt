// The Mockoon-equivalent lines of the `mockoon` log format: lines that copy
// what the Mockoon CLI writes, byte for byte where smock can, with `app`
// set to `smock`. Each is a string built by hand, never a JSON tree, with
// its keys in the order Mockoon's logger sorts them. The builders do no I/O
// and read no clock: the caller passes the time. The JSON string writers at
// the end also serve the envelope of smock's own entries (envelope.mbt)
// and the template package.

///|
/// The start of every Mockoon-equivalent line about a request the Mock
/// named `mock` answered, such as `{"app":"smock","environmentName":"users",`,
/// or, with `None`, of a line about a request no Mock answered:
/// `{"app":"smock",`. The server builds it once per Mock, when a definition
/// set loads, and every line about the Mock starts with it.
pub fn mockoon_prefix(mock : String?) -> String {
  let out = StringBuilder(size_hint=40)
  out.write_string("{\"app\":")
  write_json_string(out, app_name, 0, app_name.length())
  out.write_char(',')
  if mock is Some(name) {
    out.write_string("\"environmentName\":")
    write_json_string(out, name, 0, name.length())
    out.write_char(',')
  }
  out.to_string()
}

///|
/// The value of `app` on every line of the mockoon format, the envelope of
/// smock's own entries included.
let app_name = "smock"

///|
/// The `Server started on port <port>` line of the Mock whose prefix is
/// `prefix` (`mockoon_prefix`), with `port` the plain port smock listens
/// on, written at `at`, in milliseconds since the Unix epoch, such as
/// `{"app":"smock","environmentName":"users","level":"info","message":"Server started on port 8080","timestamp":"2026-10-31T09:00:00.105Z"}`.
pub fn started_line(prefix : String, port~ : Int32, at~ : Int64) -> String {
  let out = line_start(prefix, 96)
  out.write_string("\"level\":\"info\",\"message\":\"Server started on port ")
  write_decimal(out, port.to_int64())
  out.write_string("\",")
  line_end(out, at)
}

///|
/// The `Server stopped` line of the Mock whose prefix is `prefix`
/// (`mockoon_prefix`), written at `at`, in milliseconds since the Unix
/// epoch, such as
/// `{"app":"smock","environmentName":"users","level":"info","message":"Server stopped","timestamp":"2026-10-31T09:10:00.004Z"}`.
pub fn stopped_line(prefix : String, at~ : Int64) -> String {
  let out = line_start(prefix, 80)
  out.write_string("\"level\":\"info\",\"message\":\"Server stopped\",")
  line_end(out, at)
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
  let out = line_start(prefix, target.length() + 192)
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
  let parts = target_parts(target)
  if parts.path == parts.query {
    out.write_string("\"/\"")
  } else {
    write_json_string(out, target, parts.path, parts.query)
  }
  out.write_string(",\"requestProxied\":false,")
  if ended is Status(status) {
    out.write_string("\"responseStatus\":")
    write_decimal(out, status.to_int64())
    out.write_char(',')
  }
  line_end(out, at)
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
  let out = line_start(prefix, message.length() + stub.length() + 160)
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
  out.write_char(',')
  line_end(out, at)
}

///|
/// A builder for a Mockoon-equivalent line that starts with `prefix`
/// (`mockoon_prefix`), with room for `room` more characters.
fn line_start(prefix : String, room : Int32) -> StringBuilder {
  let out = StringBuilder(size_hint=prefix.length() + room)
  out.write_string(prefix)
  out
}

///|
/// Ends the Mockoon-equivalent line in `out` with its last key,
/// `timestamp`, the time `at` in milliseconds since the Unix epoch, and
/// returns the line. The keys before it end with a comma.
fn line_end(out : StringBuilder, at : Int64) -> String {
  out.write_string("\"timestamp\":\"")
  write_time(out, at)
  out.write_string("\"}")
  out.to_string()
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
///
/// It reads code units unchecked, so `start` and `end` must lie within
/// `s`, and copies them as they are, with `unsafe_view`: unlike
/// `exact_view`, that never aborts on a cut before a trailing surrogate.
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
      out.write_view(s.unsafe_view(start=run, end=i))
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
    out.write_view(s.unsafe_view(start=run, end~))
  }
}

///|
/// The lower-case hex digits, by value.
let hex_digits : FixedArray[Char] = [
  '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
]
