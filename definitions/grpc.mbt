// gRPC Stubs: a Stub whose exact path names a method of its Mock's
// Descriptor set, as `/helloworld.Greeter/SayHello` names `SayHello` of the
// service `helloworld.Greeter`. It is an ordinary Stub that carries its
// method. HTTP requests never match it, and it is shadowed only by gRPC
// Stubs. It is checked against its method's types when the files load, and
// what the branch cannot serve yet is refused.

///|
/// The Descriptor sets that the Mocks of the parsed files name, each decoded
/// once, so that a Stub of a Mock declared in any file, earlier or later,
/// knows its Mock's set before it is read.
priv struct DeclaredSets {
  /// Each set that a Mock names and that is in the body-file subdirectory,
  /// by its path there: decoded, or the error that stopped it. A set that
  /// several Mocks name is decoded once.
  by_path : Map[String, DecodedSet]
  /// The set of each Mock whose set decodes, by the Mock's name. When two
  /// Mocks have one name, which is a problem, the first one's.
  by_mock : Map[String, @protobuf.DescriptorSet]
}

///|
/// A body file read as a Descriptor set.
priv enum DecodedSet {
  Decoded(@protobuf.DescriptorSet)
  /// It does not decode, or is not a self-contained set, for these
  /// reasons.
  NotASet(@protobuf.DescriptorSetError)
}

///|
/// No Descriptor sets, for Stubs read without the Definition files' Mocks,
/// such as an Ephemeral Stub.
let no_declared_sets : DeclaredSets = { by_path: Map([]), by_mock: Map([]), }

///|
/// The Descriptor sets that the Mocks of `files` name, from `body_files`.
/// A Mock whose `grpc.descriptorSet` is not a path to a body file names
/// none here: `File::read_mock` reports why.
fn declared_sets(
  files : Array[(String, Result[Map[String, Json], Diagnostic])],
  body_files : Map[String, Bytes],
) -> DeclaredSets {
  let sets = { by_path: Map([]), by_mock: Map([]), }
  for file in files {
    guard file.1 is Ok(top) && top.get("mocks") is Some(Array(mocks)) else {
      continue
    }
    for mock in mocks {
      guard mock is Object(mock) &&
        mock.get("name") is Some(String(name)) &&
        mock.get("grpc") is Some(Object(grpc)) &&
        grpc.get("descriptorSet") is Some(String(path)) &&
        is_inside(path) &&
        body_files.get(path) is Some(bytes) else {
        continue
      }
      let decoded = match sets.by_path.get(path) {
        Some(decoded) => decoded
        None => {
          let decoded = decode_set(bytes)
          sets.by_path[path] = decoded
          decoded
        }
      }
      if decoded is Decoded(set) && !sets.by_mock.contains(name) {
        sets.by_mock[name] = set
      }
    }
  }
  sets
}

///|
/// `bytes` read as a Descriptor set, or the error that stops it.
fn decode_set(bytes : Bytes) -> DecodedSet {
  Decoded(@protobuf.read_descriptor_set(bytes)) catch {
    err => NotASet(err)
  }
}

///|
/// Whether `path`, relative to the body-file subdirectory, stays inside it:
/// its names are not empty, and none starts with `.`, as smock skips such
/// files.
fn is_inside(path : String) -> Bool {
  path.split("/").all(name => !name.is_empty() && !name.has_prefix("."))
}

///|
/// The method a Stub's exact path names in a Descriptor set, with its name
/// as the path gives it.
priv struct NamedMethod {
  /// The path without its leading `/`, such as
  /// `helloworld.Greeter/SayHello`.
  name : String
  /// The method, as the set declares it.
  rpc : @protobuf.MethodDescriptor
  /// The set.
  set : @protobuf.DescriptorSet
}

///|
/// The method that `stub`, a Stub as written, names in its Mock's set, if
/// it is a gRPC Stub: its `mock` names a Mock with a set, and its exact
/// `request.path` names a method of it: `/`, a service's full name, `/`
/// and the name of one of its methods. A CRUD Stub is never one: it has no
/// request path.
fn File::grpc_method_of(self : File, stub : Map[String, Json]) -> NamedMethod? {
  guard !stub.contains("crud") &&
    stub.get("mock") is Some(String(mock)) &&
    self.sets.by_mock.get(mock) is Some(set) &&
    stub.get("request") is Some(Object(request)) &&
    request.get("path") is Some(String(path)) &&
    set.find_method(path) is Some(rpc) else {
    return None
  }
  Some({ name: path[1:].to_owned(), rpc, set, })
}

