// Messages encoded from JSON, as ProtoJSON reads it
// (https://protobuf.dev/programming-guides/json/), in protobuf's binary
// encoding, as protoc encodes them: fields in field-number order, a field
// without presence left out at its default, repeated scalars packed unless
// the field says `packed = false`, and map entries sorted by key, each
// with its key and its value, as protoc's deterministic output writes
// them. Types of proto3 files are encoded, but for the well-known types.

///|
/// Why JSON is not a message of the type it is encoded as. `pointer` is the
/// JSON Pointer of the value at fault, `""` for the whole message, and
/// `message` says what is wrong with it.
#derive(Eq, Debug)
pub(all) suberror EncodeError {
  EncodeError(pointer~ : String, message~ : String)
}

///|
/// Shows the error as `<pointer>: <message>`, or as the message alone for
/// the whole message.
pub impl Show for EncodeError with fn output(self, logger) {
  let EncodeError(pointer~, message~) = self
  if pointer != "" {
    logger.write_string(pointer)
    logger.write_string(": ")
  }
  logger.write_string(message)
}

///|
/// A JSON value that is not a value of the type it is encoded as. The
/// caller says why, since it knows where the value is.
priv suberror Unfit

///|
/// No oneof, for a message that has none.
let no_oneofs : FixedArray[Int32] = []

///|
/// Encodes `json`, a message of the type `message`, a type of this set, as
/// ProtoJSON writes it, in protobuf's binary encoding, as protoc encodes
/// it.
///
/// It reads JSON as ProtoJSON reads it. A member's key is the field's
/// proto name or its JSON name. `null` leaves a field unset. Integers are
/// numbers or strings, in decimal, with an exponent or a fraction of
/// zeros if need be, and 64-bit integers are exact at any size. Floats
/// and doubles are numbers or strings, or `"NaN"`, `"Infinity"` and
/// `"-Infinity"`. bytes are base64, standard or URL-safe, with or without
/// padding. An enum is the name of one of its values, or its number. A
/// map is an object whose keys are the map's keys written as strings:
/// integers in decimal, and `true` and `false`.
///
/// Raises `EncodeError`, at the JSON Pointer of the value at fault, for
/// JSON that is not such a message: one that is not an object, a key that
/// names no field, a field given by both its names, two members of one
/// oneof, `null` in a repeated field or as a map value, a value of the
/// wrong type or out of its type's range, and messages nested deeper than
/// 100. It also raises for a type it does not encode yet: a well-known
/// type, or a type of a file that is not proto3.
pub fn DescriptorSet::encode_json(
  self : DescriptorSet,
  message : MessageDescriptor,
  json : Json,
) -> Bytes raise EncodeError {
  if not_encoded(message) is Some(why) {
    raise EncodeError(pointer="", message=why)
  }
  guard json is Object(members) else {
    raise EncodeError(
      pointer="",
      message="must be an object: the message is a \{message.full_name}",
    )
  }
  let writer = Writer()
  self.write_message(writer, message, members, 1)
  writer.to_bytes()
}

///|
/// Why the encoder does not encode messages of the type `message` yet, or
/// `None` when it does.
fn not_encoded(message : MessageDescriptor) -> String? {
  if message.is_well_known() {
    return Some(
      "smock does not encode \{message.full_name} yet: it is a well-known type",
    )
  }
  match message.syntax {
    Proto3 => None
    Proto2 =>
      Some(
        "smock does not encode \{message.full_name} yet: it is a type of a proto2 file",
      )
    Editions =>
      Some(
        "smock does not encode \{message.full_name} yet: it is a type of an editions file",
      )
  }
}

///|
/// Whether the message is one of protobuf's well-known types, which
/// ProtoJSON writes in forms of their own: Timestamp, Duration, Struct,
/// Value, ListValue, FieldMask, Empty, Any and the wrappers, such as
/// `google.protobuf.StringValue`.
pub fn MessageDescriptor::is_well_known(self : MessageDescriptor) -> Bool {
  self.full_name
  is ("google.protobuf.Timestamp"
  | "google.protobuf.Duration"
  | "google.protobuf.Struct"
  | "google.protobuf.Value"
  | "google.protobuf.ListValue"
  | "google.protobuf.FieldMask"
  | "google.protobuf.Empty"
  | "google.protobuf.Any"
  | "google.protobuf.DoubleValue"
  | "google.protobuf.FloatValue"
  | "google.protobuf.Int64Value"
  | "google.protobuf.UInt64Value"
  | "google.protobuf.Int32Value"
  | "google.protobuf.UInt32Value"
  | "google.protobuf.BoolValue"
  | "google.protobuf.StringValue"
  | "google.protobuf.BytesValue")
}

