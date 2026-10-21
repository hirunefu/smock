// The OpenAPI import: it converts an OpenAPI 3.0, 3.1 or 3.2 document into
// one Definition file, once. smock never reads OpenAPI at run time: the file
// is committed and served like any other (ADR 0002).
//
// The converter does no I/O. It takes the documents as (name, bytes) pairs,
// and returns the file's bytes with the warnings, or the errors. The CLI
// reads the documents and writes the file, as `defdir` reads what
// `definitions` loads.
//
// Its parts are kept apart, so that each can grow on its own: the document
// and its version (document.mbt), the operations under `paths`
// (operations.mbt), paths (paths.mbt), responses (responses.mbt), bodies
// and headers (bodies.mbt), samples of schemas (samples.mbt), with numbers
// within their bounds (numbers.mbt) and the exact decimals they need
// (decimal.mbt), references (references.mbt), and the file it writes
// (output.mbt).

///|
/// What a conversion needs besides the documents.
pub struct Options {
  /// The root document: its name among the documents. Its extension picks
  /// the parser: YAML 1.2 for `.yaml` and `.yml`, JSON for `.json`.
  root : String
  /// How problems name the root document, such as its path as given on
  /// the command line.
  root_label : String
  /// The name of the one Mock the file declares. Every Stub ID starts with
  /// it.
  mock : String
  /// The Definition file to write, as `--output` gives it. Problems with
  /// the file itself name it so. Its name picks the format: YAML when it
  /// ends in `.yaml` or `.yml`, else JSON. Nothing else of it reaches the
  /// file.
  output : String
}

///|
/// The options of a conversion of the document `root` into a Definition
/// file `output` that declares the Mock `mock`. Problems name the root
/// document `root_label`, by default `root`.
pub fn Options::Options(
  root~ : String,
  mock~ : String,
  output~ : String,
  root_label? : String = root,
) -> Options {
  { root, root_label, mock, output, }
}

///|
/// A problem with a document or with the file: an error, which stops the
/// file from being written, or a warning, about a part of the document
/// that was left out or changed. Each prints as `smock check` prints it.
pub(all) enum Problem {
  Error(@definitions.Diagnostic)
  Warning(@definitions.Warning)
} derive(Debug, Eq)

///|
/// `<file>: <pointer>: <message>` for an error, and
/// `<file>: <pointer>: warning: <message>` for a warning, on one line.
pub fn Problem::to_string(self : Problem) -> String {
  match self {
    Error(diagnostic) => diagnostic.to_string()
    Warning(warning) => warning.to_string()
  }
}

///|
/// Whether the problem is an error.
pub fn Problem::is_error(self : Problem) -> Bool {
  self is Error(_)
}

///|
/// What a conversion gave.
pub(all) enum Conversion {
  /// The Definition file: its bytes, the warnings, in the order the
  /// document writes what they are about, the number of Stubs in it and
  /// the number of operations they came from.
  Converted(
    file~ : Bytes,
    problems~ : Array[Problem],
    stubs~ : Int,
    operations~ : Int
  )
  /// No file: every problem, errors and warnings, in the order the document
  /// writes what they are about. At least one is an error.
  Failed(Array[Problem])
}

///|
/// The problems of the conversion, in order.
pub fn Conversion::problems(self : Conversion) -> Array[Problem] {
  match self {
    Converted(problems~, ..) => problems
    Failed(problems) => problems
  }
}

///|
/// Converts the root document that `options` names, among `documents`
/// given as (name, bytes) pairs, into a Definition file.
pub fn convert(
  documents : Array[(String, Bytes)],
  options : Options,
) -> Conversion {
  let report = Report::new(options)
  guard documents.search_by(document => document.0 == options.root) is Some(i) else {
    report.error(options.root_label, "", "the document was not given")
    return Failed(report.problems())
  }
  guard report.document(documents[i].1) is Some(document) else {
    return Failed(report.problems())
  }
  let imported = report.operations(document)
  report.file(document, imported)
}
