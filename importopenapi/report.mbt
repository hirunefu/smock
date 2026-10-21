///|
/// The problems of one conversion, in order: those with the file, then the
/// document-level ones, then each operation's, in the order the document
/// writes them.
///
/// A problem is reported at a place: a JSON Pointer into the root
/// document, such as `/paths/~1pets`, or into another document, written
/// `<number>#<pointer>`, the document's number among the documents given
/// (see `Report::place_in`). The converter calls each such place a
/// pointer, and builds a part's from its parent's with
/// `@definitions.child_pointer`, as for a JSON Pointer.
priv struct Report {
  options : Options
  /// The documents given to the conversion.
  documents : Documents
  /// The documents that references name and that were not given, in the
  /// order they were reached.
  needed : Set[String]
  problems : Array[Problem]
  /// Each problem reported in a document so far, as it prints. A part
  /// that several references reach is read once per reference, but each
  /// of its problems is reported once, where it is written.
  reported : Set[String]
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
/// The report of a conversion with the options `options`, of the documents
/// `documents`, by default none but the root, which the caller reads.
fn Report::new(
  options : Options,
  documents? : Documents = Documents::new(options),
) -> Report {
  {
    options,
    documents,
    needed: Set([]),
    problems: [],
    reported: Set([]),
    errors: 0,
    output_end: 0,
    document_end: 0,
  }
}

///|
/// Reports an error at `pointer` in `file`, unless it is reported already.
fn Report::error(
  self : Report,
  file : String,
  pointer : String,
  message : String,
) -> Unit {
  if self.add(Error({ file, pointer, message, })) {
    self.errors += 1
  }
}

///|
/// Reports a warning at `pointer` in `file`, unless it is reported
/// already.
fn Report::warning(
  self : Report,
  file : String,
  pointer : String,
  message : String,
) -> Unit {
  self.add(Warning({ file, pointer, message, })) |> ignore
}

///|
/// Adds `problem`, and returns whether it was not reported already.
fn Report::add(self : Report, problem : Problem) -> Bool {
  guard self.reported.add_and_check(problem.to_string()) else { return false }
  self.problems.push(problem)
  true
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
/// Reports an error at the place `pointer`, in the document it is in.
fn Report::error_at(self : Report, pointer : String, message : String) -> Unit {
  let (file, pointer) = self.locate(pointer)
  self.error(file, pointer, message)
}

///|
/// Reports a warning at the place `pointer`, in the document it is in.
fn Report::warning_at(
  self : Report,
  pointer : String,
  message : String,
) -> Unit {
  let (file, pointer) = self.locate(pointer)
  self.warning(file, pointer, message)
}

///|
/// Reports an error at the place `pointer` among the document-level
/// problems, after those found so far, unless it is reported already. Such
/// are references to documents that cannot be read.
fn Report::document_error_at(
  self : Report,
  pointer : String,
  message : String,
) -> Unit {
  let (file, pointer) = self.locate(pointer)
  let problem = Error({ file, pointer, message, })
  guard self.reported.add_and_check(problem.to_string()) else { return }
  self.problems.insert(self.document_end, problem)
  self.document_end += 1
  self.errors += 1
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
/// Where the place `pointer` is, as messages name a place:
/// `<file>: <pointer>`, or `<file>` for the whole of a document.
fn Report::place(self : Report, pointer : String) -> String {
  match self.locate(pointer) {
    (file, "") => file
    (file, pointer) => "\{file}: \{pointer}"
  }
}

///|
/// The place of `pointer`, a JSON Pointer into the document numbered
/// `number`, or into the root document for `None`: the pointer itself in
/// the root, and `<number>#<pointer>` in another document. A JSON Pointer
/// is empty or starts with `/`, so the two never mix.
fn place_in(number : Int?, pointer : String) -> String {
  match number {
    None => pointer
    Some(number) => "\{number}#\{pointer}"
  }
}

///|
/// The number of the document that the place `pointer` is in, or `None`
/// for the root, and the JSON Pointer into it.
fn number_of(pointer : String) -> (Int?, String) {
  guard pointer.find("#") is Some(i) && !pointer.has_prefix("/") else {
    return (None, pointer)
  }
  let mut number = 0
  for c in pointer[:i] {
    number = number * 10 + (c.to_int() - '0'.to_int())
  }
  (Some(number), pointer[i + 1:].to_owned())
}

///|
/// The document that the place `pointer` is in, as problems name it, and
/// the JSON Pointer into it.
fn Report::locate(self : Report, pointer : String) -> (String, String) {
  let (number, pointer) = number_of(pointer)
  (self.file_name(number), pointer)
}

///|
/// How problems name the document numbered `number`, or the root for
/// `None`.
fn Report::file_name(self : Report, number : Int?) -> String {
  match number {
    None => self.options.root_label
    Some(number) => self.documents.others[number].path
  }
}

///|
/// The problems so far.
fn Report::problems(self : Report) -> Array[Problem] {
  self.problems
}
