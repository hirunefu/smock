///|
/// The problems of a conversion, in order: those with the file, then the
/// document-level ones, then each operation's, in the order the document
/// writes them. It only collects and orders them: the conversion says in
/// which file and at which pointer each is.
priv struct Report {
  problems : Array[Problem]
  /// Each problem reported in a document so far, as it prints. A part
  /// that several references reach is read once per reference, but each
  /// of its problems is reported once, where it is written.
  reported : Set[String]
  /// How many of the problems are errors.
  mut errors : Int32
  /// Where the problems with the file end. They are found last, but come
  /// first.
  mut output_end : Int32
  /// Where the document-level problems end, so that one found after the
  /// operations, such as that there is no operation to import, goes with
  /// them.
  mut document_end : Int32
}

///|
/// A report with no problem yet.
fn Report::new() -> Report {
  {
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
  problems : Int32
  document_end : Int32
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
/// Reports an error with the file, named `file`, before every other
/// problem. It has no pointer, as no problem with the file has.
fn Report::output_error(self : Report, file : String, message : String) -> Unit {
  self.problems.insert(self.output_end, Error({ file, pointer: "", message, }))
  self.output_end += 1
  self.document_end += 1
  self.errors += 1
}

///|
/// Reports an error at `pointer` in `file` among the document-level
/// problems, after those found so far, unless it is reported already. Such
/// are references to documents that cannot be read.
fn Report::document_error(
  self : Report,
  file : String,
  pointer : String,
  message : String,
) -> Unit {
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
/// Reports a document-level warning at `pointer` in `file`, found after
/// the operations, among the other document-level problems.
fn Report::late_document_warning(
  self : Report,
  file : String,
  pointer : String,
  message : String,
) -> Unit {
  self.problems.insert(self.document_end, Warning({ file, pointer, message, }))
}

///|
/// The problems so far.
fn Report::problems(self : Report) -> Array[Problem] {
  self.problems
}
