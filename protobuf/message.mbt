// Messages decoded and encoded from their descriptors. A message is decoded
// into smock's decoded form, the JSON text the engine, the Journal and
// templates see, and encoded from JSON as ProtoJSON reads it
// (https://protobuf.dev/programming-guides/json/). For now the decoder
// serves singular fields of every scalar type, enums and nested messages,
// and the encoder types whose fields are singular string, bool and int32
// fields without presence.

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
  /// The octets of each record of a repeated field, in order: one or more
  /// values of a scalar or an enum, as a packed record holds them, so a
  /// value in a record of its own is a packed record of one value; one
  /// string, bytes or message; or one entry of a map.
  Elements(Array[BytesView])
}

///|
/// The oneofs of a message without oneofs.
let no_oneofs : FixedArray[Int32] = []

///|
/// The records of a repeated field that a message leaves out.
let no_elements : Array[BytesView] = []

///|
/// Decodes `input`, a message of the type `message` of `set` in protobuf's
/// binary encoding, into smock's decoded form: compact JSON text in UTF-8,
/// an object with one member per field, in field-number order, under the
/// field's JSON name. A message gives one text, whatever order its records
/// come in.
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
/// - A repeated field is an array of its values, in order, and a map an
///   object with a member per key, in key order: integer keys by value,
///   bool keys `"false"` then `"true"`, and string keys by their octets.
///   An integer key prints in decimal, as a string.
/// - A field without presence that the message leaves out is printed at
///   its default: `0`, `false`, `""`, an enum's value 0, `[]` or `{}`. A
///   proto3 `optional` field, a member of a oneof and a message field are
///   printed only when the message holds them.
///
/// It reads the message as protobuf's parsers read it: the last value of a
/// scalar or an enum field wins, the values of a message field are merged,
/// a member of a oneof replaces the one before it, repeated scalars are
/// read packed or not, and the records of a packed field are joined. A map
/// entry without a key or a value takes the default, and when a key
/// repeats, the last entry wins. Unknown fields, and fields sent with
/// another wire type than their type's, are skipped.
///
/// Raises `DecodeError` when the input is not protobuf, when a string is
/// not UTF-8, as a proto3 string must be, when messages nest deeper than
/// 100, a map entry counting as a message, and when a message it prints
/// has a field that it does not decode yet: a group, or a field of a
/// well-known type, a map's values included.
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
/// The values of the fields of the message of the type `message` whose
/// records are `records`, merged in order, by the index of each field in
/// `message.fields`; `None` for a field the message leaves out.
fn scan(
  message : MessageDescriptor,
  records : Array[BytesView],
) -> FixedArray[Value?] raise DecodeError {
  let fields = message.fields
  let values : FixedArray[Value?] = FixedArray::make(fields.length(), None)
  // The index of the member of each oneof that the message holds, by the
  // oneof's index, or -1.
  let chosen = if message.oneofs.length() == 0 {
    no_oneofs
  } else {
    FixedArray::make(message.oneofs.length(), -1)
  }
  for r in 0..<records.length() {
    let record = records[r]
    let reader = Reader(record)
    while !reader.at_end() {
      let index = message.field_index(reader.tag())
      guard index >= 0 else {
        reader.skip()
        continue
      }
      let field = fields[index]
      if field.label is Repeated {
        let at = reader.pos
        let element = match (field.type_, reader.wire_type()) {
          (String, Len) => {
            let value = reader.length_delimited()
            if !is_utf8(value) {
              raise reader.error(
                at,
                "the field \{field.name} holds octets that are not UTF-8",
              )
            }
            value
          }
          (Bytes | Message, Len) => reader.length_delimited()
          // A packed record of values.
          (
            Int32
            | Int64
            | UInt32
            | UInt64
            | SInt32
            | SInt64
            | Bool
            | Enum
            | Fixed64
            | SFixed64
            | Double
            | Fixed32
            | SFixed32
            | Float,
            Len,
          ) => reader.length_delimited()
          // A value in a record of its own, which is a packed record of
          // one value.
          (
            Int32
            | Int64
            | UInt32
            | UInt64
            | SInt32
            | SInt64
            | Bool
            | Enum,
            Varint,
          ) => {
            ignore(reader.varint())
            record[at:reader.pos]
          }
          (Fixed64 | SFixed64 | Double, I64) => {
            ignore(reader.fixed64())
            record[at:reader.pos]
          }
          (Fixed32 | SFixed32 | Float, I32) => {
            ignore(reader.fixed32())
            record[at:reader.pos]
          }
          _ => {
            reader.skip()
            continue
          }
        }
        match values[index] {
          Some(Elements(list)) => list.push(element)
          _ => values[index] = Some(Elements([element]))
        }
        continue
      }
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
        _ => {
          reader.skip()
          continue
        }
      }
      // A member of a oneof replaces the member the message held before.
      if field.oneof_index is Some(oneof) && chosen[oneof] != index {
        if chosen[oneof] >= 0 {
          values[chosen[oneof]] = None
        }
        chosen[oneof] = index
      }
    }
  }
  values
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
  let values = scan(message, records)
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
    if value is None &&
      !(field.label is Repeated) &&
      (field.oneof_index is Some(_) || field.type_ is Message) {
      continue
    }
    if !first {
      out.write_byte(b',')
    }
    first = false
    write_json_name(out, field.json_name)
    out.write_byte(b':')
    if field.label is Repeated {
      let elements = match value {
        Some(Elements(list)) => list
        _ => no_elements
      }
      match self.message_of(field) {
        Some(entry) if entry.map_entry && is_map_entry(entry) =>
          self.print_map(out, entry, elements, depth)
        _ => self.print_list(out, field, elements, depth)
      }
    } else {
      self.print_value(out, field, value, depth)
    }
  }
  out.write_byte(b'}')
}

