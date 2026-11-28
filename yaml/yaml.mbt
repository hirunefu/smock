///|
/// Why `parse` does not read a text as a YAML document, in the safe subset
/// or in the mode for OpenAPI documents: a JSON Pointer (RFC 6901) to the
/// value the problem is about, and a message.
///
/// For a value that is not read, such as a tag or an ambiguous plain
/// scalar, the pointer names that value; for a key, it names the member.
/// A key written over several lines, which YAML allows only on one line,
/// names the member by its text with the lines folded, as a scalar over
/// several lines is read: `a\n b: 1` gives `/a b`. For a syntax error, it
/// names the deepest node the parser reached. It is `""` for the whole
/// document.
#derive(Debug, Eq)
pub(all) suberror ParseError {
  ParseError(pointer~ : String, message~ : String)
}

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
/// reads them as null; write `null`), tabs in indentation (the white space
/// between a `-` and a mapping or a sequence that starts on its line is
/// indentation too), control characters, and nesting deeper than 1024
/// collections, the limit of `@json.parse`.
///
/// Rejected too, on purpose, though YAML allows them: a text with no
/// document, such as an empty one or one of comments only; a key that is a
/// collection, such as `[a, b]: 1`; a `key: value` pair in a flow sequence
/// without braces (a single pair mapping), such as `[a: 1]`; a key of a
/// flow mapping written over several lines, such as a plain key whose `:`
/// is on the next line; a tab in the white space at the start of a line,
/// even where YAML reads it as separation rather than as indentation; and
/// a line of white space whose tab comes before a block scalar's
/// indentation, with nothing after it but empty lines, comments and the
/// `...` that may end the document, as when `a: |` and `  x` are followed
/// by a last line of a space and a tab. YAML 1.2.2 reads that line as a
/// comment line after the document (`l-yaml-stream`, production 211);
/// `parse` rejects it as a tab in indentation, as libyaml and PyYAML do.
///
/// With `openapi=true`, `parse` reads the text as OpenAPI asks YAML to be
/// read: by the YAML 1.2 core schema, with every key a string. This mode is
/// for OpenAPI documents only; Definition files never use it. It differs
/// from the safe subset in these ways, and in no other:
/// - Plain scalars are typed by the YAML 1.2 core schema:
///   - null: `null`, `Null`, `NULL`, `~`, and an empty value;
///   - booleans: `true`, `True`, `TRUE`, `false`, `False` and `FALSE`;
///   - numbers: decimal integers and floats, such as `007`, `+1`, `-.5`,
///     `1.` and `1e3`, read as the same number in JSON syntax, so that a
///     decimal integer beyond 2^53 keeps its digits; and hexadecimal
///     (`0x1F`) and octal (`0o17`) integers up to 2^53 - 1;
///   - errors, since JSON cannot hold them: hexadecimal and octal integers
///     above 2^53 - 1, and `.inf`, `-.inf`, `.nan` in each spelling;
///   - strings: every other plain scalar, such as `yes`, `on`, `2020-01-01`,
///     `1_000` and `0b1010`.
/// - Every key is a string, plain or quoted, so `200:` is the key `"200"`
///   and `true:` the key `"true"`.
/// - A block scalar header may have an indentation indicator, before or
///   after its chomping indicator, as in `|2` or `>-1`. The content is then
///   indented by that many spaces more than the collection the scalar is
///   in, and the spaces beyond that are part of the text.
/// - The messages for anchors and aliases suggest `$ref`, which OpenAPI
///   has for reusing a part.
///
/// Parsing is linear in the length of `text`, does no I/O, and ends with a
/// value or an error for every input.
///
/// `parse` also holds to these rules, in both modes unless a rule names one:
/// - A key with nothing written, as in `: value`, is rejected as an empty
///   value is, with "a key must not be empty". This holds in the mode for
///   OpenAPI documents too, where an empty value is null, since every key
///   there is a string.
/// - A key that repeats in a mapping is rejected at the later key, with
///   "duplicate key". Keys are compared as the strings they read as, so
///   `a:` and `"a":` repeat each other.
/// - The members of a mapping are read in the order they are written.
/// - A `#` starts a comment only at the start of a line or after a space
///   or a tab (YAML 1.2.2, section 6.6). Right after other text of a plain
///   scalar, it is part of the scalar, as in `path: /a#b`; anywhere else,
///   such as right after a quoted value or a flow collection, it is
///   rejected with "a comment needs a space before its #".
/// - A byte order mark (U+FEFF) is dropped as the first character of the
///   text. Anywhere else, it is text inside a quoted scalar, as YAML 1.2.2
///   allows (section 5.2), and rejected outside one. A second mark at the
///   start of the text, and a mark in a plain scalar or key, a comment or a
///   block scalar's content, are rejected with "U+FEFF is a byte order
///   mark; write it as an escape in a double-quoted value". Elsewhere, as
///   right after a quoted scalar or a flow collection, or in a block
///   scalar's header, it is rejected with the message that the place gives
///   any other character.
/// - A block scalar whose last line ends the text without a line break
///   gets no line break added, as YAML 1.2.2 says (section 8.1.1.2), with
///   each chomping indicator: a text that ends with `a: |` and then `  x`,
///   with no line break after it, reads `a` as `"x"`.
/// - In the mode for OpenAPI documents, a plain scalar that JSON cannot
///   hold, such as `.inf`, `.NaN` or a hexadecimal or octal integer above
///   2^53 - 1, is rejected with a message that ends in "quote this value".
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
///   let document =
///     #|responses:
///     #|  200:
///     #|    description: |2
///     #|        indented code
///     #|      text
///     #|    example: {born: 2020-01-01, code: 007, tag: ~, legacy: yes}
///   inspect(
///     @yaml.parse(document, openapi=true).stringify(),
///     content=(
///       #|{"responses":{"200":{"description":"  indented code\ntext\n","example":{"born":"2020-01-01","code":7,"tag":null,"legacy":"yes"}}}}
///     ),
///   )
/// }
/// ```
pub fn parse(
  text : StringView,
  openapi~ : Bool = false,
) -> Json raise ParseError {
  Parser(text, openapi~).document()
}