///|
/// Checks the gRPC Stub `stub`, at `pointer`, against `named`, the method
/// its exact path names. Its fields must be served, as
/// `File::refuse_unserved` says. The method must be unary. Its input and
/// output types must be served, each on its own, as `File::check_input`
/// and `File::check_served` say. Each static `json` reply is checked
/// against the output type.
fn File::check_grpc_stub(
  self : File,
  pointer : String,
  stub : Map[String, Json],
  named : NamedMethod,
) -> Unit {
  self.refuse_unserved(pointer, stub)
  let rpc = named.rpc
  let path = child_pointer(child_pointer(pointer, "request"), "path")
  let streaming = match (rpc.client_streaming, rpc.server_streaming) {
    (false, false) => None
    (true, false) => Some("client-streaming")
    (false, true) => Some("server-streaming")
    (true, true) => Some("bidi-streaming")
  }
  if streaming is Some(streaming) {
    self.error(
      path,
      "the method \{named.name} is \{streaming}, and smock serves only unary methods: streaming methods are planned for R3",
    )
    return
  }
  self.check_input(path, named.set, named.set.input_of(rpc))
  let output = named.set.output_of(rpc)
  self.check_served(path, "output", output)
  if stub.get("response") is Some(Object(response)) {
    self.check_reply(child_pointer(pointer, "response"), response, output)
  }
  if stub.get("responses") is Some(Array(responses)) {
    let at = child_pointer(pointer, "responses")
    for i, response in responses {
      if response is Object(response) {
        self.check_reply(child_pointer(at, i.to_string()), response, output)
      }
    }
  }
}

///|
/// Checks the `json` of `response`, the reply at `pointer`, against
/// `output`, unless it is templated: a templated reply is checked once
/// rendered.
fn File::check_reply(
  self : File,
  pointer : String,
  response : Map[String, Json],
  output : @protobuf.MessageDescriptor,
) -> Unit {
  if response.get("template") is Some(True) {
    return
  }
  if response.get("json") is Some(json) {
    self.check_message(child_pointer(pointer, "json"), json, output)
  }
}

///|
/// Checks `json`, the value at `pointer`, as a message of the type
/// `message`: an object whose keys name its fields, each with a value of
/// the field's type. A field of a type that gRPC Stubs do not serve yet is
/// reported where the method is named, so its value is not checked.
fn File::check_message(
  self : File,
  pointer : String,
  json : Json,
  message : @protobuf.MessageDescriptor,
) -> Unit {
  guard json is Object(members) else {
    self.error(
      pointer,
      "must be an object: the reply is a \{message.full_name} message",
    )
    return
  }
  for key, value in members {
    let at = child_pointer(pointer, key)
    match message.find_field_by_name(key) {
      Some(field) => self.check_value(at, value, field, message)
      None => self.error(at, "is not a field of \{message.full_name}")
    }
  }
}

///|
/// Checks `json`, the value at `pointer`, as a value of `field`, a field of
/// `message`.
fn File::check_value(
  self : File,
  pointer : String,
  json : Json,
  field : @protobuf.FieldDescriptor,
  message : @protobuf.MessageDescriptor,
) -> Unit {
  if field.label is Repeated {
    return
  }
  let wanted = match (field.type_, json) {
    (String, String(_)) | (Bool, True | False) => return
    (Int32, Number(n, ..)) if n == n.floor() &&
      n >= @int.MIN_VALUE.to_double() &&
      n <= @int.MAX_VALUE.to_double() => return
    (String, _) => "a string"
    (Bool, _) => "true or false"
    (Int32, _) => "an integer from \{@int.MIN_VALUE} to \{@int.MAX_VALUE}"
    _ => return
  }
  let type_ = field.type_.to_string()
  self.error(
    pointer,
    "must be \{wanted}: the field \{field.name} of \{message.full_name} is \{article(type_)} \{type_}",
  )
}

///|
/// The indefinite article of `word`: `an` before a vowel, else `a`.
fn article(word : String) -> String {
  match word.get_char(0) {
    Some('a' | 'e' | 'i' | 'o' | 'u') => "an"
    _ => "a"
  }
}

