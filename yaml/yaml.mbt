///|
/// Why a text is not a YAML document in the safe subset: a JSON Pointer
/// (RFC 6901) to the value the problem is about, and a message.
///
/// For a value outside the subset, such as a tag or an ambiguous plain
/// scalar, the pointer names that value; for a key, it names the member.
/// For a syntax error, it names the deepest node the parser reached. It is
/// `""` for the whole document.
pub(all) suberror ParseError {
  ParseError(pointer~ : String, message~ : String)
} derive(Debug, Eq)

///|
/// `<pointer>: <message>`, or `<message>` when the pointer is `""`.
pub impl Show for ParseError with fn output(self, logger) {
  let ParseError(pointer~, message~) = self
  if pointer != "" {
    logger.write_string(pointer)
    logger.write_string(": ")
  }
  logger.write_string(message)
}

///|
/// Parses one YAML document written in a safe subset of YAML into the tree
/// `@json.parse` gives for the equivalent JSON. The subset keeps a
/// document's meaning the same in every YAML version and parser.
///
/// Supported:
/// - block mappings and sequences, and flow mappings `{...}` and sequences
///   `[...]`;
/// - plain, single-quoted and double-quoted scalars, with the escapes of
///   YAML 1.2 (which include those of JSON);
/// - `|` (literal) and `>` (folded) block scalars, with the `-` (strip) and
///   `+` (keep) chomping indicators;
/// - comments, and one document, which may start with `---` and end with
///   `...`.
///
/// Typing: plain `true`, `false`, `null` and numbers in JSON syntax are
/// typed as JSON types them. Quoted scalars are always strings. Any other
/// plain scalar that YAML 1.1 or 1.2 would type is rejected with "quote
/// this value": `yes`, `no`, `on`, `off`, `y` and `n` in any case, `~`,
/// other spellings of `true`, `false` and `null` such as `True` or `NULL`,
/// numbers such as `0x1F`, `0o17`, `007`, `1_000`, `+1`, `.5`, `.inf`,
/// `.nan` and `1:30`, and timestamps such as `2001-12-14`. Every other plain
/// scalar is a string. Mapping keys are strings, so a plain key that is not
/// a string in every YAML version is rejected with "quote this key".
///
/// Rejected, each with a message naming it: anchors, aliases, tags, merge
/// keys (`<<`), duplicate keys, multiple documents, directives, explicit
/// keys (`?`), block scalar indentation indicators, empty values (YAML
/// reads them as null; write `null`), tabs in indentation, control
/// characters, and nesting deeper than 1024 collections, the limit of
/// `@json.parse`.
///
/// Parsing is linear in the length of `text`, does no I/O, and ends with a
/// value or an error for every input.
///
/// ```mbt check
/// test {
///   let text =
///     #|mock: users
///     #|hosts: [users.example]
///     #|body: |
///     #|  {"id": 1}
///     #|status: 200
///     #|enabled: true
///   inspect(
///     @yaml.parse(text).stringify(),
///     content=(
///       #|{"mock":"users","hosts":["users.example"],"body":"{\"id\": 1}\n","status":200,"enabled":true}
///     ),
///   )
///   let error = try @yaml.parse("enabled: yes") catch {
///     error => error.to_string()
///   } noraise {
///     _ => "valid"
///   }
///   inspect(
///     error,
///     content=(
///       #|/enabled: "yes" may be read as a boolean; quote this value
///     ),
///   )
/// }
/// ```
pub fn parse(text : StringView) -> Json raise ParseError {
  Parser::new(text).document()
}
