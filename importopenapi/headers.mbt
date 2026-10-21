///|
/// The response headers that are not imported, without a warning: OpenAPI
/// says to skip `Content-Type`, and smock sets the others itself.
/// Documenting them is common and right.
let headers_smock_sets : Array[String] = [
  "content-type", "content-length", "transfer-encoding", "connection",
]

///|
/// Reads the `headers` of a response, written at `pointer`, and returns
/// the headers the response sends, as (name, value), in the order the
/// document writes them. Each Header Object is read after following its
/// `$ref`.
///
/// `Content-Type`, `Content-Length`, `Transfer-Encoding` and `Connection`
/// are skipped without a warning. A header is left out with a warning when
/// its name is `Smock-Mock`, is not an HTTP token, or repeats an earlier
/// one in another case; these are not read. It is left out with a warning
/// too when its value is one that a header cannot hold.
fn Report::headers(
  self : Report,
  document : Document,
  pointer : String,
  headers : Map[String, Json],
) -> Array[(String, String)] {
  let written = []
  // Each header name so far, as written, by its lower case.
  let names : Map[String, String] = Map([])
  for name, json in headers {
    let lower = name.to_lower()
    if headers_smock_sets.contains(lower) {
      continue
    }
    let at = @definitions.child_pointer(pointer, name)
    if lower == "smock-mock" {
      self.warning_at(
        at, "left out: smock adds Smock-Mock itself, when the Default Mock answers",
      )
      continue
    }
    if !@http1.is_token(name) {
      self.warning_at(
        at, "left out: a header name must be an HTTP token, such as X-Rate-Limit",
      )
      continue
    }
    if names.get(lower) is Some(earlier) {
      self.warning_at(
        at,
        "left out: the header name \{earlier.escape()} is already given: header names are case-insensitive",
      )
      continue
    }
    names[lower] = name
    guard self.followed(document, at, json) is Some({ pointer: at, json, }) else {
      continue
    }
    guard json is Object(header) else {
      self.error_at(at, "must be an object")
      continue
    }
    let value = self.header_value(document, at, header)
    guard self.header_text(value) is Some(text) else { continue }
    written.push((name, text))
  }
  written
}

///|
/// The value of the Header Object `header`, written at `pointer`: its
/// `example`, else the first of its `examples` that gives one; else, when
/// it is described with `content`, the value of its media type; else a
/// sample of its `schema`. `None` when it has none of these. A `schema`
/// beside `content` is ignored, with a warning.
fn Report::header_value(
  self : Report,
  document : Document,
  pointer : String,
  header : Map[String, Json],
) -> Value? {
  if self.header_example(document, pointer, header) is Some(value) {
    return Some(value)
  }
  let content_pointer = @definitions.child_pointer(pointer, "content")
  match header.get("content") {
    None => self.header_sample(document, pointer, header)
    Some(Object(content)) => {
      if header.contains("schema") {
        self.warning_at(
          @definitions.child_pointer(pointer, "schema"),
          "ignored: the header has content, which comes first",
        )
      }
      // OpenAPI allows one media type here.
      let mut chosen : String? = None
      let mut value = None
      for key, json in content {
        let at = @definitions.child_pointer(content_pointer, key)
        match chosen {
          Some(chosen) =>
            self.warning_at(
              at,
              "left out: a header's content has one media type, here \{chosen.escape()}",
            )
          None => {
            chosen = Some(key)
            value = self.header_media_type(document, at, json)
          }
        }
      }
      value
    }
    Some(_) => {
      self.error_at(content_pointer, "must be an object")
      None
    }
  }
}

///|
/// The value of the Media Type Object `json` of a header's `content`,
/// written at `pointer`, after following its `$ref`: its `example`, else
/// the first of its `examples` that gives one, else a sample of its
/// `schema`. `None` when it has none of these, or after reporting an
/// error.
fn Report::header_media_type(
  self : Report,
  document : Document,
  pointer : String,
  json : Json,
) -> Value? {
  guard self.followed(document, pointer, json) is Some({ pointer, json, }) else {
    return None
  }
  guard json is Object(media_type) else {
    self.error_at(pointer, "must be an object")
    return None
  }
  match self.header_example(document, pointer, media_type) {
    Some(value) => Some(value)
    None => self.header_sample(document, pointer, media_type)
  }
}

