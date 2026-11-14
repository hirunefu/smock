// gRPC Stubs' `json` body conditions, checked against the input type of
// the Stub's method when the files load, and normalised to smock's decoded
// form, in which a call's message reaches the Stubs. A key must name a
// field of the type at its place, by its proto name or its JSON name, and
// becomes its JSON name. A literal must be a value of its field's type as
// smock prints it (`@protobuf.DescriptorSet::printed_value`): an enum
// number or alias becomes the enum's first name, and a float is rounded to
// 32 bits. Map keys are data, never rewritten, and must be printed keys.
// Patterns and operators are allowed in any place. So matching a call
// costs nothing more than matching a JSON body.

///|
/// Where a value of a gRPC Stub's `json` condition is, in the input type,
/// which says what the value is checked against.
priv enum Place {
  /// The whole message, of this type.
  Whole(@protobuf.MessageDescriptor)
  /// The value of a field of a message: a map's entries, a repeated
  /// field's elements, or a singular field's value.
  Of(@protobuf.MessageDescriptor, @protobuf.FieldDescriptor)
  /// One element of a repeated field of a message.
  Element(@protobuf.MessageDescriptor, @protobuf.FieldDescriptor)
  /// One value of a map field of a message, whose values are those of the
  /// entry's field 2, the third.
  Value(
    @protobuf.MessageDescriptor,
    @protobuf.FieldDescriptor,
    @protobuf.FieldDescriptor
  )
}

///|
/// `request`, the conditions of the gRPC Stub `stub` at `pointer`, with its
/// `json` body condition checked against `input`, the input type of its
/// method, a type of `set`, and normalised, as this file's header says.
/// Each problem is reported at the JSON Pointer of the value at fault, and
/// then the conditions are returned as they were read.
fn File::grpc_conditions(
  self : File,
  pointer : String,
  stub : Map[String, Json],
  request : Conditions,
  set : @protobuf.DescriptorSet,
  input : @protobuf.MessageDescriptor,
) -> Conditions {
  // A condition that does not read is reported where it is read, and is
  // not checked again here.
  guard request.body is Some(Json(_)) &&
    stub.get("request") is Some(Object(written)) &&
    written.get("body") is Some(Object(body)) &&
    body.get("json") is Some(json) else {
    return request
  }
  let at = child_pointer(child_pointer(pointer, "body"), "json")
  guard self.grpc_condition(at, set, Whole(input), json) is Some(normalised) &&
    self.read_json_condition(at, normalised) is Some(condition) else {
    return request
  }
  { ..request, body: Some(Json(condition)), }
}

///|
/// `json`, the value at `pointer` of a gRPC Stub's `json` condition, which
/// is at `place` in a type of `set`, checked and normalised. A pattern
/// object is kept, wherever it is. An operator's operand is at the same
/// place, but that of `$includes` and `$last` on a repeated field, which is
/// one of its elements. `None` when it has a problem, each reported.
fn File::grpc_condition(
  self : File,
  pointer : String,
  set : @protobuf.DescriptorSet,
  place : Place,
  json : Json,
) -> Json? {
  if json is Object(members) {
    if members.length() == 1 && members.get("pattern") is Some(String(_)) {
      return Some(json)
    }
    if operator_key(members) is Some(key) {
      // The condition was read, so the operator is the only key.
      guard members.get(key) is Some(operand) && key != "$exists" else {
        return Some(json)
      }
      let operand_place = match place {
        Of(message, field) if key is ("$includes" | "$last") &&
          field.label is Repeated &&
          map_fields(set, field) is None => Element(message, field)
        _ => place
      }
      return self
        .grpc_condition(
          child_pointer(pointer, key),
          set,
          operand_place,
          operand,
        )
        .map(operand => Json::object(Map([(key, operand)])))
    }
  }
  match place {
    Whole(message) =>
      match json {
        Object(members) =>
          self.message_condition(pointer, set, message, members)
        _ => {
          self.error(
            pointer,
            "must be an object: the message is a \{message.full_name}",
          )
          None
        }
      }
    Of(message, field) =>
      match map_fields(set, field) {
        Some((key_field, value_field)) => {
          guard json is Object(entries) else {
            self.error(
              pointer,
              "must be an object: the field \{field.name} of \{message.full_name} is a map",
            )
            return None
          }
          self.map_condition(
            pointer, set, message, field, key_field, value_field, entries,
          )
        }
        None if field.label is Repeated => {
          guard json is Array(items) else {
            self.error(
              pointer,
              "must be an array: the field \{field.name} of \{message.full_name} is repeated",
            )
            return None
          }
          let out = []
          for i, item in items {
            if self.grpc_condition(
                child_pointer(pointer, i.to_string()),
                set,
                Element(message, field),
                item,
              )
              is Some(item) {
              out.push(item)
            }
          }
          guard out.length() == items.length() else { return None }
          Some(Json::array(out))
        }
        None =>
          self.value_condition(
            pointer,
            set,
            field,
            json,
            "the field \{field.name} of \{message.full_name} has the type \{type_text(field)}",
          )
      }
    Element(message, field) =>
      self.value_condition(
        pointer,
        set,
        field,
        json,
        "the elements of the field \{field.name} of \{message.full_name} have the type \{type_text(field)}",
      )
    Value(message, field, value_field) =>
      self.value_condition(
        pointer,
        set,
        value_field,
        json,
        "the values of the map field \{field.name} of \{message.full_name} have the type \{type_text(value_field)}",
      )
  }
}

