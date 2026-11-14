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
  /// Its type.
  type_ : FieldType
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
}

///|
/// Reads `input`, a FileDescriptorSet in protobuf's binary encoding, as
/// `protoc --include_imports -o` and `buf build -o` write it.
///
/// It keeps the descriptor model: each file's name, package, syntax and
/// dependencies; its messages, nested ones included, with their fields,
/// oneofs, extension ranges and the options `map_entry` and
/// `message_set_wire_format`; its enums and their values; its extensions;
/// and its services and methods. Of a field it keeps the number, label,
/// type, type name, extendee, JSON name, oneof, proto3 `optional` and the
/// option `packed`. It skips every other field, such as source info, other
/// options and Buf's image extensions. Raises `DecodeError` when the input
/// is not protobuf, when a field it keeps has another wire type than
/// descriptor.proto gives it, when a string it keeps is not UTF-8, and when
/// a syntax, a label or a type is not one that descriptor.proto defines.
///
/// It reads what the set holds and checks nothing more: files may repeat,
/// and names need not resolve.
pub fn read_descriptor_set(
  input : BytesView,
) -> DescriptorSet raise DecodeError {
  let reader = Reader(input)
  let files = []
  while !reader.at_end() {
    match reader.tag() {
      1 => {
        reader.expect(Len)
        files.push(read_file(reader.length_delimited()))
      }
      _ => reader.skip()
    }
  }
  { files: ReadOnlyArray::from_array(files), }
}

///|
/// Where a definition is: the full name of its package or message, and the
/// syntax of its file.
priv struct Scope {
  /// The full name of the package or message, or `""` for the root.
  prefix : String
  /// The syntax of the file.
  syntax : Syntax
}

///|
/// The full name of `name` in `scope`.
fn Scope::full_name(self : Scope, name : String) -> String {
  if self.prefix == "" {
    name
  } else {
    "\{self.prefix}.\{name}"
  }
}

///|
/// Reads a FileDescriptorProto. Its messages, enums, extensions and
/// services are read once the whole file is, since their full names need
/// its package and their syntax needs its syntax, which may come after
/// them.
fn read_file(input : BytesView) -> FileDescriptor raise DecodeError {
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
  let scope = { prefix: package_name, syntax, }
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
/// whole message is, since full names need its name.
fn read_message(
  input : BytesView,
  scope : Scope,
) -> MessageDescriptor raise DecodeError {
  let reader = Reader(input)
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
  let inner = { prefix: full_name, syntax: scope.syntax, }
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
  {
    name,
    full_name: scope.full_name(name),
    syntax: scope.syntax,
    values: ReadOnlyArray::from_array(values),
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
  { name, input_type, output_type, client_streaming, server_streaming, }
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
