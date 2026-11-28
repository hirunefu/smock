///|
/// Parses `text` and shows the error as `to_string` does, or `valid`.
fn shown(text : String) -> String {
  try @yaml.parse(text) catch {
    error => error.to_string()
  } noraise {
    _ => "valid"
  }
}

///|
test "an error is shown as <pointer>: <message>, or as its message alone when its pointer is the whole document's" {
  // Source: the doc comments of `impl Show for ParseError` and of
  // `impl Show for WriteError` (yaml/yaml.mbt): "`<pointer>: <message>`, or
  // `<message>` when the pointer is `""`". The pointers are RFC 6901's:
  // `""` is the whole document and `/` the member whose key is empty
  // (section 5), so `/` is no empty pointer. ParseError's doc comment: the
  // pointer of an ambiguous plain scalar names that value, and it is `""`
  // for the whole document. The message's words are those of parse's doc
  // example (`/enabled: "yes" may be read as a boolean; quote this value`).
  inspect(
    ["enabled: yes", "\"\": yes", "yes"]
    .map(text => "\{text} -> \{shown(text)}")
    .join("\n"),
    content=(
      #|enabled: yes -> /enabled: "yes" may be read as a boolean; quote this value
      #|"": yes -> /: "yes" may be read as a boolean; quote this value
      #|yes -> "yes" may be read as a boolean; quote this value
    ),
  )
  // No document gives the words of write's messages, so these errors are
  // made here, with the pointers of an item, of the member whose key is
  // empty and of the whole tree ("The pointer is `""` for the whole tree",
  // WriteError's doc comment).
  inspect(
    ["/stubs/0", "/", ""]
    .map(pointer => @yaml.WriteError(pointer~, message="a message").to_string())
    .join("\n"),
    content=(
      #|/stubs/0: a message
      #|/: a message
      #|a message
    ),
  )
}
