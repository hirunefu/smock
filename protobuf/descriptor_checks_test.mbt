// The checks of a Descriptor set, through the public interface: sets
// written field by field, each breaking one rule of a self-contained set
// that protoc would never write, and the problems they give.

///|
/// A FileDescriptorProto named `name` in `package_name`, importing
/// `dependencies`, whose other fields `body` writes.
fn file_proto(
  name : String,
  package_name~ : String = "",
  dependencies~ : Array[String] = [],
  body~ : (@protobuf.Writer) -> Unit = _ => (),
) -> Bytes {
  nested(w => {
    string_field(w, 1, name)
    if package_name != "" {
      string_field(w, 2, package_name)
    }
    for dependency in dependencies {
      string_field(w, 3, dependency)
    }
    body(w)
    string_field(w, 12, "proto3")
  })
}

///|
/// A DescriptorProto named `name`, whose other fields `body` writes.
fn message_proto(
  name : String,
  body~ : (@protobuf.Writer) -> Unit = _ => (),
) -> Bytes {
  nested(w => {
    string_field(w, 1, name)
    body(w)
  })
}

///|
/// A FieldDescriptorProto: an optional field, or an extension of
/// `extendee`, of type number `type_` (0 for none), naming `type_name`.
fn field_proto(
  name : String,
  number : UInt64,
  type_ : UInt64,
  type_name~ : String = "",
  extendee~ : String = "",
  oneof_index? : UInt64,
) -> Bytes {
  nested(w => {
    string_field(w, 1, name)
    if extendee != "" {
      string_field(w, 2, extendee)
    }
    varint_field(w, 3, number)
    varint_field(w, 4, 1)
    if type_ != 0 {
      varint_field(w, 5, type_)
    }
    if type_name != "" {
      string_field(w, 6, type_name)
    }
    if oneof_index is Some(index) {
      varint_field(w, 9, index)
    }
  })
}

///|
/// An EnumDescriptorProto named `name` with `values`, each a name and a
/// number.
fn enum_proto(name : String, values : Array[(String, UInt64)]) -> Bytes {
  nested(w => {
    string_field(w, 1, name)
    for value in values {
      message_field(
        w,
        2,
        nested(w => {
          string_field(w, 1, value.0)
          varint_field(w, 2, value.1)
        }),
      )
    }
  })
}

///|
/// A ServiceDescriptorProto named `name` with one unary method `Get`, from
/// `input` to `output`.
fn service_proto(name : String, input : String, output : String) -> Bytes {
  nested(w => {
    string_field(w, 1, name)
    message_field(
      w,
      2,
      nested(w => {
        string_field(w, 1, "Get")
        string_field(w, 2, input)
        string_field(w, 3, output)
      }),
    )
  })
}

///|
/// A FileDescriptorSet of `files`.
fn set_of(files : Array[Bytes]) -> Bytes {
  nested(w => {
    for file in files {
      message_field(w, 1, file)
    }
  })
}

///|
test "a file that imports one the set lacks is a problem that names the file and its missing import" {
  let orders = file_proto("orders.proto", package_name="shop", dependencies=[
    "common.proto", "google/protobuf/timestamp.proto",
  ])
  let timestamp = file_proto(
    "google/protobuf/timestamp.proto",
    package_name="google.protobuf",
  )
  inspect(
    read(set_of([orders, timestamp])),
    content=(
      #|error: orders.proto imports common.proto, which is not in the set; build the set with protoc --include_imports, or with buf build
    ),
  )
}

///|
test "a file in the set more than once is one problem" {
  let orders = file_proto("orders.proto", package_name="shop")
  inspect(
    read(set_of([orders, orders, orders])),
    content="error: the file orders.proto is in the set more than once",
  )
}

///|
test "a full name defined twice is a problem that names both definitions, packages and enum values included" {
  let a = file_proto("a.proto", package_name="shop", body=w => {
    message_field(w, 4, message_proto("Order"))
    message_field(w, 5, enum_proto("Status", [("UNKNOWN", 0)]))
  })
  let b = file_proto("b.proto", package_name="shop", body=w => {
    // Order again, a message named like a package, and an enum whose value
    // UNKNOWN is shop.UNKNOWN, as Status's is.
    message_field(w, 4, message_proto("Order"))
    message_field(w, 5, enum_proto("Kind", [("UNKNOWN", 0)]))
  })
  let c = file_proto("c.proto", body=w => {
    message_field(w, 4, message_proto("shop"))
  })
  let d = file_proto("d.proto", package_name="shop", body=w => {
    message_field(
      w,
      4,
      message_proto("Line", body=w => {
        message_field(w, 2, field_proto("sku", 1, 9))
        message_field(w, 2, field_proto("sku", 2, 9))
      }),
    )
  })
  inspect(
    read(set_of([a, b, c, d])),
    content=(
      #|error: the name shop.Order is defined twice, as a message in a.proto and as a message in b.proto
      #|the name shop.UNKNOWN is defined twice, as an enum value in a.proto and as an enum value in b.proto
      #|the name shop is defined twice, as a package in a.proto and as a message in c.proto
      #|the name shop.Line.sku is defined twice, as a field in d.proto and as a field in d.proto
    ),
  )
}

