// Reading a FileDescriptorSet, the compiled form of .proto files that
// `protoc --include_imports -o` and `buf build -o` write, as
// google/protobuf/descriptor.proto defines it. The model keeps what smock
// needs of each file, and skips every other field of the set, such as
// source info, most options and Buf's image extensions.

///|
/// A FileDescriptorSet: compiled .proto files, each once.
#derive(Debug, Eq)
pub struct DescriptorSet {
  /// The files, in the order of the set.
  files : ReadOnlyArray[FileDescriptor]
  /// Every message of the set, nested ones included. A field's or a
  /// method's resolved type is an index in it.
  priv all_messages : Array[MessageDescriptor]
  /// The index in `all_messages` of each message, by its full name.
  priv message_index : Map[String, Int32]
  /// Every enum of the set, nested ones included.
  priv all_enums : Array[EnumDescriptor]
  /// The index in `all_enums` of each enum, by its full name.
  priv enum_index : Map[String, Int32]
  /// Each method, by the path gRPC calls it by.
  priv methods : Map[String, MethodDescriptor]
  /// Each extension, by its full name.
  priv extensions : Map[String, FieldDescriptor]
}

///|
/// A compiled .proto file: a FileDescriptorProto.
#derive(Debug, Eq)
pub struct FileDescriptor {
  /// The file's name, its path relative to the directory it was compiled
  /// from, such as `google/protobuf/timestamp.proto`.
  name : String
  /// Its package, such as `helloworld`, or `""` for none.
  package_name : String
  /// The syntax it is written in.
  syntax : Syntax
  /// The names of the files it imports, in order.
  dependencies : ReadOnlyArray[String]
  /// Its top-level messages, in order.
  messages : ReadOnlyArray[MessageDescriptor]
  /// Its top-level enums, in order.
  enums : ReadOnlyArray[EnumDescriptor]
  /// The extensions it declares at its top level, in order.
  extensions : ReadOnlyArray[FieldDescriptor]
  /// Its services, in order.
  services : ReadOnlyArray[ServiceDescriptor]
}

///|
/// The syntax of a .proto file.
#derive(Debug, Eq)
pub(all) enum Syntax {
  /// `syntax = "proto2"`, which a file without a syntax is.
  Proto2
  /// `syntax = "proto3"`.
  Proto3
  /// An editions file, such as `edition = "2023"`.
  Editions
}

///|
/// A message type: a DescriptorProto.
#derive(Debug, Eq)
pub struct MessageDescriptor {
  /// Its name, without its package or the message it is nested in, such
  /// as `HelloRequest`.
  name : String
  /// Its full name, without a leading dot, such as
  /// `helloworld.HelloRequest`.
  full_name : String
  /// The syntax of the file that defines it.
  syntax : Syntax
  /// Its fields, in the order of the file.
  fields : ReadOnlyArray[FieldDescriptor]
  /// Its oneofs, in order, the synthetic ones of proto3 `optional` fields
  /// included. A field's `oneof_index` is an index in it.
  oneofs : ReadOnlyArray[OneofDescriptor]
  /// The messages nested in it, in order, map entries and groups included.
  messages : ReadOnlyArray[MessageDescriptor]
  /// The enums nested in it, in order.
  enums : ReadOnlyArray[EnumDescriptor]
  /// The extensions declared inside it, in order. They may extend any
  /// message.
  extensions : ReadOnlyArray[FieldDescriptor]
  /// The ranges of field numbers that extensions of it may use.
  extension_ranges : ReadOnlyArray[ExtensionRange]
  /// Whether its option `map_entry` is true: it is the entry type that a
  /// map field names, with the key as field 1 and the value as field 2.
  map_entry : Bool
  /// Whether its option `message_set_wire_format` is true, which makes it
  /// a MessageSet, whose extensions use another wire form.
  message_set_wire_format : Bool
  /// Its fields by number, the first of each number.
  priv fields_by_number : Map[Int32, FieldDescriptor]
  /// Its fields by name.
  priv fields_by_name : Map[String, FieldDescriptor]
  /// Its fields by JSON name, the first of each JSON name.
  priv fields_by_json_name : Map[String, FieldDescriptor]
  /// The extensions of the set that extend it, by number, filled when the
  /// set is checked.
  priv extended_by : Map[Int32, FieldDescriptor]
}

