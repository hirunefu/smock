///|
/// A path key of the document, as a Stub matches it.
priv enum PathKind {
  /// A path without parameters: the exact path, percent-decoded as smock
  /// decodes request paths, so that the match index finds it.
  Exact(String)
  /// A path with parameters, such as `/pets/{petId}`.
  Templated
}

///|
/// Reads the path key `key`, written at `pointer`, or reports why it is
/// not a path: one that does not start with `/`, has unbalanced braces or
/// an empty `{}`, or holds `?` or `#`.
fn Report::path(self : Report, pointer : String, key : String) -> PathKind? {
  if !key.has_prefix("/") {
    self.root_error(pointer, "a path must start with /")
    return None
  }
  if key.contains_char('?') || key.contains_char('#') {
    self.root_error(
      pointer, "a path must not hold ? or #: a query or a fragment is not part of it",
    )
    return None
  }
  let mut open = false
  let mut templated = false
  let mut previous = ' '
  for c in key {
    match c {
      '{' if open => {
        self.root_error(pointer, "a path has an unbalanced { or }")
        return None
      }
      '{' => {
        open = true
        templated = true
      }
      '}' if !open => {
        self.root_error(pointer, "a path has an unbalanced { or }")
        return None
      }
      '}' if previous == '{' => {
        self.root_error(
          pointer, "a path has an empty {}: a parameter needs a name",
        )
        return None
      }
      '}' => open = false
      _ => ()
    }
    previous = c
  }
  if open {
    self.root_error(pointer, "a path has an unbalanced { or }")
    return None
  }
  if templated {
    Some(Templated)
  } else {
    Some(Exact(decoded_path(key)))
  }
}

///|
/// `path` percent-decoded as smock decodes the path of a request: a `%`
/// that does not start an escape stays as it is, and the decoded bytes are
/// read as UTF-8, with U+FFFD for invalid sequences.
fn decoded_path(path : String) -> String {
  if path.contains_char('%') {
    @percent.decode_lossy(path)
  } else {
    path
  }
}

///|
/// Reports the `servers` of `object`, at `pointer`, a document, a Path Item
/// or an operation. Until the paths of servers are read, none is added as a
/// prefix, so a non-empty list is left out with a warning.
fn Report::servers_left_out(
  self : Report,
  pointer : String,
  object : Map[String, Json],
) -> Unit {
  if object.get("servers") is Some(Array(servers)) && !servers.is_empty() {
    self.root_warning(
      @definitions.child_pointer(pointer, "servers"),
      "left out: the paths of servers are not added as a prefix yet",
    )
  }
}
