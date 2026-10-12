// A metrics registry: counters, gauges and histograms with fixed label
// names, rendered in the Prometheus text exposition format (version 0.0.4).
// It does no I/O; the server serves what `Registry::render` returns.

///|
/// A set of metrics, rendered together in the Prometheus text format.
pub struct Registry {
  /// The metrics, in the order they were registered.
  priv families : Array[Family]
}

///|
/// One metric: its name, help, type, label names and series.
priv struct Family {
  name : String
  help : String
  kind : Kind
  labels : Array[String]
  /// The series by their label values, in the order they first appeared.
  series : Map[String, Series]
}

///|
priv enum Kind {
  Counter
  Gauge
  /// A histogram with the upper bounds of its buckets, in increasing order,
  /// without the last bucket, `+Inf`.
  Histogram(Array[Double])
}

///|
/// One series of a metric: the metric with one value for each label.
priv struct Series {
  values : Array[String]
  /// The value of a counter or a gauge.
  mut value : Double
  /// For a histogram, how many observations fell in each bucket, the last
  /// one being `+Inf`; not cumulative.
  buckets : FixedArray[Int64]
  /// For a histogram, the sum of the observations.
  mut sum : Double
}

///|
/// Creates an empty registry.
pub fn Registry::Registry() -> Registry {
  { families: [], }
}

///|
/// A counter: a value that only goes up, such as a number of requests.
pub struct Counter {
  priv family : Family
}

///|
/// The series of a counter for one set of label values.
pub struct CounterSeries {
  priv series : Series
}

///|
/// Registers a counter named `name`, with the help text `help` and the
/// label names `labels`. Every series of it gives a value for each label,
/// in the same order.
pub fn Registry::counter(
  self : Registry,
  name : String,
  help~ : String,
  labels? : Array[String] = [],
) -> Counter {
  { family: self.register(name, help, Counter, labels), }
}

///|
/// The series of the counter for the label values `values`, one for each
/// label name, in order.
pub fn Counter::labels(self : Counter, values : Array[String]) -> CounterSeries {
  { series: self.family.series_for(values), }
}

///|
/// Adds `by`, which must not be negative, to the counter.
pub fn CounterSeries::inc(self : CounterSeries, by? : Double = 1.0) -> Unit {
  if !(by >= 0.0) {
    abort("metrics: a counter cannot go down by \{by}")
  }
  self.series.value += by
}

///|
/// A gauge: a value that goes up and down, such as a number of entries
/// held.
pub struct Gauge {
  priv family : Family
}

///|
/// The series of a gauge for one set of label values.
pub struct GaugeSeries {
  priv series : Series
}

///|
/// Registers a gauge named `name`, with the help text `help` and the label
/// names `labels`, as `Registry::counter` does.
pub fn Registry::gauge(
  self : Registry,
  name : String,
  help~ : String,
  labels? : Array[String] = [],
) -> Gauge {
  { family: self.register(name, help, Gauge, labels), }
}

///|
/// The series of the gauge for the label values `values`, one for each
/// label name, in order.
pub fn Gauge::labels(self : Gauge, values : Array[String]) -> GaugeSeries {
  { series: self.family.series_for(values), }
}

///|
/// Sets the gauge to `value`.
pub fn GaugeSeries::set(self : GaugeSeries, value : Double) -> Unit {
  self.series.value = value
}

///|
/// Adds `delta`, which may be negative, to the gauge.
pub fn GaugeSeries::add(self : GaugeSeries, delta : Double) -> Unit {
  self.series.value += delta
}

///|
/// A histogram: observations, such as durations, counted in buckets, with
/// their sum and their count.
pub struct Histogram {
  priv family : Family
  priv bounds : Array[Double]
}

///|
/// The series of a histogram for one set of label values.
pub struct HistogramSeries {
  priv series : Series
  priv bounds : Array[Double]
}

///|
/// Registers a histogram named `name`, with the help text `help`, the
/// label names `labels`, as `Registry::counter` does, and the upper bounds
/// of its buckets `buckets`, in increasing order. A last bucket, `+Inf`,
/// counts every observation.
pub fn Registry::histogram(
  self : Registry,
  name : String,
  help~ : String,
  labels? : Array[String] = [],
  buckets~ : Array[Double],
) -> Histogram {
  if labels.contains("le") {
    abort("metrics: \{name}: le is the bucket label of a histogram")
  }
  for i, bound in buckets {
    if bound.is_nan() || bound.is_inf() || (i > 0 && !(buckets[i - 1] < bound)) {
      abort("metrics: \{name}: bucket bounds must be finite and increase")
    }
  }
  let bounds = buckets.copy()
  { family: self.register(name, help, Histogram(bounds), labels), bounds, }
}

///|
/// The series of the histogram for the label values `values`, one for each
/// label name, in order.
pub fn Histogram::labels(
  self : Histogram,
  values : Array[String],
) -> HistogramSeries {
  { series: self.family.series_for(values), bounds: self.bounds, }
}

///|
/// Counts `value` in the first bucket whose upper bound is at least
/// `value`, and adds it to the sum.
pub fn HistogramSeries::observe(self : HistogramSeries, value : Double) -> Unit {
  let i = match self.bounds.search_by(bound => value <= bound) {
    Some(i) => i
    None => self.bounds.length()
  }
  self.series.buckets[i] += 1
  self.series.sum += value
}

