///|
/// The methods that have their own field in a Path Item, as the document
/// writes them. Each becomes the method in upper case. `query` is 3.2's.
let fixed_methods : Array[String] = [
  "get", "put", "post", "delete", "options", "head", "patch", "trace", "query",
]

///|
/// A Stub the file declares.
priv struct Stub {
  id : String
  meth : String
  /// The exact path it matches.
  path : String
  /// The key of the response it answers, as the document writes it.
  response : String
  status : Int
}

///|
/// An operation that is imported, with its Stubs.
priv struct Imported {
  /// Its path key, as the document writes it.
  key : String
  /// Its `summary`, or `""`.
  summary : String
  /// Whether it is `deprecated`.
  deprecated : Bool
  stubs : Array[Stub]
}

///|
/// What the operations found so far have taken, so that a later one that
/// takes it again is reported.
priv struct Taken {
  /// The method and path conditions of each imported operation, as
  /// `<METHOD> <path>`, and the operation's pointer.
  conditions : Map[String, String]
  /// Each `operationId` of an imported operation, and its pointer.
  operation_ids : Map[String, String]
  /// Each generated Stub ID, and the pointer of its operation.
  ids : Map[String, String]
}

///|
/// Reads every operation under `paths`, in document order: path keys, then
/// methods in the order each Path Item writes them. Returns the imported
/// ones, in that order, with their Stubs.
fn Report::operations(self : Report, document : Document) -> Array[Imported] {
  let imported = []
  let taken = { conditions: {}, operation_ids: {}, ids: {}, }
  match document.top.get("paths") {
    None => ()
    Some(Object(paths)) =>
      for key, item in paths {
        if key.has_prefix("x-") {
          continue
        }
        self.path_item(
          imported,
          taken,
          key,
          @definitions.child_pointer("/paths", key),
          item,
        )
      }
    Some(_) => self.root_error("/paths", "must be an object")
  }
  if imported.is_empty() && self.errors == 0 {
    let pointer = if document.top.contains("paths") { "/paths" } else { "" }
    self.late_document_warning(
      pointer, "there is no operation to import: the file has no Stubs",
    )
  }
  imported
}

///|
/// Reads the operations of the Path Item `json` at the path key `key`.
fn Report::path_item(
  self : Report,
  imported : Array[Imported],
  taken : Taken,
  key : String,
  pointer : String,
  json : Json,
) -> Unit {
  guard self.path(pointer, key) is Some(path) else { return }
  guard json is Object(item) else {
    self.root_error(pointer, "must be an object")
    return
  }
  if self.reference(pointer, item) {
    return
  }
  self.servers_left_out(pointer, item)
  for field, value in item {
    let field_pointer = @definitions.child_pointer(pointer, field)
    if fixed_methods.contains(field) {
      self.operation(
        imported,
        taken,
        key,
        path,
        field.to_upper(),
        field_pointer,
        value,
      )
    } else if field == "additionalOperations" {
      guard value is Object(operations) else {
        self.root_error(field_pointer, "must be an object")
        continue
      }
      for meth, operation in operations {
        let operation_pointer = @definitions.child_pointer(field_pointer, meth)
        if !@http1.is_token(meth) {
          self.root_error(
            operation_pointer, "a method must be an HTTP token, such as COPY",
          )
        } else if fixed_methods.iter().any(field => field.to_upper() == meth) {
          self.root_error(
            operation_pointer,
            "the method \{meth} has its own field, \{meth.to_lower()}, so it cannot be an additional operation",
          )
        } else {
          self.operation(
            imported, taken, key, path, meth, operation_pointer, operation,
          )
        }
      }
    }
  }
}

///|
/// Reads the operation `json`, for the method `meth` at the path key
/// `key`, and imports it, unless a rule leaves it out with a warning.
fn Report::operation(
  self : Report,
  imported : Array[Imported],
  taken : Taken,
  key : String,
  path : PathKind,
  meth : String,
  pointer : String,
  json : Json,
) -> Unit {
  guard json is Object(operation) else {
    self.root_error(pointer, "must be an object")
    return
  }
  guard path is Exact(path) else {
    self.root_warning(
      pointer, "left out: paths with parameters are not imported yet",
    )
    return
  }
  let conditions = "\{meth} \{path}"
  if taken.conditions.get(conditions) is Some(earlier) {
    self.root_warning(
      pointer,
      "left out: \{meth} \{path.escape()} is already answered by the operation at \{self.place(earlier)}, which comes first",
    )
    return
  }
  let id_pointer = @definitions.child_pointer(pointer, "operationId")
  let operation_id = match operation.get("operationId") {
    None => None
    Some(String(id)) if id != "" => Some(id)
    Some(_) => {
      self.root_error(id_pointer, "must be a non-empty string")
      None
    }
  }
  let summary = match operation.get("summary") {
    None => ""
    Some(String(summary)) => summary
    Some(_) => {
      self.root_error(
        @definitions.child_pointer(pointer, "summary"),
        "must be a string",
      )
      ""
    }
  }
  let deprecated = match operation.get("deprecated") {
    None | Some(False) => false
    Some(True) => true
    Some(_) => {
      self.root_error(
        @definitions.child_pointer(pointer, "deprecated"),
        "must be true or false",
      )
      false
    }
  }
  if operation.get("callbacks") is Some(Object(callbacks)) &&
    !callbacks.is_empty() {
    self.root_warning(
      @definitions.child_pointer(pointer, "callbacks"),
      "callbacks are not imported",
    )
  }
  self.servers_left_out(pointer, operation)
  guard self.main_response(pointer, operation) is Some(main) else { return }
  let name = operation_id.unwrap_or("\{meth} \{key}")
  let id = "\{self.options.mock}.\{name}.\{main.key}"
  if operation_id is Some(operation_id) &&
    taken.operation_ids.get(operation_id) is Some(earlier) {
    self.root_error(
      id_pointer,
      "the operationId \{operation_id.escape()} is already used at \{self.place(earlier)}",
    )
  } else if taken.ids.get(id) is Some(earlier) {
    self.root_error(
      pointer,
      "the Stub ID \{id.escape()} is already generated for the operation at \{self.place(earlier)}",
    )
  }
  // The first place keeps its claim, so that each repeat names it.
  taken.conditions[conditions] = pointer
  if operation_id is Some(operation_id) &&
    !taken.operation_ids.contains(operation_id) {
    taken.operation_ids[operation_id] = id_pointer
  }
  if !taken.ids.contains(id) {
    taken.ids[id] = pointer
  }
  imported.push({
    key,
    summary,
    deprecated,
    stubs: [{ id, meth, path, response: main.key, status: main.status, }],
  })
}
