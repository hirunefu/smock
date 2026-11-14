// JSON values checked against a field's type as `decode_json` prints it:
// smock's decoded form. A value in that form is kept, and a value that
// means the same, such as an enum number, a float that rounding changes or
// an integer written with an exponent, becomes the printed one. A value
// that ProtoJSON reads but `decode_json` never prints, such as a 64-bit
// integer written as a string or bytes in URL-safe base64, is refused with
// the printed form, and any other value with what the field takes. smock
// checks its gRPC Stubs' conditions with these when the files load.

///|
/// Why a JSON value is not a value of a field as `decode_json` prints it.
#derive(Eq, Debug)
pub(all) suberror PrintedError {
  /// It is not a value of the field's type, or it is one that
  /// `decode_json` cannot print: `wanted` says what the field takes, such
  /// as `an integer from 0 to 4294967295`.
  NotOfType(wanted~ : String)
  /// It is a value of the field's type, which ProtoJSON reads, but
  /// `decode_json` prints that value otherwise: as `printed`, JSON text,
  /// such as `42` for `"42"`.
  NotPrinted(printed~ : String)
}

///|
/// `json`, one value of `field`, a field of a message of this set, as
/// `decode_json` prints it: the value of a singular field, or one element
/// of a repeated one. A value in that form is returned as it is, and one
/// that means the same is returned in that form:
///
/// - an integer is a number in its type's range, which may be written with
///   an exponent or a fraction of zeros, such as `1e3` or `42.0`; it is
///   returned in decimal, exact at any size;
/// - a `float` is a number within the range of a float, rounded to the
///   nearest one and returned in the shortest form that reads back as it,
///   as `decode_json` prints it, so `16777217` gives `16777216`; a
///   `double` is a number, returned as `decode_json` prints it; either may
///   be `"NaN"`, `"Infinity"` or `"-Infinity"`;
/// - a `bool` is `true` or `false`, and a `string` a string;
/// - `bytes` is a string of standard base64 with its padding;
/// - an enum is the name of one of its values, or a number from the int32
///   range, and is returned as the first name of its number, or as the
///   number when no value has it, as an open enum allows;
/// - a message is an object, returned as it is: its members are not
///   checked here.
///
/// Raises `NotPrinted` with the printed form for a value that ProtoJSON
/// reads but `decode_json` prints otherwise: an integer, a float or a
/// double written as a string, and bytes in URL-safe base64, without its
/// padding or with bits after its last octet. Raises `NotOfType` for any
/// other value, a float outside the float range included.
pub fn DescriptorSet::printed_value(
  self : DescriptorSet,
  field : FieldDescriptor,
  json : Json,
) -> Json raise PrintedError {
  let unfit = NotOfType(wanted=self.printed_wanted(field))
  match field.type_ {
    Bool => if json is (True | False) { json } else { raise unfit }
    String => if json is String(_) { json } else { raise unfit }
    Bytes => {
      guard json is String(text) else { raise unfit }
      let octets = base64_octets(text) catch { _ => raise unfit }
      // The printed form, as JSON text: the string in its quotes.
      let out = @buffer.Buffer(size_hint=text.length() + 4)
      write_base64(out, octets)
      let printed = @utf8.decode(out.to_bytes()) catch { _ => raise unfit }
      if printed.length() == text.length() + 2 &&
        printed[1:printed.length() - 1] == text {
        json
      } else {
        raise NotPrinted(printed~)
      }
    }
    Message | Group => if json is Object(_) { json } else { raise unfit }
    Float | Double => {
      if json is String("NaN" | "Infinity" | "-Infinity") {
        return json
      }
      let n = floating(json) catch { _ => raise unfit }
      let printed = if field.type_ is Float {
        let rounded = Float::from_double(n)
        if rounded.is_inf() {
          // Outside the range of a float.
          raise unfit
        }
        rounded.to_string()
      } else {
        n.to_string()
      }
      if json is String(_) {
        raise NotPrinted(printed~)
      }
      number_of(printed)
    }
    Enum => {
      guard self.enum_of(field) is Some(type_) else { raise unfit }
      let number = match json {
        String(name) =>
          match type_.find_value_by_name(name) {
            Some(value) => value.number
            None => raise unfit
          }
        Number(_) =>
          integer_bits(json, signed=true, wide=false)
          .reinterpret_as_int64()
          .to_int() catch {
            _ => raise unfit
          }
        _ => raise unfit
      }
      match type_.find_value_by_number(number) {
        Some(value) => Json::string(value.name)
        None => number_of(number.to_string())
      }
    }
    type_ => {
      guard json is (Number(_) | String(_)) else { raise unfit }
      let signed = type_
        is (Int32 | Int64 | SInt32 | SInt64 | SFixed32 | SFixed64)
      let wide = type_ is (Int64 | UInt64 | SInt64 | Fixed64 | SFixed64)
      let bits = integer_bits(json, signed~, wide~) catch { _ => raise unfit }
      let printed = decimal(bits, signed~)
      if json is String(_) {
        raise NotPrinted(printed~)
      }
      number_of(printed)
    }
  }
}

