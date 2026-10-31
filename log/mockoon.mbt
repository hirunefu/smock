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
  let path = match target.find("?") {
    Some(i) => target[:i].to_owned()
    None => target
  }
  "\{prefix}\"level\":\"info\",\"message\":\"Transaction recorded\",\"requestMethod\":\"\{meth}\",\"requestPath\":\"\{path}\",\"requestProxied\":false,\"responseStatus\":\{status},\"timestamp\":\"\{format_time(at)}\"}"
}
