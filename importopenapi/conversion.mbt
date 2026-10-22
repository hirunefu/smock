///|
/// One round of a conversion: its options, the documents given, those that
/// references name and that were not given, the root document, parsed, and
/// the report of the problems found so far. The converter's steps are its
/// methods.
priv struct Conversion {
  options : Options
  /// The documents given to the conversion.
  documents : Documents
  /// The documents that references name and that were not given, in the
  /// order they were reached.
  needed : Set[String]
  /// The root document, parsed.
  document : Document
  report : Report
}

///|
/// Reports an error with the file, before every other problem.
fn Conversion::output_error(self : Conversion, message : String) -> Unit {
  self.report.output_error(message)
}

///|
/// Reports an error at the place `pointer`, in the document it is in.
fn Conversion::error_at(
  self : Conversion,
  pointer : Place,
  message : String,
) -> Unit {
  self.report.error_at(pointer, message)
}

///|
/// Reports a warning at the place `pointer`, in the document it is in.
fn Conversion::warning_at(
  self : Conversion,
  pointer : Place,
  message : String,
) -> Unit {
  self.report.warning_at(pointer, message)
}

///|
/// Reports a document-level warning at the place `pointer`, found after
/// the operations, among the other document-level problems.
fn Conversion::late_document_warning(
  self : Conversion,
  pointer : Place,
  message : String,
) -> Unit {
  self.report.late_document_warning(pointer, message)
}

///|
/// Where the place `pointer` is, as messages name a place:
/// `<file>: <pointer>`, or `<file>` for the whole of a document.
fn Conversion::place(self : Conversion, pointer : Place) -> String {
  self.report.place(pointer)
}