///|
/// Checks that `key`, a key of a map whose key field is this field, is in
/// the form `decode_json` prints it: an integer in decimal, with no `+`,
/// no leading zeros and no `-0`; `true` or `false`; or any string, for a
/// map whose keys are strings, which are data.
///
/// Raises `NotPrinted` with the printed key, as JSON text, for a key that
/// ProtoJSON reads as the same integer, such as `"007"` or `"1e3"`, and
/// `NotOfType` for any other key that is not one of the field's type.
pub fn FieldDescriptor::check_printed_key(
  self : FieldDescriptor,
  key : String,
) -> Unit raise PrintedError {
  let wanted = match self.type_ {
    Bool => "\"true\" or \"false\""
    type_ => integers_wanted(type_)
  }
  match self.type_ {
    String => ()
    Bool => if !(key is ("true" | "false")) { raise NotOfType(wanted~) }
    type_ => {
      let bits = map_key(type_, key) catch { _ => raise NotOfType(wanted~) }
      let signed = type_
        is (Int32 | Int64 | SInt32 | SInt64 | SFixed32 | SFixed64)
      let printed = decimal(bits, signed~)
      if printed != key {
        raise NotPrinted(printed="\"\{printed}\"")
      }
    }
  }
}

///|
/// What `field`'s values must be in the form `decode_json` prints them, as
/// an error says it: what ProtoJSON reads, as `wanted` says, but bytes,
/// which are printed in standard base64 with padding.
fn DescriptorSet::printed_wanted(
  self : DescriptorSet,
  field : FieldDescriptor,
) -> String {
  match field.type_ {
    Bytes => "a string of standard base64, with padding"
    _ => self.wanted(field)
  }
}

///|
/// What the values of the integer type `type_` must be, as an error says
/// it, such as `an integer from 0 to 4294967295`; for a type that is not
/// an integer, a map key of which no key is, what map keys may be.
fn integers_wanted(type_ : FieldType) -> String {
  match type_ {
    Int32 | SInt32 | SFixed32 => "an integer from -2147483648 to 2147483647"
    Int64 | SInt64 | SFixed64 =>
      "an integer from -9223372036854775808 to 9223372036854775807"
    UInt32 | Fixed32 => "an integer from 0 to 4294967295"
    UInt64 | Fixed64 => "an integer from 0 to 18446744073709551615"
    _ => "an integer, \"true\" or \"false\", or a string"
  }
}

///|
/// `bits`, an integer in two's complement as `integer_bits` gives it, in
/// decimal: as a signed integer when `signed`, else as an unsigned one.
fn decimal(bits : UInt64, signed~ : Bool) -> String {
  if signed {
    bits.reinterpret_as_int64().to_string()
  } else {
    bits.to_string()
  }
}

///|
/// The JSON number that `text`, a number as `decode_json` prints one,
/// reads as, with its digits kept as JSON text keeps them, so that it
/// compares with a printed message's number as the message's own does.
fn number_of(text : String) -> Json {
  @json.parse(text) catch {
    _ => abort("\{text} is not a JSON number")
  }
}
