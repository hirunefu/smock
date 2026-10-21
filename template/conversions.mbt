// The conversions: `number(x)`, `range(a, b)`, and `json(x)` and `raw(x)`,
// which say how a text template writes a value.

///|
/// A conversion.
priv enum ConversionHelper {
  /// `number(x)`, which takes any expression.
  Number
  /// `range(a, b)`, whose bounds are any expressions that give integers.
  Range
  /// `json(x)`: text templates only.
  JsonText
  /// `raw(x)`: text templates only.
  Raw
}

///|
/// The conversion that `site` calls, checked. `None` when it calls a helper
/// of another family.
fn conversion_helper(site : CallSite) -> Helper? raise Syntax {
  let helper : ConversionHelper = match site.name {
    "number" => {
      site.count(1)
      Number
    }
    "range" => {
      site.count(2)
      // Each bound may be any expression; a literal one, or a literal
      // alternative of a fallback, is checked now.
      for arg in site.args {
        for literal in literals(arg.1) {
          if range_integer(literal) is None {
            raise Syntax(arg.0, range_problem(literal))
          }
        }
      }
      match (site.args[0].1, site.args[1].1) {
        (Literal(a), Literal(b)) => {
          let a = range_integer(a).unwrap()
          let b = range_integer(b).unwrap()
          if b - a + 1L > max_range.to_int64() {
            raise Syntax(
              site.start,
              "range(\{a}, \{b}) gives \{b - a + 1L} values; range gives at most \{max_range}",
            )
          }
        }
        _ => ()
      }
      Range
    }
    "json" | "raw" => {
      if !site.text {
        raise Syntax(
          site.start,
          "\{site.name}() is for text templates; in json, smock writes and escapes every value itself",
        )
      }
      site.count(1)
      if site.name == "json" {
        JsonText
      } else {
        Raw
      }
    }
    _ => return None
  }
  Some(Conversion(helper))
}

///|
/// The most values `range` gives.
let max_range : Int = 1000

///|
/// The values of a literal `range(a, b)`, if `expr` is one.
fn literal_range(expr : Expr) -> Int? {
  match expr {
    Call(Conversion(Range), [Literal(Number(a, ..)), Literal(Number(b, ..))], _) => {
      let count = b - a + 1.0
      Some(if count < 0.0 { 0 } else { count.to_int() })
    }
    _ => None
  }
}

///|
/// What the conversion `helper` gives for the values of its arguments,
/// `values`, inserted at `at`.
fn convert(
  helper : ConversionHelper,
  values : Array[Json],
  at : String,
) -> Value raise RenderError {
  match helper {
    Number =>
      match values[0] {
        Number(_) as n => { json: n, form: Ordinary, }
        String(text) =>
          match number_of(text) {
            Some(n) => { json: n, form: Ordinary, }
            None =>
              raise RenderError(
                at~,
                message="number(): \{text.escape()} is not a JSON number",
              )
          }
        other =>
          raise RenderError(
            at~,
            message="number() takes a string or a number, not \{kind_of(other)}",
          )
      }
    Range => {
      let a = range_bound(values[0], at)
      let b = range_bound(values[1], at)
      let count = b - a + 1L
      if count > max_range.to_int64() {
        raise RenderError(
          at~,
          message="range(\{a}, \{b}) gives \{count} values; range gives at most \{max_range}",
        )
      }
      let items = []
      let mut n = a
      while n <= b {
        items.push(Json::number(n.to_double()))
        n += 1L
      }
      { json: Json::array(items), form: Ordinary, }
    }
    JsonText =>
      { json: Json::string(compact_json(values[0])), form: JsonOutput, }
    Raw =>
      match values[0] {
        Object(_) | Array(_) =>
          raise RenderError(
            at~,
            message="raw() takes a string, a number, true, false or null, not an object or an array",
          )
        json => { json, form: RawText, }
      }
  }
}

///|
/// `json` as a bound of `range`: an integer from -(2^53 - 1) to 2^53 - 1.
fn range_bound(json : Json, at : String) -> Int64 raise RenderError {
  match range_integer(json) {
    Some(n) => n
    None => raise RenderError(at~, message=range_problem(json))
  }
}

///|
/// `json` as a bound of `range`, if it is one: an integer number from
/// -(2^53 - 1) to 2^53 - 1. A string is not a number here.
fn range_integer(json : Json) -> Int64? {
  match json {
    Number(n, ..) if n == n.floor() && n.abs() <= max_integer.to_double() =>
      Some(n.to_int64())
    _ => None
  }
}

///|
/// What is wrong with `json`, which is not a bound of `range`.
fn range_problem(json : Json) -> String {
  "range() takes integers from -\{max_integer} to \{max_integer}, not \{described(json)}"
}
