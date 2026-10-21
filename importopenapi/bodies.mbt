///|
/// The response headers that are not imported, without a warning: OpenAPI
/// says to skip `Content-Type`, and smock sets the others itself.
/// Documenting them is common and right.
let headers_smock_sets : Array[String] = [
  "content-type", "content-length", "transfer-encoding", "connection",
]

///|
/// Reads the main response `json` at `pointer`. Until bodies and headers
/// are imported, each media type of its content and each header it
/// documents is left out, with a warning that names it.
fn Report::main_response_parts(
  self : Report,
  pointer : String,
  json : Json,
) -> Unit {
  guard json is Object(response) else {
    self.root_error(pointer, "must be an object")
    return
  }
  if self.reference(pointer, response) {
    return
  }
  for field, value in response {
    let field_pointer = @definitions.child_pointer(pointer, field)
    match (field, value) {
      ("content", Object(content)) =>
        for media_type, _ in content {
          self.root_warning(
            @definitions.child_pointer(field_pointer, media_type),
            "left out: response bodies are not imported yet",
          )
        }
      ("headers", Object(headers)) =>
        for name, _ in headers {
          if !headers_smock_sets.contains(name.to_lower()) {
            self.root_warning(
              @definitions.child_pointer(field_pointer, name),
              "left out: response headers are not imported yet",
            )
          }
        }
      ("content" | "headers", _) =>
        self.root_error(field_pointer, "must be an object")
      _ => ()
    }
  }
}
