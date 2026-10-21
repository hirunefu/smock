///|
/// The root document, parsed.
priv struct Document {
  top : Map[String, Json]
  /// The `openapi` field as written, such as `3.1.0`.
  openapi : String
  /// The `title` and `version` of its `info`, or `""` where it has none.
  title : String
  info_version : String
}

///|
/// Parses the root document and checks its version, or reports why it
/// cannot be read. Then it reports the document-level parts that are left
/// out.
fn Report::document(self : Report, bytes : Bytes) -> Document? {
  let label = self.options.root_label
  guard self.parsed(label, self.options.root, bytes) is Some(json) else {
    return None
  }
  guard json is Object(top) else {
    self.root_error("", "must be an object")
    return None
  }
  guard self.version(top) is Some(openapi) else { return None }
  let (title, info_version) = self.info(top)
  let document = { top, openapi, title, info_version, }
  self.left_out_parts(document)
  self.end_document()
  Some(document)
}

///|
/// The tree of the document `name`, read by the parser its extension
/// picks: `.yaml` and `.yml` as YAML 1.2, as OpenAPI recommends, with
/// smock/yaml's mode for OpenAPI documents, and `.json` as JSON, where a
/// repeated key is an error. Or `None`, after reporting why it cannot be
/// read, in the document named `label`. The input must be UTF-8, and a
/// leading byte order mark is skipped.
fn Report::parsed(
  self : Report,
  label : String,
  name : String,
  bytes : Bytes,
) -> Json? {
  let yaml = name.has_suffix(".yaml") || name.has_suffix(".yml")
  if !yaml && !name.has_suffix(".json") {
    self.error(
      label, "", "an OpenAPI document's name ends in .json, .yaml or .yml",
    )
    return None
  }
  let text = @utf8.decode(bytes, ignore_bom=true) catch {
    _ => {
      self.error(label, "", "not valid UTF-8")
      return None
    }
  }
  if yaml {
    let json = @yaml.parse(text, openapi=true) catch {
      ParseError(pointer~, message~) => {
        self.error(label, pointer, message)
        return None
      }
    }
    return Some(json)
  }
  let json = @json.parse(text) catch {
    err => {
      self.error(label, "", "not valid JSON: \{err}")
      return None
    }
  }
  if @definitions.first_duplicate_key(text) is Some(pointer) {
    self.error(label, pointer, "duplicate key")
    return None
  }
  Some(json)
}

///|
/// The document's version, its `openapi` field as written, when it is
/// OpenAPI 3.0, 3.1 or 3.2; else `None`, after reporting why it is not.
/// Only the minor version counts: the patch is ignored, as the
/// specification asks.
fn Report::version(self : Report, top : Map[String, Json]) -> String? {
  match (top.get("openapi"), top.get("swagger")) {
    (Some(_), Some(_)) => {
      self.root_error(
        "/swagger", "a document has \"openapi\" or \"swagger\", not both",
      )
      None
    }
    (None, Some(String("2.0"))) => {
      self.root_error(
        "/swagger", "Swagger 2.0 is not supported: convert the document to OpenAPI 3.0 first",
      )
      None
    }
    (None, Some(_)) => {
      self.root_error(
        "/swagger", "not a version smock imports: it imports OpenAPI 3.0, 3.1 and 3.2",
      )
      None
    }
    (None, None) => {
      self.root_error(
        "", "needs \"openapi\", the OpenAPI version, such as \"3.1.0\"",
      )
      None
    }
    (Some(Number(_)), None) => {
      self.root_error(
        "/openapi", "must be a string such as \"3.1.0\": quote the version, and give its patch",
      )
      None
    }
    (Some(String(text)), None) =>
      match text.split(".").collect() {
        [major, minor, patch] if [major, minor, patch].all(is_digits) =>
          match (major, minor) {
            ("3", "0" | "1" | "2") => Some(text)
            _ => {
              self.root_error(
                "/openapi", "not a version smock imports: it imports OpenAPI 3.0, 3.1 and 3.2",
              )
              None
            }
          }
        _ => {
          self.root_error(
            "/openapi", "must be a version 3.<minor>.<patch> of digits, such as \"3.1.0\"",
          )
          None
        }
      }
    (Some(_), None) => {
      self.root_error("/openapi", "must be a string such as \"3.1.0\"")
      None
    }
  }
}

///|
/// The `title` and `version` of the document's `info`, which the comment
/// at the top of a YAML file names, or `""` for each it does not have.
/// Either of the wrong type is an error. A version that is a number, as an
/// unquoted `1.0` reads in YAML, says to quote it.
fn Report::info(self : Report, top : Map[String, Json]) -> (String, String) {
  let info = match top.get("info") {
    None => return ("", "")
    Some(Object(info)) => info
    Some(_) => {
      self.root_error("/info", "must be an object")
      return ("", "")
    }
  }
  let title = match info.get("title") {
    None => ""
    Some(String(title)) => title
    Some(_) => {
      self.root_error("/info/title", "must be a string")
      ""
    }
  }
  let version = match info.get("version") {
    None => ""
    Some(String(version)) => version
    Some(Number(_)) => {
      self.root_error("/info/version", "must be a string: quote the version")
      ""
    }
    Some(_) => {
      self.root_error("/info/version", "must be a string")
      ""
    }
  }
  (title, version)
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