///|
/// Reports at `pointer`, a gRPC Stub's path, what gRPC Stubs do not serve
/// yet of `input`, the input type of its method, a message of `set`, and
/// of each message type it reaches through its fields, each once: a type
/// of a file that is not proto3, and each field that is repeated, a map
/// included, in a oneof other than a proto3 `optional` field's, or of a
/// well-known type. Every other singular field is served: one of any scalar
/// type, of an enum, or of a message, which is checked in turn.
fn File::check_input(
  self : File,
  pointer : String,
  set : @protobuf.DescriptorSet,
  input : @protobuf.MessageDescriptor,
) -> Unit {
  let not_served = "the input type \{input.full_name} is not served yet"
  let later = "and gRPC Stubs serve no repeated fields, maps or oneofs in requests so far"
  let seen : Set[String] = Set([input.full_name])
  let pending = [input]
  while pending.pop() is Some(message) {
    let reached = message.full_name != input.full_name
    let syntax = match message.syntax {
      Proto3 => None
      Proto2 => Some("a proto2 file")
      Editions => Some("an editions file")
    }
    if syntax is Some(syntax) {
      let defines = if reached {
        "\{message.full_name}, a type it reaches"
      } else {
        "it"
      }
      self.error(
        pointer,
        "\{not_served}: \{message.file_name}, which defines \{defines}, is \{syntax}, and gRPC Stubs serve only types of proto3 files so far",
      )
      continue
    }
    let reached_types = []
    for field in message.fields {
      let type_ = set.message_of(field)
      let problem = if field.label is Repeated {
        if type_ is Some({ map_entry: true, .. }) {
          "is a map, \{later}"
        } else {
          "is repeated, \{later}"
        }
      } else if field.oneof_index is Some(index) && !field.proto3_optional {
        "is in the oneof \{message.oneofs[index].name}, \{later}"
      } else {
        let name = match (type_, set.enum_of(field)) {
          (Some(type_), _) => type_.full_name
          (_, Some(type_)) => type_.full_name
          _ => continue
        }
        if !@protobuf.is_well_known(name) {
          if type_ is Some(type_) && !seen.contains(name) {
            seen.add(name)
            reached_types.push(type_)
          }
          continue
        }
        "has the well-known type \{name}, and gRPC Stubs serve no well-known types so far"
      }
      let field_name = if reached {
        "the field \{field.name} of \{message.full_name}, a type it reaches,"
      } else {
        "its field \{field.name}"
      }
      self.error(pointer, "\{not_served}: \{field_name} \{problem}")
    }
    // The types this one reaches are checked next, in the order of its
    // fields.
    for i = reached_types.length() - 1; i >= 0; i = i - 1 {
      pending.push(reached_types[i])
    }
  }
}

///|
/// Reports at `pointer`, a gRPC Stub's path, what gRPC Stubs do not serve
/// yet of `message`, the output type of its method, as `side` says: a
/// type of a file that is not proto3, each field that is not a singular
/// string, bool or int32, and each field of those types that is in a
/// oneof, or is a proto3 `optional` field, in a synthetic one.
fn File::check_served(
  self : File,
  pointer : String,
  side : String,
  message : @protobuf.MessageDescriptor,
) -> Unit {
  let not_served = "the \{side} type \{message.full_name} is not served yet"
  let syntax = match message.syntax {
    Proto3 => None
    Proto2 => Some("a proto2 file")
    Editions => Some("an editions file")
  }
  if syntax is Some(syntax) {
    self.error(
      pointer,
      "\{not_served}: \{message.file_name}, which defines it, is \{syntax}, and gRPC Stubs serve only types of proto3 files so far",
    )
  }
  for field in message.fields {
    let problem = match (field.label, field.type_) {
      (Repeated, _) => "is repeated"
      (_, String | Bool | Int32) => {
        match field.oneof_index {
          Some(_) if field.proto3_optional =>
            self.error(
              pointer,
              "\{not_served}: its field \{field.name} is a proto3 optional field, and gRPC Stubs serve no optional or oneof fields so far",
            )
          Some(index) =>
            self.error(
              pointer,
              "\{not_served}: its field \{field.name} is in the oneof \{message.oneofs[index].name}, and gRPC Stubs serve no optional or oneof fields so far",
            )
          None => ()
        }
        continue
      }
      (_, Message | Group | Enum) =>
        "has the type \{without_dot(field.type_name)}"
      (_, type_) => "has the type \{type_}"
    }
    self.error(
      pointer,
      "\{not_served}: its field \{field.name} \{problem}, and gRPC Stubs serve only singular string, bool and int32 fields so far",
    )
  }
}

