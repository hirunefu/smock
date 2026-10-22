///|
/// One round of a conversion: its options, the documents given, those that
/// references name and that were not given, the root document, parsed, and
/// the report of the problems found so far. The converter's steps are its
/// methods.
///
/// A problem is reported at a `Place`: a document and a JSON Pointer into
/// it. The converter calls each such place a pointer.
priv struct Conversion {
  options : Options
  /// The documents given to the conversion.
  documents : Documents
  /// The documents that references name and that were not given, in the
  /// order they were reached.
  needed : Set[String]
  /// The root document, parsed. While `Conversion::new` reads it, only its
  /// `top` and, once the version is read, its `openapi` are set.
  document : Document
  report : Report
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
/// Reports an error at the place `pointer`, in the document it is in.
fn Conversion::error_at(
  self : Conversion,
  pointer : Place,
  message : String,
) -> Unit {
  self.report.error(self.file_name(pointer.document), pointer.pointer, message)
}

///|
/// Reports a warning at the place `pointer`, in the document it is in.
fn Conversion::warning_at(
  self : Conversion,
  pointer : Place,
  message : String,
) -> Unit {
  self.report.warning(
    self.file_name(pointer.document),
    pointer.pointer,
    message,
  )
}

///|
/// Reports an error at the place `pointer` among the document-level
/// problems, after those found so far, unless it is reported already.
fn Conversion::document_error_at(
  self : Conversion,
  pointer : Place,
  message : String,
) -> Unit {
  self.report.document_error(
    self.file_name(pointer.document),
    pointer.pointer,
    message,
  )
}

///|
/// Reports a document-level warning at the place `pointer`, found after
/// the operations, among the other document-level problems.
fn Conversion::late_document_warning(
  self : Conversion,
  pointer : Place,
  message : String,
) -> Unit {
  self.report.late_document_warning(
    self.file_name(pointer.document),
    pointer.pointer,
    message,
  )
}

///|
/// Reports an error with the file, before every other problem. It names
/// the file as `--output` gives it, with no pointer, as every problem with
/// the file does.
fn Conversion::output_error(self : Conversion, message : String) -> Unit {
  self.report.output_error(self.options.output, message)
}

///|
/// Where the place `pointer` is, as messages name a place:
/// `<file>: <pointer>`, or `<file>` for the whole of a document.
fn Conversion::place(self : Conversion, pointer : Place) -> String {
  let file = self.file_name(pointer.document)
  if pointer.pointer == "" {
    file
  } else {
    "\{file}: \{pointer.pointer}"
  }
}

///|
/// How problems name the document numbered `number`, or the root for
/// `None`.
fn Conversion::file_name(self : Conversion, number : Int?) -> String {
  match number {
    None => self.options.root_label
    Some(number) => self.documents.others[number].path
  }
}
