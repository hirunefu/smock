// Where the parts of a request target lie, which the engine reads for its
// conditions, the Admin API for its routes and the Transaction recorded
// line for its `requestPath`.

///|
/// Where the authority, the path and the query of a request target lie, as
/// indices into it (`target_parts`).
#valtype
pub struct TargetParts {
  /// Where the authority of an absolute-form target starts, right after
  /// its `://`, or -1 for any other target.
  authority : Int32
  /// Where the path starts: after the scheme and the authority of an
  /// absolute-form target, at the first `/`, `?` or `#` after them, or at
  /// the end when none follows; otherwise at the start.
  path : Int32
  /// Where the query starts: at the first `?` from `path` on, or at the end
  /// when there is none.
  query : Int32
}

///|
/// Where the parts of the request target `target` lie. A target whose
/// first `://` follows a scheme, a letter then letters, digits, `+`, `-`
/// and `.`, is in absolute form. Any other target, origin-form,
/// authority-form or `*`, has no authority, and its path starts at the
/// start, so that it is read as it was sent. It is a value type, so
/// finding the parts builds nothing.
///
/// ```mbt check
/// test {
///   let target = "http://users.example.com:8080/users/1?x=y"
///   let parts = @log.target_parts(target)
///   inspect(target[parts.authority:parts.path], content="users.example.com:8080")
///   inspect(target[parts.path:parts.query], content="/users/1")
///   inspect(@log.target_parts("/users/1").authority, content="-1")
/// }
/// ```
pub fn target_parts(target : String) -> TargetParts {
  let authority = authority_start(target)
  let path = if authority < 0 { 0 } else { path_start(target, authority) }
  { authority, path, query: query_start(target, path), }
}

///|
/// Where the authority of `target` starts, right after its first `://`,
/// when a scheme comes before it; otherwise -1.
fn authority_start(target : String) -> Int32 {
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
    return -1
  }
  // A scheme is a letter, then letters, digits, `+`, `-` and `.`.
  for i in 0..<colon {
    let c = target.unsafe_get(i)
    let letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    let other = (c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.'
    if !(letter || (i > 0 && other)) {
      return -1
    }
  }
  colon + 3
}

///|
/// Where the path of `target` starts when its authority starts at
/// `authority`: at the first `/`, `?` or `#` from there on, or at the end
/// when none follows.
fn path_start(target : String, authority : Int32) -> Int32 {
  for i in authority..<target.length() {
    let c = target.unsafe_get(i)
    if c == '/' || c == '?' || c == '#' {
      return i
    }
  }
  target.length()
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
