// The lookups that decoding, encoding and conditions share, through the
// public interface, on the set protoc builds from
// fixtures/protobuf/model/shop/orders.proto (shop_set_test.mbt).

///|
/// The set of fixtures/protobuf/model/shop.binpb.
fn shop() -> @protobuf.DescriptorSet raise {
  @protobuf.read_descriptor_set(
    @hex.decode(shop_set.replace_all(old="\n", new=""))[:],
  )
}

///|
/// The full name of `field`, or `-` for none.
fn field_name(field : @protobuf.FieldDescriptor?) -> String {
  match field {
    Some(field) => field.full_name
    None => "-"
  }
}

///|
test "a method is found by the path gRPC calls it by, and its input and output types by the method" {
  let set = shop()
  let out = []
  for
    path in [
      "/shop.v1.Orders/Get", "/shop.v1.Orders/Chat", "/shop.v1.Orders/Missing", "/shop.v1.Orders.Get",
      "shop.v1.Orders/Get", "/Orders/Get",
    ] {
    match set.find_method(path) {
      Some(rpc) =>
        out.push(
          "\{path}: \{rpc.name}(\{set.input_of(rpc).full_name}) returns (\{set.output_of(rpc).full_name})",
        )
      None => out.push("\{path}: -")
    }
  }
  inspect(
    out.join("\n"),
    content=(
      #|/shop.v1.Orders/Get: Get(shop.v1.Order) returns (shop.v1.Order)
      #|/shop.v1.Orders/Chat: Chat(shop.v1.Order) returns (shop.v1.Order)
      #|/shop.v1.Orders/Missing: -
      #|/shop.v1.Orders.Get: -
      #|shop.v1.Orders/Get: -
      #|/Orders/Get: -
    ),
  )
}

///|
test "messages and enums are found by their full names, nested ones included, and each knows the syntax of its file" {
  let set = shop()
  let out = []
  for
    name in [
      "shop.v1.Order", "shop.v1.Order.Line", "shop.Money.Note", "shop.legacy.Item",
      ".shop.v1.Order", "Order", "shop.Status",
    ] {
    match set.find_message(name) {
      Some(message) =>
        out.push("\{name}: message, \{syntax_name(message.syntax)}")
      None => out.push("\{name}: -")
    }
  }
  for name in ["shop.Status", "shop.v1.Order.Line.Kind", "shop.v1.Order"] {
    match set.find_enum(name) {
      Some(enum_) => out.push("\{name}: enum, \{syntax_name(enum_.syntax)}")
      None => out.push("\{name}: -")
    }
  }
  debug_inspect(
    out,
    content=(
      #|[
      #|  "shop.v1.Order: message, proto3",
      #|  "shop.v1.Order.Line: message, proto3",
      #|  "shop.Money.Note: message, proto2",
      #|  "shop.legacy.Item: message, editions",
      #|  ".shop.v1.Order: -",
      #|  "Order: -",
      #|  "shop.Status: -",
      #|  "shop.Status: enum, proto2",
      #|  "shop.v1.Order.Line.Kind: enum, proto3",
      #|  "shop.v1.Order: -",
      #|]
    ),
  )
}

///|
test "a field's message or enum type is found from the field, map entries and groups included" {
  let set = shop()
  let out = []
  for name in ["shop.v1.Order", "shop.Money", "shop.v1.Order.Line"] {
    guard set.find_message(name) is Some(message) else { fail("no \{name}") }
    for field in message.fields {
      let type_ = match (set.message_of(field), set.enum_of(field)) {
        (Some(message), None) => "message \{message.full_name}"
        (None, Some(enum_)) => "enum \{enum_.full_name}"
        (None, None) => "\{field.type_}"
        (Some(_), Some(_)) => "both"
      }
      out.push("\{field.full_name}: \{type_}")
    }
  }
  debug_inspect(
    out,
    content=(
      #|[
      #|  "shop.v1.Order.order_id: uint64",
      #|  "shop.v1.Order.total: message shop.Money",
      #|  "shop.v1.Order.lines: message shop.v1.Order.Line",
      #|  "shop.v1.Order.labels: message shop.v1.Order.LabelsEntry",
      #|  "shop.v1.Order.note: string",
      #|  "shop.v1.Order.user_name: string",
      #|  "shop.v1.Order.company: message shop.v1.Order.Company",
      #|  "shop.v1.Order.codes: int32",
      #|  "shop.v1.Order.display_name: string",
      #|  "shop.v1.Order.item: message shop.legacy.Item",
      #|  "shop.Money.currency: string",
      #|  "shop.Money.units: int64",
      #|  "shop.Money.cents: int32",
      #|  "shop.Money.note: message shop.Money.Note",
      #|  "shop.Money.status: enum shop.Status",
      #|  "shop.v1.Order.Line.sku: string",
      #|  "shop.v1.Order.Line.kind: enum shop.v1.Order.Line.Kind",
      #|]
    ),
  )
}

