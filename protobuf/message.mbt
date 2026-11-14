// Messages decoded from their descriptors into smock's decoded form, the
// JSON text the engine, the Journal and templates see. For now the decoder
// serves singular fields of every scalar type, enums and nested messages.
// encode.mbt encodes messages from JSON.

///|
/// The index in `fields` of the message's field numbered `number`, or -1,
/// found by binary search in the index of its fields by number.
fn MessageDescriptor::field_index(
  self : MessageDescriptor,
  number : Int32,
) -> Int32 {
  let order = self.by_number
  let mut low = 0
  let mut high = order.length()
  while low < high {
    let middle = (low + high) / 2
    if self.fields[order[middle]].number < number {
      low = middle + 1
    } else {
      high = middle
    }
  }
  if low < order.length() && self.fields[order[low]].number == number {
    order[low]
  } else {
    -1
  }
}

///|
/// The value of a field of a message being decoded, as its records give
/// it.
priv enum Value {
  /// The last value of a scalar or an enum field: a varint, or a fixed
  /// 32-bit or 64-bit value, as its bits.
  Number(UInt64)
  /// The octets of the last value of a string or bytes field.
  Octets(BytesView)
  /// The octets of each value of a message field, in order. protobuf's
  /// parsers merge them into one message.
  Messages(Array[BytesView])
}

///|
/// Decodes `input`, a message of the type `message` of `set` in protobuf's
/// binary encoding, into smock's decoded form: compact JSON text in UTF-8,
/// an object with one member per field, in field-number order, under the
/// field's JSON name.
///
/// - 64-bit integers are numbers, exact at any size; 32-bit integers are
///   numbers too.
/// - A double is printed as `Double::to_string` prints it, and a float in
///   the shortest form that reads back as the same 32-bit float, so 0.1f
///   prints `0.1`. NaN and the infinities are the strings `"NaN"`,
///   `"Infinity"` and `"-Infinity"`.
/// - A bool is `true` or `false`, a string is a JSON string, and bytes are
///   a string of standard base64 with padding.
/// - An enum value is printed by its name, the first one of an alias, or
///   by its number when the enum does not define it.
/// - A nested message is an object in the same form.
/// - A field without presence that the message leaves out is printed at
///   its default: `0`, `false`, `""`, or an enum's value 0. A proto3
///   `optional` field and a message field are printed only when the
///   message holds them.
///
/// It reads the message as protobuf's parsers read it: the last value of a
/// scalar or an enum field wins, the values of a message field are merged,
/// and unknown fields, and fields sent with another wire type than their
/// type's, are skipped.
///
/// Raises `DecodeError` when the input is not protobuf, when a string is
/// not UTF-8, as a proto3 string must be, when messages nest deeper than
/// 100, and when a message it prints has a field that it does not decode
/// yet: a repeated field, a map, a field in a oneof other than a proto3
/// `optional` field's, a group, or a field of a well-known type.
pub fn decode_json(
  set : DescriptorSet,
  message : MessageDescriptor,
  input : BytesView,
) -> Bytes raise DecodeError {
  let out = @buffer.Buffer(size_hint=2 * input.length() + 16)
  set.print_message(out, message, [input], 0)
  out.to_bytes()
}

///|
/// Prints to `out` the message of the type `message` whose values are
/// `records`, merged in order, `depth` messages deep in the message that
/// `decode_json` decodes, as `decode_json` prints it.
fn DescriptorSet::print_message(
  self : DescriptorSet,
  out : @buffer.Buffer,
  message : MessageDescriptor,
  records : Array[BytesView],
  depth : Int32,
) -> Unit raise DecodeError {
  let fields = message.fields
  let values : FixedArray[Value?] = FixedArray::make(fields.length(), None)
  for r in 0..<records.length() {
    let reader = Reader(records[r])
    while !reader.at_end() {
      let index = message.field_index(reader.tag())
      guard index >= 0 else {
        reader.skip()
        continue
      }
      let field = fields[index]
      match (field.type_, reader.wire_type()) {
        (Int32 | Int64 | UInt32 | UInt64 | SInt32 | SInt64 | Bool | Enum, Varint
        ) => values[index] = Some(Number(reader.varint()))
        (Fixed64 | SFixed64 | Double, I64) =>
          values[index] = Some(Number(reader.fixed64()))
        (Fixed32 | SFixed32 | Float, I32) =>
          values[index] = Some(Number(reader.fixed32().to_uint64()))
        (String, Len) => {
          let at = reader.pos
          let value = reader.length_delimited()
          if !is_utf8(value) {
            raise reader.error(
              at,
              "the field \{field.name} holds octets that are not UTF-8",
            )
          }
          values[index] = Some(Octets(value))
        }
        (Bytes, Len) => values[index] = Some(Octets(reader.length_delimited()))
        (Message, Len) => {
          let value = reader.length_delimited()
          match values[index] {
            Some(Messages(list)) => list.push(value)
            _ => values[index] = Some(Messages([value]))
          }
        }
        _ => reader.skip()
      }
    }
  }
  out.write_byte(b'{')
  let order = message.by_number
  let mut first = true
  for n in 0..<order.length() {
    let index = order[n]
    let field = fields[index]
    if self.not_decoded(field) is Some(why) {
      raise DecodeError(
        position=records[0].start_offset(),
        message="the field \{field.name} \{why}, which smock does not decode yet",
      )
    }
    let value = values[index]
    if value is None && (field.proto3_optional || field.type_ is Message) {
      continue
    }
    if !first {
      out.write_byte(b',')
    }
    first = false
    write_json_name(out, field.json_name)
    out.write_byte(b':')
    match value {
      Some(Messages(list)) => {
        if depth >= max_depth {
          raise DecodeError(
            position=list[0].start_offset(),
            message="messages nest deeper than \{max_depth}",
          )
        }
        match self.message_of(field) {
          Some(type_) => self.print_message(out, type_, list, depth + 1)
          // Never: a message field's type is a message of its set.
          None => out.write_bytes(b"{}")
        }
      }
      Some(Octets(octets)) =>
        if field.type_ is Bytes {
          write_base64(out, octets)
        } else {
          write_json_string(out, octets)
        }
      Some(Number(bits)) => self.print_number(out, field, bits)
      None =>
        match field.type_ {
          String | Bytes => out.write_bytes(b"\"\"")
          _ => self.print_number(out, field, 0)
        }
    }
  }
  out.write_byte(b'}')
}

