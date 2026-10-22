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
/// The conversion of the root document `document`, whose problems go to
/// `report`, with the options, the documents and the needed documents of
/// the report.
fn Conversion::new(report : Report, document : Document) -> Conversion {
  {
    options: report.options,
    documents: report.documents,
    needed: report.needed,
    document,
    report,
  }
}

///|
/// Reports an error with the file, before every other problem.
fn Conversion::output_error(self : Conversion, message : String) -> Unit {
  self.report.output_error(message)
}
