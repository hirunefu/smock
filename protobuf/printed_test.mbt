// JSON values checked against a field's type as `decode_json` prints it,
// through the public interface: a value in the printed form is kept, or
// rewritten when it means the same value, as an enum number or a float
// does; a value that ProtoJSON reads but never prints names the printed
// form; any other value says what the field takes. The fields are those of
// fixtures/protobuf/replies/replies.proto and fixtures/protobuf/scalars/
// scalars.proto.

///|
/// The field `name` of the message `message`, a type of the set the script
/// wrote in `hex`, and the set.
fn field_of(
  hex : String,
  message : String,
  name : String,
) -> (@protobuf.DescriptorSet, @protobuf.FieldDescriptor) {
  let set = hex_set(hex)
  guard set.find_message(message) is Some(type_) &&
    type_.find_field_by_name(name) is Some(field) else {
    abort("no field \{name} in \{message}")
  }
  (set, field)
}

///|
/// What `printed_value` makes of `text`, JSON text, as a value of the field
/// `name` of `message` in the set the script wrote in `hex`: the value it
/// gives, as JSON text, or the error.
fn printed_form(
  hex : String,
  message : String,
  name : String,
  text : String,
) -> String {
  let (set, field) = field_of(hex, message, name)
  let json = @json.parse(text) catch { err => abort("not JSON: \{err}") }
  set.printed_value(field, json).stringify() catch {
    NotOfType(wanted~) => "must be \{wanted}"
    NotPrinted(printed~) => "must be written \{printed}"
  }
}

///|
/// What `printed` makes of each of `texts`, as a value of the field `name`
/// of replies.Everything, one per line: the text, then what it gives.
fn everything(name : String, texts : Array[String]) -> String {
  texts
  .map(text => {
    "\{text} -> \{printed_form(replies_set, "replies.Everything", name, text)}"
  })
  .join("\n")
}

///|
test "an integer is a number of its type's range, kept as smock prints it; one written as a string is read by ProtoJSON but never printed, so the number is named" {
  inspect(
    everything("an_int64", [
      "42", "\"42\"", "9223372036854775807", "-9223372036854775808", "9223372036854775808",
      "\"-9223372036854775808\"", "\"1e3\"", "1e3", "100000000000000000", "1e17",
      "42.0", "1.5", "\"1.5\"", "true", "null", "[42]", "{}",
    ]),
    content=(
      #|42 -> 42
      #|"42" -> must be written 42
      #|9223372036854775807 -> 9223372036854775807
      #|-9223372036854775808 -> -9223372036854775808
      #|9223372036854775808 -> must be an integer from -9223372036854775808 to 9223372036854775807
      #|"-9223372036854775808" -> must be written -9223372036854775808
      #|"1e3" -> must be written 1000
      #|1e3 -> 1000
      #|100000000000000000 -> 100000000000000000
      #|1e17 -> 100000000000000000
      #|42.0 -> 42
      #|1.5 -> must be an integer from -9223372036854775808 to 9223372036854775807
      #|"1.5" -> must be an integer from -9223372036854775808 to 9223372036854775807
      #|true -> must be an integer from -9223372036854775808 to 9223372036854775807
      #|null -> must be an integer from -9223372036854775808 to 9223372036854775807
      #|[42] -> must be an integer from -9223372036854775808 to 9223372036854775807
      #|{} -> must be an integer from -9223372036854775808 to 9223372036854775807
    ),
  )
  inspect(
    everything("an_int32", ["2147483647", "-2147483648", "2147483648", "\"7\""]),
    content=(
      #|2147483647 -> 2147483647
      #|-2147483648 -> -2147483648
      #|2147483648 -> must be an integer from -2147483648 to 2147483647
      #|"7" -> must be written 7
    ),
  )
  inspect(
    everything("a_uint64", [
      "18446744073709551615", "-1", "\"18446744073709551615\"",
    ]),
    content=(
      #|18446744073709551615 -> 18446744073709551615
      #|-1 -> must be an integer from 0 to 18446744073709551615
      #|"18446744073709551615" -> must be written 18446744073709551615
    ),
  )
  inspect(
    everything("a_sint32", ["-5", "\"-5\""]) +
    "\n" +
    everything("a_fixed32", ["4294967295", "4294967296"]) +
    "\n" +
    everything("an_sfixed64", ["-1"]),
    content=(
      #|-5 -> -5
      #|"-5" -> must be written -5
      #|4294967295 -> 4294967295
      #|4294967296 -> must be an integer from 0 to 4294967295
      #|-1 -> -1
    ),
  )
}

