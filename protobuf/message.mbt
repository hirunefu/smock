// Messages decoded and encoded from their descriptors. A message is decoded
// into smock's decoded form, the JSON text the engine, the Journal and
// templates see, and encoded from JSON as ProtoJSON reads it
// (https://protobuf.dev/programming-guides/json/). For now both serve
// types whose fields are singular string, bool and int32 fields without
// presence.

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
/// Whether the codec serves `field`: a singular string, bool or int32
/// field, outside any oneof, so without presence, as a proto3 `optional`
/// field is in its own oneof.
fn is_served(field : FieldDescriptor) -> Bool {
  field.label is (Optional | Required) &&
  field.type_ is (String | Bool | Int32) &&
  field.oneof_index is None
}

///|
/// Why the codec does not serve `field` yet, for a field that `is_served`
/// does not serve: `done` is what it does not do, such as `decode`.
fn not_served(field : FieldDescriptor, done : String) -> String {
  let what = if field.label is Repeated {
    "is repeated"
  } else if field.type_name != "" {
    let name = field.type_name
    "has the type \{if name.has_prefix(".") { name[1:].to_owned() } else { name }}"
  } else if field.type_ is (String | Bool | Int32) {
    "is in a oneof or optional"
  } else {
    "has the type \{field.type_}"
  }
  "the field \{field.name} \{what}, which smock does not \{done} yet"
}

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
/// Decodes `input`, a message of the type `message` in protobuf's binary
/// encoding, into smock's decoded form: compact JSON text in UTF-8, an
/// object with one member per field, in field-number order, under the
/// field's JSON name. A field the message leaves out is printed at its
/// default, `""`, `false` or `0`. A string is printed as JSON escapes it,
/// an int32 as a decimal number and a bool as `true` or `false`.
///
/// It reads the message as protobuf's parsers read it: the last value of a
/// field wins, and unknown fields, and fields sent with another wire type
/// than their type's, are skipped. Raises `DecodeError` when the input is
/// not protobuf, when a string is not UTF-8, as a proto3 string must be,
/// and when the type has a field that the codec does not decode yet: one
/// that is not a singular string, bool or int32 field.
pub fn decode_json(
  message : MessageDescriptor,
  input : BytesView,
) -> Bytes raise DecodeError {
  let fields = message.fields
  for field in fields {
    if !is_served(field) {
      raise DecodeError(
        position=input.start_offset(),
        message=not_served(field, "decode"),
      )
    }
  }
  // The last value of each field: a string's octets, or a varint.
  let strings : FixedArray[BytesView?] = FixedArray::make(fields.length(), None)
  let varints = FixedArray::make(fields.length(), 0UL)
  let reader = Reader(input)
  while !reader.at_end() {
    let index = message.field_index(reader.tag())
    guard index >= 0 else {
      reader.skip()
      continue
    }
    match (fields[index].type_, reader.wire_type()) {
      (String, Len) => {
        let at = reader.pos
        let value = reader.length_delimited()
        if !is_utf8(value) {
          raise reader.error(
            at,
            "the field \{fields[index].name} holds octets that are not UTF-8",
          )
        }
        strings[index] = Some(value)
      }
      (Bool | Int32, Varint) => varints[index] = reader.varint()
      _ => reader.skip()
    }
  }
  let out = @buffer.Buffer(size_hint=input.length() + 16 * fields.length())
  out.write_byte(b'{')
  let order = message.by_number
  for n in 0..<order.length() {
    let i = order[n]
    if n > 0 {
      out.write_byte(b',')
    }
    write_json_string(out, @utf8.encode(fields[i].json_name))
    out.write_byte(b':')
    match fields[i].type_ {
      String =>
        match strings[i] {
          Some(value) => write_json_string(out, value)
          None => out.write_bytes(b"\"\"")
        }
      Bool =>
        out.write_bytes(if varints[i] != 0UL { b"true" } else { b"false" })
      _ => {
        let value = (varints[i] & 0xFFFF_FFFFUL).to_uint().reinterpret_as_int()
        out.write_string_utf8(value.to_string())
      }
    }
  }
  out.write_byte(b'}')
  out.to_bytes()
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

///|
/// Encodes `json`, a message of the type `message` as ProtoJSON writes it,
/// in protobuf's binary encoding, as protoc encodes it: its fields in
/// field-number order, each left out at its default, as a proto3 field
/// without presence is. A member's key is the field's proto name or its
/// JSON name. A string field takes a JSON string, a bool field `true` or
/// `false`, and an int32 field a number with an integral value from
/// -2147483648 to 2147483647.
///
/// Raises `EncodeError` for JSON that is not such a message: not an
/// object, a key that names no field, or a value of the wrong type or out
/// of its type's range; and when the type has a field that the codec does
/// not encode yet.
pub fn encode_json(
  message : MessageDescriptor,
  json : Json,
) -> Bytes raise EncodeError {
  let fields = message.fields
  for field in fields {
    if !is_served(field) {
      raise EncodeError(pointer="", message=not_served(field, "encode"))
    }
  }
  guard json is Object(members) else {
    raise EncodeError(
      pointer="",
      message="must be an object: the message is a \{message.full_name}",
    )
  }
  for key, value in members {
    let pointer = "/" +
      key.replace_all(old="~", new="~0").replace_all(old="/", new="~1")
    let field = match message.find_field_by_json_name(key) {
      Some(field) => field
      None =>
        match message.find_field_by_name(key) {
          Some(field) => field
          None =>
            raise EncodeError(
              pointer~,
              message="is not a field of \{message.full_name}",
            )
        }
    }
    let fits = match (field.type_, value) {
      (String, String(_)) | (Bool, True | False) => true
      (Int32, Number(n, ..)) =>
        n == n.floor() && n >= -2147483648.0 && n <= 2147483647.0
      _ => false
    }
    if !fits {
      let (wanted, type_) = match field.type_ {
        String => ("a string", "a string")
        Bool => ("true or false", "a bool")
        _ => ("an integer from -2147483648 to 2147483647", "an int32")
      }
      raise EncodeError(
        pointer~,
        message="must be \{wanted}: the field \{field.name} is \{type_}",
      )
    }
  }
  let writer = Writer()
  let order = message.by_number
  for n in 0..<order.length() {
    let field = fields[order[n]]
    let value = match members.get(field.json_name) {
      Some(value) => value
      None =>
        match members.get(field.name) {
          Some(value) => value
          None => continue
        }
    }
    match value {
      String(text) if text != "" => {
        writer.tag(field.number, Len)
        writer.length_delimited(@utf8.encode(text))
      }
      True => {
        writer.tag(field.number, Varint)
        writer.varint(1)
      }
      Number(n, ..) if n != 0.0 => {
        writer.tag(field.number, Varint)
        // A negative int32 is sign-extended to 64 bits, as protobuf
        // encodes it.
        writer.varint(n.to_int().to_int64().reinterpret_as_uint64())
      }
      _ => ()
    }
  }
  writer.to_bytes()
}