///|
/// Whether the enum is `google.protobuf.NullValue`, the well-known enum
/// that ProtoJSON writes as `null`.
pub fn EnumDescriptor::is_well_known(self : EnumDescriptor) -> Bool {
  self.full_name == "google.protobuf.NullValue"
}

///|
/// Writes `members`, the members of an object that is a message of the
/// type `message` at nesting depth `depth`, as its fields, in field-number
/// order. Raises at the JSON Pointer of the value at fault, from
/// `members`.
fn DescriptorSet::write_message(
  self : DescriptorSet,
  writer : Writer,
  message : MessageDescriptor,
  members : Map[String, Json],
  depth : Int32,
) -> Unit raise EncodeError {
  let fields = message.fields
  // The value of each field, by its index in `fields`.
  let values : FixedArray[Json?] = FixedArray::make(fields.length(), None)
  // The index of the field that sets each oneof, or -1.
  let oneofs = if message.oneofs.length() == 0 {
    no_oneofs
  } else {
    FixedArray::make(message.oneofs.length(), -1)
  }
  for key, value in members {
    let index = message.position_of(key)
    if index < 0 {
      raise EncodeError(
        pointer=pointer_of(key),
        message="is not a field of \{message.full_name}",
      )
    }
    let field = fields[index]
    if values[index] is Some(_) {
      let other = if key == field.json_name {
        field.name
      } else {
        field.json_name
      }
      raise EncodeError(
        pointer=pointer_of(key),
        message="names the field \{field.name} of \{message.full_name}, as \"\{other}\" does: give a field once, by its proto name or its JSON name",
      )
    }
    if field.oneof_index is Some(oneof) && !(value is Null) {
      let earlier = oneofs[oneof]
      if earlier >= 0 {
        raise EncodeError(
          pointer=pointer_of(key),
          message="sets the oneof \{message.oneofs[oneof].name} of \{message.full_name}, as \"\{key_of(members, fields[earlier])}\" does: give one member of a oneof at most",
        )
      }
      oneofs[oneof] = index
    }
    values[index] = Some(value)
  }
  let order = message.by_number
  for n in 0..<order.length() {
    let index = order[n]
    guard values[index] is Some(value) else { continue }
    let field = fields[index]
    self.write_field(writer, message, field, value, depth) catch {
      EncodeError(pointer~, message=why) =>
        raise EncodeError(
          pointer=pointer_of(key_of(members, field)) + pointer,
          message=why,
        )
    }
  }
}

///|
/// The index in `fields` of the message's field that `key` names: by its
/// JSON name, or else by its proto name; -1 when it names none.
fn MessageDescriptor::position_of(
  self : MessageDescriptor,
  key : String,
) -> Int32 {
  let index = field_position(self.fields, self.by_json_name, key, json=true)
  if index >= 0 {
    index
  } else {
    field_position(self.fields, self.by_name, key, json=false)
  }
}

///|
/// The key that gives `field` among `members`: its JSON name, or else its
/// proto name.
fn key_of(members : Map[String, Json], field : FieldDescriptor) -> String {
  if members.contains(field.json_name) {
    field.json_name
  } else {
    field.name
  }
}

///|
/// The JSON Pointer of the member `key` of an object, relative to the
/// object: `/` and the key, with `~` and `/` escaped.
fn pointer_of(key : String) -> String {
  "/" + key.replace_all(old="~", new="~0").replace_all(old="/", new="~1")
}

