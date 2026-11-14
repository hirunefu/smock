// Reading a Descriptor set whole: decoding it, then checking that it is
// self-contained, with each file once, each full name defined once and
// every type it names resolved, and indexing it for the lookups in
// lookups.mbt. Everything a lookup reads is built here, once.

///|
/// Why bytes are not a Descriptor set that the module can read.
#derive(Eq, Debug)
pub(all) suberror DescriptorSetError {
  /// The bytes are not a FileDescriptorSet in protobuf's binary encoding.
  NotDecoded(DecodeError)
  /// The set decodes, but is not self-contained, or not consistent: one
  /// sentence for each problem, in the order of the set.
  Invalid(ReadOnlyArray[String])
}

///|
/// Shows the decoding error as `DecodeError` shows it, or the problems,
/// one per line.
pub impl Show for DescriptorSetError with fn output(self, logger) {
  match self {
    NotDecoded(err) => Show::output(err, logger)
    Invalid(problems) => logger.write_string(problems.join("\n"))
  }
}

///|
/// Reads `input`, a FileDescriptorSet in protobuf's binary encoding, as
/// `protoc --include_imports -o` and `buf build -o` write it, and checks
/// it.
///
/// It keeps the descriptor model: each file's name, package, syntax and
/// dependencies; its messages, nested ones included, with their fields,
/// oneofs, extension ranges and the options `map_entry` and
/// `message_set_wire_format`; its enums and their values; its extensions;
/// and its services and methods. Of a field it keeps the number, label,
/// type, type name, extendee, JSON name, oneof, proto3 `optional` and the
/// option `packed`. It skips every other field, such as source info, other
/// options and Buf's image extensions.
///
/// Raises `NotDecoded` when the input is not protobuf, when a field it keeps
/// has another wire type than descriptor.proto gives it, when a string it
/// keeps is not UTF-8, and when a syntax, a label or a type is not one that
/// descriptor.proto defines.
///
/// Raises `Invalid`, with every problem, when the set is not one that
/// protoc could have written:
/// - a file is in the set more than once, or imports a file that is not in
///   it;
/// - a full name is defined twice: a package, message, enum, enum value
///   (in the scope that holds its enum, as protobuf scopes them), field,
///   oneof, extension, service or method;
/// - a message uses a field number twice, or a field names a oneof its
///   message does not have;
/// - a type that a field, an extension or a method names is not defined in
///   the set as the kind of type it needs, or a field has no type;
/// - an extension's number is not one that its message declares for
///   extensions, or is used by another extension of the same message.
///
/// Type names are checked only when every import is in the set and every
/// full name is defined once, so a missing import gives no other problem.
/// A type may be defined in any file of the set.
pub fn read_descriptor_set(
  input : BytesView,
) -> DescriptorSet raise DescriptorSetError {
  let names = { left: max_name_length, }
  let files = read_files(input, names) catch {
    err =>
      raise if names.left < 0 {
        Invalid([too_many_names])
      } else {
        NotDecoded(err)
      }
  }
  let set = {
    files,
    all_messages: [],
    message_index: Map([]),
    all_enums: [],
    enum_index: Map([]),
    methods: Map([]),
    extensions: Map([]),
  }
  let checker = Checker::new(set, names)
  checker.check() catch {
    _ => raise Invalid([too_many_names])
  }
  if checker.problems.length() > 0 {
    raise Invalid(ReadOnlyArray::from_array(checker.problems))
  }
  set
}

///|
/// The kinds of definition that a full name can name.
priv enum Kind {
  Package
  Message
  Enum
  EnumValue
  Field
  Oneof
  Extension
  Service
  Method
}

///|
/// The kind, with its article, such as `a message`.
impl Show for Kind with fn output(self, logger) {
  logger.write_string(
    match self {
      Package => "a package"
      Message => "a message"
      Enum => "an enum"
      EnumValue => "an enum value"
      Field => "a field"
      Oneof => "a oneof"
      Extension => "an extension"
      Service => "a service"
      Method => "a method"
    },
  )
}

///|
/// What a full name names, and in which file.
priv struct Symbol {
  /// The kind of definition.
  kind : Kind
  /// The name of the file that defines it.
  file : String
}

///|
/// Checks a set and builds its indexes, collecting the problems.
priv struct Checker {
  /// The set being checked.
  set : DescriptorSet
  /// The problems found, in order.
  problems : Array[String]
  /// Every full name defined so far.
  symbols : Map[String, Symbol]
  /// The fields of every message, to resolve.
  fields : Array[FieldDescriptor]
  /// Every extension, to resolve.
  extensions : Array[FieldDescriptor]
  /// Every method, with its full name, to resolve.
  methods : Array[(String, MethodDescriptor)]
  /// What is left of the bound on full names.
  names : Names
}

