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
}

///|
/// One series of a metric: the metric with one value for each label.
priv struct Series {
  values : Array[String]
  mut value : Double
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
/// Adds `by` to the counter.
pub fn CounterSeries::inc(self : CounterSeries, by? : Double = 1.0) -> Unit {
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
/// Registers a metric. A metric without labels gets its one series at once,
/// so it renders from the start.
fn Registry::register(
  self : Registry,
  name : String,
  help : String,
  kind : Kind,
  labels : Array[String],
) -> Family {
  let family = { name, help, kind, labels, series: Map([]), }
  self.families.push(family)
  if labels.is_empty() {
    let _ = family.series_for([])
  }
  family
}

///|
fn Family::series_for(self : Family, values : Array[String]) -> Series {
  let key = values.join("\u{0}")
  match self.series.get(key) {
    Some(series) => series
    None => {
      let series = { values, value: 0.0, }
      self.series[key] = series
      series
    }
  }
}

///|
/// Every metric in the Prometheus text exposition format, version 0.0.4:
/// for each metric, in the order they were registered, its `# HELP` and
/// `# TYPE` lines, then a line for each series.
pub fn Registry::render(self : Registry) -> String {
  let out = StringBuilder()
  for family in self.families {
    out.write_string("# HELP \{family.name} \{family.help}\n")
    let kind = match family.kind {
      Counter => "counter"
      Gauge => "gauge"
    }
    out.write_string("# TYPE \{family.name} \{kind}\n")
    for _, series in family.series {
      out.write_string(family.name)
      if !family.labels.is_empty() {
        out.write_string("{")
        for i, label in family.labels {
          if i > 0 {
            out.write_string(",")
          }
          out.write_string("\{label}=\"\{series.values[i]}\"")
        }
        out.write_string("}")
      }
      out.write_string(" ")
      out.write_string(series.value.to_string())
      out.write_string("\n")
    }
  }
  out.to_string()
}
