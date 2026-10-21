///|
/// What the `examples` of the media type `key`, written at `pointer`, with
/// the Media Type Object at `media_pointer`, answer with: the first example
/// that gives a value is the response's body, and each further one gets a
/// Stub of its own, which a request selects with `Smock-Example: <name>`.
/// `None` when no example gives a value, so that the next source gives the
/// body.
///
/// A further example whose name a request cannot send in a header gets no
/// Stub, with a warning. As the first example, it still gives the body.
fn Report::examples(
  self : Report,
  document : Document,
  media_pointer : String,
  pointer : String,
  key : String,
  examples : Map[String, Json],
) -> Answers? {
  let mut first = None
  let named = []
  for name, json in examples {
    let at = @definitions.child_pointer(pointer, name)
    guard self.example_value(document, at, key, json) is Some(value) else {
      continue
    }
    if first is None {
      let payload = self.example_payload(document, media_pointer, key, value)
      first = Some({ example: Some(name), payload, })
    } else if !is_sendable(name) {
      self.warning_at(
        at, "left out: no Stub selects this example, since a request cannot send its name in Smock-Example: a name must be non-empty, of visible ASCII characters and spaces, with no space at either end",
      )
    } else {
      let payload = self.example_payload(document, media_pointer, key, value)
      named.push({ example: Some(name), payload, })
    }
  }
  match first {
    Some(first) => Some({ first, named, })
    None => None
  }
}

///|
/// The value of the Example Object `json` at `pointer`, after following
/// its `$ref`, for the media type `key`. For a JSON media type, it is
/// `dataValue`, else `value`, else `serializedValue`; for another one,
/// `serializedValue`, else `dataValue`, else `value`. `None` when it has
/// none of these, with a warning, or after reporting an error.
fn Report::example_value(
  self : Report,
  document : Document,
  pointer : String,
  key : String,
  json : Json,
) -> Value? {
  guard self.followed(document, pointer, json) is Some({ pointer, json, }) else {
    return None
  }
  guard json is Object(example) else {
    self.error_at(pointer, "must be an object")
    return None
  }
  let serialized = match example.get("serializedValue") {
    None => None
    Some(String(text)) =>
      Some(
        Serialized(@definitions.child_pointer(pointer, "serializedValue"), text),
      )
    Some(_) => {
      self.error_at(
        @definitions.child_pointer(pointer, "serializedValue"),
        "must be a string",
      )
      return None
    }
  }
  let data = match (example.get("dataValue"), example.get("value")) {
    (Some(value), _) =>
      Some(Data(@definitions.child_pointer(pointer, "dataValue"), value))
    (None, Some(value)) =>
      Some(Data(@definitions.child_pointer(pointer, "value"), value))
    (None, None) => None
  }
  let value = match (is_json_media_type(key), data, serialized) {
    (true, Some(_), _) | (false, Some(_), None) => data
    _ => serialized
  }
  if value is None {
    if example.contains("externalValue") {
      self.warning_at(
        pointer, "left out: smock does not read externalValue, and the example has no dataValue, value or serializedValue",
      )
    } else {
      self.warning_at(
        pointer, "left out: the example has no dataValue, value or serializedValue",
      )
    }
  }
  value
}

///|
/// What a response of the media type `key`, written at `pointer`, sends
/// for the example value `value`. The value is copied as data, so that a
/// `$ref` member in it stays as written. A value that would nest too deep
/// for the file is left out of the body, with a warning.
fn Report::example_payload(
  self : Report,
  document : Document,
  pointer : String,
  key : String,
  value : Value,
) -> Payload {
  let value = match value {
    Data(at, json) =>
      match self.sampler(document).copied(at, json, body_nesting) {
        Some(json) => Some(Data(at, json))
        None => None
      }
    _ => Some(value)
  }
  self.payload(pointer, key, value)
}

///|
/// Whether a request can send `name` as the value of a header: it is not
/// empty, holds only visible ASCII characters and spaces, and has no space
/// at either end.
fn is_sendable(name : String) -> Bool {
  if name == "" || name.has_prefix(" ") || name.has_suffix(" ") {
    return false
  }
  for c in name {
    if c < ' ' || c > '~' {
      return false
    }
  }
  true
}