///|
test "a field is found by its proto name, its JSON name or its number, each spelling only by its own lookup" {
  let set = shop()
  guard set.find_message("shop.v1.Order") is Some(order) else {
    fail("no Order")
  }
  debug_inspect(
    [
      field_name(order.find_field_by_number(9)),
      field_name(order.find_field_by_name("display_name")),
      field_name(order.find_field_by_json_name("title")),
      field_name(order.find_field_by_json_name("display_name")),
      field_name(order.find_field_by_json_name("displayName")),
      field_name(order.find_field_by_name("title")),
      field_name(order.find_field_by_number(11)),
      field_name(order.find_field_by_name("user_name")),
      field_name(order.find_field_by_json_name("userName")),
      field_name(order.find_field_by_name("userName")),
    ],
    content=(
      #|[
      #|  "shop.v1.Order.display_name",
      #|  "shop.v1.Order.display_name",
      #|  "shop.v1.Order.display_name",
      #|  "-",
      #|  "-",
      #|  "-",
      #|  "-",
      #|  "shop.v1.Order.user_name",
      #|  "shop.v1.Order.user_name",
      #|  "-",
      #|]
    ),
  )
}

///|
test "an enum value is found by its name or its number, a number giving its first name, so an alias gives the value's first name" {
  let set = shop()
  guard set.find_enum("shop.Status") is Some(status) else { fail("no Status") }
  let value = (value : @protobuf.EnumValueDescriptor?) => {
    match value {
      Some(value) => "\{value.name} = \{value.number}"
      None => "-"
    }
  }
  let first_name = match status.find_value_by_name("ENABLED") {
    Some(enabled) => value(status.find_value_by_number(enabled.number))
    None => "-"
  }
  debug_inspect(
    [
      value(status.find_value_by_name("ACTIVE")),
      value(status.find_value_by_name("ENABLED")),
      value(status.find_value_by_number(1)),
      value(status.find_value_by_number(0)),
      value(status.find_value_by_number(2)),
      value(status.find_value_by_name("active")),
      first_name,
    ],
    content=(
      #|[
      #|  "ACTIVE = 1",
      #|  "ENABLED = 1",
      #|  "ACTIVE = 1",
      #|  "STATUS_UNKNOWN = 0",
      #|  "-",
      #|  "-",
      #|  "ACTIVE = 1",
      #|]
    ),
  )
}

///|
test "an extension is found by its full name, or by the message it extends and its number" {
  let set = shop()
  guard set.find_message("shop.Money") is Some(money) else { fail("no Money") }
  guard set.find_message("shop.v1.Order") is Some(order) else {
    fail("no Order")
  }
  debug_inspect(
    [
      field_name(money.find_extension(100)),
      field_name(money.find_extension(101)),
      field_name(money.find_extension(102)),
      field_name(order.find_extension(100)),
      field_name(money.find_field_by_number(100)),
      field_name(set.find_extension("shop.priority")),
      field_name(set.find_extension("shop.Audit.audited_by")),
      field_name(set.find_extension("shop.Money.currency")),
      field_name(set.find_extension("[shop.priority]")),
    ],
    content=(
      #|[
      #|  "shop.priority",
      #|  "shop.Audit.audited_by",
      #|  "-",
      #|  "-",
      #|  "-",
      #|  "shop.priority",
      #|  "shop.Audit.audited_by",
      #|  "-",
      #|  "-",
      #|]
    ),
  )
}
