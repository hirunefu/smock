// Reading a FileDescriptorSet through the public interface: the set protoc
// builds from gRPC's helloworld.proto (greeter_set_test.mbt, written by
// scripts/gen-protobuf-fixtures.sh), sets written field by field to reach
// what that one lacks, and sets that do not decode.

///|
/// `set`, one line per file, message, field, service and method.
fn render(set : @protobuf.DescriptorSet) -> String {
  let out = StringBuilder()
  for file in set.files {
    let syntax = match file.syntax {
      Proto2 => "proto2"
      Proto3 => "proto3"
      Editions => "editions"
    }
    out.write_string(
      "file \{file.name}, package \{file.package_name}, \{syntax}, dependencies [\{file.dependencies.join(", ")}]\n",
    )
    for message in file.messages {
      out.write_string("  message \{message.name}")
      if message.message_set_wire_format {
        out.write_string(", message_set_wire_format")
      }
      out.write_string("\n")
      for field in message.fields {
        let label = match field.label {
          Optional => "optional"
          Required => "required"
          Repeated => "repeated"
        }
        let type_ = match field.type_ {
          Some(type_) => "\{type_}"
          None => "(no type)"
        }
        out.write_string("    \{field.number} \{field.name}: \{label} \{type_}")
        if field.type_name != "" {
          out.write_string(" \{field.type_name}")
        }
        out.write_string("\n")
      }
    }
    for service in file.services {
      out.write_string("  service \{service.name}\n")
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
      #|  message HelloRequest
      #|    1 name: optional string
      #|  message HelloReply
      #|    1 message: optional string
      #|  service Greeter
      #|    SayHello(.helloworld.HelloRequest) returns (.helloworld.HelloReply)
      #|    SayHelloStreamReply(.helloworld.HelloRequest) returns (stream .helloworld.HelloReply)
      #|    SayHelloBidiStream(stream .helloworld.HelloRequest) returns (stream .helloworld.HelloReply)
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
      #|  message Order
      #|    1 id: required uint64
      #|    2 lines: repeated message .shop.Line
      #|    3 status: optional (no type) .shop.Status
      #|    4 total: optional double
      #|  message Bag, message_set_wire_format
      #|  service Orders
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