///|
/// Writes `json`, the value of `field`, a field of `message`, at nesting
/// depth `depth`. `null` leaves it unset. Raises at the JSON Pointer of the
/// value at fault, from `json`.
fn DescriptorSet::write_field(
  self : DescriptorSet,
  writer : Writer,
  message : MessageDescriptor,
  field : FieldDescriptor,
  json : Json,
  depth : Int32,
) -> Unit raise EncodeError {
  if json is Null {
    return
  }
  if field.label is Repeated {
    match self.message_of(field) {
      Some(entry) if entry.map_entry =>
        self.write_map(writer, message, field, entry, json, depth)
      _ => self.write_list(writer, message, field, json, depth)
    }
    return
  }
  // A message field, and a member of a oneof, a proto3 `optional` field
  // included, have presence: they are written whenever they are set.
  let present = field.oneof_index is Some(_) || field.type_ is Message
  self.write_value(writer, field, json, depth, present~) catch {
    Unfit =>
      raise EncodeError(
        pointer="",
        message="must be \{self.wanted(field)}: the field \{field.name} of \{message.full_name} has the type \{type_of(field)}",
      )
    error => raise nested(error, "")
  }
}

///|
/// `error`, an error of a value at `at` that is not `Unfit`, as an
/// `EncodeError` at its pointer from the value that holds the one at `at`.
fn nested(error : Error, at : String) -> EncodeError {
  match error {
    EncodeError(pointer~, message~) =>
      EncodeError(pointer=at + pointer, message~)
    error => EncodeError(pointer=at, message=error.to_string())
  }
}

///|
/// Writes `json`, one value of `field`, as a record of the field: a value
/// of a singular field, or one element of a repeated one. A value at its
/// type's default is left out unless `present`. Raises `Unfit` when `json`
/// is not a value of the field's type.
fn DescriptorSet::write_value(
  self : DescriptorSet,
  writer : Writer,
  field : FieldDescriptor,
  json : Json,
  depth : Int32,
  present~ : Bool,
) -> Unit raise {
  match field.type_ {
    Message => {
      guard self.message_of(field) is Some(type_) && json is Object(members) else {
        raise Unfit
      }
      let message = self.encoded_message(type_, members, depth)
      writer.tag(field.number, Len)
      writer.length_delimited(message)
    }
    String => {
      guard json is String(text) else { raise Unfit }
      if text != "" || present {
        writer.tag(field.number, Len)
        writer.utf8(text)
      }
    }
    Bytes => {
      guard json is String(text) else { raise Unfit }
      let octets = base64_octets(text)
      if octets.length() > 0 || present {
        writer.tag(field.number, Len)
        writer.length_delimited(octets)
      }
    }
    Group => raise Unfit
    type_ => {
      let bits = self.scalar_bits(field, json)
      if bits != 0 || present {
        writer.tag(field.number, wire_type_of(type_))
        writer.scalar(type_, bits)
      }
    }
  }
}

///|
/// `members`, an object that is a message of the type `message`, a nested
/// message at nesting depth `depth`, encoded. Raises `EncodeError` from
/// `members`, and when the type is not encoded yet or nests too deep.
fn DescriptorSet::encoded_message(
  self : DescriptorSet,
  message : MessageDescriptor,
  members : Map[String, Json],
  depth : Int32,
) -> Bytes raise EncodeError {
  if not_encoded(message) is Some(why) {
    raise EncodeError(pointer="", message=why)
  }
  if depth >= max_depth {
    raise EncodeError(
      pointer="",
      message="nests messages deeper than \{max_depth}",
    )
  }
  let nested = Writer()
  self.write_message(nested, message, members, depth + 1)
  nested.to_bytes()
}

///|
/// Writes `json`, the value of `field`, a repeated field of `message` that
/// is not a map, from an array: packed, when the field is a scalar of a
/// proto3 type that does not say `packed = false`, otherwise one record
/// per element.
fn DescriptorSet::write_list(
  self : DescriptorSet,
  writer : Writer,
  message : MessageDescriptor,
  field : FieldDescriptor,
  json : Json,
  depth : Int32,
) -> Unit raise EncodeError {
  guard json is Array(items) else {
    raise EncodeError(
      pointer="",
      message="must be an array: the field \{field.name} of \{message.full_name} is repeated",
    )
  }
  if items.is_empty() {
    return
  }
  let packed = !(field.type_ is (String | Bytes | Message | Group)) &&
    field.packed is (None | Some(true))
  let out = if packed { Writer() } else { writer }
  for i, item in items {
    let at = "/\{i}"
    if item is Null {
      raise EncodeError(
        pointer=at,
        message="cannot be null: it is an element of the repeated field \{field.name} of \{message.full_name}",
      )
    }
    if packed {
      out.scalar(field.type_, self.scalar_bits(field, item)) catch {
        _ => raise self.unfit_element(message, field, at)
      }
    } else {
      self.write_value(out, field, item, depth, present=true) catch {
        Unfit => raise self.unfit_element(message, field, at)
        error => raise nested(error, at)
      }
    }
  }
  if packed {
    writer.tag(field.number, Len)
    writer.length_delimited(out.to_bytes())
  }
}

