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
  /// The path it matches.
  path : PathCondition
  /// The key of the response it answers, as the document writes it.
  response : String
  status : Int
  /// Whether a request selects it with the header `Smock-Status:
  /// <response>`, as for every response but the main one.
  selected : Bool
  /// The name of the media type's named example its body comes from, if it
  /// comes from one.
  example : String?
  /// Whether a request selects it with the header `Smock-Example:
  /// <example>`, as for every named example but the first.
  named : Bool
  /// What the response sends besides its status.
  payload : Payload
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
  /// The kind of each segment of the path its Stubs match, by which
  /// operations are sorted.
  segments : Array[Segment]
  stubs : Array[Stub]
}

///|
/// What the operations found so far have taken, so that a later one that
/// takes it again is reported.
priv struct Taken {
  /// The method and path conditions of each imported operation, as
  /// `<METHOD> <path>` or `<METHOD> pattern <pattern>`, and the
  /// operation's pointer.
  conditions : Map[String, String]
  /// Each `operationId` of an imported operation, its pointer, and the
  /// path key of the operation.
  operation_ids : Map[String, (String, String)]
  /// Each generated Stub ID, and the pointer of its operation.
  ids : Map[String, String]
}

///|
/// Reads every operation under `paths`, in document order: path keys, then
/// methods in the order each Path Item writes them, so that problems come
/// in that order. Returns the imported ones with their Stubs, sorted by
/// how specific their paths are, so that a concrete path comes before a
/// templated one. The sort is stable: operations whose paths have the same
/// kinds of segments keep the document's order.
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
          document,
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
  // sort_by is not stable, so ties are ordered by their place in the
  // document.
  let order = Array::makei(imported.length(), i => i)
  order.sort_by((a, b) => {
    let by_path = compare_specificity(
      imported[a].segments,
      imported[b].segments,
    )
    if by_path != 0 {
      by_path
    } else {
      a.compare(b)
    }
  })
  order.map(i => imported[i])
}

///|
/// Reads the operations of the Path Item `json` at the path key `key`,
/// after following its `$ref`.
fn Report::path_item(
  self : Report,
  document : Document,
  imported : Array[Imported],
  taken : Taken,
  key : String,
  pointer : String,
  json : Json,
) -> Unit {
  guard self.path(pointer, key) is Some(path) else { return }
  guard self.followed(document, pointer, json, path_item=true)
    is Some({ pointer, json, }) else {
    return
  }
  guard json is Object(item) else {
    self.root_error(pointer, "must be an object")
    return
  }
  self.servers_left_out(pointer, item)
  for field, value in item {
    let field_pointer = @definitions.child_pointer(pointer, field)
    if fixed_methods.contains(field) {
      self.operation(
        document,
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
            document, imported, taken, key, path, meth, operation_pointer, operation,
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
  document : Document,
  imported : Array[Imported],
  taken : Taken,
  key : String,
  path : Path,
  meth : String,
  pointer : String,
  json : Json,
) -> Unit {
  guard json is Object(operation) else {
    self.root_error(pointer, "must be an object")
    return
  }
  // An exact path starts with /, so its conditions never read as a
  // pattern's.
  let (conditions, described) = match path.condition {
    Exact(path) => ("\{meth} \{path}", "\{meth} \{path.escape()}")
    Pattern(pattern) =>
      (
        "\{meth} pattern \{pattern}",
        "\{meth} with the path pattern \{pattern.escape()}",
      )
  }
  if taken.conditions.get(conditions) is Some(earlier) {
    self.root_warning(
      pointer,
      "left out: \{described} is already answered by the operation at \{self.place(earlier)}, which comes first",
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
  guard self.responses(document, pointer, meth, operation) is Some(responses) else {
    return
  }
  let name = operation_id.unwrap_or("\{meth} \{key}")
  // The Stubs that select with more headers come first, so that none is
  // shadowed: the other responses' named examples, the other responses,
  // the main response's named examples, then the main Stub. The main
  // response comes last among the responses.
  let stubs = []
  for response in responses {
    if !response.main {
      for answer in response.answers.named {
        stubs.push(self.stub(name, meth, path, response, answer, named=true))
      }
    }
  }
  for response in responses {
    if response.main {
      for answer in response.answers.named {
        stubs.push(self.stub(name, meth, path, response, answer, named=true))
      }
    }
    let answer = response.answers.first
    stubs.push(self.stub(name, meth, path, response, answer, named=false))
  }
  if operation_id is Some(operation_id) &&
    taken.operation_ids.get(operation_id) is Some((earlier, earlier_key)) {
    // Two path keys can name one Path Item.
    if earlier == id_pointer {
      self.root_error(
        id_pointer,
        "the operationId \{operation_id.escape()} is already used under the path key \{earlier_key.escape()}, which names the same Path Item",
      )
    } else {
      self.root_error(
        id_pointer,
        "the operationId \{operation_id.escape()} is already used at \{self.place(earlier)}",
      )
    }
  } else {
    for stub in stubs {
      if taken.ids.get(stub.id) is Some(earlier) {
        self.root_error(
          pointer,
          "the Stub ID \{stub.id.escape()} is already generated for the operation at \{self.place(earlier)}",
        )
      }
    }
  }
  // The first place keeps its claim, so that each repeat names it.
  taken.conditions[conditions] = pointer
  if operation_id is Some(operation_id) &&
    !taken.operation_ids.contains(operation_id) {
    taken.operation_ids[operation_id] = (id_pointer, key)
  }
  for stub in stubs {
    if !taken.ids.contains(stub.id) {
      taken.ids[stub.id] = pointer
    }
  }
  imported.push({ key, summary, deprecated, segments: path.segments, stubs, })
}

///|
/// The Stub of the operation `name`, for the method `meth` at `path`, that
/// gives `answer`, one of `response`'s. A `named` one is selected by
/// `Smock-Example` too, and its ID ends in the example's name.
fn Report::stub(
  self : Report,
  name : String,
  meth : String,
  path : Path,
  response : Response,
  answer : Answer,
  named~ : Bool,
) -> Stub {
  let id = match answer.example {
    Some(example) if named =>
      "\{self.options.mock}.\{name}.\{response.key}.\{example}"
    _ => "\{self.options.mock}.\{name}.\{response.key}"
  }
  {
    id,
    meth,
    path: path.condition,
    response: response.key,
    status: response.status,
    selected: !response.main,
    example: answer.example,
    named,
    payload: answer.payload,
  }
}
