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
          return Some({ service, rpc, })
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