///|
/// The error of the element at `at` of `field`, a repeated field of
/// `message`, which is not a value of its type.
fn DescriptorSet::unfit_element(
  self : DescriptorSet,
  message : MessageDescriptor,
  field : FieldDescriptor,
  at : String,
) -> EncodeError {
  EncodeError(
    pointer=at,
    message="must be \{self.wanted(field)}: the elements of the field \{field.name} of \{message.full_name} have the type \{type_of(field)}",
  )
}

///|
/// Writes `json`, the value of `field`, a map field of `message` whose
/// entries have the type `entry`, from an object: one entry per member,
/// sorted by key, each with its key and its value, as protoc writes them.
fn DescriptorSet::write_map(
  self : DescriptorSet,
  writer : Writer,
  message : MessageDescriptor,
  field : FieldDescriptor,
  entry : MessageDescriptor,
  json : Json,
  depth : Int32,
) -> Unit raise EncodeError {
  guard json is Object(members) else {
    raise EncodeError(
      pointer="",
      message="must be an object: the field \{field.name} of \{message.full_name} is a map",
    )
  }
  guard entry.find_field_by_number(1) is Some(key_field) &&
    entry.find_field_by_number(2) is Some(value_field) else {
    raise EncodeError(
      pointer="",
      message="the map field \{field.name} of \{message.full_name} has an entry type without a key and a value",
    )
  }
  let count = members.length()
  if count == 0 {
    return
  }
  let key_type = key_field.type_
  // Each member's key and value, and, for a key that is not a string, the
  // key's value: a bool's 0 or 1, or an integer in two's complement.
  let keys : FixedArray[String] = FixedArray::make(count, "")
  let values : FixedArray[Json] = FixedArray::make(count, Json::null())
  let numbers : FixedArray[UInt64] = FixedArray::make(count, 0)
  let order : FixedArray[Int32] = FixedArray::make(count, 0)
  let mut n = 0
  for key, value in members {
    keys[n] = key
    values[n] = value
    order[n] = n
    if !(key_type is String) {
      numbers[n] = map_key(key_type, key) catch {
        _ =>
          raise EncodeError(
            pointer=pointer_of(key),
            message="must be \{self.wanted_key(key_field)}: the keys of the map field \{field.name} of \{message.full_name} have the type \{type_of(key_field)}",
          )
      }
    }
    n += 1
  }
  // Signed keys sort as unsigned ones once their sign bits are flipped.
  let flip = if key_type
    is (Int32 | Int64 | SInt32 | SInt64 | SFixed32 | SFixed64) {
    0x8000_0000_0000_0000UL
  } else {
    0
  }
  sort_entries(order, keys, numbers, by_text=key_type is String, flip~)
  for i in 0..<count {
    let index = order[i]
    let key = keys[index]
    let at = pointer_of(key)
    let value = values[index]
    if value is Null {
      raise EncodeError(
        pointer=at,
        message="cannot be null: it is a value of the map field \{field.name} of \{message.full_name}",
      )
    }
    let pair = Writer()
    if key_type is String {
      pair.tag(1, Len)
      pair.utf8(key) catch {
        _ =>
          raise EncodeError(
            pointer=at,
            message="must be \{self.wanted(key_field)}: the keys of the map field \{field.name} of \{message.full_name} have the type \{type_of(key_field)}",
          )
      }
    } else {
      pair.tag(1, wire_type_of(key_type))
      pair.scalar(key_type, zigzag(key_type, numbers[index]))
    }
    self.write_value(pair, value_field, value, depth, present=true) catch {
      Unfit =>
        raise EncodeError(
          pointer=at,
          message="must be \{self.wanted(value_field)}: the values of the map field \{field.name} of \{message.full_name} have the type \{type_of(value_field)}",
        )
      error => raise nested(error, at)
    }
    writer.tag(field.number, Len)
    writer.length_delimited(pair.to_bytes())
  }
}

