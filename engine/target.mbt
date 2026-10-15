// Reading the request target: the path and the query parameters that Stub
// conditions are compared with. Decoding follows the WHATWG URL Standard:
// percent-decoding leaves a `%` that does not start an escape as it is, the
// decoded bytes are read as UTF-8, with U+FFFD for invalid sequences, and
// query parameters are parsed as application/x-www-form-urlencoded, where
// `+` stands for a space.

///|
/// The percent-decoded path of a request target, as `path_of` finds it.
fn decoded_path(target : String) -> String {
  percent_decode(path_of(target), plus_is_space=false)
}

///|
/// The query parameters of a request target, as decoded (name, value)
/// pairs, in order. A parameter without `=` has the empty value; empty
/// parameters, as between `&&`, are skipped.
fn query_parameters(target : String) -> Array[(String, String)] {
  let out = []
  guard target.find("?") is Some(i) else { return out }
  for parameter in target[i + 1:].split("&") {
    if parameter.is_empty() {
      continue
    }
    let (name, value) = match parameter.find("=") {
      Some(j) => (parameter[:j], parameter[j + 1:])
      None => (parameter, "")
    }
    out.push(
      (
        percent_decode(name, plus_is_space=true),
        percent_decode(value, plus_is_space=true),
      ),
    )
  }
  out
}

///|
/// Percent-decodes `s`, as `@percent.decode_lossy` does. With
/// `plus_is_space`, `+` stands for a space.
fn percent_decode(s : StringView, plus_is_space~ : Bool) -> String {
  if plus_is_space && s.contains_char('+') {
    @percent.decode_lossy(s.to_owned().replace_all(old="+", new=" "))
  } else if s.contains_char('%') {
    @percent.decode_lossy(s)
  } else {
    s.to_owned()
  }
}
