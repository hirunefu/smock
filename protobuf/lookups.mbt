// The lookups that decoding, encoding and conditions share. Each reads an
// index that read_descriptor_set built, so none walks the set.

///|
/// The method that gRPC calls by `path`: `/`, the full name of its
/// service, `/` and its name, such as `/helloworld.Greeter/SayHello`.
pub fn DescriptorSet::find_method(
  self : DescriptorSet,
  path : String,
) -> MethodDescriptor? {
  self.methods.get(path)
}

///|
/// The message whose full name, without a leading dot, is `full_name`,
/// such as `helloworld.HelloRequest`. Nested messages are found too, such
/// as `shop.Order.Line`.
pub fn DescriptorSet::find_message(
  self : DescriptorSet,
  full_name : String,
) -> MessageDescriptor? {
  match self.message_index.get(full_name) {
    Some(index) => Some(self.all_messages[index])
    None => None
  }
}

///|
/// The enum whose full name, without a leading dot, is `full_name`.
pub fn DescriptorSet::find_enum(
  self : DescriptorSet,
  full_name : String,
) -> EnumDescriptor? {
  match self.enum_index.get(full_name) {
    Some(index) => Some(self.all_enums[index])
    None => None
  }
}

///|
/// The extension whose full name, without a leading dot, is `full_name`,
/// such as `shop.priority`: the name that ProtoJSON writes between
/// brackets.
pub fn DescriptorSet::find_extension(
  self : DescriptorSet,
  full_name : String,
) -> FieldDescriptor? {
  self.extensions.get(full_name)
}

///|
/// The message type of `field`, a field or an extension of this set whose
/// type is a message or a group, or `None` for another type.
pub fn DescriptorSet::message_of(
  self : DescriptorSet,
  field : FieldDescriptor,
) -> MessageDescriptor? {
  match field.type_ {
    Message | Group => Some(self.all_messages[field.type_index])
    _ => None
  }
}

///|
/// The enum type of `field`, a field or an extension of this set whose
/// type is an enum, or `None` for another type.
pub fn DescriptorSet::enum_of(
  self : DescriptorSet,
  field : FieldDescriptor,
) -> EnumDescriptor? {
  match field.type_ {
    Enum => Some(self.all_enums[field.type_index])
    _ => None
  }
}

///|
/// The input type of `rpc`, a method of this set.
pub fn DescriptorSet::input_of(
  self : DescriptorSet,
  rpc : MethodDescriptor,
) -> MessageDescriptor {
  self.all_messages[rpc.input_index]
}

///|
/// The output type of `rpc`, a method of this set.
pub fn DescriptorSet::output_of(
  self : DescriptorSet,
  rpc : MethodDescriptor,
) -> MessageDescriptor {
  self.all_messages[rpc.output_index]
}

///|
/// The field of the message numbered `number`. Extensions are found by
/// `find_extension`.
pub fn MessageDescriptor::find_field_by_number(
  self : MessageDescriptor,
  number : Int32,
) -> FieldDescriptor? {
  self.fields_by_number.get(number)
}

///|
/// The field of the message named `name`, as the .proto file spells it,
/// such as `user_name`.
pub fn MessageDescriptor::find_field_by_name(
  self : MessageDescriptor,
  name : String,
) -> FieldDescriptor? {
  self.fields_by_name.get(name)
}

///|
/// The field of the message whose JSON name is `json_name`, such as
/// `userName`. When two fields have one JSON name, as a proto2 message
/// may, the first is found.
pub fn MessageDescriptor::find_field_by_json_name(
  self : MessageDescriptor,
  json_name : String,
) -> FieldDescriptor? {
  self.fields_by_json_name.get(json_name)
}

///|
/// The extension of the set that extends the message with field number
/// `number`.
pub fn MessageDescriptor::find_extension(
  self : MessageDescriptor,
  number : Int32,
) -> FieldDescriptor? {
  self.extended_by.get(number)
}

///|
/// The value of the enum named `name`. An alias is found by its own name.
pub fn EnumDescriptor::find_value_by_name(
  self : EnumDescriptor,
  name : String,
) -> EnumValueDescriptor? {
  self.values_by_name.get(name)
}

///|
/// The first value of the enum numbered `number`: its first name, when
/// aliases share the number.
pub fn EnumDescriptor::find_value_by_number(
  self : EnumDescriptor,
  number : Int32,
) -> EnumValueDescriptor? {
  self.values_by_number.get(number)
}