///|
/// Why a tree cannot be written as a YAML document that `parse` reads back
/// as the same tree: a JSON Pointer (RFC 6901) to the value the problem is
/// about, and a message. The pointer is `""` for the whole tree.
#derive(Debug, Eq)
pub(all) suberror WriteError {
  WriteError(pointer~ : String, message~ : String)
}

///|
/// `<pointer>: <message>`, or `<message>` when the pointer is `""`.
pub impl Show for WriteError with fn output(self, logger) {
  let WriteError(pointer~, message~) = self
  if pointer != "" {
    logger.write_string(pointer)
    logger.write_string(": ")
  }
  logger.write_string(message)
}

///|
/// Writes `value` as one YAML document, in UTF-8, that `parse` reads back as
/// the same tree: the same members in the same order, and numbers with the
/// same text.
///
/// Layout: block style, two spaces per level. A mapping or sequence that is
/// an item of a sequence starts on the line of its `-`. Empty collections
/// are `{}` and `[]`; there are no other flow collections and no block
/// scalars. Lines end with LF, the last one too, and the bytes are the same
/// on every target.
///
/// Quoting: a string or a key is written plain when `parse` reads it back,
/// in that place, as the same string, and double-quoted otherwise. So
/// `"404"`, `"yes"`, `"on"`, `"null"`, `""` and `"2000-01-01"` are quoted,
/// and so are strings with leading or trailing spaces, with `: ` or ` #`,
/// or that start with an indicator such as `-`, `&`, `[` or `"`. A string
/// that holds a control character, a tab or a line break is quoted too.
/// Inside double quotes, `"`, `\`, control characters, U+2028, U+2029,
/// U+FEFF, U+FFFE and U+FFFF are escapes, such as `\n`, `\t`, `\e`, `\x01`
/// and `\uFEFF`. Every other character is written as itself.
///
/// Numbers: `repr`, the text a number was read from, when it has one. The
/// JSON parser keeps it for an integer beyond 2^53, so its digits stay the
/// same. Every other number takes the shortest form that reads back as the
/// same 64-bit float, as smock writes JSON numbers.
///
/// Comments: `comment` gives the lines of a comment at the top of the
/// document. `item_comments` gives the lines of a comment before items of
/// sequences, by the JSON Pointer of the item, such as `/stubs/0`. In a
/// comment, control characters (C0, DEL and C1), U+2028 and U+2029, and the
/// other characters that YAML does not allow, become spaces, and trailing
/// spaces are dropped. So a comment never changes the document.
///
/// Errors, each with the pointer of the value or of the comment:
/// - nesting deeper than 1024 collections, empty ones included, the limit
///   of `parse`;
/// - a number that is NaN or infinite and has no `repr`, or whose `repr` is
///   not a number in JSON syntax;
/// - a string or key with half of a surrogate pair, which UTF-8 cannot hold;
/// - a pointer in `item_comments` that names no item of a sequence.
///
/// Writing does no I/O.
///
/// ```mbt check
/// test {
///   let tree = @json.parse(
///     (
///       #|{ "stubs": [{ "id": "a", "request": { "method": "GET", "path": "/users/1" },
///       #|              "response": { "status": 200, "headers": { "X-Id": "1" },
///       #|                            "json": { "on": "yes", "tags": [] } } }] }
///     ),
///   )
///   let bytes = @yaml.write(tree, comment=["Users"], item_comments={
///     "/stubs/0": ["GET /users/1"],
///   })
///   inspect(
///     @utf8.decode(bytes),
///     content=(
///       #|# Users
///       #|stubs:
///       #|  # GET /users/1
///       #|  - id: a
///       #|    request:
///       #|      method: GET
///       #|      path: /users/1
///       #|    response:
///       #|      status: 200
///       #|      headers:
///       #|        X-Id: "1"
///       #|      json:
///       #|        "on": "yes"
///       #|        tags: []
///       #|
///     ),
///   )
///   assert_eq(@yaml.parse(@utf8.decode(bytes)), tree)
/// }
/// ```
pub fn write(
  value : Json,
  comment~ : Array[String] = [],
  item_comments~ : Map[String, Array[String]] = {},
) -> Bytes raise WriteError {
  Writer(item_comments).document(value, comment)
}
