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
    Some(name) => "{\"app\":\"smock\",\"environmentName\":\"\{name}\","
    None => "{\"app\":\"smock\","
  }
}

///|
/// The `Transaction recorded` line of a request that `prefix`
/// (`mockoon_prefix`) says who answered, with the method `meth` and the
/// request target `target` as sent, answered with `status`, written at
/// `at`, in milliseconds since the Unix epoch, such as
/// `{"app":"smock","environmentName":"users","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/users/1","requestProxied":false,"responseStatus":200,"timestamp":"2026-10-31T09:00:01.250Z"}`.
pub fn transaction_line(
  prefix : String,
  meth~ : String,
  target~ : String,
  status~ : Int32,
  at~ : Int64,
) -> String {
  let out = StringBuilder(size_hint=prefix.length() + target.length() + 192)
  out.write_string(prefix)
  out.write_string(
    "\"level\":\"info\",\"message\":\"Transaction recorded\",\"requestMethod\":\"",
  )
  out.write_string(meth)
  out.write_string("\",\"requestPath\":\"")
  let start = path_start(target)
  let end = query_start(target, start)
  if start == end {
    out.write_char('/')
  } else {
    out.write_view(target.view(start_offset=start, end_offset=end))
  }
  out.write_string("\",\"requestProxied\":false,\"responseStatus\":")
  out.write_string(status.to_string())
  out.write_string(",\"timestamp\":\"")
  out.write_string(format_time(at))
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