///|
/// Prints to `out` the value `value` of `field`, a singular field of a
/// message `depth` messages deep, or its default when it is `None`.
fn DescriptorSet::print_value(
  self : DescriptorSet,
  out : @buffer.Buffer,
  field : FieldDescriptor,
  value : Value?,
  depth : Int32,
) -> Unit raise DecodeError {
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
    None | Some(Elements(_)) =>
      match field.type_ {
        String | Bytes => out.write_bytes(b"\"\"")
        // Never: a message field the message leaves out is not printed,
        // and a map value is given.
        Message | Group => out.write_bytes(b"{}")
        _ => self.print_number(out, field, 0)
      }
  }
}

///|
/// Prints to `out` the values of `field`, a repeated field other than a
/// map of a message `depth` messages deep, whose records are `elements`,
/// as an array.
fn DescriptorSet::print_list(
  self : DescriptorSet,
  out : @buffer.Buffer,
  field : FieldDescriptor,
  elements : Array[BytesView],
  depth : Int32,
) -> Unit raise DecodeError {
  out.write_byte(b'[')
  let mut first = true
  for e in 0..<elements.length() {
    let element = elements[e]
    match field.type_ {
      String | Bytes | Message | Group => {
        if !first {
          out.write_byte(b',')
        }
        first = false
        match self.message_of(field) {
          Some(type_) => {
            if depth >= max_depth {
              raise DecodeError(
                position=element.start_offset(),
                message="messages nest deeper than \{max_depth}",
              )
            }
            self.print_message(out, type_, [element], depth + 1)
          }
          None if field.type_ is Bytes => write_base64(out, element)
          None => write_json_string(out, element)
        }
      }
      _ => {
        let reader = Reader(element)
        while !reader.at_end() {
          let bits = match field.type_ {
            Fixed64 | SFixed64 | Double => reader.fixed64()
            Fixed32 | SFixed32 | Float => reader.fixed32().to_uint64()
            _ => reader.varint()
          }
          if !first {
            out.write_byte(b',')
          }
          first = false
          self.print_number(out, field, bits)
        }
      }
    }
  }
  out.write_byte(b']')
}

///|
/// Whether `entry`, a message with the option `map_entry`, is a map entry
/// that ProtoJSON prints as an object: its key, field 1, is an integer, a
/// bool or a string, and its value is field 2. protoc writes no other.
fn is_map_entry(entry : MessageDescriptor) -> Bool {
  let key = entry.field_index(1)
  key >= 0 &&
  entry.field_index(2) >= 0 &&
  entry.fields[key].label is (Optional | Required) &&
  entry.fields[key].type_
  is (Int32
  | Int64
  | UInt32
  | UInt64
  | SInt32
  | SInt64
  | Fixed32
  | Fixed64
  | SFixed32
  | SFixed64
  | Bool
  | String)
}

