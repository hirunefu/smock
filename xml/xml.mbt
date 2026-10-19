///|
/// A parsed XML document. Parse it once with `parse`, then select values
/// from it with any number of compiled paths.
///
/// It refers to the input rather than copying it, and keeps of it only
/// where each element's local name starts and how deep the element is:
/// five bytes per element. Values are read from the input when a path
/// selects them.
pub struct Document {
  /// The input, a well-formed document.
  priv input : BytesView
  /// Where the local name of each element starts in `input`, in document
  /// order: the order of their start tags, the root element's first.
  priv names : Array[Int]
  /// How deep each of them is, less one: 0 for the root element.
  priv depths : Array[Byte]
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
  let parser = Parser::new(input)
  parser.document()
  { input, names: parser.names, depths: parser.depths, }
}