///|
test "a float is rounded to the nearest 32-bit float and kept as smock prints it; one outside the float range, or written as a string, is not" {
  inspect(
    everything("a_float", [
      "0.1", "9.99", "16777217", "3.4028235e38", "3.5e38", "-3.5e38", "1e-50", "0",
      "\"NaN\"", "\"Infinity\"", "\"-Infinity\"", "\"0.1\"", "\"16777217\"", "\"3.5e38\"",
      "\"nan\"", "1e400", "true",
    ]),
    content=(
      #|0.1 -> 0.1
      #|9.99 -> 9.99
      #|16777217 -> 16777216
      #|3.4028235e38 -> 3.4028235e+38
      #|3.5e38 -> must be a number within the range of a float, or "NaN", "Infinity" or "-Infinity"
      #|-3.5e38 -> must be a number within the range of a float, or "NaN", "Infinity" or "-Infinity"
      #|1e-50 -> 0
      #|0 -> 0
      #|"NaN" -> "NaN"
      #|"Infinity" -> "Infinity"
      #|"-Infinity" -> "-Infinity"
      #|"0.1" -> must be written 0.1
      #|"16777217" -> must be written 16777216
      #|"3.5e38" -> must be a number within the range of a float, or "NaN", "Infinity" or "-Infinity"
      #|"nan" -> must be a number within the range of a float, or "NaN", "Infinity" or "-Infinity"
      #|1e400 -> must be a number within the range of a float, or "NaN", "Infinity" or "-Infinity"
      #|true -> must be a number within the range of a float, or "NaN", "Infinity" or "-Infinity"
    ),
  )
  inspect(
    everything("a_double", [
      "0.1", "1e21", "12345678901234567890", "\"NaN\"", "\"1.5\"", "1e400", "\"x\"",
    ]),
    content=(
      #|0.1 -> 0.1
      #|1e21 -> 1e+21
      #|12345678901234567890 -> 12345678901234567000
      #|"NaN" -> "NaN"
      #|"1.5" -> must be written 1.5
      #|1e400 -> must be a number, or "NaN", "Infinity" or "-Infinity"
      #|"x" -> must be a number, or "NaN", "Infinity" or "-Infinity"
    ),
  )
}

///|
test "an enum is the name of a value, which becomes the first name of its number, as does a number; an unknown number of an open enum stays a number" {
  let status = [
    "\"ACTIVE\"", "\"ENABLED\"", "2", "1", "0", "7", "-1", "\"BOGUS\"", "\"2\"",
    "2147483648", "1.5", "true",
  ]
  inspect(
    status
    .map(text => {
      "\{text} -> \{printed_form(scalars_set, "scalars.Every", "a_status", text)}"
    })
    .join("\n"),
    content=(
      #|"ACTIVE" -> "ACTIVE"
      #|"ENABLED" -> "ACTIVE"
      #|2 -> "ACTIVE"
      #|1 -> "PENDING"
      #|0 -> "STATUS_UNSPECIFIED"
      #|7 -> 7
      #|-1 -> -1
      #|"BOGUS" -> must be the name of a value of scalars.Status, or an integer from -2147483648 to 2147483647
      #|"2" -> must be the name of a value of scalars.Status, or an integer from -2147483648 to 2147483647
      #|2147483648 -> must be the name of a value of scalars.Status, or an integer from -2147483648 to 2147483647
      #|1.5 -> must be the name of a value of scalars.Status, or an integer from -2147483648 to 2147483647
      #|true -> must be the name of a value of scalars.Status, or an integer from -2147483648 to 2147483647
    ),
  )
}

