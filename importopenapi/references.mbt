///|
/// A part of the document that the converter reads, after following its
/// Reference Objects: its value, and the pointer where it is written.
/// Problems in it are reported there.
priv struct Part {
  pointer : String
  json : Json
}

///|
/// The part `json`, written at `pointer` where the converter reads an
/// object that may be a Reference Object, after following each `$ref` to
/// the part it names. `None` after reporting why a `$ref` cannot be
/// followed.
///
/// The fields beside a `$ref` are ignored. Beside a Path Item's `$ref`,
/// where OpenAPI leaves their meaning undefined, each gets a warning,
/// except `x-` extensions. Beside a Reference Object's, they get none, as
/// OpenAPI asks: its `summary` and `description` only describe.
fn Report::followed(
  self : Report,
  document : Document,
  pointer : String,
  json : Json,
  path_item? : Bool = false,
) -> Part? {
  let mut pointer = pointer
  let mut json = json
  // The Reference Objects followed so far, by pointer.
  let followed = []
  while json is Object(object) && object.get("$ref") is Some(reference) {
    let reference_pointer = @definitions.child_pointer(pointer, "$ref")
    guard reference is String(reference) else {
      self.root_error(reference_pointer, "must be a string")
      return None
    }
    if path_item {
      for field, _ in object {
        if field != "$ref" && !field.has_prefix("x-") {
          self.root_warning(
            @definitions.child_pointer(pointer, field),
            "ignored: a field beside a Path Item's $ref has no defined meaning",
          )
        }
      }
    }
    guard self.target(document, reference_pointer, reference) is Some(target) else {
      return None
    }
    followed.push(pointer)
    if followed.contains(target.pointer) {
      self.root_error(
        reference_pointer,
        "a cycle of references: this one leads back to \{self.place(target.pointer)}",
      )
      return None
    }
    pointer = target.pointer
    json = target.json
  }
  Some({ pointer, json, })
}

///|
/// The part that `reference`, the `$ref` at `pointer`, names, or `None`
/// after reporting why it cannot be followed. It names a part of the same
/// document by its fragment, an RFC 6901 JSON Pointer, percent-decoded,
/// that may step into arrays. smock reads no URLs and no absolute paths.
fn Report::target(
  self : Report,
  document : Document,
  pointer : String,
  reference : String,
) -> Part? {
  if has_scheme(reference) || reference.has_prefix("/") {
    self.root_error(
      pointer, "smock reads no URLs and no absolute paths: bundle the document into one file first, with another tool",
    )
    return None
  }
  // Until references to other files are followed, a reference names the
  // same document: it is empty, or only a fragment.
  guard reference == "" || reference.has_prefix("#") else {
    self.root_error(
      pointer, "references to other files are not followed yet: bundle the document into one file first, with another tool",
    )
    return None
  }
  let target = @percent.decode_lossy(reference.strip_prefix("#").unwrap_or(""))
  guard pointer_keys(target) is Some(keys) else {
    if target.has_prefix("/") {
      self.root_error(
        pointer, "the fragment must be a JSON Pointer: ~ is written ~0 in it, and / in a key ~1",
      )
    } else {
      self.root_error(
        pointer, "the fragment must be a JSON Pointer, such as #/components/responses/Ok: smock does not look up $anchor names",
      )
    }
    return None
  }
  let mut target_pointer = ""
  let mut json = Json::object(document.top)
  for key in keys {
    let value = match json {
      Object(object) => object.get(key)
      Array(items) =>
        match array_index(key) {
          Some(i) if i < items.length() => Some(items[i])
          _ => None
        }
      _ => None
    }
    guard value is Some(value) else {
      self.root_error(pointer, "the document has nothing at \{target}")
      return None
    }
    target_pointer = @definitions.child_pointer(target_pointer, key)
    json = value
  }
  Some({ pointer: target_pointer, json, })
}

///|
/// Whether `reference` starts with a URI scheme, such as `https:`, `file:`
/// or `urn:`: a letter, then letters, digits, `+`, `-` or `.`, then `:`.
fn has_scheme(reference : String) -> Bool {
  for i, c in reference {
    match c {
      ':' => return i > 0
      'a'..='z' | 'A'..='Z' => ()
      '0'..='9' | '+' | '-' | '.' if i > 0 => ()
      _ => return false
    }
  }
  false
}

///|
/// The keys of the RFC 6901 JSON Pointer `pointer`, with `~1` read as `/`
/// and `~0` as `~`, or `None` when it is not a JSON Pointer: when it does
/// not start with `/`, or holds a `~` that `0` or `1` does not follow.
/// The empty pointer names the whole document, and has no key.
fn pointer_keys(pointer : String) -> Array[String]? {
  if pointer == "" {
    return Some([])
  }
  guard pointer.has_prefix("/") else { return None }
  let keys = []
  for token in pointer.split("/").drop(1) {
    let key = StringBuilder()
    let mut escaped = false
    for c in token {
      match (escaped, c) {
        (false, '~') => escaped = true
        (false, _) => key.write_char(c)
        (true, '0') => {
          key.write_char('~')
          escaped = false
        }
        (true, '1') => {
          key.write_char('/')
          escaped = false
        }
        (true, _) => return None
      }
    }
    if escaped {
      return None
    }
    keys.push(key.to_string())
  }
  Some(keys)
}

///|
/// The array index that the JSON Pointer token `token` gives: `0`, or
/// digits without a leading zero. `None` for any other token, `-` among
/// them, which names no item.
fn array_index(token : String) -> Int? {
  guard token != "" && token.length() <= 9 && is_digits(token) else {
    return None
  }
  guard token == "0" || !token.has_prefix("0") else { return None }
  let mut index = 0
  for c in token {
    index = index * 10 + (c.to_int() - '0'.to_int())
  }
  Some(index)
}
