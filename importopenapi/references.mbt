///|
/// A part of the document that the converter reads, after following its
/// Reference Objects: its value, and the pointer where it is written.
/// Problems in it are reported there.
priv struct Part {
  pointer : Place
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
fn Conversion::followed(
  self : Conversion,
  pointer : Place,
  json : Json,
  path_item? : Bool = false,
) -> Part? {
  let mut pointer = pointer
  let mut json = json
  // The Reference Objects followed so far, by pointer.
  let followed = []
  while json is Object(object) && object.get("$ref") is Some(reference) {
    let reference_pointer = pointer.child("$ref")
    guard reference is String(reference) else {
      self.error_at(reference_pointer, "must be a string")
      return None
    }
    if path_item {
      for field, _ in object {
        if field != "$ref" && !field.has_prefix("x-") {
          self.warning_at(
            pointer.child(field),
            "ignored: a field beside a Path Item's $ref has no defined meaning",
          )
        }
      }
    }
    guard self.target(reference_pointer, reference) is Some(target) else {
      return None
    }
    followed.push(pointer)
    if followed.contains(target.pointer) {
      self.error_at(
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
/// The object `json`, written at `pointer` where the converter reads an
/// object that may be a Reference Object, after following each `$ref`, as
/// `Conversion::followed` does: where it is, and its fields. `None` after
/// reporting why a `$ref` cannot be followed, or that the part it leads to
/// is not an object, at that part.
fn Conversion::followed_object(
  self : Conversion,
  pointer : Place,
  json : Json,
  path_item? : Bool = false,
) -> (Place, Map[String, Json])? {
  guard self.followed(pointer, json, path_item~) is Some({ pointer, json, }) else {
    return None
  }
  guard json is Object(object) else {
    self.error_at(pointer, "must be an object")
    return None
  }
  Some((pointer, object))
}

///|
/// The part that `reference`, the `$ref` at `pointer`, names, or `None`
/// after reporting why it cannot be followed, or while the document it
/// names is not given yet.
///
/// A reference is a relative file path, or none for the document it is
/// in, then an optional fragment: an RFC 6901 JSON Pointer, percent-decoded,
/// that may step into arrays. smock reads no URLs and no absolute paths.
fn Conversion::target(
  self : Conversion,
  pointer : Place,
  reference : String,
) -> Part? {
  if has_scheme(reference) || reference.has_prefix("/") {
    self.error_at(pointer, no_urls)
    return None
  }
  let (path, fragment) = match reference.find("#") {
    Some(i) => (reference[:i], reference[i + 1:])
    None => (reference[:], "")
  }
  let (number, json) = if path == "" {
    (pointer.document, self.tree(pointer.document))
  } else {
    guard self.referenced_document(pointer, path.to_owned()) is Some(found) else {
      return None
    }
    found
  }
  let target = @percent.decode_lossy(fragment.to_owned())
  guard pointer_keys(target) is Some(keys) else {
    if target.has_prefix("/") {
      self.error_at(
        pointer, "the fragment must be a JSON Pointer: ~ is written ~0 in it, and / in a key ~1",
      )
    } else {
      self.error_at(
        pointer, "the fragment must be a JSON Pointer, such as #/components/responses/Ok: smock does not look up $anchor names",
      )
    }
    return None
  }
  let mut target_pointer = Place::{ document: number, pointer: "", }
  let mut json = json
  for key in keys {
    guard step(json, key) is Some(value) else {
      if path == "" {
        self.error_at(pointer, "the document has nothing at \{target}")
      } else {
        self.error_at(
          pointer,
          "\{self.report.file_name(number)} has nothing at \{target}",
        )
      }
      return None
    }
    target_pointer = target_pointer.child(key)
    json = value
  }
  Some({ pointer: target_pointer, json, })
}

///|
/// What a reference to a URL or an absolute path is told.
let no_urls : String = "smock reads no URLs and no absolute paths: bundle the document into one file first, with another tool"

///|
/// The tree of the document numbered `number`, or of the root document
/// for `None`. A reference is followed only from a document that was
/// parsed.
fn Conversion::tree(self : Conversion, number : Int?) -> Json {
  match number {
    None => Json::object(self.document.top)
    Some(number) =>
      match self.documents.others[number].content {
        Parsed(json) => json
        _ => Json::null()
      }
  }
}

///|
/// The document that the file path `path` names, from the `$ref` at
/// `pointer`: its number, or `None` for the root, and its tree. Or `None`
/// after reporting why it cannot be read, or while it is not given, after
/// noting that it is needed.
///
/// The path is percent-decoded, and must end in `.json`, `.yaml` or
/// `.yml`. It is resolved against the directory of the document that names
/// it, and must lie under the directory that references are followed in.
/// A document that cannot be read or parsed is reported among the
/// document-level problems.
fn Conversion::referenced_document(
  self : Conversion,
  pointer : Place,
  path : String,
) -> (Int?, Json)? {
  let path = @percent.decode_lossy(path)
  if path.has_prefix("/") {
    self.error_at(pointer, no_urls)
    return None
  }
  if path.contains_char('\u{0}') {
    self.error_at(
      pointer, "a referenced file's path must not hold a NUL character, %00",
    )
    return None
  }
  if !@definitions.is_json_or_yaml_name(path) {
    self.error_at(
      pointer, "a referenced file's name must end in .json, .yaml or .yml",
    )
    return None
  }
  let base = match pointer.document {
    None => self.options.root
    Some(number) => self.documents.others[number].name
  }
  guard resolved(base, path) is Some(name) else {
    self.error_at(
      pointer, "the file is outside --ref-dir: smock follows references only to files under it, by default the root document's directory",
    )
    return None
  }
  if name == self.options.root {
    return Some((None, Json::object(self.document.top)))
  }
  guard self.documents.numbers.get(name) is Some(number) else {
    self.needed.add(name)
    return None
  }
  let given = self.documents.others[number]
  match given.content {
    Parsed(json) => Some((Some(number), json))
    Invalid(pointer~, message~) => {
      self.document_error_at(
        Place::{ document: Some(number), pointer, },
        message,
      )
      None
    }
    Unread(reason) => {
      self.document_error_at(
        pointer,
        "\{given.path} cannot be read: \{reason.to_string()}",
      )
      None
    }
  }
}

///|
/// The name that the relative file path `path` gives from the directory of
/// the document `name`: `/`-separated, without `.`, `..` or empty
/// segments. `None` when it climbs above the directory that names are
/// under.
fn resolved(name : String, path : String) -> String? {
  let segments = name.split("/").map(segment => segment.to_owned()).collect()
  // The document's own name.
  segments.pop() |> ignore
  for segment in path.split("/") {
    match segment {
      "" | "." => ()
      ".." => if segments.pop() is None { return None }
      _ => segments.push(segment.to_owned())
    }
  }
  Some(segments.join("/"))
}

///|
/// The documents of a conversion, as they are given: the root, and the
/// others, which a place names by their number, their index here.
priv struct Documents {
  /// The root's name, and how problems name each document.
  options : Options
  mut root : Content?
  others : Array[Given]
  /// The number of each other document, by name.
  numbers : Map[String, Int]
  /// How many bytes were given in all, until they pass `max_read_bytes`.
  mut bytes : Int
  /// The document with which the bytes given passed `max_read_bytes`, if
  /// any. It is not parsed.
  mut passed : String?
}

///|
/// A document other than the root, as it was given.
priv struct Given {
  /// Its path under the directory that references are followed in.
  name : String
  /// How problems name it.
  path : String
  content : Content
}

///|
/// What is known of a document given to a conversion.
priv enum Content {
  /// Its tree.
  Parsed(Json)
  /// It cannot be parsed: where, and why.
  Invalid(pointer~ : String, message~ : String)
  /// It cannot be read, and why.
  Unread(Unreadable)
}

///|
/// The documents of a conversion with the options `options`: none yet.
fn Documents::new(options : Options) -> Documents {
  { options, root: None, others: [], numbers: {}, bytes: 0, passed: None, }
}

///|
/// How many documents were given, the root included.
fn Documents::count(self : Documents) -> Int {
  self.others.length() + (if self.root is Some(_) { 1 } else { 0 })
}

///|
/// Gives the document `name`, read as `bytes`, and parses it, unless the
/// bytes given pass `max_read_bytes` with it.
fn Documents::give(self : Documents, name : String, bytes : Bytes) -> Unit {
  if self.passed is Some(_) || self.has(name) {
    return
  }
  if bytes.length() > max_read_bytes - self.bytes {
    self.passed = Some(name)
    return
  }
  self.bytes += bytes.length()
  self.add(name, parse(name, bytes))
}

///|
/// Whether the document `name` was given.
fn Documents::has(self : Documents, name : String) -> Bool {
  if name == self.options.root {
    self.root is Some(_)
  } else {
    self.numbers.contains(name)
  }
}

///|
/// Adds the document `name` with `content`, unless it was given already.
fn Documents::add(self : Documents, name : String, content : Content) -> Unit {
  if self.has(name) {
    return
  }
  if name == self.options.root {
    self.root = Some(content)
  } else {
    self.numbers[name] = self.others.length()
    self.others.push({ name, path: self.options.path(name), content, })
  }
}

///|
/// Whether `reference` starts with a URI scheme, such as `https:`, `file:`
/// or `urn:`: a letter, then letters, digits, `+`, `-` or `.`, then `:`.
/// smock reads no URLs: the CLI uses it to say so when the root document
/// it cannot read names one.
pub fn has_scheme(reference : String) -> Bool {
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
/// The member `key` of `json`, an object, or its item at the index that
/// `key` gives, an array: one step of a JSON Pointer. `None` when there is
/// none.
fn step(json : Json, key : String) -> Json? {
  match json {
    Object(object) => object.get(key)
    Array(items) =>
      match array_index(key) {
        Some(i) if i < items.length() => Some(items[i])
        _ => None
      }
    _ => None
  }
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