///|
/// A oneof of a message: a OneofDescriptorProto.
#derive(Debug, Eq)
pub struct OneofDescriptor {
  /// Its name, such as `payer`.
  name : String
}

///|
/// A range of field numbers that extensions of a message may use.
#derive(Debug, Eq)
pub struct ExtensionRange {
  /// The first number of the range.
  start : Int32
  /// The number after the last, as descriptor.proto gives it.
  end : Int32
}

///|
/// A field of a message, or an extension: a FieldDescriptorProto.
#derive(Debug, Eq)
pub struct FieldDescriptor {
  /// Its name, as the .proto file spells it.
  name : String
  /// Its full name, without a leading dot, such as
  /// `helloworld.HelloRequest.name`, or `shop.priority` for an extension
  /// declared at the top level of package `shop`.
  full_name : String
  /// Its field number.
  number : Int32
  /// Whether it is optional, required or repeated.
  label : Label
  /// Its type. When the set gives none, it is `Message` or `Enum`, as the
  /// type that `type_name` names is.
  mut type_ : FieldType
  /// The full name of its message, group or enum type, as the set gives
  /// it, such as `.helloworld.HelloRequest`, or `""` for a scalar type.
  type_name : String
  /// For an extension, the full name of the message it extends, as the
  /// set gives it, such as `.shop.Money`; `""` for a field of a message.
  extendee : String
  /// Its JSON name: the `json_name` of the set, or else its name in
  /// lowerCamelCase, as protoc computes it.
  json_name : String
  /// The index of its oneof in its message's `oneofs`, if it is in one.
  oneof_index : Int32?
  /// Whether it is a proto3 `optional` field, in a synthetic oneof.
  proto3_optional : Bool
  /// Its option `packed`, when it gives one.
  packed : Bool?
  /// Whether the set gives its type.
  priv typed : Bool
  /// The index of its message or group type in the set's `all_messages`,
  /// or of its enum type in `all_enums`, once resolved; -1 otherwise.
  priv mut type_index : Int32
}

///|
/// A field's label.
#derive(Debug, Eq)
pub(all) enum Label {
  /// Optional, as every singular proto3 field is, with or without presence.
  Optional
  /// Required: a proto2 field that every message must hold.
  Required
  /// Repeated.
  Repeated
}

///|
/// A field's type.
#derive(Debug, Eq)
pub(all) enum FieldType {
  Double
  Float
  Int64
  UInt64
  Int32
  Fixed64
  Fixed32
  Bool
  String
  /// A proto2 group: a message delimited by group tags.
  Group
  Message
  Bytes
  UInt32
  Enum
  SFixed32
  SFixed64
  SInt32
  SInt64
}

///|
/// Shows the type as a .proto file spells it, such as `uint64`, or as
/// `group`, `message` or `enum`.
pub impl Show for FieldType with fn output(self, logger) {
  logger.write_string(
    match self {
      Double => "double"
      Float => "float"
      Int64 => "int64"
      UInt64 => "uint64"
      Int32 => "int32"
      Fixed64 => "fixed64"
      Fixed32 => "fixed32"
      Bool => "bool"
      String => "string"
      Group => "group"
      Message => "message"
      Bytes => "bytes"
      UInt32 => "uint32"
      Enum => "enum"
      SFixed32 => "sfixed32"
      SFixed64 => "sfixed64"
      SInt32 => "sint32"
      SInt64 => "sint64"
    },
  )
}

///|
/// An enum type: an EnumDescriptorProto.
#derive(Debug, Eq)
pub struct EnumDescriptor {
  /// Its name, such as `Status`.
  name : String
  /// Its full name, without a leading dot, such as `shop.Status`.
  full_name : String
  /// The syntax of the file that defines it.
  syntax : Syntax
  /// Its values, in the order of the file. An alias is a value with the
  /// number of an earlier one.
  values : ReadOnlyArray[EnumValueDescriptor]
  /// Its values by name.
  priv values_by_name : Map[String, EnumValueDescriptor]
  /// Its values by number, the first of each number.
  priv values_by_number : Map[Int32, EnumValueDescriptor]
}

