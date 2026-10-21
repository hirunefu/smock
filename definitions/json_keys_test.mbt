// Tests of the duplicate-key check for JSON text, which Definition files and
// the OpenAPI import share. They run on native and on wasm-gc.

///|
/// Where `text` first repeats a key, as a quoted JSON Pointer, or `none`.
fn duplicate_at(text : String) -> String {
  match @definitions.first_duplicate_key(text) {
    Some(pointer) => "at \"\{pointer}\""
    None => "none"
  }
}

///|
test "the first repeated key in a JSON text is found at its JSON Pointer, however deep in objects and arrays" {
  inspect(
    duplicate_at("{\"a\": [{\"b\": 1}, {\"c\": {\"d\": 1, \"d\": 2}}]}"),
    content="at \"/a/1/c/d\"",
  )
  inspect(duplicate_at("[[], {\"\": 1, \"\": 2}]"), content="at \"/1/\"")
  // The inner repeat comes first in the text, so it is the one named.
  inspect(
    duplicate_at("{\"k\": {\"x\": 1, \"x\": 2}, \"k\": 3}"),
    content="at \"/k/x\"",
  )
  // Names compare after escapes, and the pointer escapes `~` and `/`.
  inspect(
    duplicate_at("{\"a~b/c\": 1, \"a\\u007eb/c\": 2}"),
    content="at \"/a~0b~1c\"",
  )
}

///|
test "the same key in two objects, or inside a string, is no repeat" {
  inspect(
    duplicate_at(
      "{\"a\": 1, \"b\": {\"a\": 2}, \"c\": [{\"a\": 3}, {\"a\": 4}]}",
    ),
    content="none",
  )
  inspect(duplicate_at("[\"{\\\"a\\\": 1, \\\"a\\\": 2}\", 1]"), content="none")
}
