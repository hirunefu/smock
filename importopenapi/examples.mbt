///|
/// What the `examples` of the media type `key`, written at
/// `examples_pointer`, with the Media Type Object at `media_pointer`,
/// answer with: the first example that gives a value is the response's
/// body, and each further one gets a Stub of its own, which a request
/// selects with `Smock-Example: <name>`. `None` when no example gives a
/// value, so that the next source gives the body.
///
/// A further example whose name a request cannot send in a header gets no
/// Stub, with a warning. As the first example, it still gives the body.
fn Conversion::examples(
  self : Conversion,
  media_pointer : Place,
  examples_pointer : Place,
  key : String,
  examples : Map[String, Json],
) -> Answers? {
  let mut first = None
  let named = []
  let serialized_first = !is_json_media_type(key)
  for name, json in examples {
    let at = examples_pointer.child(name)
    guard self.example_value(at, json, serialized_first~) is Some(value) else {
      continue
    }
    if first is None {
      let payload = self.example_payload(media_pointer, key, value)
      first = Some({ example: Some(name), payload, cut: false, })
    } else if !is_sendable(name) {
      self.warning_at(
        at, "left out: no Stub selects this example, since a request cannot send its name in Smock-Example: a name must be non-empty, of visible ASCII characters and spaces, with no space at either end",
      )
    } else {
      let payload = self.example_payload(media_pointer, key, value)
      named.push({ example: Some(name), payload, cut: false, })
    }
  }
  match first {
    Some(first) => Some({ first, named, headers: [], })
    None => None
  }
}

///|
/// The value of the Example Object `json` at `pointer`, after following
/// its `$ref`: `dataValue`, else `value`, else `serializedValue`, as for a
/// JSON media type; or, when `serialized_first` is true, as for another
/// media type and for a header, `serializedValue`, else `dataValue`, else
/// `value`. `None` when it has none of these, with a warning, or after
/// reporting an error.
fn Conversion::example_value(
  self : Conversion,
  pointer : Place,
  json : Json,
  serialized_first~ : Bool,
) -> Value? {
  guard self.report.followed_object(self.document, pointer, json)
    is Some((pointer, example)) else {
    return None
  }
  let serialized = match example.get("serializedValue") {
    None => None
    Some(String(text)) =>
      Some(Serialized(pointer.child("serializedValue"), text))
    Some(_) => {
      self.error_at(pointer.child("serializedValue"), "must be a string")
      return None
    }
  }
  let data = match (example.get("dataValue"), example.get("value")) {
    (Some(value), _) => Some(Data(pointer.child("dataValue"), value))
    (None, Some(value)) => Some(Data(pointer.child("value"), value))
    (None, None) => None
  }
  let value = match (serialized_first, data, serialized) {
    (false, Some(_), _) | (true, Some(_), None) => data
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
fn Conversion::example_payload(
  self : Conversion,
  pointer : Place,
  key : String,
  value : Value,
) -> Payload {
  let value = match value {
    Data(at, json) =>
      match self.report.copied(at, json, body_nesting) {
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
