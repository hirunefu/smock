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
  for file in set.files {
    for declared in file.services {
      guard full_name(file, declared.name) == service else { continue }
      for rpc in declared.methods {
        if rpc.name == name.to_owned() {
          return Some({ service, rpc, set })
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
  let name = if type_name.has_prefix(".") {
    type_name[1:].to_owned()
  } else {
    type_name
  }
  for file in set.files {
    for message in file.messages {
      if full_name(file, message.name) == name {
        return Some({ name, file, message })
      }
    }
  }
  None
}

///|
/// Checks the gRPC Stub `stub`, at `pointer`, against `named`, the method
/// its exact path names: each static `json` reply against the method's
/// output type.
fn File::check_grpc_stub(
  self : File,
  pointer : String,
  stub : Map[String, Json],
  named : NamedMethod,
) -> Unit {
  guard find_message(named.set, named.rpc.output_type) is Some(output) else {
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
    (Some(Int32), _) =>
      "an integer from \{@int.MIN_VALUE} to \{@int.MAX_VALUE}"
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
