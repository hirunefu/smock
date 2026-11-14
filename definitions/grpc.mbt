// gRPC Stubs: a Stub whose exact path names a method of its Mock's
// Descriptor set, as `/helloworld.Greeter/SayHello` names `SayHello` of the
// service `helloworld.Greeter`. It is an ordinary Stub that carries its
// method. HTTP requests never match it, and it is shadowed only by gRPC
// Stubs. It is checked against its method's types when the files load,
// what the branch cannot serve yet is refused, and its static replies are
// encoded with its output type.

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
/// `File::refuse_unserved` says. The method must be unary. Its input type
/// must be served, as `File::check_input` says, and its output type, as
/// `File::check_output` says. Returns the output type when it is served,
/// so that the Stub's static replies are encoded with it.
fn File::check_grpc_stub(
  self : File,
  pointer : String,
  stub : Map[String, Json],
  named : NamedMethod,
) -> @protobuf.MessageDescriptor? {
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
    return None
  }
  self.check_input(path, named.set, named.set.input_of(rpc))
  let output = named.set.output_of(rpc)
  if self.check_output(path, named.set, output) {
    Some(output)
  } else {
    None
  }
}

///|
/// The reply message of `json`, a gRPC Stub's response at `pointer`,
/// encoded with `output`, a type of `set`: its `json`, read as ProtoJSON,
/// or an empty message without one. `None` for a templated response, whose
/// message is encoded once rendered, and for a reply that is not a message
/// of the type, which is reported at the JSON Pointer of the value at
/// fault.
fn File::encode_reply(
  self : File,
  pointer : String,
  json : Json,
  set : @protobuf.DescriptorSet,
  output : @protobuf.MessageDescriptor,
) -> EncodedMessage? {
  guard json is Object(response) else { return None }
  if response.get("template") is Some(True) {
    return None
  }
  let message = match response.get("json") {
    Some(json) =>
      set.encode_json(output, json) catch {
        EncodeError(pointer=at, message~) => {
          self.error(child_pointer(pointer, "json") + at, message)
          return None
        }
      }
    None => b""
  }
  Some({ output, message, })
}

///|
/// Reports at `pointer`, a gRPC Stub's path, what gRPC Stubs do not serve
/// yet of `output`, the output type of its method, a message of `set`, and
/// of each message type it reaches through its fields, each once, a map's
/// values included: a type of a file that is not proto3, and each field of
/// a well-known type. Every other field is served, as `File::check_input`
/// words its problems. Returns whether every type it reaches is served.
fn File::check_output(
  self : File,
  pointer : String,
  set : @protobuf.DescriptorSet,
  output : @protobuf.MessageDescriptor,
) -> Bool {
  let not_served = "the output type \{output.full_name} is not served yet"
  if @protobuf.is_well_known(output.full_name) {
    self.error(
      pointer,
      "\{not_served}: it is a well-known type, and gRPC Stubs serve no well-known types so far",
    )
    return false
  }
  let mut served = true
  let seen : Set[String] = Set([output.full_name])
  let pending = [output]
  while pending.pop() is Some(message) {
    let reached = message.full_name != output.full_name
    if syntax_name(message.syntax) is Some(syntax) {
      let defines = if reached {
        "\{message.full_name}, a type it reaches"
      } else {
        "it"
      }
      self.error(
        pointer,
        "\{not_served}: \{message.file_name}, which defines \{defines}, is \{syntax}, and gRPC Stubs serve only types of proto3 files so far",
      )
      served = false
      continue
    }
    let reached_types = []
    for field in message.fields {
      // A map field reaches the type of its values.
      let value = match set.message_of(field) {
        Some(entry) if entry.map_entry =>
          entry.find_field_by_number(2).unwrap_or(field)
        _ => field
      }
      let type_ = set.message_of(value)
      let name = match (type_, set.enum_of(value)) {
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
      let field_name = if reached {
        "the field \{field.name} of \{message.full_name}, a type it reaches,"
      } else {
        "its field \{field.name}"
      }
      self.error(
        pointer,
        "\{not_served}: \{field_name} has the well-known type \{name}, and gRPC Stubs serve no well-known types so far",
      )
      served = false
    }
    // The types this one reaches are checked next, in the order of its
    // fields.
    for i = reached_types.length() - 1; i >= 0; i = i - 1 {
      pending.push(reached_types[i])
    }
  }
  served
}

///|
/// The syntax `syntax` as a problem names it, such as `a proto2 file`, or
/// `None` for proto3, which gRPC Stubs serve.
fn syntax_name(syntax : @protobuf.Syntax) -> String? {
  match syntax {
    Proto3 => None
    Proto2 => Some("a proto2 file")
    Editions => Some("an editions file")
  }
}

///|
/// Reports at `pointer`, a gRPC Stub's path, what gRPC Stubs do not serve
/// yet of `input`, the input type of its method, a message of `set`, and
/// of each message type it reaches through its fields, a map's values
/// included, each once: a type of a file that is not proto3, and each
/// field of a well-known type, or a map whose values have one. Every other
/// field is served, singular or repeated, a map or in a oneof: one of any
/// scalar type, of an enum, or of a message, which is checked in turn.
fn File::check_input(
  self : File,
  pointer : String,
  set : @protobuf.DescriptorSet,
  input : @protobuf.MessageDescriptor,
) -> Unit {
  let not_served = "the input type \{input.full_name} is not served yet"
  let later = "and gRPC Stubs serve no well-known types so far"
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
      // A map's values are checked as the field's own values are.
      let (value, map) = match set.message_of(field) {
        Some(entry) if field.label is Repeated && entry.map_entry =>
          match entry.find_field_by_number(2) {
            Some(value) => (value, true)
            None => (field, false)
          }
        _ => (field, false)
      }
      let name = match (set.message_of(value), set.enum_of(value)) {
        (Some(type_), _) => type_.full_name
        (_, Some(type_)) => type_.full_name
        _ => continue
      }
      if !@protobuf.is_well_known(name) {
        if set.message_of(value) is Some(type_) && !seen.contains(name) {
          seen.add(name)
          reached_types.push(type_)
        }
        continue
      }
      let field_name = if reached {
        "the field \{field.name} of \{message.full_name}, a type it reaches,"
      } else {
        "its field \{field.name}"
      }
      let problem = if map {
        "is a map whose values have the well-known type \{name}"
      } else {
        "has the well-known type \{name}"
      }
      self.error(pointer, "\{not_served}: \{field_name} \{problem}, \{later}")
    }
    // The types this one reaches are checked next, in the order of its
    // fields.
    for i = reached_types.length() - 1; i >= 0; i = i - 1 {
      pending.push(reached_types[i])
    }
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
/// against these alone. Its Near miss is chosen among every gRPC Stub of
/// the Mock, those of `stubs` that are gRPC Stubs.
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
