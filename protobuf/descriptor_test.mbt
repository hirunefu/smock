// Reading a FileDescriptorSet through the public interface: the set protoc
// builds from gRPC's helloworld.proto (greeter_set_test.mbt, written by
// scripts/gen-protobuf-fixtures.sh), sets written field by field to reach
// what that one lacks, and sets that do not decode.

///|
/// `set`, one line per file, message, field, enum, extension, service and
/// method, nested types indented under their message.
fn render(set : @protobuf.DescriptorSet) -> String {
  let out = StringBuilder()
  for file in set.files {
    out.write_string(
      "file \{file.name}, package \{file.package_name}, \{syntax_name(file.syntax)}, dependencies [\{file.dependencies.join(", ")}]\n",
    )
    for message in file.messages {
      render_message(out, message, "  ")
    }
    for enum_ in file.enums {
      render_enum(out, enum_, "  ")
    }
    for extension in file.extensions {
      out.write_string("  extension ")
      render_field(out, extension)
    }
    for service in file.services {
      out.write_string("  service \{service.full_name}\n")
      for rpc in service.methods {
        let input = if rpc.client_streaming { "stream " } else { "" }
        let output = if rpc.server_streaming { "stream " } else { "" }
        out.write_string(
          "    \{rpc.name}(\{input}\{rpc.input_type}) returns (\{output}\{rpc.output_type})\n",
        )
      }
    }
  }
  out.to_string()
}

///|
/// A syntax as a .proto file names it.
fn syntax_name(syntax : @protobuf.Syntax) -> String {
  match syntax {
    Proto2 => "proto2"
    Proto3 => "proto3"
    Editions => "editions"
  }
}

///|
/// Writes `message`, with its fields, nested types and extensions, each
/// line after `indent`.
fn render_message(
  out : StringBuilder,
  message : @protobuf.MessageDescriptor,
  indent : String,
) -> Unit {
  out.write_string("\{indent}message \{message.full_name}")
  if message.map_entry {
    out.write_string(", map_entry")
  }
  if message.message_set_wire_format {
    out.write_string(", message_set_wire_format")
  }
  out.write_string("\n")
  for field in message.fields {
    out.write_string("\{indent}  ")
    render_field(out, field)
  }
  if message.oneofs.length() > 0 {
    out.write_string(
      "\{indent}  oneofs [\{message.oneofs.map(oneof => oneof.name).join(", ")}]\n",
    )
  }
  if message.extension_ranges.length() > 0 {
    let ranges = message.extension_ranges.map(range => {
      "\{range.start} to \{range.end - 1}"
    })
    out.write_string("\{indent}  extensions \{ranges.join(", ")}\n")
  }
  for extension in message.extensions {
    out.write_string("\{indent}  extension ")
    render_field(out, extension)
  }
  for nested in message.messages {
    render_message(out, nested, indent + "  ")
  }
  for enum_ in message.enums {
    render_enum(out, enum_, indent + "  ")
  }
}

///|
/// Writes `field` on one line: its number, name and JSON name, label and
/// type, then what else it says.
fn render_field(out : StringBuilder, field : @protobuf.FieldDescriptor) -> Unit {
  let label = match field.label {
    Optional => "optional"
    Required => "required"
    Repeated => "repeated"
  }
  out.write_string(
    "\{field.number} \{field.full_name}, json \{field.json_name}: \{label} \{field.type_}",
  )
  if field.type_name != "" {
    out.write_string(" \{field.type_name}")
  }
  if field.extendee != "" {
    out.write_string(", extends \{field.extendee}")
  }
  if field.oneof_index is Some(index) {
    out.write_string(", oneof \{index}")
  }
  if field.proto3_optional {
    out.write_string(", proto3 optional")
  }
  match field.packed {
    Some(true) => out.write_string(", packed")
    Some(false) => out.write_string(", not packed")
    None => ()
  }
  out.write_string("\n")
}

///|
/// Writes `enum_` on one line, with its values.
fn render_enum(
  out : StringBuilder,
  enum_ : @protobuf.EnumDescriptor,
  indent : String,
) -> Unit {
  let values = enum_.values.map(value => "\{value.name} = \{value.number}")
  out.write_string("\{indent}enum \{enum_.full_name}: \{values.join(", ")}\n")
}

///|
/// The set in `bytes`, rendered, or the error reading it raises.
fn read(bytes : Bytes) -> String {
  render(@protobuf.read_descriptor_set(bytes[:])) catch {
    err => "error: \{err}"
  }
}

///|
test "the set protoc builds from gRPC's helloworld.proto gives its file, messages, fields, service and methods" {
  let bytes = @hex.decode(greeter_set.replace_all(old="\n", new=""))
  inspect(
    read(bytes),
    content=(
      #|file helloworld.proto, package helloworld, proto3, dependencies []
      #|  message helloworld.HelloRequest
      #|    1 helloworld.HelloRequest.name, json name: optional string
      #|  message helloworld.HelloReply
      #|    1 helloworld.HelloReply.message, json message: optional string
      #|  service helloworld.Greeter
      #|    SayHello(.helloworld.HelloRequest) returns (.helloworld.HelloReply)
      #|    SayHelloStreamReply(.helloworld.HelloRequest) returns (stream .helloworld.HelloReply)
      #|    SayHelloBidiStream(stream .helloworld.HelloRequest) returns (stream .helloworld.HelloReply)
      #|
    ),
  )
}

