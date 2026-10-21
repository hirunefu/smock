// Samples of numbers and integers, within their bounds: `minimum`,
// `maximum` and their exclusive forms. The arithmetic is exact on the
// bounds' decimal text (decimal.mbt), so every target writes the same
// digits.

///|
/// A bound of a sampled number: its value, where it is written, and
/// whether the number may not equal it.
priv struct Bound {
  pointer : String
  value : Decimal
  exclusive : Bool
}

///|
/// Whether `value` is above the lower bound `self`, or equal to it when
/// it is not exclusive.
fn Bound::allows_above(self : Bound, value : Decimal) -> Bool {
  let order = value.compare(self.value)
  order > 0 || (order == 0 && !self.exclusive)
}

///|
/// Whether `value` is below the upper bound `self`, or equal to it when
/// it is not exclusive.
fn Bound::allows_below(self : Bound, value : Decimal) -> Bool {
  let order = value.compare(self.value)
  order < 0 || (order == 0 && !self.exclusive)
}

///|
/// The bound's value, moved by `step` when the bound is exclusive: the
/// nearest number it allows, 1 inside it.
fn Bound::inside(self : Bound, step : Int) -> Decimal {
  if self.exclusive {
    self.value.plus(step)
  } else {
    self.value
  }
}

///|
/// For an integer, the bound rounded inward to `whole`, the whole number
/// next to its value on the side it allows. When the value is not whole,
/// `whole` is within the bound, so the integer may equal it.
fn Bound::rounded(self : Bound, whole : Decimal) -> Bound {
  if whole.compare(self.value) == 0 {
    self
  } else {
    { ..self, value: whole, exclusive: false, }
  }
}

///|
/// Whether `value` is within the bounds `lower` and `upper`.
fn fits(lower : Bound?, upper : Bound?, value : Decimal) -> Bool {
  if lower is Some(lower) && !lower.allows_above(value) {
    return false
  }
  !(upper is Some(upper) && !upper.allows_below(value))
}

///|
/// The sample of a number, or of an integer when `integer`: 0 when its
/// bounds allow it. Else the nearest bound, moved by 1 inside an exclusive
/// bound, or to the middle of the two bounds when that leaves the range.
/// For an integer, a bound that is not whole is first rounded inward, a
/// lower bound up and an upper bound down, and the middle is rounded down.
/// When nothing fits, the sample is the lower bound, with a warning.
fn Sampler::number(self : Sampler, merged : Merged, integer~ : Bool) -> Decimal {
  let mut lower = self.bound(merged, "minimum", "exclusiveMinimum", lower=true)
  let mut upper = self.bound(merged, "maximum", "exclusiveMaximum", lower=false)
  if integer {
    lower = lower.map(bound => bound.rounded(bound.value.ceil()))
    upper = upper.map(bound => bound.rounded(bound.value.floor()))
  }
  let zero = Decimal::zero()
  if fits(lower, upper, zero) {
    return zero
  }
  // The nearest bound is the lower one when it leaves out 0, else the
  // upper one, which then does.
  let nearest = match (lower, upper) {
    (Some(lower), _) if !lower.allows_above(zero) => lower.inside(1)
    (_, Some(upper)) => upper.inside(-1)
    _ => zero
  }
  if fits(lower, upper, nearest) {
    return nearest
  }
  // The nearest bound, moved inside, is within it, so the other bound
  // leaves it out: there are two.
  guard (lower, upper) is (Some(lower), Some(upper)) else { return nearest }
  let middle = lower.value.middle(upper.value)
  let middle = if integer { middle.floor() } else { middle }
  if fits(Some(lower), Some(upper), middle) {
    return middle
  }
  self.report.warning_at(
    lower.pointer,
    if integer {
      "changed: no integer fits the bounds; the sample is the lower bound, rounded up"
    } else {
      "changed: no number fits the bounds; the sample is the lower bound"
    },
  )
  lower.value
}

///|
/// The lower bound of `merged` when `lower`, else its upper bound, from
/// the number `keyword` and its exclusive form `exclusive`. In OpenAPI
/// 3.0, `exclusive` is `true` or `false`, and `true` makes `keyword`
/// exclusive. From 3.1, it is a number, and the tighter of the two counts:
/// the exclusive one when they are equal.
fn Sampler::bound(
  self : Sampler,
  merged : Merged,
  keyword : String,
  exclusive : String,
  lower~ : Bool,
) -> Bound? {
  let inclusive = self.number_bound(
    merged,
    keyword,
    "ignored: must be a number",
    exclusive=false,
  )
  if self.v30 {
    return self.exclusive_v30(merged, inclusive, exclusive)
  }
  let exclusive = self.number_bound(
    merged,
    exclusive,
    "ignored: must be a number in OpenAPI 3.1 and 3.2",
    exclusive=true,
  )
  match (inclusive, exclusive) {
    (Some(inclusive), Some(exclusive)) => {
      let order = exclusive.value.compare(inclusive.value)
      Some(
        if (lower && order >= 0) || (!lower && order <= 0) {
          exclusive
        } else {
          inclusive
        },
      )
    }
    (Some(_), None) => inclusive
    (None, _) => exclusive
  }
}

///|
/// `bound`, made exclusive when the boolean `keyword` of `merged`, from
/// the first layer that has one, is `true`, as in OpenAPI 3.0. A value of
/// another type is ignored, with a warning.
fn Sampler::exclusive_v30(
  self : Sampler,
  merged : Merged,
  bound : Bound?,
  keyword : String,
) -> Bound? {
  for layer in merged.layers {
    match layer.schema.get(keyword) {
      None => ()
      Some(True) => return bound.map(bound => { ..bound, exclusive: true, })
      Some(False) => return bound
      Some(_) =>
        self.report.warning_at(
          @definitions.child_pointer(layer.pointer, keyword),
          "ignored: must be true or false in OpenAPI 3.0",
        )
    }
  }
  bound
}

///|
/// The number `keyword` of `merged`, as a bound that is `exclusive` or
/// not, from the first layer that has a usable one. A value that is not a
/// number is ignored, with the warning `message`. So is one with more than
/// 18 digits before or after the point, with a warning of its own. A
/// number is taken as the decimal text smock writes for it: the shortest
/// that reads back as the same double, or the digits of a big integer.
fn Sampler::number_bound(
  self : Sampler,
  merged : Merged,
  keyword : String,
  message : String,
  exclusive~ : Bool,
) -> Bound? {
  for layer in merged.layers {
    let at = @definitions.child_pointer(layer.pointer, keyword)
    match layer.schema.get(keyword) {
      None => ()
      Some(Number(n, repr~)) =>
        match Decimal::parse(@template.number_text(n, repr)) {
          Some(value) => return Some({ pointer: at, value, exclusive, })
          None =>
            self.report.warning_at(
              at,
              "ignored: a bound may have at most \{max_places} digits before the point and \{max_places} after",
            )
        }
      Some(_) => self.report.warning_at(at, message)
    }
  }
  None
}