///|
/// Prints to `out` the value of `field`, a scalar or an enum field other
/// than a string or bytes, whose bits are `bits`: a varint, or a fixed
/// 32-bit or 64-bit value.
fn DescriptorSet::print_number(
  self : DescriptorSet,
  out : @buffer.Buffer,
  field : FieldDescriptor,
  bits : UInt64,
) -> Unit {
  match field.type_ {
    Bool => out.write_bytes(if bits != 0 { b"true" } else { b"false" })
    Int64 | SFixed64 => write_signed(out, bits.reinterpret_as_int64())
    UInt64 | Fixed64 => write_unsigned(out, bits)
    Int32 | SFixed32 =>
      write_signed(out, bits.to_uint().reinterpret_as_int().to_int64())
    UInt32 | Fixed32 => write_unsigned(out, bits & 0xFFFF_FFFFUL)
    SInt32 => {
      let n = bits.to_uint()
      let value = (n >> 1).reinterpret_as_int() ^ -(n & 1).reinterpret_as_int()
      write_signed(out, value.to_int64())
    }
    SInt64 =>
      write_signed(
        out,
        (bits >> 1).reinterpret_as_int64() ^ -(bits & 1).reinterpret_as_int64(),
      )
    Double => write_double(out, bits.reinterpret_as_double())
    Float => {
      let value = Float::reinterpret_from_uint(bits.to_uint())
      if value.is_nan() || value.is_inf() {
        write_double(out, value.to_double())
      } else {
        out.write_string_utf8(value.to_string())
      }
    }
    Enum => {
      let number = bits.to_uint().reinterpret_as_int()
      match self.enum_of(field) {
        Some(type_) =>
          match type_.find_value_by_number(number) {
            Some(value) => write_json_name(out, value.name)
            None => write_signed(out, number.to_int64())
          }
        None => write_signed(out, number.to_int64())
      }
    }
    _ => ()
  }
}

///|
/// Why `decode_json` does not decode `field` yet, a field of a message of
/// this set, or `None` when it does: it is repeated, as a map is, in a
/// oneof other than a proto3 `optional` field's, a group, or of a
/// well-known type, which ProtoJSON prints in a form of its own.
fn DescriptorSet::not_decoded(
  self : DescriptorSet,
  field : FieldDescriptor,
) -> String? {
  if field.label is Repeated {
    return Some("is repeated")
  }
  if field.oneof_index is Some(_) && !field.proto3_optional {
    return Some("is in a oneof")
  }
  let name = match field.type_ {
    Group => return Some("is a group")
    Message =>
      match self.message_of(field) {
        Some(type_) => type_.full_name
        None => return None
      }
    Enum =>
      match self.enum_of(field) {
        Some(type_) => type_.full_name
        None => return None
      }
    _ => return None
  }
  if is_well_known(name) {
    Some("has the well-known type \{name}")
  } else {
    None
  }
}

