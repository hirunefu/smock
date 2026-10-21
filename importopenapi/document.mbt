///|
/// The root document, parsed.
priv struct Document {
  top : Map[String, Json]
}

///|
/// Parses the root document and checks its version, or reports why it
/// cannot be read. Then it reports the document-level parts that are left
/// out.
fn Report::document(self : Report, bytes : Bytes) -> Document? {
  let name = self.options.root
  if name.has_suffix(".yaml") || name.has_suffix(".yml") {
    self.root_error("", "YAML documents are not read yet: give a JSON document")
    return None
  }
  if !name.has_suffix(".json") {
    self.root_error("", "an OpenAPI document's name ends in .json")
    return None
  }
  // A leading byte order mark is skipped, as the YAML parser skips it.
  let text = @utf8.decode(bytes, ignore_bom=true) catch {
    _ => {
      self.root_error("", "not valid UTF-8")
      return None
    }
  }
  let json = @json.parse(text) catch {
    err => {
      self.root_error("", "not valid JSON: \{err}")
      return None
    }
  }
  if @definitions.first_duplicate_key(text) is Some(pointer) {
    self.root_error(pointer, "duplicate key")
    return None
  }
  guard json is Object(top) else {
    self.root_error("", "must be an object")
    return None
  }
  guard self.version(top) else { return None }
  let document = { top, }
  self.left_out_parts(document)
  self.end_document()
  Some(document)
}

///|
/// Whether the document's version, from its `openapi` field, is OpenAPI
/// 3.0, 3.1 or 3.2, after reporting why it is not. Only the minor version
/// counts: the patch is ignored, as the specification asks.
fn Report::version(self : Report, top : Map[String, Json]) -> Bool {
  match (top.get("openapi"), top.get("swagger")) {
    (Some(_), Some(_)) => {
      self.root_error(
        "/swagger", "a document has \"openapi\" or \"swagger\", not both",
      )
      false
    }
    (None, Some(String("2.0"))) => {
      self.root_error(
        "/swagger", "Swagger 2.0 is not supported: convert the document to OpenAPI 3.0 first",
      )
      false
    }
    (None, Some(_)) => {
      self.root_error(
        "/swagger", "not a version smock imports: it imports OpenAPI 3.0, 3.1 and 3.2",
      )
      false
    }
    (None, None) => {
      self.root_error(
        "", "needs \"openapi\", the OpenAPI version, such as \"3.1.0\"",
      )
      false
    }
    (Some(Number(_)), None) => {
      self.root_error(
        "/openapi", "must be a string such as \"3.1.0\": quote the version, and give its patch",
      )
      false
    }
    (Some(String(text)), None) =>
      match text.split(".").collect() {
        [major, minor, patch] if [major, minor, patch].all(is_digits) =>
          match (major, minor) {
            ("3", "0" | "1" | "2") => true
            _ => {
              self.root_error(
                "/openapi", "not a version smock imports: it imports OpenAPI 3.0, 3.1 and 3.2",
              )
              false
            }
          }
        _ => {
          self.root_error(
            "/openapi", "must be a version 3.<minor>.<patch> of digits, such as \"3.1.0\"",
          )
          false
        }
      }
    (Some(_), None) => {
      self.root_error("/openapi", "must be a string such as \"3.1.0\"")
      false
    }
  }
}

///|
/// Whether `s` is one or more ASCII digits.
fn is_digits(s : StringView) -> Bool {
  s.length() > 0 && s.iter().all(c => c >= '0' && c <= '9')
}

///|
/// Reports the document-level parts that are not imported: webhooks,
/// which are requests the API sends, not ones it answers, and, until the
/// paths of servers are read, the document's servers.
fn Report::left_out_parts(self : Report, document : Document) -> Unit {
  self.servers_left_out("", document.top)
  if document.top.get("webhooks") is Some(Object(webhooks)) &&
    !webhooks.is_empty() {
    self.root_warning(
      "/webhooks", "webhooks are not imported: they are requests the API sends, not ones it answers",
    )
  }
}