///|
/// A value of an enum: an EnumValueDescriptorProto.
#derive(Debug, Eq)
pub struct EnumValueDescriptor {
  /// Its name, such as `ACTIVE`.
  name : String
  /// Its number.
  number : Int32
}

///|
/// A service: a ServiceDescriptorProto.
#derive(Debug, Eq)
pub struct ServiceDescriptor {
  /// Its name, without its package, such as `Greeter`.
  name : String
  /// Its full name, without a leading dot, such as `helloworld.Greeter`.
  full_name : String
  /// Its methods, in order.
  methods : ReadOnlyArray[MethodDescriptor]
}

///|
/// A method of a service: a MethodDescriptorProto.
#derive(Debug, Eq)
pub struct MethodDescriptor {
  /// Its name, such as `SayHello`.
  name : String
  /// The full name of its input type, as the set gives it, such as
  /// `.helloworld.HelloRequest`.
  input_type : String
  /// The full name of its output type, as the set gives it.
  output_type : String
  /// Whether the client sends a stream of messages.
  client_streaming : Bool
  /// Whether the server sends a stream of messages.
  server_streaming : Bool
  /// The index of its input type in the set's `all_messages`, once
  /// resolved.
  priv mut input_index : Int32
  /// The index of its output type, once resolved.
  priv mut output_index : Int32
}

///|
/// How many characters the full names that a set's names are joined into
/// may take in all. A full name repeats the names of its package and of
/// the messages it is nested in, so a small set could otherwise hold full
/// names many times its size.
let max_name_length : Int32 = 16 * 1024 * 1024

///|
/// What is left of `max_name_length` while a set is read.
priv struct Names {
  /// The characters left.
  mut left : Int32
}

///|
/// The problem of a set whose full names take more than `max_name_length`.
let too_many_names : String = "the full names of the set take more than 16 MiB"

///|
/// Takes `length` characters, or raises `DecodeError` when that passes the
/// bound, which `read_descriptor_set` reports as `too_many_names`.
fn Names::take(self : Names, length : Int32) -> Unit raise DecodeError {
  self.left = self.left - length
  if self.left < 0 {
    raise DecodeError(position=0, message=too_many_names)
  }
}

///|
/// `prefix` and `name` joined with a dot, counted against the bound.
fn Names::join(
  self : Names,
  prefix : String,
  name : String,
) -> String raise DecodeError {
  if prefix == "" {
    return name
  }
  self.take(prefix.length() + 1 + name.length())
  "\{prefix}.\{name}"
}

///|
/// How deep messages may nest, as protobuf's C++ and Java parsers bound
/// messages by default.
let max_message_depth : Int32 = 100

///|
/// Reads the files of a FileDescriptorSet, each with what it indexes of
/// its own messages and enums, counting the full names it builds in
/// `names`. Raises `DecodeError` as `read_descriptor_set` says.
fn read_files(
  input : BytesView,
  names : Names,
) -> ReadOnlyArray[FileDescriptor] raise DecodeError {
  let reader = Reader(input)
  let files = []
  while !reader.at_end() {
    match reader.tag() {
      1 => {
        reader.expect(Len)
        files.push(read_file(reader.length_delimited(), names))
      }
      _ => reader.skip()
    }
  }
  ReadOnlyArray::from_array(files)
}

///|
/// Where a definition is: the full name of its package or message, how
/// deep that message is nested, and the syntax of its file.
priv struct Scope {
  /// The full name of the package or message, or `""` for the root.
  prefix : String
  /// How many messages the scope is nested in: 0 for a package.
  depth : Int32
  /// The syntax of the file.
  syntax : Syntax
  /// What is left of the bound on full names.
  names : Names
}

///|
/// The full name of `name` in `scope`.
fn Scope::full_name(self : Scope, name : String) -> String raise DecodeError {
  self.names.join(self.prefix, name)
}

