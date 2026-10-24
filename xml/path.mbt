///|
/// A compiled path: element names from the root element down, then
/// optionally an attribute name. Compile it once with `compile_path`, then
/// select it in any number of documents with `Document::select`.
pub struct Path {
  /// The path as written.
  priv source : String
  /// The local names of the elements, the root element's first, in UTF-8,
  /// as selection compares them with a document.
  priv elements : Array[Bytes]
  /// The local name of the attribute in UTF-8, when the path ends in one.
  priv attribute : Bytes?
}

///|
/// Paths are equal when they are written the same.
pub impl Eq for Path with fn equal(self, other) {
  self.source == other.source
}

///|
/// Shows the path as it is written.
pub impl Show for Path with fn output(self, logger) {
  logger.write_string(self.source)
}

///|
/// Shows the path as it is written.
pub impl Debug for Path with fn to_repr(self) {
  Repr::ctor("Path", [(None, Repr::string(self.source))])
}

///|
/// Why a path does not compile. `position` is where in the path the
/// problem is, counted in characters (code points) from 0, and `message`
/// says what the problem is.
pub(all) suberror PathError {
  PathError(position~ : Int32, message~ : String)
} derive(Eq, Debug)

///|
/// Shows the error as `position <n>: <message>`.
pub impl Show for PathError with fn output(self, logger) {
  let PathError(position~, message~) = self
  logger.write_string("position \{position}: \{message}")
}

///|
/// Compiles `source`, a path such as `/order/item/@sku`: `/` and one or
/// more element names separated by `/`, optionally ending in `/@` and an
/// attribute name. Names are local names, without a prefix.
///
/// Raises `PathError` for anything else. XPath that the paths leave out,
/// such as `//`, wildcards, predicates, indexes, axes and functions, is an
/// error whose message says it is not supported. So is a final `@xmlns`:
/// `xmlns` names namespace declarations, which are not attributes here.
/// An attribute with a prefix and the local name `xmlns`, such as
/// `p:xmlns`, cannot be selected either.
pub fn compile_path(source : String) -> Path raise PathError {
  let chars : Array[Char] = source.iter().collect()
  let n = chars.length()
  if n == 0 || chars[0] != '/' {
    raise PathError(position=0, message="a path starts with /")
  }
  let elements = []
  let mut attribute = None
  let mut i = 0
  while i < n {
    // chars[i] is the / that starts a step.
    let slash = i
    if attribute is Some(_) {
      raise PathError(
        position=slash,
        message="an attribute step must come last",
      )
    }
    i += 1
    let is_attribute = i < n && chars[i] == '@'
    if is_attribute {
      if elements.is_empty() {
        raise PathError(
          position=i,
          message="a path names the root element first",
        )
      }
      i += 1
    }
    let start = i
    let expected = if is_attribute {
      "expected an attribute name"
    } else {
      "expected an element name"
    }
    if i == n {
      raise PathError(position=i, message=expected)
    }
    match chars[i] {
      '/' if !is_attribute => unsupported(slash, "// (descendants)")
      '*' => unsupported(i, "wildcard *")
      '.' if i + 1 < n && chars[i + 1] == '.' => unsupported(i, "step ..")
      '.' => unsupported(i, "step .")
      c if c == ':' || !is_name_start(c.to_int()) =>
        raise PathError(position=i, message=expected)
      _ => ()
    }
    while i < n && chars[i] != ':' && is_name_char(chars[i].to_int()) {
      i += 1
    }
    let name = String::from_array(chars[start:i])
    if i < n {
      match chars[i] {
        '/' => ()
        ':' if i + 1 < n && chars[i + 1] == ':' =>
          unsupported(start, "axis \{name}::")
        ':' =>
          raise PathError(
            position=start,
            message="prefix \{name}: is not supported in smock's XML paths; name the local name only",
          )
        '(' => unsupported(start, "function \{name}()")
        '[' => unsupported(i, "predicate or index [...]")
        _ =>
          raise PathError(
            position=i,
            message="expected / or the end of the path",
          )
      }
    }
    if is_attribute {
      // Namespace declarations are not attributes for selection, and a path
      // that seems to select them is refused rather than selecting nothing.
      if name == "xmlns" {
        raise PathError(
          position=start,
          message="@xmlns is not supported in smock's XML paths: xmlns names namespace declarations, which are not attributes here",
        )
      }
      attribute = Some(name)
    } else {
      elements.push(name)
    }
  }
  {
    source,
    elements: elements.map(name => @utf8.encode(name)),
    attribute: attribute.map(name => @utf8.encode(name)),
  }
}

///|
/// Raises the error for XPath syntax, named by `what`, that smock's paths
/// leave out.
fn unsupported(position : Int32, what : String) -> Unit raise PathError {
  raise PathError(
    position~,
    message="\{what} is not supported in smock's XML paths",
  )
}
