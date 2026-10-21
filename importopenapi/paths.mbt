///|
/// A path key of the document, as Stubs match it.
priv struct Path {
  /// The `path` condition of its Stubs.
  condition : PathCondition
  /// The kind of each segment of the path that Stubs match, from the
  /// left, by which operations are sorted.
  segments : Array[Segment]
}

///|
/// The `path` condition of a Stub.
priv enum PathCondition {
  /// A path without parameters: the exact path, percent-decoded as smock
  /// decodes request paths, so that the match index finds it.
  Exact(String)
  /// A path with parameters, such as `/pets/{petId}`: a pattern in which
  /// each parameter is `[^/]+`.
  Pattern(String)
}

///|
/// The kind of a segment of a path that Stubs match: of the text before
/// its first `/`, between two, or after its last. The kinds come in order:
/// a more specific one first.
priv enum Segment {
  /// Literal text only, or nothing.
  Literal
  /// Literal text and parameters, such as `{name}.json`, or several
  /// parameters, such as `{a}{b}`.
  Mixed
  /// One parameter, such as `{petId}`.
  Parameter
} derive(Eq, Compare)

///|
/// Reads the path key `key`, written at `pointer`, or reports why it is
/// not a path: one that does not start with `/`, has unbalanced braces or
/// an empty `{}`, or holds `?` or `#`.
fn Report::path(self : Report, pointer : String, key : String) -> Path? {
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
  let mut previous = ' '
  for c in key {
    match c {
      '{' if open => {
        self.root_error(pointer, "a path has an unbalanced { or }")
        return None
      }
      '{' => open = true
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
  Some(matched_path(key))
}

///|
/// The path that Stubs match for the path key `key`, whose braces are
/// balanced. Without parameters, it is the exact path. With them, it is a
/// pattern in which each `{name}` becomes `[^/]+`. Literal text is
/// percent-decoded as smock decodes request paths, and in a pattern its
/// ASCII punctuation other than `/` is then escaped with `\`, so that
/// `/files/{name}.json` becomes `/files/[^/]+\.json`. Segments are split
/// at the `/` of the decoded text, as smock splits a request's decoded
/// path.
fn matched_path(key : String) -> Path {
  // Literal texts, decoded, and None for each parameter.
  let pieces : Array[String?] = []
  let text = StringBuilder()
  let mut in_name = false
  for c in key {
    if in_name {
      in_name = c != '}'
    } else if c == '{' {
      pieces.push(Some(decoded_path(text.to_string())))
      pieces.push(None)
      text.reset()
      in_name = true
    } else {
      text.write_char(c)
    }
  }
  pieces.push(Some(decoded_path(text.to_string())))
  let pattern = StringBuilder()
  let segments = []
  let mut literal = false
  let mut parameters = 0
  for piece in pieces {
    match piece {
      None => {
        pattern.write_string("[^/]+")
        parameters += 1
      }
      Some(text) =>
        for c in text {
          if c == '/' {
            segments.push(segment(literal, parameters))
            literal = false
            parameters = 0
          } else {
            if is_ascii_punctuation(c) {
              pattern.write_char('\\')
            }
            literal = true
          }
          pattern.write_char(c)
        }
    }
  }
  segments.push(segment(literal, parameters))
  let condition = if pieces is [Some(path)] {
    PathCondition::Exact(path)
  } else {
    Pattern(pattern.to_string())
  }
  { condition, segments, }
}

///|
/// The kind of a segment that holds literal text or not, and `parameters`
/// parameters.
fn segment(literal : Bool, parameters : Int) -> Segment {
  match parameters {
    0 => Literal
    1 if !literal => Parameter
    _ => Mixed
  }
}

///|
/// Whether `c` is ASCII punctuation, which a pattern escapes so that it
/// stands for itself. `/` is not: a pattern writes it as it is.
fn is_ascii_punctuation(c : Char) -> Bool {
  match c {
    '!'..='.' | ':'..='@' | '['..='`' | '{'..='~' => true
    _ => false
  }
}

///|
/// Compares the paths that Stubs match by how specific they are, segment
/// by segment from the left: a literal segment comes first, then a mixed
/// one, then one parameter. When one path's kinds are a prefix of the
/// other's, the shorter path comes first. So an exact path comes before
/// every pattern that matches it.
fn compare_specificity(a : Array[Segment], b : Array[Segment]) -> Int {
  let shorter = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<shorter {
    let order = Compare::compare(a[i], b[i])
    if order != 0 {
      return order
    }
  }
  a.length().compare(b.length())
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