///|
/// Reads a FileDescriptorProto. Its messages, enums, extensions and
/// services are read once the whole file is, since their full names need
/// its package and their syntax needs its syntax, which may come after
/// them.
fn read_file(
  input : BytesView,
  names : Names,
) -> FileDescriptor raise DecodeError {
  let reader = Reader(input)
  let mut name = ""
  let mut package_name = ""
  let mut syntax = Proto2
  let dependencies = []
  let message_views = []
  let enum_views = []
  let extension_views = []
  let service_views = []
  while !reader.at_end() {
    match reader.tag() {
      1 => name = reader.text()
      2 => package_name = reader.text()
      3 => dependencies.push(reader.text())
      4 => message_views.push(reader.message())
      5 => enum_views.push(reader.message())
      6 => service_views.push(reader.message())
      7 => extension_views.push(reader.message())
      12 => {
        let at = reader.pos
        syntax = match reader.text() {
          "" | "proto2" => Proto2
          "proto3" => Proto3
          "editions" => Editions
          other =>
            raise reader.error(
              at,
              "the syntax \{other.escape()} is not proto2, proto3 or editions",
            )
        }
      }
      _ => reader.skip()
    }
  }
  let scope = { prefix: package_name, depth: 0, syntax, names, }
  let messages = []
  for view in message_views {
    messages.push(read_message(view, scope))
  }
  let enums = []
  for view in enum_views {
    enums.push(read_enum(view, scope))
  }
  let extensions = []
  for view in extension_views {
    extensions.push(read_field(view, scope))
  }
  let services = []
  for view in service_views {
    services.push(read_service(view, scope))
  }
  {
    name,
    package_name,
    syntax,
    dependencies: ReadOnlyArray::from_array(dependencies),
    messages: ReadOnlyArray::from_array(messages),
    enums: ReadOnlyArray::from_array(enums),
    extensions: ReadOnlyArray::from_array(extensions),
    services: ReadOnlyArray::from_array(services),
  }
}

///|
/// Reads a DescriptorProto in `scope`. What it holds is read once the
/// whole message is, since full names need its name. Raises `DecodeError`
/// when messages nest deeper than 100.
fn read_message(
  input : BytesView,
  scope : Scope,
) -> MessageDescriptor raise DecodeError {
  let reader = Reader(input)
  if scope.depth >= max_message_depth {
    raise reader.error(0, "messages nest deeper than \{max_message_depth}")
  }
  let mut name = ""
  let field_views = []
  let message_views = []
  let enum_views = []
  let extension_views = []
  let oneofs = []
  let extension_ranges = []
  let mut map_entry = false
  let mut message_set_wire_format = false
  while !reader.at_end() {
    match reader.tag() {
      1 => name = reader.text()
      2 => field_views.push(reader.message())
      3 => message_views.push(reader.message())
      4 => enum_views.push(reader.message())
      5 => extension_ranges.push(read_extension_range(reader.message()))
      6 => extension_views.push(reader.message())
      7 => {
        // MessageOptions. A message field that repeats is merged, so a
        // later value of an option wins.
        let options = Reader(reader.message())
        while !options.at_end() {
          match options.tag() {
            1 => message_set_wire_format = options.boolean()
            7 => map_entry = options.boolean()
            _ => options.skip()
          }
        }
      }
      8 => oneofs.push(read_oneof(reader.message()))
      _ => reader.skip()
    }
  }
  let full_name = scope.full_name(name)
  let inner = {
    prefix: full_name,
    depth: scope.depth + 1,
    syntax: scope.syntax,
    names: scope.names,
  }
  let fields = []
  for view in field_views {
    fields.push(read_field(view, inner))
  }
  let messages = []
  for view in message_views {
    messages.push(read_message(view, inner))
  }
  let enums = []
  for view in enum_views {
    enums.push(read_enum(view, inner))
  }
  let extensions = []
  for view in extension_views {
    extensions.push(read_field(view, inner))
  }
  let fields_by_number = Map([])
  let fields_by_name = Map([])
  let fields_by_json_name = Map([])
  for field in fields {
    if !fields_by_number.contains(field.number) {
      fields_by_number[field.number] = field
    }
    if !fields_by_name.contains(field.name) {
      fields_by_name[field.name] = field
    }
    if !fields_by_json_name.contains(field.json_name) {
      fields_by_json_name[field.json_name] = field
    }
  }
  {
    name,
    full_name,
    syntax: scope.syntax,
    fields: ReadOnlyArray::from_array(fields),
    oneofs: ReadOnlyArray::from_array(oneofs),
    messages: ReadOnlyArray::from_array(messages),
    enums: ReadOnlyArray::from_array(enums),
    extensions: ReadOnlyArray::from_array(extensions),
    extension_ranges: ReadOnlyArray::from_array(extension_ranges),
    map_entry,
    message_set_wire_format,
    fields_by_number,
    fields_by_name,
    fields_by_json_name,
    extended_by: Map([]),
  }
}