///|
/// Prints to `out` the map whose entries, of the type `entry`, are
/// `entries`, a field of a message `depth` messages deep, as an object
/// with a member per key, in key order. An entry without a key or a value
/// takes the default, and of the entries with one key, the last wins.
fn DescriptorSet::print_map(
  self : DescriptorSet,
  out : @buffer.Buffer,
  entry : MessageDescriptor,
  entries : Array[BytesView],
  depth : Int32,
) -> Unit raise DecodeError {
  let count = entries.length()
  if count == 0 {
    out.write_bytes(b"{}")
    return
  }
  // An entry is a message nested in the map's.
  if depth >= max_depth {
    raise DecodeError(
      position=entries[0].start_offset(),
      message="messages nest deeper than \{max_depth}",
    )
  }
  let key_index = entry.field_index(1)
  let value_index = entry.field_index(2)
  let key_field = entry.fields[key_index]
  let value_field = entry.fields[value_index]
  let textual = key_field.type_ is String
  // Each entry's key: its text for a string key, or else a number whose
  // unsigned order is the key's order, the default's until the entry
  // gives one.
  let keys : FixedArray[UInt64] = FixedArray::make(
    count,
    key_order(key_field.type_, 0),
  )
  let texts : FixedArray[BytesView] = FixedArray::make(
    if textual {
      count
    } else {
      0
    },
    b""[:],
  )
  for i in 0..<count {
    let reader = Reader(entries[i])
    while !reader.at_end() {
      let number = reader.tag()
      let at = reader.pos
      match (number, key_field.type_, reader.wire_type()) {
        (1, String, Len) => {
          let text = reader.length_delimited()
          if !is_utf8(text) {
            raise reader.error(
              at,
              "the field \{key_field.name} holds octets that are not UTF-8",
            )
          }
          texts[i] = text
        }
        (1, Int32 | Int64 | UInt32 | UInt64 | SInt32 | SInt64 | Bool, Varint)
        | (1, Fixed64 | SFixed64, I64)
        | (1, Fixed32 | SFixed32, I32) =>
          keys[i] = key_order(
            key_field.type_,
            match reader.wire_type() {
              I64 => reader.fixed64()
              I32 => reader.fixed32().to_uint64()
              _ => reader.varint()
            },
          )
        (2, String, Len) if value_field.type_ is String => {
          // Checked here, since only the last entry of a key is printed.
          let text = reader.length_delimited()
          if !is_utf8(text) {
            raise reader.error(
              at,
              "the field \{value_field.name} holds octets that are not UTF-8",
            )
          }
        }
        _ => reader.skip()
      }
    }
  }
  let order = sorted_entries(keys, texts)
  out.write_byte(b'{')
  let mut first = true
  for n in 0..<count {
    let i = order[n]
    // Of the entries with one key, the last wins.
    if n + 1 < count && same_key(keys, texts, i, order[n + 1]) {
      continue
    }
    if !first {
      out.write_byte(b',')
    }
    first = false
    let values = scan(entry, [entries[i]])
    match values[key_index] {
      Some(Octets(text)) => write_json_string(out, text)
      Some(Number(bits)) => {
        out.write_byte(b'"')
        self.print_number(out, key_field, bits)
        out.write_byte(b'"')
      }
      _ =>
        if textual {
          out.write_bytes(b"\"\"")
        } else {
          out.write_byte(b'"')
          self.print_number(out, key_field, 0)
          out.write_byte(b'"')
        }
    }
    out.write_byte(b':')
    let value = match values[value_index] {
      // A message value that the entry leaves out is an empty message.
      None if value_field.type_ is (Message | Group) =>
        Some(Messages([entries[i][0:0]]))
      value => value
    }
    self.print_value(out, value_field, value, depth + 1)
  }
  out.write_byte(b'}')
}