///|
/// The value of `key`, a key of a map whose keys have the type `type_`,
/// written as a JSON object's key: a bool's 0 or 1, from `false` or
/// `true`, or an integer in two's complement, from its decimal text.
/// Raises `Unfit` when `key` is not a key of the type.
fn map_key(type_ : FieldType, key : String) -> UInt64 raise Unfit {
  match type_ {
    Bool =>
      match key {
        "false" => 0
        "true" => 1
        _ => raise Unfit
      }
    Int32 | SInt32 | SFixed32 => integer_of_text(key, signed=true, wide=false)
    Int64 | SInt64 | SFixed64 => integer_of_text(key, signed=true, wide=true)
    UInt32 | Fixed32 => integer_of_text(key, signed=false, wide=false)
    UInt64 | Fixed64 => integer_of_text(key, signed=false, wide=true)
    _ => raise Unfit
  }
}

///|
/// Sorts `order`, indexes of a map's entries, by their keys: by `keys` in
/// code point order, when `by_text`, or else by `numbers`, as unsigned
/// integers once XORed with `flip`. The sort is a merge sort, stable, with
/// plain loops.
fn sort_entries(
  order : FixedArray[Int32],
  keys : FixedArray[String],
  numbers : FixedArray[UInt64],
  by_text~ : Bool,
  flip~ : UInt64,
) -> Unit {
  let count = order.length()
  let mut from = order
  let mut to : FixedArray[Int32] = FixedArray::make(count, 0)
  let mut width = 1
  while width < count {
    let mut low = 0
    while low < count {
      let middle = if low + width < count { low + width } else { count }
      let high = if middle + width < count { middle + width } else { count }
      let mut left = low
      let mut right = middle
      for i in low..<high {
        let take_right = right < high &&
          (
            left >= middle ||
            (if by_text {
              code_point_compare(keys[from[right]], keys[from[left]]) < 0
            } else {
              (numbers[from[right]] ^ flip) < (numbers[from[left]] ^ flip)
            })
          )
        if take_right {
          to[i] = from[right]
          right += 1
        } else {
          to[i] = from[left]
          left += 1
        }
      }
      low = high
    }
    let sorted = to
    to = from
    from = sorted
    width *= 2
  }
  if !physical_equal(from, order) {
    for i in 0..<count {
      order[i] = from[i]
    }
  }
}

///|
/// Compares `a` and `b` by their code points, as their octets in UTF-8
/// compare: UTF-16 code units compare so, but for surrogates, which come
/// after U+E000 to U+FFFF in code point order.
fn code_point_compare(a : String, b : String) -> Int32 {
  let length = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<length {
    let x = a.unsafe_get(i).to_int()
    let y = b.unsafe_get(i).to_int()
    if x != y {
      return code_point_rank(x) - code_point_rank(y)
    }
  }
  a.length() - b.length()
}

///|
/// Where the UTF-16 code unit `unit` sorts in code point order: surrogates
/// after U+E000 to U+FFFF, which come down before them.
fn code_point_rank(unit : Int32) -> Int32 {
  if unit >= 0xE000 {
    unit - 0x800
  } else if unit >= 0xD800 {
    unit + 0x2000
  } else {
    unit
  }
}

///|
/// The wire type that the scalar type `type_` is written with.
fn wire_type_of(type_ : FieldType) -> WireType {
  match type_ {
    Double | Fixed64 | SFixed64 => I64
    Float | Fixed32 | SFixed32 => I32
    _ => Varint
  }
}

///|
/// Writes `bits`, a value of the scalar type `type_` as `scalar_bits`
/// gives it, as its wire type writes it.
fn Writer::scalar(self : Writer, type_ : FieldType, bits : UInt64) -> Unit {
  match wire_type_of(type_) {
    I64 => self.fixed64(bits)
    I32 => self.fixed32(bits.to_uint())
    _ => self.varint(bits)
  }
}

///|
/// Writes `text` as a length-delimited value: the length of its UTF-8,
/// then its UTF-8. Raises `Unfit` when it holds a surrogate that is not
/// part of a pair, which UTF-8 cannot write.
fn Writer::utf8(self : Writer, text : String) -> Unit raise Unfit {
  let length = text.length()
  let mut octets = 0
  let mut i = 0
  while i < length {
    let unit = text.unsafe_get(i).to_int()
    if unit < 0x80 {
      octets += 1
    } else if unit < 0x800 {
      octets += 2
    } else if unit >= 0xD800 && unit < 0xDC00 {
      guard i + 1 < length &&
        text.unsafe_get(i + 1).to_int() >= 0xDC00 &&
        text.unsafe_get(i + 1).to_int() < 0xE000 else {
        raise Unfit
      }
      octets += 4
      i += 1
    } else if unit >= 0xDC00 && unit < 0xE000 {
      raise Unfit
    } else {
      octets += 3
    }
    i += 1
  }
  self.varint(octets.to_uint64())
  self.out.write_string_utf8(text)
}