///|
test "a set with proto2, proto3 and an edition gives nested types, enums with aliases, groups, extensions, maps, oneofs and options" {
  let bytes = @hex.decode(shop_set.replace_all(old="\n", new=""))
  inspect(
    read(bytes),
    content=(
      #|file shop/common.proto, package shop, proto2, dependencies []
      #|  message shop.Money
      #|    1 shop.Money.currency, json currency: required string
      #|    2 shop.Money.units, json units: optional int64
      #|    3 shop.Money.cents, json cents: repeated int32, packed
      #|    4 shop.Money.note, json note: optional group .shop.Money.Note
      #|    5 shop.Money.status, json status: optional enum .shop.Status
      #|    extensions 100 to 199, 1000 to 536870911
      #|    message shop.Money.Note
      #|      1 shop.Money.Note.text, json text: optional string
      #|  message shop.Audit
      #|    extension 101 shop.Audit.audited_by, json auditedBy: optional string, extends .shop.Money
      #|  enum shop.Status: STATUS_UNKNOWN = 0, ACTIVE = 1, ENABLED = 1
      #|  extension 100 shop.priority, json priority: optional int32, extends .shop.Money
      #|file shop/legacy.proto, package shop.legacy, editions, dependencies []
      #|  message shop.legacy.Item
      #|    1 shop.legacy.Item.name, json name: optional string
      #|file shop/orders.proto, package shop.v1, proto3, dependencies [shop/common.proto, shop/legacy.proto]
      #|  message shop.v1.Order
      #|    1 shop.v1.Order.order_id, json orderId: optional uint64
      #|    2 shop.v1.Order.total, json total: optional message .shop.Money
      #|    3 shop.v1.Order.lines, json lines: repeated message .shop.v1.Order.Line
      #|    4 shop.v1.Order.labels, json labels: repeated message .shop.v1.Order.LabelsEntry
      #|    5 shop.v1.Order.note, json note: optional string, oneof 1, proto3 optional
      #|    6 shop.v1.Order.user_name, json userName: optional string, oneof 0
      #|    7 shop.v1.Order.company, json company: optional message .shop.v1.Order.Company, oneof 0
      #|    8 shop.v1.Order.codes, json codes: repeated int32, not packed
      #|    9 shop.v1.Order.display_name, json title: optional string
      #|    10 shop.v1.Order.item, json item: optional message .shop.legacy.Item
      #|    oneofs [payer, _note]
      #|    message shop.v1.Order.LabelsEntry, map_entry
      #|      1 shop.v1.Order.LabelsEntry.key, json key: optional string
      #|      2 shop.v1.Order.LabelsEntry.value, json value: optional int32
      #|    message shop.v1.Order.Line
      #|      1 shop.v1.Order.Line.sku, json sku: optional string
      #|      2 shop.v1.Order.Line.kind, json kind: optional enum .shop.v1.Order.Line.Kind
      #|      enum shop.v1.Order.Line.Kind: KIND_UNSPECIFIED = 0, GOODS = 1
      #|    message shop.v1.Order.Company
      #|      1 shop.v1.Order.Company.name, json name: optional string
      #|  service shop.v1.Orders
      #|    Get(.shop.v1.Order) returns (.shop.v1.Order)
      #|    Watch(.shop.v1.Order) returns (stream .shop.v1.Order)
      #|    Upload(stream .shop.v1.Order) returns (.shop.v1.Order)
      #|    Chat(stream .shop.v1.Order) returns (stream .shop.v1.Order)
      #|
    ),
  )
}

///|
/// A message whose fields `write` writes, as a length-delimited value.
fn nested(write : (@protobuf.Writer) -> Unit) -> Bytes {
  let writer = @protobuf.Writer()
  write(writer)
  writer.to_bytes()
}

///|
/// Writes `text` as field `field`, a string.
fn string_field(
  writer : @protobuf.Writer,
  field : Int32,
  text : String,
) -> Unit {
  writer.tag(field, Len)
  writer.length_delimited(@utf8.encode(text))
}

///|
/// Writes `value` as field `field`, a varint.
fn varint_field(
  writer : @protobuf.Writer,
  field : Int32,
  value : UInt64,
) -> Unit {
  writer.tag(field, Varint)
  writer.varint(value)
}

///|
/// Writes `message` as field `field`, a message.
fn message_field(
  writer : @protobuf.Writer,
  field : Int32,
  message : Bytes,
) -> Unit {
  writer.tag(field, Len)
  writer.length_delimited(message)
}

