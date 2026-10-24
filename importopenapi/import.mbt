// The OpenAPI import: it converts an OpenAPI 3.0, 3.1 or 3.2 document into
// one Definition file, once. smock never reads OpenAPI at run time: the file
// is committed and served like any other (ADR 0002).
//
// The converter does no I/O. It takes the documents as (name, bytes) pairs,
// and returns the names of the documents it still needs, or the file's
// bytes with the warnings, or the errors. The CLI reads the documents it
// asks for and writes the file, as `defdir` reads what `definitions` loads.
//
// Its parts are kept apart, so that each can grow on its own: the document
// and its version (document.mbt), the operations under `paths`
// (operations.mbt), paths (paths.mbt), servers and base paths
// (servers.mbt), responses (responses.mbt), bodies (bodies.mbt), headers
// (headers.mbt), examples (examples.mbt), samples of schemas (samples.mbt),
// with numbers within their bounds (numbers.mbt) and the exact decimals
// they need (decimal.mbt), references and the documents they name
// (references.mbt), the file it writes (output.mbt), the state of a round
// of the conversion and the places problems are reported at
// (conversion.mbt), and the problems and their order (report.mbt).

///|
/// The most documents a conversion reads, the root included.
let max_documents : Int32 = 1000

///|
/// The most bytes a conversion reads, in all its documents, the root
/// included: 64 MiB. Both parsers build a tree, and the YAML parser copies
/// the text into 4-byte characters, so a run needs many times what it
/// reads.
pub let max_read_bytes : Int32 = 64 * 1024 * 1024

///|
/// What a conversion needs besides the documents.
pub struct Options {
  /// The root document: its name among the documents, its path under the
  /// directory that references are followed in, such as `openapi.yaml` or
  /// `v1/openapi.yaml`. Its extension picks the parser: YAML 1.2 for
  /// `.yaml` and `.yml`, JSON for `.json`. Only its base name reaches the
  /// file.
  root : String
  /// How problems name the root document, such as its path as given on
  /// the command line.
  root_label : String
  /// How problems name the directory that the documents' names are under:
  /// `--ref-dir` as given, or the directory part of the root's path as
  /// given, such as `api/`, or `""` when it has none. Nothing of it reaches
  /// the file.
  ref_dir : String
  /// The name of the one Mock the file declares. Every Stub ID starts with
  /// it.
  mock : String
  /// The Hosts the Mock is declared with, as given, such as
  /// `petstore.test`. The caller checks them as a Definition file would,
  /// and that none repeats: the converter writes them as they are. Empty
  /// when the Mock has no Hosts, or is not declared.
  hosts : Array[String]
  /// Whether the file declares the Mock. When it does not, the file holds
  /// only Stubs, for a Mock that another file declares.
  declare_mock : Bool
  /// The Definition file to write, as `--output` gives it. Problems with
  /// the file itself name it so. Its name picks the format: YAML when it
  /// ends in `.yaml` or `.yml`, else JSON. Nothing else of it reaches the
  /// file.
  output : String
  /// The path that `--base-path` gives, as given, such as
  /// `/mock/petstore`. When there is one, it is put in front of every path
  /// in place of the paths of servers, which are then not read at all. It
  /// is percent-decoded as smock decodes request paths, and a trailing `/`
  /// is dropped, so `/` means no prefix. The caller checks that it starts
  /// with `/` and holds no `?` or `#`.
  base_path : String?
}

///|
/// The options of a conversion of the document `root` into a Definition
/// file `output` that declares the Mock `mock`, with the Hosts `hosts`, by
/// default none, or that holds only its Stubs when `declare_mock` is false.
/// Problems name the root document `root_label`, by default `root`, and the
/// others under `ref_dir`, by default `""`. `base_path`, when given,
/// replaces the paths of servers in front of every path.
pub fn Options::Options(
  root~ : String,
  mock~ : String,
  output~ : String,
  root_label~ : String = root,
  ref_dir~ : String = "",
  hosts~ : Array[String] = [],
  declare_mock~ : Bool = true,
  base_path? : String,
) -> Options {
  { root, root_label, ref_dir, mock, hosts, declare_mock, output, base_path, }
}