///|
/// The value of `json` as a value of `field`, a field of a scalar or enum
/// type, as the bits its wire type writes: a varint's value, with negative
/// `int32`, `int64` and enum numbers in two's complement and `sint32` and
/// `sint64` in ZigZag, or the octets of a fixed-width type, little-endian.
/// Raises `Unfit` when `json` is not such a value.
fn DescriptorSet::scalar_bits(
  self : DescriptorSet,
  field : FieldDescriptor,
  json : Json,
) -> UInt64 raise Unfit {
  match field.type_ {
    Bool =>
      match json {
        True => 1
        False => 0
        _ => raise Unfit
      }
    Int32 | SFixed32 | SInt32 =>
      zigzag(field.type_, integer_bits(json, signed=true, wide=false))
    Int64 | SFixed64 | SInt64 =>
      zigzag(field.type_, integer_bits(json, signed=true, wide=true))
    UInt32 | Fixed32 => integer_bits(json, signed=false, wide=false)
    UInt64 | Fixed64 => integer_bits(json, signed=false, wide=true)
    Double => {
      let n = floating(json)
      if n.is_nan() {
        // NaN as protobuf writes it.
        0x7FF8_0000_0000_0000
      } else {
        n.reinterpret_as_uint64()
      }
    }
    Float => {
      let n = floating(json)
      if n.is_nan() {
        0x7FC0_0000
      } else {
        let f = Float::from_double(n)
        if f.is_inf() && !n.is_inf() {
          // Out of the range of a float.
          raise Unfit
        }
        f.reinterpret_as_uint().to_uint64()
      }
    }
    Enum => {
      guard self.enum_of(field) is Some(type_) && !type_.is_well_known() else {
        raise Unfit
      }
      match json {
        String(name) =>
          match type_.find_value_by_name(name) {
            Some(value) => value.number.to_int64().reinterpret_as_uint64()
            None => raise Unfit
          }
        // Any number of an open enum, as a proto3 enum is.
        _ => integer_bits(json, signed=true, wide=false)
      }
    }
    String | Bytes | Message | Group => raise Unfit
  }
}

///|
/// `value`, an integer of the type `type_` in two's complement, as the
/// wire format writes it: in ZigZag for `sint32` and `sint64`, so that
/// numbers near 0 take few octets, and as it is for other types.
fn zigzag(type_ : FieldType, value : UInt64) -> UInt64 {
  match type_ {
    SInt32 => {
      let n = value.to_int()
      ((n << 1) ^ (n >> 31)).reinterpret_as_uint().to_uint64()
    }
    SInt64 => {
      let n = value.reinterpret_as_int64()
      ((n << 1) ^ (n >> 63)).reinterpret_as_uint64()
    }
    _ => value
  }
}

///|
/// What `field`'s values must be, as an error says it: such as `a string`.
fn DescriptorSet::wanted(
  self : DescriptorSet,
  field : FieldDescriptor,
) -> String {
  match field.type_ {
    Double => "a number, or \"NaN\", \"Infinity\" or \"-Infinity\""
    Float =>
      "a number within the range of a float, or \"NaN\", \"Infinity\" or \"-Infinity\""
    Int32 | SInt32 | SFixed32 => "an integer from -2147483648 to 2147483647"
    Int64 | SInt64 | SFixed64 =>
      "an integer from -9223372036854775808 to 9223372036854775807"
    UInt32 | Fixed32 => "an integer from 0 to 4294967295"
    UInt64 | Fixed64 => "an integer from 0 to 18446744073709551615"
    Bool => "true or false"
    String => "a string of Unicode text"
    Bytes => "a string in base64, standard or URL-safe, with or without padding"
    Enum =>
      match self.enum_of(field) {
        Some(type_) =>
          "the name of a value of \{type_.full_name}, or an integer from -2147483648 to 2147483647"
        None => "an enum value"
      }
    Message | Group => "an object"
  }
}

