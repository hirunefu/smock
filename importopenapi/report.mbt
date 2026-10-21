///|
/// The problems of one conversion, in order: those with the file, then the
/// document-level ones, then each operation's, in the order the document
/// writes them.
priv struct Report {
  options : Options
  problems : Array[Problem]
  /// How many of the problems are errors.
  mut errors : Int
  /// Where the problems with the file end. They are found last, but come
  /// first.
  mut output_end : Int
  /// Where the document-level problems end, so that one found after the
  /// operations, such as that there is no operation to import, goes with
  /// them.
  mut document_end : Int
}

///|
fn Report::new(options : Options) -> Report {
  { options, problems: [], errors: 0, output_end: 0, document_end: 0, }
}

///|
/// Reports an error at `pointer` in `file`.
fn Report::error(
  self : Report,
  file : String,
  pointer : String,
  message : String,
) -> Unit {
  self.problems.push(Error({ file, pointer, message, }))
  self.errors += 1
}

///|
/// Reports a warning at `pointer` in `file`.
fn Report::warning(
  self : Report,
  file : String,
  pointer : String,
  message : String,
) -> Unit {
  self.problems.push(Warning({ file, pointer, message, }))
}

///|
/// Reports an error at `pointer` in the file, before every other problem.
fn Report::output_error(
  self : Report,
  pointer : String,
  message : String,
) -> Unit {
  self.problems.insert(
    self.output_end,
    Error({ file: self.options.output, pointer, message, }),
  )
  self.output_end += 1
  self.document_end += 1
  self.errors += 1
}

///|
/// Reports an error at `pointer` in the root document.
fn Report::root_error(
  self : Report,
  pointer : String,
  message : String,
) -> Unit {
  self.error(self.options.root_label, pointer, message)
}

///|
/// Reports a warning at `pointer` in the root document.
fn Report::root_warning(
  self : Report,
  pointer : String,
  message : String,
) -> Unit {
  self.warning(self.options.root_label, pointer, message)
}

///|
/// Marks the end of the document-level problems.
fn Report::end_document(self : Report) -> Unit {
  self.document_end = self.problems.length()
}

///|
/// Reports a document-level warning found after the operations, among the
/// other document-level problems.
fn Report::late_document_warning(
  self : Report,
  pointer : String,
  message : String,
) -> Unit {
  self.problems.insert(
    self.document_end,
    Warning({ file: self.options.root_label, pointer, message, }),
  )
}

///|
/// Where `pointer` is in the root document, as messages name a place:
/// `<file>: <pointer>`.
fn Report::place(self : Report, pointer : String) -> String {
  "\{self.options.root_label}: \{pointer}"
}

///|
/// The problems so far.
fn Report::problems(self : Report) -> Array[Problem] {
  self.problems
}
