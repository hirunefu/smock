// Messages decoded and encoded from their descriptors. A message is decoded
// into smock's decoded form, the JSON text the engine, the Journal and
// templates see, and encoded from JSON as ProtoJSON reads it
// (https://protobuf.dev/programming-guides/json/). For now both serve
// types whose fields are singular string, bool and int32 fields, each
// named by its JSON name: the field's name in lowerCamelCase, as protoc
// computes it.

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
/// The JSON name of a field named `name`: its name in lowerCamelCase, each
/// `_` dropped and the letter after it in upper case, as protoc computes
/// the `json_name` it writes in a set.
fn json_name(name : String) -> String {
  guard name.contains_char('_') else { return name }
  let out = StringBuilder()
  let mut upper = false
  for c in name {
    if c == '_' {
      upper = true
    } else if upper {
      out.write_char(
        if c >= 'a' && c <= 'z' {
          (c.to_int() - 32).unsafe_to_char()
        } else {
          c
        },
      )
      upper = false
    } else {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// The type of `field` when it is one the codec serves: a singular string,
/// bool or int32 field.
fn served_type(field : FieldDescriptor) -> FieldType? {
  match (field.label, field.type_) {
    (Repeated, _) => None
    (_, Some(String | Bool | Int32) as type_) => type_
    _ => None
  }
}

///|
/// Why the codec does not serve `field` yet, for a field that `served_type`
/// does not serve: `done` is what it does not do, such as `decode`.
fn not_served(field : FieldDescriptor, done : String) -> String {
  let what = match (field.label, field.type_) {
    (Repeated, _) => "is repeated"
    (_, Some(type_)) if field.type_name == "" => "has the type \{type_}"
    (_, _) => {
      let name = field.type_name
      "has the type \{if name.has_prefix(".") { name[1:].to_owned() } else { name }}"
    }
  }
  "the field \{field.name} \{what}, which smock does not \{done} yet"
}

///|
/// The indices of `fields` in field-number order.
fn by_number(fields : ReadOnlyArray[FieldDescriptor]) -> FixedArray[Int32] {
  let order = FixedArray::make(fields.length(), 0)
  for i in 0..<fields.length() {
    // Insertion sort: a message has few fields.
    let mut j = i
    while j > 0 && fields[order[j - 1]].number > fields[i].number {
      order[j] = order[j - 1]
      j = j - 1
    }
    order[j] = i
  }
  order
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
    if served_type(field) is None {
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
    let number = reader.tag()
    let mut index = -1
    for i in 0..<fields.length() {
      if fields[i].number == number {
        index = i
        break
      }
    }
    guard index >= 0 else {
      reader.skip()
      continue
    }
    match (fields[index].type_, reader.wire_type()) {
      (Some(String), Len) => {
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
      (Some(Bool | Int32), Varint) => varints[index] = reader.varint()
      _ => reader.skip()
    }
  }
  let out = @buffer.Buffer(size_hint=input.length() + 16 * fields.length())
  out.write_byte(b'{')
  let order = by_number(fields)
  for n in 0..<order.length() {
    let i = order[n]
    if n > 0 {
      out.write_byte(b',')
    }
    write_json_string(out, @utf8.encode(json_name(fields[i].name)))
    out.write_byte(b':')
    match fields[i].type_ {
      Some(String) =>
        match strings[i] {
          Some(value) => write_json_string(out, value)
          None => out.write_bytes(b"\"\"")
        }
      Some(Bool) =>
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
    if served_type(field) is None {
      raise EncodeError(pointer="", message=not_served(field, "encode"))
    }
  }
  guard json is Object(members) else {
    raise EncodeError(
      pointer="",
      message="must be an object: the message is a \{message.name}",
    )
  }
  let values : FixedArray[Json?] = FixedArray::make(fields.length(), None)
  for key, value in members {
    let mut index = -1
    for i in 0..<fields.length() {
      if fields[i].name == key || json_name(fields[i].name) == key {
        index = i
        break
      }
    }
    let pointer = "/" +
      key.replace_all(old="~", new="~0").replace_all(old="/", new="~1")
    guard index >= 0 else {
      raise EncodeError(pointer~, message="is not a field of \{message.name}")
    }
    let field = fields[index]
    let fits = match (field.type_, value) {
      (Some(String), String(_)) | (Some(Bool), True | False) => true
      (Some(Int32), Number(n, ..)) =>
        n == n.floor() && n >= -2147483648.0 && n <= 2147483647.0
      _ => false
    }
    if !fits {
      let wanted = match field.type_ {
        Some(String) => "a string"
        Some(Bool) => "true or false"
        _ => "an integer from -2147483648 to 2147483647"
      }
      let type_ = match field.type_ {
        Some(String) => "a string"
        Some(Bool) => "a bool"
        _ => "an int32"
      }
      raise EncodeError(
        pointer~,
        message="must be \{wanted}: the field \{field.name} is \{type_}",
      )
    }
    values[index] = Some(value)
  }
  let writer = Writer()
  let order = by_number(fields)
  for n in 0..<order.length() {
    let i = order[n]
    let number = fields[i].number
    match values[i] {
      Some(String(text)) if text != "" => {
        writer.tag(number, Len)
        writer.length_delimited(@utf8.encode(text))
      }
      Some(True) => {
        writer.tag(number, Varint)
        writer.varint(1)
      }
      Some(Number(n, ..)) if n != 0.0 => {
        writer.tag(number, Varint)
        // A negative int32 is sign-extended to 64 bits, as protobuf
        // encodes it.
        writer.varint(n.to_int().to_int64().reinterpret_as_uint64())
      }
      _ => ()
    }
  }
  writer.to_bytes()
}