///|
/// A full name as a Descriptor set writes it, such as `.helloworld.Hello`,
/// without its leading dot.
fn without_dot(name : String) -> String {
  if name.has_prefix(".") {
    name[1:].to_owned()
  } else {
    name
  }
}

///|
/// Reports each member of the gRPC Stub `stub`, at `pointer`, that gRPC
/// Stubs do not serve yet. They serve `id`, `mock`, `priority`, `scenario`,
/// `variables`, `dataWrites`, `fault.seed`, `request.method`,
/// `request.path`, `request.headers`, a `json` body condition, and `json`,
/// `template` and `weight` in a reply. A member that no Stub has is
/// reported as unknown where it is read.
fn File::refuse_unserved(
  self : File,
  pointer : String,
  stub : Map[String, Json],
) -> Unit {
  for key, value in stub {
    let at = child_pointer(pointer, key)
    match (key, value) {
      ("fault", Object(fault)) =>
        for name, _ in fault {
          if name is ("delay" | "connection") {
            self.not_served(child_pointer(at, name))
          }
        }
      ("request", Object(request)) =>
        for name, condition in request {
          let field = child_pointer(at, name)
          match (name, condition) {
            ("query" | "cookies", _) => self.not_served(field)
            ("body", String(_)) =>
              self.error(
                field, "an exact-text condition is not served on gRPC Stubs yet",
              )
            ("body", Object(body)) =>
              for kind, _ in body {
                if kind is ("pattern" | "form" | "xml") {
                  self.not_served(child_pointer(field, kind))
                }
              }
            _ => ()
          }
        }
      ("response", Object(response)) => self.refuse_unserved_reply(at, response)
      ("responses", Array(responses)) =>
        for i, response in responses {
          if response is Object(response) {
            self.refuse_unserved_reply(
              child_pointer(at, i.to_string()),
              response,
            )
          }
        }
      _ => ()
    }
  }
}

///|
/// Reports each member of `response`, a reply of a gRPC Stub at `pointer`,
/// that gRPC Stubs do not serve yet: all but `json`, `template` and
/// `weight`.
fn File::refuse_unserved_reply(
  self : File,
  pointer : String,
  response : Map[String, Json],
) -> Unit {
  for name, _ in response {
    if name is ("status" | "headers" | "body" | "bodyFile" | "events" | "llm") {
      self.not_served(child_pointer(pointer, name))
    }
  }
}

///|
/// Reports that the member at `pointer` is not served on gRPC Stubs yet.
fn File::not_served(self : File, pointer : String) -> Unit {
  self.error(pointer, "is not served on gRPC Stubs yet")
}

///|
/// The gRPC Stubs of `path`, the `:path` of a gRPC call, in matching order:
/// the Stubs of the Mock whose exact path it is. A gRPC call is matched
/// against these alone, and its Near miss is chosen among them.
pub fn Mock::grpc_candidates(self : Mock, path : String) -> ReadOnlyArray[Stub] {
  match self.grpc_stubs.get(path) {
    Some(stubs) => stubs
    None => no_stubs
  }
}

///|
/// No Stubs.
let no_stubs : ReadOnlyArray[Stub] = ReadOnlyArray::from_array([])

///|
/// The gRPC Stubs of a Mock that has none, by path: none, shared by every
/// such Mock, so that a Mock without gRPC Stubs holds nothing new for them.
let no_grpc_stubs : Map[String, ReadOnlyArray[Stub]] = Map([])

///|
/// The gRPC Stubs among `stubs`, a Mock's Stubs in matching order, by their
/// exact path, each list in matching order.
fn grpc_stubs_by_path(
  stubs : ReadOnlyArray[Stub],
) -> Map[String, ReadOnlyArray[Stub]] {
  let by_path : Map[String, Array[Stub]] = Map([])
  for stub in stubs {
    if stub.serves
      is Ordinary(
        {
          grpc_method: Some(_),
          request: { path: Some(Has(Exact(path))), .. },
          ..
        }
      ) {
      match by_path.get(path) {
        Some(list) => list.push(stub)
        None => by_path[path] = [stub]
      }
    }
  }
  if by_path.is_empty() {
    return no_grpc_stubs
  }
  let out = Map([])
  for path, list in by_path {
    out[path] = ReadOnlyArray::from_array(list)
  }
  out
}