///|
/// A checker of `set`, which has no index yet, whose full names take
/// what `names` has left.
fn Checker::new(set : DescriptorSet, names : Names) -> Checker {
  {
    set,
    problems: [],
    symbols: Map([]),
    fields: [],
    extensions: [],
    methods: [],
    names,
  }
}

///|
/// Checks the set and indexes it: files, imports and full names first,
/// then, when they hold no problem, the types that the set names.
fn Checker::check(self : Checker) -> Unit raise DecodeError {
  let seen : Map[String, Bool] = Map([])
  let files = []
  for file in self.set.files {
    match seen.get(file.name) {
      None => {
        seen[file.name] = false
        files.push(file)
      }
      Some(false) => {
        self.problems.push("the file \{file.name} is in the set more than once")
        seen[file.name] = true
      }
      Some(true) => ()
    }
  }
  for file in files {
    for dependency in file.dependencies {
      if !seen.contains(dependency) {
        self.problems.push(
          "\{file.name} imports \{dependency}, which is not in the set; build the set with protoc --include_imports, or with buf build",
        )
      }
    }
  }
  for file in files {
    self.define_file(file)
  }
  if self.problems.length() == 0 {
    self.resolve()
  }
}

///|
/// Defines `name` as a `kind` of `file`, or reports that it is defined
/// already. A package may be defined by many files.
fn Checker::add_symbol(
  self : Checker,
  name : String,
  kind : Kind,
  file : String,
) -> Unit {
  match self.symbols.get(name) {
    None => self.symbols[name] = { kind, file, }
    Some({ kind: Package, .. }) if kind is Package => ()
    Some(first) =>
      self.problems.push(
        "the name \{name} is defined twice, as \{first.kind} in \{first.file} and as \{kind} in \{file}",
      )
  }
}

///|
/// Defines what `file` defines, and indexes its messages, enums,
/// extensions and methods.
fn Checker::define_file(
  self : Checker,
  file : FileDescriptor,
) -> Unit raise DecodeError {
  if file.package_name != "" {
    // A package a.b defines the packages a and a.b.
    let mut end = 0
    while end < file.package_name.length() {
      end = end + 1
      if end == file.package_name.length() ||
        file.package_name.unsafe_get(end) == '.' {
        self.names.take(end)
        self.add_symbol(file.package_name[:end].to_owned(), Package, file.name)
      }
    }
  }
  for message in file.messages {
    self.define_message(message, file.name)
  }
  for enum_ in file.enums {
    self.define_enum(enum_, file.package_name, file.name)
  }
  for extension in file.extensions {
    self.define_extension(extension, file.name)
  }
  for service in file.services {
    self.add_symbol(service.full_name, Service, file.name)
    for rpc in service.methods {
      let full_name = self.names.join(service.full_name, rpc.name)
      self.add_symbol(full_name, Method, file.name)
      self.names.take(service.full_name.length() + rpc.name.length() + 2)
      let path = "/\{service.full_name}/\{rpc.name}"
      if !self.set.methods.contains(path) {
        self.set.methods[path] = rpc
      }
      self.methods.push((full_name, rpc))
    }
  }
}

///|
/// Defines `message` of `file`, what it holds and the messages nested in
/// it, and indexes it.
fn Checker::define_message(
  self : Checker,
  message : MessageDescriptor,
  file : String,
) -> Unit raise DecodeError {
  self.add_symbol(message.full_name, Message, file)
  if !self.set.message_index.contains(message.full_name) {
    self.set.message_index[message.full_name] = self.set.all_messages.length()
    self.set.all_messages.push(message)
  }
  for field in message.fields {
    self.add_symbol(field.full_name, Field, file)
    if message.fields_by_number.get(field.number) is Some(first) &&
      !physical_equal(first, field) {
      self.problems.push(
        "the message \{message.full_name} uses field number \{field.number} twice, for \{first.name} and \{field.name}",
      )
    }
    if field.oneof_index is Some(index) &&
      (index < 0 || index >= message.oneofs.length()) {
      self.problems.push(
        "the field \{field.full_name} is in oneof \{index}, which \{message.full_name} does not have",
      )
    }
    self.fields.push(field)
  }
  for oneof in message.oneofs {
    self.add_symbol(self.names.join(message.full_name, oneof.name), Oneof, file)
  }
  for nested in message.messages {
    self.define_message(nested, file)
  }
  for enum_ in message.enums {
    self.define_enum(enum_, message.full_name, file)
  }
  for extension in message.extensions {
    self.define_extension(extension, file)
  }
}

