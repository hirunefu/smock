///|
/// A parsed XML document. Parse it once with `parse`, then select values
/// from it with any number of compiled paths.
pub struct Document {
  /// The root element.
  priv root : Element
}

///|
/// An element: its local name, its attributes, and its content in document
/// order.
priv struct Element {
  /// The local name: the qualified name without its prefix.
  name : String
  /// The attributes, in document order.
  attributes : Array[Attribute]
  /// The text and the child elements, in document order.
  children : Array[Node]
}

///|
/// An attribute of an element.
priv struct Attribute {
  /// The local name: the qualified name without its prefix.
  name : String
  /// The value, normalised.
  value : String
}

///|
/// A piece of an element's content.
priv enum Node {
  /// Character data and CDATA, with references decoded and line ends as
  /// line feeds.
  Text(String)
  Child(Element)
}

///|
/// Why bytes are not an XML document that the module accepts. `position`
/// is the byte offset in the input where the problem is, from 0, and
/// `message` says what the problem is.
pub(all) suberror ParseError {
  ParseError(position~ : Int, message~ : String)
} derive(Eq, Debug)

///|
/// Shows the error as `position <n>: <message>`.
pub impl Show for ParseError with fn output(self, logger) {
  let ParseError(position~, message~) = self
  logger.write_string("position \{position}: \{message}")
}

///|
/// Parses `input`, an XML 1.0 document in UTF-8, into a document whose
/// values `Document::select` reads.
///
/// The input must be well-formed XML, with these limits:
/// - It is UTF-8, optionally after a byte order mark. An XML declaration
///   that names another encoding is an error.
/// - Any DOCTYPE is an error, so no entity is ever declared or expanded.
///   The five predefined entities and character references are decoded.
/// - Elements nest at most 256 deep.
/// - Element and attribute names have at most one colon, between a prefix
///   and a local name. Prefixes are not resolved, so a prefix need not be
///   declared.
///
/// Comments and processing instructions are skipped, and CDATA is text.
/// Raises `ParseError` for input that breaks any of these rules or is not
/// well-formed.
///
/// Parsing does no I/O and ends with a document or an error for every
/// input. It takes time linear in the length of `input`, except that the
/// attribute names of a tag with more than eight attributes are sorted, in
/// O(n log n) time for n attributes, to find a repeated one.
pub fn parse(input : BytesView) -> Document raise ParseError {
  { root: Parser::{ input, pos: 0, names: [], offsets: [], }.document(), }
}