///|
/// The path of the document `name`, as problems name it: `root_label` for
/// the root, else `ref_dir` joined with `name`. It names the file as the
/// user can open it, so the CLI reads the document there.
pub fn Options::path(self : Options, name : String) -> String {
  if name == self.root {
    self.root_label
  } else if self.ref_dir == "" || self.ref_dir.has_suffix("/") {
    self.ref_dir + name
  } else {
    "\{self.ref_dir}/\{name}"
  }
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
/// Why a document that a conversion asked for cannot be read. The
/// converter reports it at every `$ref` that names the document.
pub(all) enum Unreadable {
  /// There is no file of that name.
  Missing
  /// It is a directory, or another file that is not a regular file.
  NotRegularFile
  /// A symlink leads it outside the directory that references are followed
  /// in.
  SymlinkOutside
  /// Another reason, as the system gives it, such as `permission denied`.
  Other(String)
} derive(Debug, Eq)

///|
/// The reason, as a problem gives it, such as `no such file`.
pub fn Unreadable::to_string(self : Unreadable) -> String {
  match self {
    Missing => "no such file"
    NotRegularFile => "not a regular file"
    SymlinkOutside => "a symlink leads it outside --ref-dir"
    Other(reason) => reason
  }
}

///|
/// What a conversion gave.
pub(all) enum Outcome {
  /// The Definition file: its bytes, the warnings, in the order the
  /// document writes what they are about, the number of Stubs in it and
  /// the number of operations they came from.
  Converted(
    file~ : Bytes,
    problems~ : Array[Problem],
    stubs~ : Int32,
    operations~ : Int32
  )
  /// No file: every problem, errors and warnings, in the order the document
  /// writes what they are about. At least one is an error.
  Failed(Array[Problem])
  /// The names of the documents that references name and the conversion
  /// does not have yet, in the order it reached them, none twice. Give
  /// each, or say why it cannot be read, then convert again.
  Needs(Array[String])
}

///|
/// The problems of the conversion, in order: none while it needs
/// documents.
pub fn Outcome::problems(self : Outcome) -> Array[Problem] {
  match self {
    Converted(problems~, ..) => problems
    Failed(problems) => problems
    Needs(_) => []
  }
}

///|
/// A conversion in rounds: it is given the documents it has, and asks for
/// those it still needs, until it has all it needs. Each document is
/// parsed once, when it is given, however many rounds the conversion
/// takes.
struct Converter {
  options : Options
  documents : Documents
}

///|
/// A conversion with the options `options`, and no document yet.
pub fn Converter::new(options : Options) -> Converter {
  { options, documents: Documents::new(options), }
}

///|
/// Gives the conversion the document `name`, its path under the directory
/// that references are followed in, read as `bytes`. A name given before
/// keeps what it was first given.
pub fn Converter::give(self : Converter, name : String, bytes : Bytes) -> Unit {
  self.documents.give(name, bytes)
}

///|
/// Tells the conversion that the document `name`, which it asked for,
/// cannot be read, and why. A name given before keeps what it was first
/// given.
pub fn Converter::give_unreadable(
  self : Converter,
  name : String,
  reason : Unreadable,
) -> Unit {
  self.documents.add(name, Unread(reason))
}

///|
/// Converts the root document, with the documents given so far, into a
/// Definition file, or says which documents it still needs.
///
/// At most `max_documents` documents and `max_read_bytes` bytes are read,
/// the root included: passing either is an error.
pub fn Converter::convert(self : Converter) -> Outcome {
  let options = self.options
  let report = Report::new()
  if self.documents.passed is Some(name) {
    let most = size_text(max_read_bytes)
    let message = if name == options.root {
      "is larger than \{most}, the most smock import-openapi reads"
    } else {
      "with it, the documents read pass \{most}, the most smock import-openapi reads in all, the root included"
    }
    report.error(options.path(name), "", message)
    return Failed(report.problems())
  }
  guard self.documents.root is Some(root) else {
    report.error(options.root_label, "", "the document was not given")
    return Failed(report.problems())
  }
  guard Conversion::new(options, self.documents, report, root)
    is Some(conversion) else {
    return Failed(report.problems())
  }
  let imported = conversion.operations()
  if self.documents.count() + conversion.needed.length() > max_documents {
    // This one error replaces every other problem: the documents past the
    // bound are never asked for, so the problems found so far are not
    // final, as in a round that needs documents.
    return Failed([
      Error({
        file: options.root_label,
        pointer: "",
        message: "the documents it refers to pass \{count_text(max_documents)}, the most smock import-openapi reads, the root included: bundle the document into one file first, with another tool",
      }),
    ])
  }
  if !conversion.needed.is_empty() {
    return Needs(conversion.needed.to_array())
  }
  conversion.file(imported)
}

///|
/// Converts the root document that `options` names, among `documents`
/// given as (name, bytes) pairs, into a Definition file, or says which
/// documents it still needs. A name is a document's path under the
/// directory that references are followed in, `/`-separated, without `.`
/// or `..`.
pub fn convert(
  documents : Array[(String, Bytes)],
  options : Options,
) -> Outcome {
  let converter = Converter::new(options)
  for document in documents {
    converter.give(document.0, document.1)
  }
  converter.convert()
}

///|
/// `n`, a count that is not negative, as messages write it: its digits in
/// groups of three, separated by commas, such as `1,000`.
fn count_text(n : Int32) -> String {
  let digits = n.to_string()
  let out = StringBuilder()
  for i, c in digits {
    if i > 0 && (digits.length() - i) % 3 == 0 {
      out.write_char(',')
    }
    out.write_char(c)
  }
  out.to_string()
}
