// The conversions: `number(x)`, `range(a, b)`, and `json(x)` and `raw(x)`,
// which say how a text template writes a value.

///|
/// A conversion.
priv enum ConversionHelper {
  /// `number(x)`, which takes any expression.
  Number
  /// `range(a, b)`, whose arguments are integer literals or `number(…)`.
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
      for arg in site.args {
        if !is_range_bound(arg.1) {
          raise Syntax(
            arg.0,
            "range() takes integers: integer literals, or number(…) of a request value",
          )
        }
      }
      match (site.args[0].1, site.args[1].1) {
        (Literal(_), Literal(_)) => {
          let a = site.integer(0, -max_integer, max_integer)
          let b = site.integer(1, -max_integer, max_integer)
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
/// Whether `expr` can bound a range: an integer literal, `number(…)`, or a
/// fallback of those.
fn is_range_bound(expr : Expr) -> Bool {
  match expr {
    Literal(Number(n, ..)) => n == n.floor()
    Call(Conversion(Number), _) => true
    Fallback(alternatives) => alternatives.iter().all(is_range_bound)
    _ => false
  }
}

///|
/// The values of a literal `range(a, b)`, if `expr` is one.
fn literal_range(expr : Expr) -> Int? {
  match expr {
    Call(Conversion(Range), [Literal(Number(a, ..)), Literal(Number(b, ..))]) => {
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
  match json {
    Number(n, ..) if n == n.floor() && n.abs() <= max_integer.to_double() =>
      n.to_int64()
    _ =>
      raise RenderError(
        at~,
        message="range() takes integers from -\{max_integer} to \{max_integer}, not \{compact_json(json)}",
      )
  }
}
