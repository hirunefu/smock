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
/// Whether the path key `key`, written at `pointer`, is a path, or reports
/// why it is not: one that does not start with `/`, has unbalanced braces
/// or an empty `{}`, or holds `?` or `#`.
fn Report::path_key(self : Report, pointer : String, key : String) -> Bool {
  if !key.has_prefix("/") {
    self.error_at(pointer, "a path must start with /")
    return false
  }
  if key.contains_char('?') || key.contains_char('#') {
    self.error_at(
      pointer, "a path must not hold ? or #: a query or a fragment is not part of it",
    )
    return false
  }
  match template_pieces(key) {
    Ok(_) => true
    Err(Unbalanced) => {
      self.error_at(pointer, "a path has an unbalanced { or }")
      false
    }
    Err(EmptyName) => {
      self.error_at(pointer, "a path has an empty {}: a parameter needs a name")
      false
    }
  }
}

///|
/// A piece of a template, such as a path key `/pets/{petId}` or a server
/// URL `https://{host}/v1`.
priv enum Piece {
  /// Literal text, not empty.
  Literal(String)
  /// The name between a `{` and its `}`, such as `petId`.
  Name(String)
}

///|
/// Why a text is not a template.
priv enum TemplateError {
  /// A `{` or a `}` does not pair: a `}` with no `{` before it, a `{`
  /// inside braces, or a `{` that is not closed.
  Unbalanced
  /// An empty `{}`, which names nothing.
  EmptyName
}

///|
/// The pieces of the template `text`, in order: its literal texts and the
/// names in its braces. Or why it is not a template. Path keys and server
/// URLs are both such templates; each caller words its own message.
fn template_pieces(text : String) -> Result[Array[Piece], TemplateError] {
  let pieces : Array[Piece] = []
  let current = StringBuilder()
  let mut in_name = false
  for c in text {
    match (in_name, c) {
      (false, '{') => {
        let literal = current.to_string()
        if literal != "" {
          pieces.push(Literal(literal))
        }
        current.reset()
        in_name = true
      }
      (false, '}') | (true, '{') => return Err(Unbalanced)
      (true, '}') => {
        let name = current.to_string()
        if name == "" {
          return Err(EmptyName)
        }
        pieces.push(Name(name))
        current.reset()
        in_name = false
      }
      _ => current.write_char(c)
    }
  }
  if in_name {
    return Err(Unbalanced)
  }
  let literal = current.to_string()
  if literal != "" {
    pieces.push(Literal(literal))
  }
  Ok(pieces)
}

///|
/// The path that Stubs match for the path key `key`, whose braces are
/// balanced, put after `prefix`, which is decoded already. Without
/// parameters, it is the exact path. With them, it is a pattern in which
/// each `{name}` becomes `[^/]+`. Literal text, the prefix included, is
/// percent-decoded as smock decodes request paths, and in a pattern its
/// ASCII punctuation other than `/` is then escaped with `\`, so that
/// `/files/{name}.json` becomes `/files/[^/]+\.json`. Segments are split
/// at the `/` of the decoded text, as smock splits a request's decoded
/// path.
fn matched_path(key : String, prefix~ : String) -> Path {
  // Literal texts, decoded, and None for each parameter. The prefix comes
  // first, without being decoded again.
  let pieces : Array[String?] = [Some(prefix)]
  let exact = StringBuilder()
  exact.write_string(prefix)
  let mut names = 0
  // `path_key` checked the braces, so the key is a template.
  for piece in template_pieces(key).unwrap_or([Literal(key)]) {
    match piece {
      Literal(text) => {
        let text = decoded_path(text)
        pieces.push(Some(text))
        exact.write_string(text)
      }
      Name(_) => {
        pieces.push(None)
        names += 1
      }
    }
  }
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
  let condition = if names == 0 {
    PathCondition::Exact(exact.to_string())
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