///|
/// Reads a DescriptorProto.ExtensionRange.
fn read_extension_range(input : BytesView) -> ExtensionRange raise DecodeError {
  let reader = Reader(input)
  let mut start = 0
  let mut end = 0
  while !reader.at_end() {
    match reader.tag() {
      1 => start = reader.int32()
      2 => end = reader.int32()
      _ => reader.skip()
    }
  }
  { start, end, }
}

///|
/// Reads a OneofDescriptorProto.
fn read_oneof(input : BytesView) -> OneofDescriptor raise DecodeError {
  let reader = Reader(input)
  let mut name = ""
  while !reader.at_end() {
    match reader.tag() {
      1 => name = reader.text()
      _ => reader.skip()
    }
  }
  { name, }
}

///|
/// Reads a FieldDescriptorProto in `scope`, a field of a message or an
/// extension.
fn read_field(
  input : BytesView,
  scope : Scope,
) -> FieldDescriptor raise DecodeError {
  let reader = Reader(input)
  let mut name = ""
  let mut number = 0
  let mut label = Optional
  let mut type_ = None
  let mut type_name = ""
  let mut extendee = ""
  let mut json_name = None
  let mut oneof_index = None
  let mut proto3_optional = false
  let mut packed = None
  while !reader.at_end() {
    match reader.tag() {
      1 => name = reader.text()
      2 => extendee = reader.text()
      3 => number = reader.int32()
      4 => {
        let at = reader.pos
        label = match reader.int32() {
          1 => Optional
          2 => Required
          3 => Repeated
          other =>
            raise reader.error(at, "the label \{other} is not a field label")
        }
      }
      5 => {
        let at = reader.pos
        type_ = Some(
          match reader.int32() {
            1 => Double
            2 => Float
            3 => Int64
            4 => UInt64
            5 => Int32
            6 => Fixed64
            7 => Fixed32
            8 => Bool
            9 => String
            10 => Group
            11 => Message
            12 => Bytes
            13 => UInt32
            14 => Enum
            15 => SFixed32
            16 => SFixed64
            17 => SInt32
            18 => SInt64
            other =>
              raise reader.error(at, "the type \{other} is not a field type")
          },
        )
      }
      6 => type_name = reader.text()
      8 => {
        // FieldOptions, merged as MessageOptions are.
        let options = Reader(reader.message())
        while !options.at_end() {
          match options.tag() {
            2 => packed = Some(options.boolean())
            _ => options.skip()
          }
        }
      }
      9 => oneof_index = Some(reader.int32())
      10 => json_name = Some(reader.text())
      17 => proto3_optional = reader.boolean()
      _ => reader.skip()
    }
  }
  {
    name,
    full_name: scope.full_name(name),
    number,
    label,
    type_: type_.unwrap_or(Message),
    type_name,
    extendee,
    json_name: json_name.unwrap_or_else(() => lower_camel_case(name)),
    oneof_index,
    proto3_optional,
    packed,
    typed: type_ is Some(_),
    type_index: -1,
  }
}