///|
/// What the keys of a map whose key field is `field` must be, as an error
/// says it: a bool key is `"true"` or `"false"`.
fn DescriptorSet::wanted_key(
  self : DescriptorSet,
  field : FieldDescriptor,
) -> String {
  match field.type_ {
    Bool => "\"true\" or \"false\""
    _ => self.wanted(field)
  }
}

///|
/// The type of `field`, as an error names it: a scalar type as a .proto
/// file spells it, such as `uint64`, or the full name of a message or enum
/// type, without a leading dot.
fn type_of(field : FieldDescriptor) -> String {
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

///|
/// The integer that `json` gives, as a number or as a string, as its 64
/// bits in two's complement. It must be in the range of a signed integer,
/// when `signed`, or else an unsigned one, of 64 bits, when `wide`, or else
/// 32. Raises `Unfit` when it is not one.
fn integer_bits(
  json : Json,
  signed~ : Bool,
  wide~ : Bool,
) -> UInt64 raise Unfit {
  match json {
    // The text of a number that a 64-bit float does not hold exactly.
    Number(_, repr=Some(text)) | String(text) =>
      integer_of_text(text, signed~, wide~)
    Number(n, repr=None) => {
      if n.is_inf() || n != n.floor() {
        raise Unfit
      }
      let low = if !signed {
        0.0
      } else if wide {
        -9223372036854775808.0
      } else {
        -2147483648.0
      }
      // The largest integers of the 64-bit ranges are not doubles, so
      // these are 2^63 and 2^64, the first doubles above them.
      let high = if wide && signed {
        9223372036854775808.0
      } else if wide {
        18446744073709551616.0
      } else if signed {
        2147483647.0
      } else {
        4294967295.0
      }
      if n < low || n > high || (wide && n == high) {
        raise Unfit
      }
      if n < 0.0 {
        n.to_int64().reinterpret_as_uint64()
      } else {
        n.to_uint64()
      }
    }
    _ => raise Unfit
  }
}

///|
/// The integer that `text` writes in decimal, as JSON writes a number: an
/// optional `-`, digits, which may start with zeros, then an optional
/// fraction and an optional exponent, so long as the value is an integer,
/// such as `1e3` or `100.0`. The value is exact at any size. It is
/// returned as `integer_bits` returns it.
fn integer_of_text(
  text : StringView,
  signed~ : Bool,
  wide~ : Bool,
) -> UInt64 raise Unfit {
  if !is_number_text(text) {
    raise Unfit
  }
  // The digits, without their trailing zeros, as a number; how many zeros
  // trail them; how many digits the fraction has; and the exponent.
  let mut digits = 0UL
  let mut zeros = 0
  let mut fraction = 0
  let mut exponent = 0
  let mut exponent_sign = 1
  let negative = text.length() > 0 &&
    text.unsafe_get(0).to_int() == '-'.to_int()
  // 0 in the integer, 1 in the fraction, 2 in the exponent.
  let mut part = 0
  for i in 0..<text.length() {
    let unit = text.unsafe_get(i).to_int()
    if unit == '.'.to_int() {
      part = 1
    } else if unit == 'e'.to_int() || unit == 'E'.to_int() {
      part = 2
    } else if unit == '-'.to_int() {
      if part == 2 {
        exponent_sign = -1
      }
    } else if unit >= '0'.to_int() && unit <= '9'.to_int() {
      let digit = unit - '0'.to_int()
      if part == 2 {
        // Large enough to put any other digits out of range.
        if exponent < 100_000 {
          exponent = exponent * 10 + digit
        }
      } else {
        if part == 1 {
          fraction += 1
        }
        if digit == 0 {
          zeros += 1
        } else {
          for _ in 0..<zeros {
            digits = times_ten(digits)
          }
          zeros = 0
          let next = times_ten(digits) + digit.to_uint64()
          if next < digits {
            raise Unfit
          }
          digits = next
        }
      }
    }
  }
  // The value is the digits times 10 to `shift`.
  let shift = zeros + exponent_sign * exponent - fraction
  let mut magnitude = digits
  if digits != 0 {
    if shift < 0 {
      // The last digit is not zero, so the value has a fraction.
      raise Unfit
    }
    for _ in 0..<shift {
      magnitude = times_ten(magnitude)
    }
  }
  let largest = if wide && signed {
    0x7FFF_FFFF_FFFF_FFFFUL
  } else if wide {
    0xFFFF_FFFF_FFFF_FFFFUL
  } else if signed {
    0x7FFF_FFFFUL
  } else {
    0xFFFF_FFFFUL
  }
  if negative && magnitude != 0 {
    // The smallest signed integer is one further from 0 than the largest.
    if !signed || magnitude > largest + 1 {
      raise Unfit
    }
    0UL - magnitude
  } else if magnitude > largest {
    raise Unfit
  } else {
    magnitude
  }
}

///|
/// `n` times 10, or `Unfit` when that is above the largest 64-bit unsigned
/// integer.
fn times_ten(n : UInt64) -> UInt64 raise Unfit {
  if n > 0x1999_9999_9999_9999 {
    raise Unfit
  }
  n * 10
}

///|
/// Whether `text` is a number as JSON writes one, but that its digits may
/// start with zeros: an optional `-`, one digit or more, then optionally
/// `.` and one digit or more, then optionally `e` or `E`, an optional sign
/// and one digit or more.
fn is_number_text(text : StringView) -> Bool {
  // 0 at the start, 1 after `-`, 2 in the integer's digits, 3 after `.`,
  // 4 in the fraction, 5 after `e`, 6 after its sign, 7 in the exponent.
  let mut state = 0
  for i in 0..<text.length() {
    let unit = text.unsafe_get(i).to_int()
    let digit = unit >= '0'.to_int() && unit <= '9'.to_int()
    state = if digit {
      match state {
        0 | 1 | 2 => 2
        3 | 4 => 4
        _ => 7
      }
    } else if unit == '-'.to_int() && state == 0 {
      1
    } else if unit == '.'.to_int() && state == 2 {
      3
    } else if (unit == 'e'.to_int() || unit == 'E'.to_int()) && state is (2 | 4) {
      5
    } else if (unit == '+'.to_int() || unit == '-'.to_int()) && state == 5 {
      6
    } else {
      return false
    }
  }
  state is (2 | 4 | 7)
}

///|
/// The number that `json` gives, as a float or double field reads it: a
/// number, or a string that is one, or `"NaN"`, `"Infinity"` or
/// `"-Infinity"`. Raises `Unfit` for anything else, and for a number
/// beyond the range of a double.
fn floating(json : Json) -> Double raise Unfit {
  let n = match json {
    Number(n, ..) => n
    String("NaN") => return @double.not_a_number
    String("Infinity") => return @double.infinity
    String("-Infinity") => return @double.neg_infinity
    String(text) if is_number_text(text) =>
      @string.parse_double(text) catch {
        _ => raise Unfit
      }
    _ => raise Unfit
  }
  // A number that JSON wrote beyond the range of a double reads as an
  // infinity.
  if n.is_inf() || n.is_nan() {
    raise Unfit
  }
  n
}

///|
/// The octets that `text`, base64, gives: standard or URL-safe, with or
/// without its padding. Raises `Unfit` when it is not base64.
fn base64_octets(text : String) -> Bytes raise Unfit {
  let mut length = text.length()
  // Padding, when there is some, makes whole groups of four.
  if length % 4 == 0 &&
    length > 0 &&
    text.unsafe_get(length - 1).to_int() == '='.to_int() {
    length -= 1
    if text.unsafe_get(length - 1).to_int() == '='.to_int() {
      length -= 1
    }
  }
  if length % 4 == 1 {
    raise Unfit
  }
  let out = @buffer.Buffer(size_hint=length * 3 / 4)
  let mut bits = 0
  let mut held = 0
  for i in 0..<length {
    let value = match text.unsafe_get(i).to_int() {
      unit if unit >= 'A'.to_int() && unit <= 'Z'.to_int() =>
        unit - 'A'.to_int()
      unit if unit >= 'a'.to_int() && unit <= 'z'.to_int() =>
        unit - 'a'.to_int() + 26
      unit if unit >= '0'.to_int() && unit <= '9'.to_int() =>
        unit - '0'.to_int() + 52
      unit if unit == '+'.to_int() || unit == '-'.to_int() => 62
      unit if unit == '/'.to_int() || unit == '_'.to_int() => 63
      _ => raise Unfit
    }
    bits = (bits << 6) | value
    held += 6
    if held >= 8 {
      held -= 8
      out.write_byte(((bits >> held) & 0xFF).to_byte())
    }
  }
  out.to_bytes()
}
