// Reading a FileDescriptorSet, the compiled form of .proto files that
// `protoc --include_imports -o` and `buf build -o` write, as
// google/protobuf/descriptor.proto defines it. The model keeps what smock
// needs of each file, and skips every other field of the set, such as
// source info, options and Buf's image extensions.

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
  /// Its name, without its package, such as `HelloRequest`.
  name : String
  /// Its fields, in the order of the file.
  fields : ReadOnlyArray[FieldDescriptor]
  /// Whether its option `message_set_wire_format` is true, which makes it
  /// a MessageSet, whose extensions use another wire form.
  message_set_wire_format : Bool
}

///|
/// A field of a message: a FieldDescriptorProto.
#derive(Debug, Eq)
pub struct FieldDescriptor {
  /// Its name, as the .proto file spells it.
  name : String
  /// Its field number.
  number : Int32
  /// Whether it is optional, required or repeated.
  label : Label
  /// Its type, or `None` when the set leaves it to `type_name`, as only a
  /// set whose names are not yet resolved does.
  type_ : FieldType?
  /// The full name of its message or enum type, such as
  /// `.helloworld.HelloRequest`, or `""` for a scalar type.
  type_name : String
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
/// A service: a ServiceDescriptorProto.
#derive(Debug, Eq)
pub struct ServiceDescriptor {
  /// Its name, without its package, such as `Greeter`.
  name : String
  /// Its methods, in order.
  methods : ReadOnlyArray[MethodDescriptor]
}

///|
/// A method of a service: a MethodDescriptorProto.
#derive(Debug, Eq)
pub struct MethodDescriptor {
  /// Its name, such as `SayHello`.
  name : String
  /// The full name of its input type, such as `.helloworld.HelloRequest`.
  input_type : String
  /// The full name of its output type.
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
/// It keeps each file's name, package, syntax and dependencies, its
/// top-level messages with their fields and `message_set_wire_format`, and
/// its services with their methods, and skips every other field. Raises
/// `DecodeError` when the input is not protobuf, when a field it keeps has
/// another wire type than descriptor.proto gives it, when a string it keeps
/// is not UTF-8, and when a syntax, a label or a type is not one that
/// descriptor.proto defines.
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
/// Reads a FileDescriptorProto.
fn read_file(input : BytesView) -> FileDescriptor raise DecodeError {
  let reader = Reader(input)
  let mut name = ""
  let mut package_name = ""
  let mut syntax = Proto2
  let dependencies = []
  let messages = []
  let services = []
  while !reader.at_end() {
    match reader.tag() {
      1 => name = reader.text()
      2 => package_name = reader.text()
      3 => dependencies.push(reader.text())
      4 => messages.push(read_message(reader.message()))
      6 => services.push(read_service(reader.message()))
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
  {
    name,
    package_name,
    syntax,
    dependencies: ReadOnlyArray::from_array(dependencies),
    messages: ReadOnlyArray::from_array(messages),
    services: ReadOnlyArray::from_array(services),
  }
}

///|
/// Reads a DescriptorProto.
fn read_message(input : BytesView) -> MessageDescriptor raise DecodeError {
  let reader = Reader(input)
  let mut name = ""
  let fields = []
  let mut message_set_wire_format = false
  while !reader.at_end() {
    match reader.tag() {
      1 => name = reader.text()
      2 => fields.push(read_field(reader.message()))
      7 =>
        // MessageOptions. A message field that repeats is merged, so a
        // later value of the option wins.
        if read_message_set_option(reader.message()) is Some(value) {
          message_set_wire_format = value
        }
      _ => reader.skip()
    }
  }
  { name, fields: ReadOnlyArray::from_array(fields), message_set_wire_format, }
}

///|
/// Reads `message_set_wire_format` from MessageOptions, or `None` when they
/// do not give it.
fn read_message_set_option(input : BytesView) -> Bool? raise DecodeError {
  let reader = Reader(input)
  let mut value = None
  while !reader.at_end() {
    match reader.tag() {
      1 => value = Some(reader.boolean())
      _ => reader.skip()
    }
  }
  value
}

///|
/// Reads a FieldDescriptorProto.
fn read_field(input : BytesView) -> FieldDescriptor raise DecodeError {
  let reader = Reader(input)
  let mut name = ""
  let mut number = 0
  let mut label = Optional
  let mut type_ = None
  let mut type_name = ""
  while !reader.at_end() {
    match reader.tag() {
      1 => name = reader.text()
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
      _ => reader.skip()
    }
  }
  { name, number, label, type_, type_name, }
}

///|
/// Reads a ServiceDescriptorProto.
fn read_service(input : BytesView) -> ServiceDescriptor raise DecodeError {
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
  { name, methods: ReadOnlyArray::from_array(methods), }
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
