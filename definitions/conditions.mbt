///|
/// Validates and compiles request conditions given apart from a Stub, such
/// as those of a Journal filter: `json` in the shape of a Stub's `request`.
/// They mean what they mean in a Stub, and patterns are compiled the same
/// way.
///
/// Returns the conditions, or every problem found, with the messages a
/// Stub's conditions get. A problem has no file (`""`), and its JSON
/// Pointer points into `json`.
pub fn request_conditions(json : Json) -> Result[Conditions, Array[Diagnostic]] {
  let diagnostics = []
  let file = File::{ name: "", diagnostics, body_files: None, }
  let conditions = file.read_conditions("", json)
  if diagnostics.is_empty() {
    Ok(conditions)
  } else {
    Err(diagnostics)
  }
}
