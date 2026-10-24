// Duplicate keys in JSON Definition files. The JSON parser keeps the last
// of two members with the same name, so a JSON file that repeats a key
// would load without a word, while the equivalent YAML file is rejected
// with "duplicate key". JSON leaves what such an object means to each
// reader (RFC 8259, section 4), so it is ambiguous, and smock rejects it
// as it rejects the YAML file. The check is public so that the OpenAPI
// import rejects a JSON document that repeats a key in the same way.

///|
/// An object or an array that is open where the scan is.
priv struct Open {
  /// Its JSON Pointer.
  pointer : String
  /// The names of the members so far, for an object; `None` for an array.
  names : Set[String]?
  /// For an array, the index of the element the scan is in.
  mut index : Int32
  /// For an object, whether a member's name comes next rather than its
  /// value.
  mut expects_name : Bool
  /// For an object, the JSON Pointer of the member whose value comes next.
  mut next_value : String
}

///|
/// The JSON Pointer of the value that starts next inside `open`, or of the
/// whole document when nothing is open.
fn value_pointer(open : Array[Open]) -> String {
  match open.last() {
    None => ""
    Some({ names: Some(_), next_value, .. }) => next_value
    Some({ names: None, pointer, index, .. }) =>
      child_pointer(pointer, index.to_string())
  }
}

///|
/// The JSON Pointer of the first key, in the order of `text`, that an
/// earlier member of its object already has, if any. `text` must parse as
/// JSON. Names are compared as they read, after escapes, so `"x"` and
/// `"\u0078"` are the same key. The pointer escapes `~` and `/` as RFC 6901
/// asks.
pub fn first_duplicate_key(text : String) -> String? {
  let open : Array[Open] = []
  let mut i = 0
  while i < text.length() {
    let c = text[i]
    if c == '"' {
      // The scan is in valid JSON, so a quote that no backslash escapes ends
      // the string.
      let mut end = i + 1
      let mut escaped = false
      while text[end] != '"' {
        escaped = escaped || text[end] == '\\'
        end += if text[end] == '\\' { 2 } else { 1 }
      }
      if open.last()
        is Some({ names: Some(names), expects_name: true, .. } as object) {
        let name = if escaped {
          match (@json.parse(text[i:end + 1]) catch { _ => Json::null() }) {
            String(name) => name
            _ => text[i + 1:end].to_owned()
          }
        } else {
          text[i + 1:end].to_owned()
        }
        let pointer = child_pointer(object.pointer, name)
        if names.contains(name) {
          return Some(pointer)
        }
        names.add(name)
        object.next_value = pointer
      }
      i = end + 1
      continue
    }
    match c {
      '{' => {
        let pointer = value_pointer(open)
        open.push({
          pointer,
          names: Some(Set([])),
          index: 0,
          expects_name: true,
          next_value: "",
        })
      }
      '[' => {
        let pointer = value_pointer(open)
        open.push({
          pointer,
          names: None,
          index: 0,
          expects_name: false,
          next_value: "",
        })
      }
      '}' | ']' => open.pop() |> ignore
      ',' =>
        if open.last() is Some(last) {
          last.index += 1
          last.expects_name = true
        }
      ':' => if open.last() is Some(last) { last.expects_name = false }
      _ => ()
    }
    i += 1
  }
  None
}