///|
/// `members`, the object at `pointer` that is a condition on a message of
/// the type `message`, a type of `set`, with each key, which must name a
/// field by its proto name or its JSON name, once, as the field's JSON
/// name, and each value checked and normalised at the field's place.
fn File::message_condition(
  self : File,
  pointer : String,
  set : @protobuf.DescriptorSet,
  message : @protobuf.MessageDescriptor,
  members : Map[String, Json],
) -> Json? {
  let out : Map[String, Json] = Map([])
  // The key that gave each field, by its number.
  let given : Map[Int32, String] = Map([])
  let mut valid = true
  for key, value in members {
    let at = child_pointer(pointer, key)
    let field = match message.find_field_by_json_name(key) {
      Some(field) => Some(field)
      None => message.find_field_by_name(key)
    }
    guard field is Some(field) else {
      self.error(at, "is not a field of \{message.full_name}")
      valid = false
      continue
    }
    if given.get(field.number) is Some(other) {
      self.error(
        at,
        "names the field \{field.name} of \{message.full_name}, as \{other.escape()} does: give a field once, by its proto name or its JSON name",
      )
      valid = false
      continue
    }
    given[field.number] = key
    match self.grpc_condition(at, set, Of(message, field), value) {
      Some(value) => out[field.json_name] = value
      None => valid = false
    }
  }
  if valid {
    Some(Json::object(out))
  } else {
    None
  }
}

///|
/// `entries`, the object at `pointer` that is a condition on the map field
/// `field` of `message`, whose entries have the key field `key_field` and
/// the value field `value_field`, with each value checked and normalised.
/// Its keys are data and are kept as written, `$$` included; each must be
/// a key as smock prints it.
fn File::map_condition(
  self : File,
  pointer : String,
  set : @protobuf.DescriptorSet,
  message : @protobuf.MessageDescriptor,
  field : @protobuf.FieldDescriptor,
  key_field : @protobuf.FieldDescriptor,
  value_field : @protobuf.FieldDescriptor,
  entries : Map[String, Json],
) -> Json? {
  let out : Map[String, Json] = Map([])
  let mut valid = true
  let keys = "the keys of the map field \{field.name} of \{message.full_name} have the type \{type_text(key_field)}"
  for key, value in entries {
    let at = child_pointer(pointer, key)
    // `$$name` is the key `$name`.
    let data = if key.has_prefix("$$") { key[1:].to_owned() } else { key }
    let key_valid = try key_field.check_printed_key(data) catch {
      NotOfType(wanted~) => {
        self.error(at, "must be \{wanted}: \{keys}")
        false
      }
      NotPrinted(printed~) => {
        self.error(
          at,
          "must be written \{printed}, as smock prints it: \{keys}",
        )
        false
      }
    } noraise {
      _ => true
    }
    match
      self.grpc_condition(at, set, Value(message, field, value_field), value) {
      Some(value) if key_valid => out[key] = value
      _ => valid = false
    }
  }
  if valid {
    Some(Json::object(out))
  } else {
    None
  }
}

///|
/// `json`, the value at `pointer` of a condition on one value of `field`,
/// a field of a type of `set`, checked and normalised: an object of a
/// message field is a condition on its message; any other value is a
/// literal, in its printed form. `subject` says what the value is a value
/// of, as a problem says it.
fn File::value_condition(
  self : File,
  pointer : String,
  set : @protobuf.DescriptorSet,
  field : @protobuf.FieldDescriptor,
  json : Json,
  subject : String,
) -> Json? {
  if json is Object(members) && set.message_of(field) is Some(message) {
    return self.message_condition(pointer, set, message, members)
  }
  try set.printed_value(field, json) catch {
    NotOfType(wanted~) => {
      self.error(pointer, "must be \{wanted}: \{subject}")
      None
    }
    NotPrinted(printed~) => {
      self.error(
        pointer,
        "must be written \{printed}, as smock prints it: \{subject}",
      )
      None
    }
  } noraise {
    value => Some(value)
  }
}

///|
/// The key field and the value field of `field`, a field of a type of
/// `set`, when it is a map.
fn map_fields(
  set : @protobuf.DescriptorSet,
  field : @protobuf.FieldDescriptor,
) -> (@protobuf.FieldDescriptor, @protobuf.FieldDescriptor)? {
  guard field.label is Repeated &&
    set.message_of(field) is Some(entry) &&
    entry.map_entry &&
    entry.find_field_by_number(1) is Some(key_field) &&
    entry.find_field_by_number(2) is Some(value_field) else {
    return None
  }
  Some((key_field, value_field))
}

///|
/// The type of `field`, as a problem names it: a scalar type as a .proto
/// file spells it, such as `uint64`, or the full name of a message or an
/// enum type, without its leading dot.
fn type_text(field : @protobuf.FieldDescriptor) -> String {
  match field.type_ {
    Message | Group | Enum =>
      if field.type_name.has_prefix(".") {
        field.type_name[1:].to_owned()
      } else {
        field.type_name
      }
    type_ => "\{type_}"
  }
}