///|
/// Defines `enum_` of `file`, and its values in `scope`, the full name of
/// the package or message that holds the enum, and indexes it.
fn Checker::define_enum(
  self : Checker,
  enum_ : EnumDescriptor,
  scope : String,
  file : String,
) -> Unit raise DecodeError {
  self.add_symbol(enum_.full_name, Enum, file)
  if !self.set.enum_index.contains(enum_.full_name) {
    self.set.enum_index[enum_.full_name] = self.set.all_enums.length()
    self.set.all_enums.push(enum_)
  }
  for value in enum_.values {
    let name = self.names.join(scope, value.name)
    self.add_symbol(name, EnumValue, file)
  }
}

///|
/// Defines `extension` of `file`, and indexes it.
fn Checker::define_extension(
  self : Checker,
  extension : FieldDescriptor,
  file : String,
) -> Unit {
  self.add_symbol(extension.full_name, Extension, file)
  if !self.set.extensions.contains(extension.full_name) {
    self.set.extensions[extension.full_name] = extension
  }
  self.extensions.push(extension)
}

///|
/// The index in the set's `all_messages` of the message that `type_name`
/// names, a full name with or without a leading dot, if the set defines
/// one.
fn Checker::message_named(self : Checker, type_name : String) -> Int32? {
  self.set.message_index.get(without_dot(type_name))
}

///|
/// The index in the set's `all_enums` of the enum that `type_name` names.
fn Checker::enum_named(self : Checker, type_name : String) -> Int32? {
  self.set.enum_index.get(without_dot(type_name))
}

///|
/// `type_name` without its leading dot.
fn without_dot(type_name : String) -> String {
  if type_name.has_prefix(".") {
    type_name[1:].to_owned()
  } else {
    type_name
  }
}

///|
/// Resolves the types that fields, extensions and methods name, and
/// indexes each extension under the message it extends.
fn Checker::resolve(self : Checker) -> Unit {
  for field in self.fields {
    self.resolve_type(field, "field")
  }
  for extension in self.extensions {
    match self.message_named(extension.extendee) {
      None =>
        self.problems.push(
          "the extension \{extension.full_name} extends \{extension.extendee}, which the set does not define as a message",
        )
      Some(index) => {
        let message = self.set.all_messages[index]
        let mut declared = false
        for range in message.extension_ranges {
          if extension.number >= range.start && extension.number < range.end {
            declared = true
          }
        }
        if !declared {
          self.problems.push(
            "the extension \{extension.full_name} has field number \{extension.number}, which \{message.full_name} does not declare for extensions",
          )
        } else {
          match message.extended_by.get(extension.number) {
            Some(first) =>
              self.problems.push(
                "the extensions \{first.full_name} and \{extension.full_name} extend \{message.full_name} with the same field number \{extension.number}",
              )
            None => message.extended_by[extension.number] = extension
          }
        }
      }
    }
    self.resolve_type(extension, "extension")
  }
  for entry in self.methods {
    let (full_name, rpc) = entry
    match self.message_named(rpc.input_type) {
      Some(index) => rpc.input_index = index
      None =>
        self.problems.push(
          "the method \{full_name} takes \{rpc.input_type}, which the set does not define as a message",
        )
    }
    match self.message_named(rpc.output_type) {
      Some(index) => rpc.output_index = index
      None =>
        self.problems.push(
          "the method \{full_name} returns \{rpc.output_type}, which the set does not define as a message",
        )
    }
  }
}

///|
/// Resolves the type of `field`, which is a `what` such as `field`: a
/// message or group type to a message, an enum type to an enum, and a
/// field without a type to whichever its type name names.
fn Checker::resolve_type(
  self : Checker,
  field : FieldDescriptor,
  what : String,
) -> Unit {
  let unresolved = (kind : String) => {
    self.problems.push(
      "the \{what} \{field.full_name} has the type \{field.type_name}, which the set does not define as \{kind}",
    )
  }
  if !field.typed {
    if field.type_name == "" {
      self.problems.push("the \{what} \{field.full_name} has no type")
    } else if self.message_named(field.type_name) is Some(index) {
      field.type_ = Message
      field.type_index = index
    } else if self.enum_named(field.type_name) is Some(index) {
      field.type_ = Enum
      field.type_index = index
    } else {
      unresolved("a message or an enum")
    }
    return
  }
  match field.type_ {
    Message | Group | Enum if field.type_name == "" =>
      self.problems.push(
        "the \{what} \{field.full_name} has the type \{field.type_}, but names no type",
      )
    Message | Group =>
      match self.message_named(field.type_name) {
        Some(index) => field.type_index = index
        None => unresolved("a message")
      }
    Enum =>
      match self.enum_named(field.type_name) {
        Some(index) => field.type_index = index
        None => unresolved("an enum")
      }
    _ => ()
  }
}
