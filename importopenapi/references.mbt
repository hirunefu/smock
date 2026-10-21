///|
/// Reports a `$ref` in `object`, at `pointer`, where the converter reads a
/// Reference Object, and returns whether there was one. Until references
/// are followed, it is an error.
fn Report::reference(
  self : Report,
  pointer : String,
  object : Map[String, Json],
) -> Bool {
  guard object.contains("$ref") else { return false }
  self.root_error(
    @definitions.child_pointer(pointer, "$ref"),
    "references are not followed yet: write the part it names in its place",
  )
  true
}