///|
/// The JSON name protoc gives a field named `name` that sets no
/// `json_name`: each `_` is dropped, and the letter after it is upper-cased.
/// Other letters stay as they are.
fn lower_camel_case(name : String) -> String {
  let out = StringBuilder()
  let mut capitalize_next = false
  for c in name {
    if c == '_' {
      capitalize_next = true
    } else if capitalize_next {
      out.write_char(c.to_ascii_uppercase())
      capitalize_next = false
    } else {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// Reads an EnumDescriptorProto in `scope`.
fn read_enum(
  input : BytesView,
  scope : Scope,
) -> EnumDescriptor raise DecodeError {
  let reader = Reader(input)
  let mut name = ""
  let values = []
  while !reader.at_end() {
    match reader.tag() {
      1 => name = reader.text()
      2 => values.push(read_enum_value(reader.message()))
      _ => reader.skip()
    }
  }
  let values_by_name = Map([])
  let values_by_number = Map([])
  for value in values {
    if !values_by_name.contains(value.name) {
      values_by_name[value.name] = value
    }
    if !values_by_number.contains(value.number) {
      values_by_number[value.number] = value
    }
  }
  {
    name,
    full_name: scope.full_name(name),
    syntax: scope.syntax,
    values: ReadOnlyArray::from_array(values),
    values_by_name,
    values_by_number,
  }
}

///|
/// Reads an EnumValueDescriptorProto.
fn read_enum_value(input : BytesView) -> EnumValueDescriptor raise DecodeError {
  let reader = Reader(input)
  let mut name = ""
  let mut number = 0
  while !reader.at_end() {
    match reader.tag() {
      1 => name = reader.text()
      2 => number = reader.int32()
      _ => reader.skip()
    }
  }
  { name, number, }
}

///|
/// Reads a ServiceDescriptorProto in `scope`.
fn read_service(
  input : BytesView,
  scope : Scope,
) -> ServiceDescriptor raise DecodeError {
  let reader = Reader(input)
  let mut name = ""
  let methods = []
  while !reader.at_end() {
    match reader.tag() {
      1 => name = reader.text()
      2 => methods.push(read_method(reader.message()))
      _ => reader.skip()
    }
  }
  {
    name,
    full_name: scope.full_name(name),
    methods: ReadOnlyArray::from_array(methods),
  }
}

///|
/// Reads a MethodDescriptorProto.
fn read_method(input : BytesView) -> MethodDescriptor raise DecodeError {
  let reader = Reader(input)
  let mut name = ""
  let mut input_type = ""
  let mut output_type = ""
  let mut client_streaming = false
  let mut server_streaming = false
  while !reader.at_end() {
    match reader.tag() {
      1 => name = reader.text()
      2 => input_type = reader.text()
      3 => output_type = reader.text()
      5 => client_streaming = reader.boolean()
      6 => server_streaming = reader.boolean()
      _ => reader.skip()
    }
  }
  {
    name,
    input_type,
    output_type,
    client_streaming,
    server_streaming,
    input_index: -1,
    output_index: -1,
  }
}

///|
/// Reads the value of a `string` field of descriptor.proto: a
/// length-delimited value in UTF-8.
fn Reader::text(self : Reader) -> String raise DecodeError {
  self.expect(Len)
  let at = self.pos
  let bytes = self.length_delimited()
  @utf8.decode(bytes) catch {
    _ => raise self.error(at, "a string is not UTF-8")
  }
}

///|
/// Reads the value of a message field of descriptor.proto, as a view.
fn Reader::message(self : Reader) -> BytesView raise DecodeError {
  self.expect(Len)
  self.length_delimited()
}

///|
/// Reads the value of an `int32` or enum field of descriptor.proto: a
/// varint, of which the low 32 bits are the value, as protobuf reads it.
fn Reader::int32(self : Reader) -> Int32 raise DecodeError {
  self.expect(Varint)
  self.varint().to_int()
}

///|
/// Reads the value of a `bool` field of descriptor.proto: a varint, true
/// unless it is 0.
fn Reader::boolean(self : Reader) -> Bool raise DecodeError {
  self.expect(Varint)
  self.varint() != 0
}