///|
/// Whether `full_name`, a full name without a leading dot, is the name of
/// one of protobuf's well-known types that ProtoJSON prints in a form of
/// its own: Any, Duration, Timestamp, FieldMask, Struct, Value, ListValue,
/// NullValue, Empty and the wrappers, such as
/// `google.protobuf.Timestamp`.
pub fn is_well_known(full_name : String) -> Bool {
  full_name.has_prefix("google.protobuf.") &&
  full_name
  is ("google.protobuf.Any"
  | "google.protobuf.Duration"
  | "google.protobuf.Timestamp"
  | "google.protobuf.FieldMask"
  | "google.protobuf.Struct"
  | "google.protobuf.Value"
  | "google.protobuf.ListValue"
  | "google.protobuf.NullValue"
  | "google.protobuf.Empty"
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
/// Writes `value` as a JSON number, or as the string `"NaN"`, `"Infinity"`
/// or `"-Infinity"`, which JSON has no number for.
fn write_double(out : @buffer.Buffer, value : Double) -> Unit {
  if value.is_nan() {
    out.write_bytes(b"\"NaN\"")
  } else if value.is_pos_inf() {
    out.write_bytes(b"\"Infinity\"")
  } else if value.is_neg_inf() {
    out.write_bytes(b"\"-Infinity\"")
  } else {
    out.write_string_utf8(value.to_string())
  }
}

///|
/// Writes `value` in decimal, with a `-` when it is negative.
fn write_signed(out : @buffer.Buffer, value : Int64) -> Unit {
  if value < 0 {
    out.write_byte(b'-')
    // In two's complement, so that the smallest Int64 has its magnitude.
    write_unsigned(out, 0UL - value.reinterpret_as_uint64())
  } else {
    write_unsigned(out, value.reinterpret_as_uint64())
  }
}

///|
/// Writes `value` in decimal.
fn write_unsigned(out : @buffer.Buffer, value : UInt64) -> Unit {
  // The power of ten of the first digit. It never passes `value`, so it
  // never overflows.
  let mut unit = 1UL
  while value / unit >= 10 {
    unit = unit * 10
  }
  while unit > 0 {
    out.write_byte((0x30UL + value / unit % 10).to_byte())
    unit = unit / 10
  }
}

///|
/// The digits of standard base64, in order.
let base64_digits : Bytes = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

///|
/// Writes `octets` as a JSON string of standard base64, with padding.
fn write_base64(out : @buffer.Buffer, octets : BytesView) -> Unit {
  out.write_byte(b'"')
  let length = octets.length()
  let mut i = 0
  while i + 3 <= length {
    let bits = (octets[i].to_int() << 16) |
      (octets[i + 1].to_int() << 8) |
      octets[i + 2].to_int()
    out.write_byte(base64_digits[bits >> 18])
    out.write_byte(base64_digits[(bits >> 12) & 63])
    out.write_byte(base64_digits[(bits >> 6) & 63])
    out.write_byte(base64_digits[bits & 63])
    i = i + 3
  }
  if length - i == 1 {
    let bits = octets[i].to_int() << 16
    out.write_byte(base64_digits[bits >> 18])
    out.write_byte(base64_digits[(bits >> 12) & 63])
    out.write_bytes(b"==")
  } else if length - i == 2 {
    let bits = (octets[i].to_int() << 16) | (octets[i + 1].to_int() << 8)
    out.write_byte(base64_digits[bits >> 18])
    out.write_byte(base64_digits[(bits >> 12) & 63])
    out.write_byte(base64_digits[(bits >> 6) & 63])
    out.write_byte(b'=')
  }
  out.write_byte(b'"')
}

///|
/// Writes `name`, a field's JSON name or an enum value's name, as a JSON
/// string. Such a name is ASCII without quotes or controls, unless a
/// `json_name` makes it otherwise, so it is written one code unit at a time
/// until a code unit needs more.
fn write_json_name(out : @buffer.Buffer, name : String) -> Unit {
  for i in 0..<name.length() {
    let unit = name[i]
    if unit < 0x20 || unit >= 0x7F || unit == '"' || unit == '\\' {
      write_json_string(out, @utf8.encode(name))
      return
    }
  }
  out.write_byte(b'"')
  for i in 0..<name.length() {
    out.write_byte(name[i].to_byte())
  }
  out.write_byte(b'"')
}

///|
/// Whether `octets` are UTF-8.
fn is_utf8(octets : BytesView) -> Bool {
  let _ = @utf8.decode(octets, ignore_bom=false) catch { _ => return false }
  true
}

///|
/// Writes `octets`, UTF-8 text, as a JSON string: in quotes, with `"`, `\`
/// and the control characters escaped as `@json` escapes them.
fn write_json_string(out : @buffer.Buffer, octets : BytesView) -> Unit {
  out.write_byte(b'"')
  for octet in octets {
    match octet {
      b'"' => out.write_bytes(b"\\\"")
      b'\\' => out.write_bytes(b"\\\\")
      b'\n' => out.write_bytes(b"\\n")
      b'\r' => out.write_bytes(b"\\r")
      b'\t' => out.write_bytes(b"\\t")
      b'\x08' => out.write_bytes(b"\\b")
      b'\x0c' => out.write_bytes(b"\\f")
      _ if octet < b'\x20' => {
        out.write_bytes(b"\\u00")
        out.write_byte(hex_digit(octet.to_int() >> 4))
        out.write_byte(hex_digit(octet.to_int() & 15))
      }
      _ => out.write_byte(octet)
    }
  }
  out.write_byte(b'"')
}

///|
/// The lower-case hex digit of `n`, from 0 to 15.
fn hex_digit(n : Int32) -> Byte {
  if n < 10 {
    (0x30 + n).to_byte()
  } else {
    (0x61 + n - 10).to_byte()
  }
}