///|
test "a field number used twice in a message, or a oneof the message lacks, is a problem" {
  let file = file_proto("a.proto", package_name="shop", body=w => {
    message_field(
      w,
      4,
      message_proto("Order", body=w => {
        message_field(w, 2, field_proto("id", 1, 4))
        message_field(w, 2, field_proto("order_id", 1, 4))
        message_field(w, 2, field_proto("name", 2, 9, oneof_index=1))
        message_field(w, 8, nested(w => string_field(w, 1, "payer")))
      }),
    )
  })
  inspect(
    read(set_of([file])),
    content=(
      #|error: the message shop.Order uses field number 1 twice, for id and order_id
      #|the field shop.Order.name is in oneof 1, which shop.Order does not have
    ),
  )
}

///|
test "a type that a field, a method or an extension names must be defined in the set, as a message or an enum as its type says" {
  let file = file_proto("a.proto", package_name="shop", body=w => {
    message_field(
      w,
      4,
      message_proto("Order", body=w => {
        message_field(
          w,
          2,
          field_proto("customer", 1, 11, type_name=".shop.Customer"),
        )
        message_field(
          w,
          2,
          field_proto("status", 2, 11, type_name=".shop.Status"),
        )
        message_field(w, 2, field_proto("kind", 3, 14, type_name=".shop.Order"))
        message_field(w, 2, field_proto("line", 4, 0, type_name=".shop.Line"))
        message_field(w, 2, field_proto("note", 5, 0))
        message_field(w, 2, field_proto("total", 6, 11))
        message_field(
          w,
          5,
          nested(w => {
            varint_field(w, 1, 100)
            varint_field(w, 2, 200)
          }),
        )
      }),
    )
    message_field(w, 5, enum_proto("Status", [("UNKNOWN", 0)]))
    message_field(
      w,
      6,
      service_proto("Orders", ".shop.GetRequest", ".shop.Status"),
    )
    message_field(w, 7, field_proto("priority", 100, 5, extendee=".shop.Money"))
    message_field(
      w,
      7,
      field_proto("tag", 101, 11, type_name=".shop.Tag", extendee=".shop.Order"),
    )
  })
  inspect(
    read(set_of([file])),
    content=(
      #|error: the field shop.Order.customer has the type .shop.Customer, which the set does not define as a message
      #|the field shop.Order.status has the type .shop.Status, which the set does not define as a message
      #|the field shop.Order.kind has the type .shop.Order, which the set does not define as an enum
      #|the field shop.Order.line has the type .shop.Line, which the set does not define as a message or an enum
      #|the field shop.Order.note has no type
      #|the field shop.Order.total has the type message, but names no type
      #|the extension shop.priority extends .shop.Money, which the set does not define as a message
      #|the extension shop.tag has the type .shop.Tag, which the set does not define as a message
      #|the method shop.Orders.Get takes .shop.GetRequest, which the set does not define as a message
      #|the method shop.Orders.Get returns .shop.Status, which the set does not define as a message
    ),
  )
}

///|
test "an extension needs a number that its message declares for extensions, and only one extension of a message may use it" {
  let file = file_proto("a.proto", package_name="shop", body=w => {
    message_field(
      w,
      4,
      message_proto("Money", body=w => {
        message_field(
          w,
          5,
          nested(w => {
            varint_field(w, 1, 100)
            varint_field(w, 2, 200)
          }),
        )
      }),
    )
    message_field(w, 7, field_proto("priority", 100, 5, extendee=".shop.Money"))
    message_field(w, 7, field_proto("rank", 100, 5, extendee=".shop.Money"))
    message_field(w, 7, field_proto("note", 200, 9, extendee=".shop.Money"))
  })
  inspect(
    read(set_of([file])),
    content=(
      #|error: the extensions shop.priority and shop.rank extend shop.Money with the same field number 100
      #|the extension shop.note has field number 200, which shop.Money does not declare for extensions
    ),
  )
}

///|
test "names are checked only once every import is in the set, so a missing import gives no other problem" {
  let orders = file_proto(
    "orders.proto",
    package_name="shop",
    dependencies=["common.proto"],
    body=w => {
      message_field(
        w,
        4,
        message_proto("Order", body=w => {
          message_field(
            w,
            2,
            field_proto("total", 1, 11, type_name=".shop.Money"),
          )
        }),
      )
    },
  )
  inspect(
    read(set_of([orders])),
    content=(
      #|error: orders.proto imports common.proto, which is not in the set; build the set with protoc --include_imports, or with buf build
    ),
  )
}