///|
test "a file without syntax is proto2, and dependencies, labels, field types, MessageSet and streaming flags are kept" {
  let field = (name, number, label, type_, type_name) => {
    nested(w => {
      string_field(w, 1, name)
      varint_field(w, 3, number)
      varint_field(w, 4, label)
      if type_ != 0UL {
        varint_field(w, 5, type_)
      }
      if type_name != "" {
        string_field(w, 6, type_name)
      }
    })
  }
  let file = nested(w => {
    string_field(w, 1, "shop/orders.proto")
    string_field(w, 2, "shop")
    string_field(w, 3, "shop/common.proto")
    string_field(w, 3, "google/protobuf/timestamp.proto")
    message_field(
      w,
      4,
      nested(w => {
        string_field(w, 1, "Order")
        message_field(w, 2, field("id", 1, 2, 4, ""))
        message_field(w, 2, field("lines", 2, 3, 11, ".shop.Line"))
        message_field(w, 2, field("status", 3, 1, 0, ".shop.Status"))
        message_field(w, 2, field("total", 4, 1, 1, ""))
      }),
    )
    message_field(
      w,
      4,
      nested(w => {
        string_field(w, 1, "Bag")
        message_field(w, 7, nested(w => varint_field(w, 1, 1)))
      }),
    )
    message_field(
      w,
      6,
      nested(w => {
        string_field(w, 1, "Orders")
        message_field(
          w,
          2,
          nested(w => {
            string_field(w, 1, "Upload")
            string_field(w, 2, ".shop.Order")
            string_field(w, 3, ".shop.Bag")
            varint_field(w, 5, 1)
          }),
        )
      }),
    )
  })
  let editions = nested(w => {
    string_field(w, 1, "new.proto")
    string_field(w, 12, "editions")
  })
  let set = nested(w => {
    message_field(w, 1, file)
    message_field(w, 1, editions)
  })
  inspect(
    read(set),
    content=(
      #|file shop/orders.proto, package shop, proto2, dependencies [shop/common.proto, google/protobuf/timestamp.proto]
      #|  message shop.Order
      #|    1 shop.Order.id, json id: required uint64
      #|    2 shop.Order.lines, json lines: repeated message .shop.Line
      #|    3 shop.Order.status, json status: optional message .shop.Status
      #|    4 shop.Order.total, json total: optional double
      #|  message shop.Bag, message_set_wire_format
      #|  service shop.Orders
      #|    Upload(stream .shop.Order) returns (.shop.Bag)
      #|file new.proto, package , editions, dependencies []
      #|
    ),
  )
}

///|
test "fields the model does not keep are skipped, such as source info, options and Buf's image extensions" {
  let file = nested(w => {
    string_field(w, 1, "a.proto")
    // Options, source info, and Buf's ImageFileExtension (field 8042).
    message_field(w, 8, nested(w => string_field(w, 1, "com.example")))
    message_field(w, 9, nested(w => varint_field(w, 1, 7)))
    message_field(w, 8042, nested(w => varint_field(w, 1, 0)))
    string_field(w, 12, "proto3")
    // A group of an unknown field, with a varint in it.
    w.tag(5000, StartGroup)
    varint_field(w, 1, 1)
    w.tag(5000, EndGroup)
  })
  let set = nested(w => {
    varint_field(w, 2, 1)
    message_field(w, 1, file)
    w.tag(3, I32)
    w.fixed32(1)
  })
  inspect(
    read(set),
    content=(
      #|file a.proto, package , proto3, dependencies []
      #|
    ),
  )
  inspect(read(b""), content="")
}

///|
test "a set that is not protobuf, or that breaks descriptor.proto in a field the model keeps, is an error at the octet where it breaks" {
  // A file's name that is a varint, not a string.
  inspect(
    read(b"\x0a\x02\x08\x01"),
    content="error: octet 2: field 1 has wire type VARINT, not LEN",
  )
  // The set's files that are a varint, not a message.
  inspect(
    read(b"\x08\x01"),
    content="error: octet 0: field 1 has wire type VARINT, not LEN",
  )
  // A file whose length runs past the end of the set.
  inspect(
    read(b"\x0a\x05\x0a\x01a"),
    content="error: octet 1: a length of 5 runs past the end of the input, which has 3 octets left",
  )
  // A name whose length runs past the end of its file.
  inspect(
    read(b"\x0a\x03\x0a\x05a\x0a\x00"),
    content="error: octet 3: a length of 5 runs past the end of the input, which has 1 octets left",
  )
  inspect(
    read(b"\x0a\x03\x0a\x01\xff"),
    content="error: octet 3: a string is not UTF-8",
  )
  inspect(
    read(b"\x0a\x08\x62\x06proto4"),
    content="error: octet 3: the syntax \"proto4\" is not proto2, proto3 or editions",
  )
  // A message whose field has label 4, then one whose field has type 19.
  inspect(
    read(b"\x0a\x06\x22\x04\x12\x02\x20\x04"),
    content="error: octet 7: the label 4 is not a field label",
  )
  inspect(
    read(b"\x0a\x06\x22\x04\x12\x02\x28\x13"),
    content="error: octet 7: the type 19 is not a field type",
  )
  // A group that ends where none started, and a truncated varint.
  inspect(
    read(b"\x14"),
    content="error: octet 0: the group of field 2 ends where none started",
  )
  inspect(
    read(b"\x10\x80"),
    content="error: octet 1: the input ends inside a varint",
  )
}