///|
/// Registers a metric. A metric without labels gets its one series at once,
/// so it renders from the start.
fn Registry::register(
  self : Registry,
  name : String,
  help : String,
  kind : Kind,
  labels : Array[String],
) -> Family {
  if !is_name(name, colon=true) {
    abort("metrics: \{name.escape()} is not a metric name")
  }
  if self.families.iter().any(family => family.name == name) {
    abort("metrics: \{name} is registered twice")
  }
  for i, label in labels {
    if !is_name(label, colon=false) || label.has_prefix("__") {
      abort("metrics: \{name}: \{label.escape()} is not a label name")
    }
    if labels[:i].contains(label) {
      abort("metrics: \{name}: the label \{label} is named twice")
    }
  }
  let family = { name, help, kind, labels: labels.copy(), series: Map([]), }
  self.families.push(family)
  if labels.is_empty() {
    let _ = family.series_for([])
  }
  family
}

///|
fn Family::series_for(self : Family, values : Array[String]) -> Series {
  if values.length() != self.labels.length() {
    abort(
      "metrics: \{self.name} takes \{self.labels.length()} label values, not \{values.length()}",
    )
  }
  // Each value with its length in front, so that no two lists of values
  // give the same key.
  let key = values.map(value => "\{value.length()}:\{value}").join("")
  match self.series.get(key) {
    Some(series) => series
    None => {
      let buckets = match self.kind {
        Histogram(bounds) => FixedArray::make(bounds.length() + 1, 0L)
        Counter | Gauge => FixedArray::make(0, 0L)
      }
      let series = { values: values.copy(), value: 0.0, buckets, sum: 0.0, }
      self.series[key] = series
      series
    }
  }
}

///|
/// Every metric in the Prometheus text exposition format, version 0.0.4:
/// for each metric, in the order they were registered, its `# HELP` and
/// `# TYPE` lines, then its samples for each series, in the order the series
/// first appeared. A histogram has a cumulative `_bucket` sample for each
/// bucket, labelled `le`, then `_sum` and `_count`.
pub fn Registry::render(self : Registry) -> String {
  let out = StringBuilder()
  for family in self.families {
    out.write_string("# HELP \{family.name} ")
    escape(out, family.help, quote=false)
    out.write_string("\n")
    let kind = match family.kind {
      Counter => "counter"
      Gauge => "gauge"
      Histogram(_) => "histogram"
    }
    out.write_string("# TYPE \{family.name} \{kind}\n")
    for _, series in family.series {
      match family.kind {
        Counter | Gauge =>
          sample(out, family.name, family.labels, series.values, series.value)
        Histogram(bounds) => {
          let names = [..family.labels, "le"]
          let mut count = 0L
          for i, n in series.buckets {
            count += n
            let le = if i < bounds.length() {
              number(bounds[i])
            } else {
              "+Inf"
            }
            sample(
              out,
              "\{family.name}_bucket",
              names,
              [..series.values, le],
              count.to_double(),
            )
          }
          sample(
            out,
            "\{family.name}_sum",
            family.labels,
            series.values,
            series.sum,
          )
          sample(
            out,
            "\{family.name}_count",
            family.labels,
            series.values,
            count.to_double(),
          )
        }
      }
    }
  }
  out.to_string()
}

///|
/// Writes one sample line: `name{label="value",...} value`.
fn sample(
  out : StringBuilder,
  name : String,
  labels : Array[String],
  values : Array[String],
  value : Double,
) -> Unit {
  out.write_string(name)
  if !labels.is_empty() {
    out.write_string("{")
    for i, label in labels {
      if i > 0 {
        out.write_string(",")
      }
      out.write_string("\{label}=\"")
      escape(out, values[i], quote=true)
      out.write_string("\"")
    }
    out.write_string("}")
  }
  out.write_string(" ")
  out.write_string(number(value))
  out.write_string("\n")
}

///|
/// Writes `text` with `\` and line feed escaped as the text format wants,
/// and `"` too when `quote` is set, as in a label value.
fn escape(out : StringBuilder, text : String, quote~ : Bool) -> Unit {
  for c in text {
    match c {
      '\\' => out.write_string("\\\\")
      '\n' => out.write_string("\\n")
      '"' if quote => out.write_string("\\\"")
      c => out.write_char(c)
    }
  }
}

///|
/// `value` as the text format writes a number: `+Inf`, `-Inf` and `NaN`
/// for the values that are not finite.
fn number(value : Double) -> String {
  if value.is_pos_inf() {
    "+Inf"
  } else if value.is_neg_inf() {
    "-Inf"
  } else {
    value.to_string()
  }
}

///|
/// Whether `name` is a Prometheus metric name, with `colon`, or label name:
/// ASCII letters, digits and `_` (and `:` in a metric name), not starting
/// with a digit.
fn is_name(name : String, colon~ : Bool) -> Bool {
  if name == "" {
    return false
  }
  for i, c in name {
    let ok = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      c == '_' ||
      (colon && c == ':') ||
      (i > 0 && c >= '0' && c <= '9')
    if !ok {
      return false
    }
  }
  true
}
