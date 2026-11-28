///|
/// The testee reads a case's input in both modes, and answers with one line
/// of JSON. The values come from `@yaml.parse`'s documentation: its first
/// example document, read the same in both modes; and `enabled: yes`, which
/// the safe subset refuses with the message it shows, while the YAML 1.2 core
/// schema of the mode for OpenAPI documents reads `yes` as a string.
test "a case's answer gives what each mode reads, or its refusal" {
  inspect(
    answer("2SXE", @utf8.encode("mock: users\nhosts: [users.example]\n")),
    content=(
      #|{"case":"2SXE","safe":{"value":{"mock":"users","hosts":["users.example"]}},"openapi":{"value":{"mock":"users","hosts":["users.example"]}}}
    ),
  )
  inspect(
    answer("9KAX", @utf8.encode("enabled: yes")),
    content=(
      #|{"case":"9KAX","safe":{"error":{"pointer":"/enabled","message":"\"yes\" may be read as a boolean; quote this value"}},"openapi":{"value":{"enabled":"yes"}}}
    ),
  )
}

///|
/// smock reads a Definition file and an OpenAPI document only as UTF-8
/// (definitions/read.mbt and importopenapi/document.mbt refuse one that is
/// not, before the parser sees it), so the testee skips such an input in
/// both modes. 0xFF is never part of UTF-8 (RFC 3629, section 1).
test "an input that is not UTF-8 is skipped in both modes" {
  inspect(
    answer("bad", b"a: \xFF"),
    content=(
      #|{"case":"bad","safe":{"skipped":"not valid UTF-8"},"openapi":{"skipped":"not valid UTF-8"}}
    ),
  )
}

///|
/// smock drops one byte order mark at the start of a Definition file and of
/// an OpenAPI document in YAML, and no more: definitions/read.mbt and
/// importopenapi/document.mbt both give the parser the text with its mark,
/// as the maintainer decided for `smock import-openapi` on 2026-11-28 (#437,
/// the thirtieth round of #275's answers). `@yaml.parse`'s documentation
/// says that the parser drops a mark that is the text's first character and
/// rejects a second at the start with "U+FEFF is a byte order mark; write
/// it as an escape in a double-quoted value", words the maintainer
/// confirmed the same day; the whole text is the deepest node reached.
test "an input may start with one byte order mark, and no more, in both modes" {
  inspect(
    answer("one", b"\xef\xbb\xbfa: 1"),
    content=(
      #|{"case":"one","safe":{"value":{"a":1}},"openapi":{"value":{"a":1}}}
    ),
  )
  inspect(
    answer("two", b"\xef\xbb\xbf\xef\xbb\xbfa: 1"),
    content=(
      #|{"case":"two","safe":{"error":{"pointer":"","message":"U+FEFF is a byte order mark; write it as an escape in a double-quoted value"}},"openapi":{"error":{"pointer":"","message":"U+FEFF is a byte order mark; write it as an escape in a double-quoted value"}}}
    ),
  )
}
