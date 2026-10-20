// Reading the request target: the path and the query parameters that Stub
// conditions are compared with. Decoding follows the WHATWG URL Standard:
// percent-decoding leaves a `%` that does not start an escape as it is, the
// decoded bytes are read as UTF-8, with U+FFFD for invalid sequences, and
// query parameters are parsed as application/x-www-form-urlencoded, where
// `+` stands for a space (see `urlencoded`).

///|
/// The percent-decoded path of a request target, as `path_of` finds it.
fn decoded_path(target : String) -> String {
  percent_decode(path_of(target))
}

///|
/// The query parameters of a request target, as decoded (name, value)
/// pairs, in order. A parameter without `=` has the empty value; empty
/// parameters, as between `&&`, are skipped.
fn query_parameters(target : String) -> Array[(String, String)] {
  match target.find("?") {
    // The target is ASCII, so its bytes are its characters.
    Some(i) => urlencoded(@utf8.encode(target[i + 1:]))
    None => []
  }
}

///|
/// Percent-decodes `s`, as `@percent.decode_lossy` does.
fn percent_decode(s : StringView) -> String {
  if s.contains_char('%') {
    @percent.decode_lossy(s)
  } else {
    s.to_owned()
  }
}