///|
/// The example of a header in `object`, a Header Object or the Media Type
/// Object of its `content`, written at `pointer`: its `example`, else the
/// first of its `examples` that gives one. `None` when it has neither. An
/// Example Object gives its `serializedValue` first, since it is the exact
/// text of the header, then its `dataValue`, then its `value`.
///
/// With both `example` and `examples`, `examples` is ignored, with a
/// warning. The examples after the one that gives the value are left out,
/// with a warning each.
fn Report::header_example(
  self : Report,
  document : Document,
  pointer : String,
  object : Map[String, Json],
) -> Value? {
  let examples_pointer = @definitions.child_pointer(pointer, "examples")
  if object.get("example") is Some(value) {
    if object.contains("examples") {
      self.warning_at(
        examples_pointer, "ignored: a header is written with its example, which comes first",
      )
    }
    return Some(Data(@definitions.child_pointer(pointer, "example"), value))
  }
  match object.get("examples") {
    None => None
    Some(Object(examples)) => {
      let mut value = None
      for name, json in examples {
        let at = @definitions.child_pointer(examples_pointer, name)
        if value is Some(_) {
          self.warning_at(
            at, "left out: a header is written with its first example",
          )
        } else {
          value = self.example_value(document, at, json, serialized_first=true)
        }
      }
      value
    }
    Some(_) => {
      self.error_at(examples_pointer, "must be an object")
      None
    }
  }
}

///|
/// The sample of the `schema` of `object`, a Header Object or the Media
/// Type Object of its `content`, written at `pointer`, within the bounds of
/// a body's sample. `None` when it has none, when the schema gives no
/// value, or when the sample would pass them.
fn Report::header_sample(
  self : Report,
  document : Document,
  pointer : String,
  object : Map[String, Json],
) -> Value? {
  let schema_pointer = @definitions.child_pointer(pointer, "schema")
  match object.get("schema") {
    None => None
    Some(Object(_) | True | False as json) => {
      let part = "the header's value"
      match self.body_sample(document, schema_pointer, json, part~).value {
        Some(sample) => Some(Sampled(schema_pointer, sample))
        None => None
      }
    }
    Some(_) => {
      self.error_at(schema_pointer, "must be a schema, an object or a boolean")
      None
    }
  }
}

///|
/// The text of the header value `value`, or `None` when the header is
/// left out. With no value, the text is empty. A string is the text as it
/// is, a number is written as smock writes numbers, a boolean as `true`
/// or `false`, and an array of these joined with `,`, as style `simple`
/// asks. An object, null, an array that holds either or an array, and a
/// control character other than tab, which a header cannot hold, leave
/// the header out, with a warning where the value comes from.
fn Report::header_text(self : Report, value : Value?) -> String? {
  let (at, text) = match value {
    None => return Some("")
    Some(Serialized(at, text)) => (at, text)
    Some(Data(at, json) | Sampled(at, json)) =>
      match json {
        Array(items) => {
          let text = StringBuilder()
          for i, item in items {
            guard scalar_text(item) is Some(item) else {
              self.warning_at(
                at,
                "left out: a header cannot hold an array that holds \{kind_of(item)}",
              )
              return None
            }
            if i > 0 {
              text.write_char(',')
            }
            text.write_string(item)
          }
          (at, text.to_string())
        }
        _ =>
          match scalar_text(json) {
            Some(text) => (at, text)
            None => {
              self.warning_at(
                at,
                "left out: a header cannot hold \{kind_of(json)}",
              )
              return None
            }
          }
      }
  }
  if !@http1.is_field_value(text) {
    self.warning_at(at, "left out: a header cannot hold a control character")
    return None
  }
  Some(text)
}

///|
/// The text of `json` in a header, when it is a string, a number or a
/// boolean.
fn scalar_text(json : Json) -> String? {
  match json {
    String(text) => Some(text)
    Number(n, repr~) => Some(@template.number_text(n, repr))
    True => Some("true")
    False => Some("false")
    _ => None
  }
}
