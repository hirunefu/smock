// The arithmetic helpers. They compute in exact decimal (decimal.mbt), so
// `add(0.1, 0.2)` is `0.3`, and give numbers that keep the plain decimal
// they are written as.

///|
/// An arithmetic helper.
priv enum ArithmeticHelper {
  /// An operation on two numbers.
  Operation(Operation)
  /// `ceil(x)`, `floor(x)`, `round(x)` and `parseInt(x)`: an integer,
  /// rounded as each says.
  Integral(Rounding)
  /// `toFixed(x, places)`: rounded half away from zero, and written with
  /// exactly `places` decimals.
  ToFixed(Int)
}

///|
/// An operation on two numbers.
priv enum Operation {
  /// `add(a, b)`: exact.
  Add
  /// `subtract(a, b)`: exact.
  Subtract
  /// `multiply(a, b)`: exact.
  Multiply
  /// `divide(a, b)`: rounded half to even at 10 decimal places.
  Divide
  /// `modulo(a, b)`: the remainder of division truncated toward zero.
  Modulo
}

///|
/// The helper's name, for messages.
fn ArithmeticHelper::name(self : ArithmeticHelper) -> String {
  match self {
    Operation(Add) => "add"
    Operation(Subtract) => "subtract"
    Operation(Multiply) => "multiply"
    Operation(Divide) => "divide"
    Operation(Modulo) => "modulo"
    Integral(Ceiling) => "ceil"
    Integral(Floor) => "floor"
    Integral(HalfAwayFromZero) => "round"
    Integral(TowardZero) => "parseInt"
    ToFixed(_) => "toFixed"
  }
}

///|
/// The arithmetic helper that `site` calls, checked. `None` when it calls
/// a helper of another family.
fn arithmetic_helper(site : CallSite) -> Helper? raise Syntax {
  let helper : ArithmeticHelper = match site.name {
    "add" => Operation(Add)
    "subtract" => Operation(Subtract)
    "multiply" => Operation(Multiply)
    "divide" => Operation(Divide)
    "modulo" => Operation(Modulo)
    "ceil" => Integral(Ceiling)
    "floor" => Integral(Floor)
    "round" => Integral(HalfAwayFromZero)
    "parseInt" => Integral(TowardZero)
    "toFixed" => {
      site.count(2)
      site.numeric(0)
      let places = site.integer(1, 0L, max_places.to_int64()).to_int()
      return Some(Arithmetic(ToFixed(places)))
    }
    _ => return None
  }
  site.count(if helper is Operation(_) { 2 } else { 1 })
  for k in 0..<site.args.length() {
    site.numeric(k)
  }
  Some(Arithmetic(helper))
}

///|
/// Whether `name` names an arithmetic helper, whose number literals the
/// parser reads with `exact_literal`.
fn is_arithmetic(name : String) -> Bool {
  name
  is ("add"
  | "subtract"
  | "multiply"
  | "divide"
  | "modulo"
  | "ceil"
  | "floor"
  | "round"
  | "parseInt"
  | "toFixed")
}

///|
/// The number literal `json`, written as `text` among the arguments of an
/// arithmetic helper. It keeps `text` unless its 64-bit float writes the
/// same decimal, as `1.50` and `1e3` do, so that the helper reads every
/// digit written and the bounds apply to them: `0.12345678901234567891` is
/// not 0.12345678901234568. Only the helper reads the literal, so how a
/// literal is written anywhere else does not change.
fn exact_literal(json : Json, text : String) -> Json {
  guard json is Number(n, repr=None) else { return json }
  let kept = Json::number(n, repr=text)
  let written = Decimal::parse(text) catch { _ => return kept }
  let float = Decimal::parse(n.to_string()) catch { _ => return kept }
  if written.text() == float.text() {
    json
  } else {
    kept
  }
}

///|
/// Checks the literals that argument `k` (from 0) can give: each must be
/// numeric, and within the bounds.
fn CallSite::numeric(self : CallSite, k : Int) -> Unit raise Syntax {
  let (at, arg) = self.args[k]
  for literal in literals(arg) {
    if decimal_value(self.name, k, literal) is Err(message) {
      raise Syntax(at, message)
    }
  }
}

///|
/// `json`, argument `k` (from 0) of the helper `name`, as a decimal, or
/// what is wrong with it. A number is taken as smock writes it, and a
/// string that is a JSON number as its own text.
fn decimal_value(
  name : String,
  k : Int,
  json : Json,
) -> Result[Decimal, String] {
  let text = match json {
    Number(n, repr~) => number_text(n, repr)
    String(text) if number_of(text) is Some(_) => text
    _ => return Err(argument_problem(name, k, Numeric, json))
  }
  Ok(Decimal::parse(text)) catch {
    _ =>
      Err(
        "\{name}(): argument \{k + 1} must have at most \{max_places} digits before the point and \{max_places} after, not \{described(json)}",
      )
  }
}

///|
/// Argument `k` (from 0) of the helper `name`, whose value is `json`, as a
/// decimal. Raises a render error at `at` when it is not one.
fn decimal_argument(
  name : String,
  k : Int,
  json : Json,
  at : String,
) -> Decimal raise RenderError {
  match decimal_value(name, k, json) {
    Ok(decimal) => decimal
    Err(message) => raise RenderError(at~, message~)
  }
}

///|
/// The render error at `at` of a result of the helper `name` that is
/// beyond the bounds.
fn result_beyond(name : String, beyond : Beyond, at : String) -> RenderError {
  let side = match beyond {
    TooLarge => "before"
    TooPrecise => "after"
  }
  RenderError(
    at~,
    message="\{name}(): the result has more than \{max_places} digits \{side} the point",
  )
}

///|
/// What the arithmetic helper `helper` gives for the values of its
/// arguments, `values`, inserted at `at`.
fn arithmetic_value(
  helper : ArithmeticHelper,
  values : Array[Json],
  at : String,
) -> Json raise RenderError {
  let name = helper.name()
  let x = decimal_argument(name, 0, values[0], at)
  let text = match helper {
    Operation(operation) => {
      let y = decimal_argument(name, 1, values[1], at)
      if operation is (Divide | Modulo) && y.is_zero() {
        raise RenderError(
          at~,
          message="\{name}(): argument 2, the divisor, is zero",
        )
      }
      let result = operation.apply(x, y) catch {
        beyond => raise result_beyond(name, beyond, at)
      }
      result.text()
    }
    Integral(rounding) => {
      let result = x.rounded(0, rounding) catch {
        beyond => raise result_beyond(name, beyond, at)
      }
      result.text()
    }
    ToFixed(places) => {
      let result = x.rounded(places, HalfAwayFromZero) catch {
        beyond => raise result_beyond(name, beyond, at)
      }
      result.fixed(places)
    }
  }
  decimal_number(text)
}

///|
/// The number that `text`, a plain decimal, writes, keeping `text`. Its
/// 64-bit float, which only other helpers' checks read, is the nearest one,
/// as reading `text` as JSON gives.
fn decimal_number(text : String) -> Json {
  // The text is a plain decimal, which always reads as a float.
  let float = @string.parse_double(text) catch { _ => 0.0 }
  Json::number(float, repr=text)
}

///|
/// What the operation gives for `x` and `y`.
fn Operation::apply(
  self : Operation,
  x : Decimal,
  y : Decimal,
) -> Decimal raise Beyond {
  match self {
    Add => x.add(y)
    Subtract => x.add(y.negated())
    Multiply => x.multiply(y)
    Divide => x.divide(y)
    Modulo => x.modulo(y)
  }
}
