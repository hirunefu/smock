///|
/// The state of one conversion: its options, the documents given and those
/// still needed, and the problems found so far, in order: those with the
/// file, then the document-level ones, then each operation's, in the order
/// the document writes them. The converter's steps are its methods.
///
/// A problem is reported at a `Place`: a document and a JSON Pointer into
/// it. The converter calls each such place a pointer.
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
/// How far the problems have come at some point: how many there are, and
/// where the document-level ones end, so that those reported after it can
/// be dropped.
priv struct Mark {
  problems : Int
  document_end : Int
}

///|
/// How far the problems have come now.
fn Report::mark(self : Report) -> Mark {
  { problems: self.problems.length(), document_end: self.document_end, }
}

///|
/// Drops the problems reported after `mark`, as if they had not been
/// reported: those of a sample that is made again. Those reported among
/// the document-level problems since, such as a file that cannot be read,
/// are dropped too.
fn Report::rollback(self : Report, mark : Mark) -> Unit {
  let inserted = self.document_end - mark.document_end
  while self.problems.length() > mark.problems + inserted {
    guard self.problems.pop() is Some(problem) else { break }
    self.unreport(problem)
  }
  for _ in 0..<inserted {
    self.unreport(self.problems.remove(mark.document_end))
  }
  self.document_end = mark.document_end
}

///|
/// Counts `problem`, just removed from the problems, as not reported.
fn Report::unreport(self : Report, problem : Problem) -> Unit {
  self.reported.remove(problem.to_string())
  if problem.is_error() {
    self.errors -= 1
  }
}

///|
/// Reports an error with the file, before every other problem. It names
/// the file as `--output` gives it, with no pointer, as every problem with
/// the file does.
fn Report::output_error(self : Report, message : String) -> Unit {
  self.problems.insert(
    self.output_end,
    Error({ file: self.options.output, pointer: "", message, }),
  )
  self.output_end += 1
  self.document_end += 1
  self.errors += 1
}

///|
/// Reports an error at the place `pointer`, in the document it is in.
fn Report::error_at(self : Report, pointer : Place, message : String) -> Unit {
  self.error(self.file_name(pointer.document), pointer.pointer, message)
}

///|
/// Reports a warning at the place `pointer`, in the document it is in.
fn Report::warning_at(self : Report, pointer : Place, message : String) -> Unit {
  self.warning(self.file_name(pointer.document), pointer.pointer, message)
}

///|
/// Reports an error at the place `pointer` among the document-level
/// problems, after those found so far, unless it is reported already. Such
/// are references to documents that cannot be read.
fn Report::document_error_at(
  self : Report,
  pointer : Place,
  message : String,
) -> Unit {
  let problem = Error({
    file: self.file_name(pointer.document),
    pointer: pointer.pointer,
    message,
  })
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
/// Reports a document-level warning at the place `pointer`, found after
/// the operations, among the other document-level problems.
fn Report::late_document_warning(
  self : Report,
  pointer : Place,
  message : String,
) -> Unit {
  self.problems.insert(
    self.document_end,
    Warning({
      file: self.file_name(pointer.document),
      pointer: pointer.pointer,
      message,
    }),
  )
}

///|
/// Where the place `pointer` is, as messages name a place:
/// `<file>: <pointer>`, or `<file>` for the whole of a document.
fn Report::place(self : Report, pointer : Place) -> String {
  let file = self.file_name(pointer.document)
  if pointer.pointer == "" {
    file
  } else {
    "\{file}: \{pointer.pointer}"
  }
}

///|
/// A place in the documents of a conversion, where a problem is reported:
/// a JSON Pointer into the document numbered `document`, its number among
/// the documents given, or into the root document for `None`.
priv struct Place {
  document : Int?
  pointer : String
} derive(Eq)

///|
/// The place `pointer` in the root document.
fn Place::root(pointer : String) -> Place {
  { document: None, pointer, }
}

///|
/// The place of the member `key` of what is at this place, or of the item
/// at the index that `key` gives, in the same document, as
/// `@definitions.child_pointer` builds a JSON Pointer.
fn Place::child(self : Place, key : String) -> Place {
  {
    document: self.document,
    pointer: @definitions.child_pointer(self.pointer, key),
  }
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