///|
/// A number whose unsigned order is the order of the map key of the type
/// `type_`, an integer or a bool, whose bits are `bits`.
fn key_order(type_ : FieldType, bits : UInt64) -> UInt64 {
  // A signed key with its sign bit flipped orders as an unsigned number.
  let sign = 0x8000_0000_0000_0000UL
  match type_ {
    Int32 | SFixed32 =>
      bits.to_uint().reinterpret_as_int().to_int64().reinterpret_as_uint64() ^
      sign
    SInt32 => {
      let n = bits.to_uint()
      let value = (n >> 1).reinterpret_as_int() ^ -(n & 1).reinterpret_as_int()
      value.to_int64().reinterpret_as_uint64() ^ sign
    }
    Int64 | SFixed64 => bits ^ sign
    SInt64 =>
      ((bits >> 1).reinterpret_as_int64() ^ -(bits & 1).reinterpret_as_int64()).reinterpret_as_uint64() ^
      sign
    UInt32 | Fixed32 => bits & 0xFFFF_FFFFUL
    Bool => if bits != 0 { 1 } else { 0 }
    _ => bits
  }
}

///|
/// How the keys of the entries `a` and `b` of a map compare: by `texts`
/// when it holds the keys, or else by `keys`. Negative when `a`'s comes
/// first, 0 when they are one key.
fn compare_keys(
  keys : FixedArray[UInt64],
  texts : FixedArray[BytesView],
  a : Int32,
  b : Int32,
) -> Int32 {
  if texts.length() == 0 {
    return if keys[a] < keys[b] {
      -1
    } else if keys[a] > keys[b] {
      1
    } else {
      0
    }
  }
  let x = texts[a]
  let y = texts[b]
  let length = if x.length() < y.length() { x.length() } else { y.length() }
  for i in 0..<length {
    if x[i] != y[i] {
      return if x[i] < y[i] { -1 } else { 1 }
    }
  }
  x.length() - y.length()
}

///|
/// Whether the entries `a` and `b` of a map have one key.
fn same_key(
  keys : FixedArray[UInt64],
  texts : FixedArray[BytesView],
  a : Int32,
  b : Int32,
) -> Bool {
  compare_keys(keys, texts, a, b) == 0
}

///|
/// The indexes of a map's entries, whose keys are `keys` or `texts`, as
/// `compare_keys` says, in key order, entries with one key in their order:
/// a merge sort, a run at a time, with plain loops.
fn sorted_entries(
  keys : FixedArray[UInt64],
  texts : FixedArray[BytesView],
) -> FixedArray[Int32] {
  let count = keys.length()
  let mut from : FixedArray[Int32] = FixedArray::make(count, 0)
  for i in 0..<count {
    from[i] = i
  }
  let mut into : FixedArray[Int32] = FixedArray::make(count, 0)
  let mut width = 1
  while width < count {
    let mut low = 0
    while low < count {
      let middle = if low + width < count { low + width } else { count }
      let high = if middle + width < count { middle + width } else { count }
      let mut left = low
      let mut right = middle
      for k in low..<high {
        // Ties take the left run's entry first, so the order is stable.
        if left < middle &&
          (
            right >= high ||
            compare_keys(keys, texts, from[left], from[right]) <= 0
          ) {
          into[k] = from[left]
          left = left + 1
        } else {
          into[k] = from[right]
          right = right + 1
        }
      }
      low = high
    }
    let swap = from
    from = into
    into = swap
    width = width * 2
  }
  from
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
/// this set, or `None` when it does: it is a group, or of a well-known
/// type, which ProtoJSON prints in a form of its own, or a map whose
/// values are.
fn DescriptorSet::not_decoded(
  self : DescriptorSet,
  field : FieldDescriptor,
) -> String? {
  if field.type_ is Group {
    return Some("is a group")
  }
  if field.label is Repeated &&
    self.message_of(field) is Some(entry) &&
    entry.map_entry &&
    is_map_entry(entry) {
    return match self.well_known_of(entry.fields[entry.field_index(2)]) {
      Some(name) =>
        Some("is a map whose values have the well-known type \{name}")
      None => None
    }
  }
  match self.well_known_of(field) {
    Some(name) => Some("has the well-known type \{name}")
    None => None
  }
}

///|
/// The full name of the type of `field`, a field of a message of this set,
/// when it is a well-known type, as `is_well_known` says.
fn DescriptorSet::well_known_of(
  self : DescriptorSet,
  field : FieldDescriptor,
) -> String? {
  let name = match (self.message_of(field), self.enum_of(field)) {
    (Some(type_), _) => type_.full_name
    (_, Some(type_)) => type_.full_name
    _ => return None
  }
  if is_well_known(name) {
    Some(name)
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