///|
test "bools, strings, bytes in standard base64 with padding, and messages; unpadded or URL-safe base64 names the printed form" {
  inspect(
    everything("a_bool", ["true", "false", "\"true\"", "1"]) +
    "\n" +
    everything("a_string", ["\"Kyōto\"", "\"\"", "1", "null"]) +
    "\n" +
    everything("some_bytes", [
      "\"AAH7/w==\"", "\"\"", "\"AAH7/w\"", "\"AAH7_w==\"", "\"AAH7_w\"", "\"QR==\"",
      "\"YQ\"", "\"!!\"", "\"Q\"", "1",
    ]) +
    "\n" +
    everything("nested", ["{}", "{\"word\":1}", "1", "\"x\"", "[]"]),
    content=(
      #|true -> true
      #|false -> false
      #|"true" -> must be true or false
      #|1 -> must be true or false
      #|"Kyōto" -> "Kyōto"
      #|"" -> ""
      #|1 -> must be a string of Unicode text
      #|null -> must be a string of Unicode text
      #|"AAH7/w==" -> "AAH7/w=="
      #|"" -> ""
      #|"AAH7/w" -> must be written "AAH7/w=="
      #|"AAH7_w==" -> must be written "AAH7/w=="
      #|"AAH7_w" -> must be written "AAH7/w=="
      #|"QR==" -> must be written "QQ=="
      #|"YQ" -> must be written "YQ=="
      #|"!!" -> must be a string of standard base64, with padding
      #|"Q" -> must be a string of standard base64, with padding
      #|1 -> must be a string of standard base64, with padding
      #|{} -> {}
      #|{"word":1} -> {"word":1}
      #|1 -> must be an object
      #|"x" -> must be an object
      #|[] -> must be an object
    ),
  )
}

///|
/// What `check_printed_key` makes of each of `keys`, as keys of the map
/// field `name` of replies.Everything, one per line: the key, then `ok` or
/// the error.
fn keys_of(name : String, keys : Array[String]) -> String {
  let (set, field) = field_of(replies_set, "replies.Everything", name)
  guard set.message_of(field) is Some(entry) &&
    entry.find_field_by_number(1) is Some(key_field) else {
    abort("\{name} is not a map")
  }
  keys
  .map(key => {
    let checked = try key_field.check_printed_key(key) catch {
      NotOfType(wanted~) => "must be \{wanted}"
      NotPrinted(printed~) => "must be written \{printed}"
    } noraise {
      _ => "ok"
    }
    "\{key.escape()} -> \{checked}"
  })
  .join("\n")
}

///|
test "a map key is in the form smock prints it: integers in decimal without leading zeros, bools as true and false, and strings as they are" {
  inspect(
    keys_of("counts", ["math_score", "007", ""]) +
    "\n" +
    keys_of("names", [
      "7", "-7", "0", "007", "-0", "+7", "1e1", "7.0", " 7", "x", "2147483648", "",
    ]) +
    "\n" +
    keys_of("by_flag", ["true", "false", "True", "1"]) +
    "\n" +
    keys_of("by_id", ["-9223372036854775808", "9223372036854775808"]) +
    "\n" +
    keys_of("blobs", ["18446744073709551615", "-1"]) +
    "\n" +
    keys_of("by_sint", ["-1", "01"]) +
    "\n" +
    keys_of("by_fixed", ["1000", "1e3"]),
    content=(
      #|"math_score" -> ok
      #|"007" -> ok
      #|"" -> ok
      #|"7" -> ok
      #|"-7" -> ok
      #|"0" -> ok
      #|"007" -> must be written "7"
      #|"-0" -> must be written "0"
      #|"+7" -> must be an integer from -2147483648 to 2147483647
      #|"1e1" -> must be written "10"
      #|"7.0" -> must be written "7"
      #|" 7" -> must be an integer from -2147483648 to 2147483647
      #|"x" -> must be an integer from -2147483648 to 2147483647
      #|"2147483648" -> must be an integer from -2147483648 to 2147483647
      #|"" -> must be an integer from -2147483648 to 2147483647
      #|"true" -> ok
      #|"false" -> ok
      #|"True" -> must be "true" or "false"
      #|"1" -> must be "true" or "false"
      #|"-9223372036854775808" -> ok
      #|"9223372036854775808" -> must be an integer from -9223372036854775808 to 9223372036854775807
      #|"18446744073709551615" -> ok
      #|"-1" -> must be an integer from 0 to 18446744073709551615
      #|"-1" -> ok
      #|"01" -> must be written "1"
      #|"1000" -> ok
      #|"1e3" -> must be written "1000"
    ),
  )
}
