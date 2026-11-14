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
/// A body file decoded as a Descriptor set.
priv enum DecodedSet {
  Decoded(@protobuf.DescriptorSet)
  /// It does not decode, for this reason.
  NotASet(@protobuf.DecodeError)
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
/// `bytes` decoded as a Descriptor set, or the error that stops it.
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
/// The method a Stub's exact path names in a Descriptor set, with the full
/// name of its service.
priv struct NamedMethod {
  /// The full name of the service, such as `helloworld.Greeter`.
  service : String
  /// The method, as the set declares it.
  rpc : @protobuf.MethodDescriptor
  /// The set.
  set : @protobuf.DescriptorSet
}

///|
/// The method that `stub`, a Stub as written, names in its Mock's set, if
/// it is a gRPC Stub: its `mock` names a Mock with a set, and its exact
/// `request.path` names a method of it. A CRUD Stub is never one: it has
/// no request path.
fn File::grpc_method_of(self : File, stub : Map[String, Json]) -> NamedMethod? {
  guard !stub.contains("crud") &&
    stub.get("mock") is Some(String(mock)) &&
    self.sets.by_mock.get(mock) is Some(set) &&
    stub.get("request") is Some(Object(request)) &&
    request.get("path") is Some(String(path)) else {
    return None
  }
  method_named(set, path)
}

///|
/// The method that `path` names in `set`, if any: the path is `/`, a
/// service's full name, `/` and the name of one of its methods.
fn method_named(set : @protobuf.DescriptorSet, path : String) -> NamedMethod? {
  guard path.has_prefix("/") else { return None }
  let parts = path[1:].to_owned().split("/").collect()
  guard parts is [service, name] else { return None }
  let service = service.to_owned()
  let name = name.to_owned()
  for file in set.files {
    for declared in file.services {
      guard full_name(file, declared.name) == service else { continue }
      for rpc in declared.methods {
        if rpc.name == name {
          return Some({ service, rpc, set, })
        }
      }
    }
  }
  None
}

///|
/// The full name of `name`, declared at the top level of `file`: with the
/// file's package, if it has one.
fn full_name(file : @protobuf.FileDescriptor, name : String) -> String {
  if file.package_name == "" {
    name
  } else {
    "\{file.package_name}.\{name}"
  }
}

///|
/// A message type of a Descriptor set, found by its full name.
priv struct FoundMessage {
  /// Its full name, such as `helloworld.HelloReply`.
  name : String
  /// The file that defines it.
  file : @protobuf.FileDescriptor
  message : @protobuf.MessageDescriptor
}

///|
/// The top-level message of `set` whose full name is `type_name`, as a
/// method names its types, with a leading dot, such as
/// `.helloworld.HelloReply`.
fn find_message(
  set : @protobuf.DescriptorSet,
  type_name : String,
) -> FoundMessage? {
  let name = without_dot(type_name)
  for file in set.files {
    for message in file.messages {
      if full_name(file, message.name) == name {
        return Some({ name, file, message, })
      }
    }
  }
  None
}

///|
/// Checks the gRPC Stub `stub`, at `pointer`, against `named`, the method
/// its exact path names. Its fields must be served, as
/// `File::refuse_unserved` says. The method must be unary. Its input and
/// output types must be served, each on its own, as `File::check_served`
/// says. Each static `json` reply is checked against the output type.
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
      "the method \{named.service}/\{rpc.name} is \{streaming}, and smock serves only unary methods: streaming methods are planned for R3",
    )
    return
  }
  let _ = self.check_served(path, named.set, "input", rpc.input_type)
  guard self.check_served(path, named.set, "output", rpc.output_type)
    is Some(output) else {
    return
  }
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
  output : FoundMessage,
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
  message : FoundMessage,
) -> Unit {
  guard json is Object(members) else {
    self.error(
      pointer,
      "must be an object: the reply is a \{message.name} message",
    )
    return
  }
  let fields = message.message.fields
  for key, value in members {
    let at = child_pointer(pointer, key)
    let mut field = None
    for i in 0..<fields.length() {
      if fields[i].name == key {
        field = Some(fields[i])
        break
      }
    }
    match field {
      Some(field) => self.check_value(at, value, field, message)
      None => self.error(at, "is not a field of \{message.name}")
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
  message : FoundMessage,
) -> Unit {
  if field.label is Repeated {
    return
  }
  let wanted = match (field.type_, json) {
    (Some(String), String(_)) | (Some(Bool), True | False) => return
    (Some(Int32), Number(n, ..)) if n == n.floor() &&
      n >= @int.MIN_VALUE.to_double() &&
      n <= @int.MAX_VALUE.to_double() => return
    (Some(String), _) => "a string"
    (Some(Bool), _) => "true or false"
    (Some(Int32), _) => "an integer from \{@int.MIN_VALUE} to \{@int.MAX_VALUE}"
    _ => return
  }
  let type_ = field.type_.map_or("", type_ => type_.to_string())
  self.error(
    pointer,
    "must be \{wanted}: the field \{field.name} of \{message.name} is \{article(type_)} \{type_}",
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
/// Finds the message type `type_name` of `set`, the input or output type
/// of a gRPC Stub's method, as `side` says, and reports at `pointer`, the
/// Stub's path, what gRPC Stubs do not serve of it yet: a type that is not
/// a top-level message, a type of a file that is not proto3, and each field
/// that is not a singular string, bool or int32. Returns the type, unless
/// it is not found.
fn File::check_served(
  self : File,
  pointer : String,
  set : @protobuf.DescriptorSet,
  side : String,
  type_name : String,
) -> FoundMessage? {
  guard find_message(set, type_name) is Some(found) else {
    self.error(
      pointer,
      "the \{side} type \{without_dot(type_name)} is not served yet: it is not a top-level message of the Descriptor set, and gRPC Stubs serve only those so far",
    )
    return None
  }
  let not_served = "the \{side} type \{found.name} is not served yet"
  let syntax = match found.file.syntax {
    Proto3 => None
    Proto2 => Some("a proto2 file")
    Editions => Some("an editions file")
  }
  if syntax is Some(syntax) {
    self.error(
      pointer,
      "\{not_served}: \{found.file.name}, which defines it, is \{syntax}, and gRPC Stubs serve only types of proto3 files so far",
    )
  }
  for field in found.message.fields {
    let problem = match (field.label, field.type_) {
      (Repeated, _) => "is repeated"
      (_, Some(String | Bool | Int32)) => continue
      (_, Some(type_)) if field.type_name == "" => "has the type \{type_}"
      (_, _) => "has the type \{without_dot(field.type_name)}"
    }
    self.error(
      pointer,
      "\{not_served}: its field \{field.name} \{problem}, and gRPC Stubs serve only singular string, bool and int32 fields so far",
    )
  }
  Some(found)
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
