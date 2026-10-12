// A reader of the Prometheus text exposition format, version 0.0.4, for the
// Seam 2 tests of /metrics. It is written from the format's description,
// apart from smock's renderer, and rejects what Prometheus would reject.

///|
/// One sample: the metric name, the labels in the order they were written,
/// and the value.
struct Sample {
  name : String
  labels : Array[(String, String)]
  value : Double
}

///|
/// The sample as the text format writes it, such as
/// `smock_requests_total{mock="users",stub=""} 2`.
fn Sample::line(self : Sample) -> String {
  let labels = if self.labels.is_empty() {
    ""
  } else {
    let pairs = self.labels.map(label => "\{label.0}=\{label.1.escape()}")
    "{\{pairs.join(",")}}"
  }
  "\{self.name}\{labels} \{self.value}"
}

///|
/// The value of the label `name`, if the sample has it.
fn Sample::label(self : Sample, name : String) -> String? {
  self.labels.iter().find_first(label => label.0 == name).map(label => label.1)
}

///|
/// Parses `text` in the Prometheus text exposition format, version 0.0.4,
/// and returns its samples, in order. Raises at the first thing Prometheus
/// would reject:
///
/// - text that does not end with a line feed, or a line that is not empty,
///   a comment, `# HELP`, `# TYPE` or a sample;
/// - a metric or label name that is not one, a label named twice, a label
///   value with an escape other than `\\`, `\"` and `\n`, or a value or
///   timestamp that is not a number;
/// - a second `# HELP` or `# TYPE` for a metric, a `# TYPE` after the
///   metric's samples, or lines of a metric that are not together;
/// - the same series twice;
/// - a sample of a histogram other than `_bucket` with `le`, `_sum` and
///   `_count`, buckets of a series whose bounds do not increase to
///   `le="+Inf"` or whose counts go down, or a `_count` that differs from
///   the `+Inf` bucket.
fn parse_prometheus(text : String) -> Array[Sample] raise {
  if text != "" && !text.has_suffix("\n") {
    fail("the text does not end with a line feed")
  }
  let types : Map[String, String] = Map([])
  let helps : Set[String] = Set([])
  // The metrics whose lines have ended, and the one whose lines go on.
  let done : Set[String] = Set([])
  let mut current = ""
  let enter = (metric : String) => {
    if metric != current {
      if done.contains(metric) {
        fail("the lines of \{metric} are not together")
      }
      if current != "" {
        done.add(current)
      }
      current = metric
    }
  }
  let samples = []
  let series : Set[String] = Set([])
  for raw in text.split("\n") {
    let line = raw.to_owned()
    if line == "" {
      continue
    }
    if line.has_prefix("#") {
      let words = line.split(" ").map(word => word.to_owned()).collect()
      if words.length() >= 3 && words[0] == "#" && words[1] == "HELP" {
        let metric = words[2]
        check_name(metric, colon=true)
        enter(metric)
        if helps.contains(metric) {
          fail("a second HELP for \{metric}")
        }
        helps.add(metric)
        check_escapes(line, quote=false)
      } else if words.length() >= 3 && words[0] == "#" && words[1] == "TYPE" {
        let metric = words[2]
        check_name(metric, colon=true)
        guard words.length() == 4 &&
          ["counter", "gauge", "histogram", "summary", "untyped"].contains(
            words[3],
          ) else {
          fail("not a TYPE line: \{line}")
        }
        if types.contains(metric) {
          fail("a second TYPE for \{metric}")
        }
        if done.contains(metric) ||
          (
            current == metric &&
            samples.iter().any(s => family(s, types) == metric)
          ) {
          fail("the TYPE of \{metric} comes after its samples")
        }
        enter(metric)
        types[metric] = words[3]
      }
      continue
    }
    let sample = parse_sample(line)
    enter(family(sample, types))
    let key = "\{sample.name}\{sample.labels.map(l => "\{l.0}=\{l.1.escape()}").join(",")}"
    if series.contains(key) {
      fail("the same series twice: \{line}")
    }
    series.add(key)
    samples.push(sample)
  }
  check_histograms(samples, types)
  samples
}

///|
/// The metric a sample belongs to: a histogram's `x` for its `x_bucket`,
/// `x_sum` and `x_count`, otherwise the sample's own name.
fn family(sample : Sample, types : Map[String, String]) -> String {
  for suffix in ["_bucket", "_sum", "_count"] {
    if sample.name.strip_suffix(suffix) is Some(base) {
      let base = base.to_owned()
      match types.get(base) {
        Some("histogram") => return base
        Some("summary") if suffix != "_bucket" => return base
        _ => ()
      }
    }
  }
  sample.name
}

///|
/// Parses one sample line: `name{label="value",...} value [timestamp]`.
fn parse_sample(line : String) -> Sample raise {
  let chars = line.to_array()
  let mut i = 0
  while i < chars.length() && chars[i] != '{' && chars[i] != ' ' {
    i += 1
  }
  let name = String::from_array(chars[:i])
  check_name(name, colon=true)
  let labels : Array[(String, String)] = []
  if i < chars.length() && chars[i] == '{' {
    i += 1
    while i < chars.length() && chars[i] != '}' {
      let start = i
      while i < chars.length() && chars[i] != '=' {
        i += 1
      }
      let label = String::from_array(chars[start:i])
      check_name(label, colon=false)
      if labels.iter().any(l => l.0 == label) {
        fail("the label \{label} twice: \{line}")
      }
      guard i + 1 < chars.length() && chars[i + 1] == '"' else {
        fail("a label value is not quoted: \{line}")
      }
      i += 2
      let value = StringBuilder()
      while i < chars.length() && chars[i] != '"' {
        if chars[i] == '\\' {
          guard i + 1 < chars.length() else { fail("a lone \\: \{line}") }
          match chars[i + 1] {
            '\\' => value.write_char('\\')
            '"' => value.write_char('"')
            'n' => value.write_char('\n')
            c => fail("the escape \\\{c}: \{line}")
          }
          i += 2
        } else {
          value.write_char(chars[i])
          i += 1
        }
      }
      guard i < chars.length() else { fail("an unclosed label value: \{line}") }
      i += 1
      labels.push((label, value.to_string()))
      if i < chars.length() && chars[i] == ',' {
        i += 1
      }
    }
    guard i < chars.length() else { fail("unclosed labels: \{line}") }
    i += 1
  }
  guard i < chars.length() && chars[i] == ' ' else { fail("no value: \{line}") }
  let rest = String::from_array(chars[i + 1:]).split(" ").collect()
  guard rest.length() is (1 | 2) else { fail("not a sample: \{line}") }
  let value = number(rest[0], line)
  if rest.length() == 2 {
    let _ = @string.parse_int64(rest[1]) catch {
      _ => fail("the timestamp is not an integer: \{line}")
    }
  }
  { name, labels, value, }
}

///|
/// A sample value, as Go's `strconv.ParseFloat` reads it, as Prometheus
/// does: a decimal number, `+Inf`, `-Inf` or `NaN`.
fn number(text : StringView, line : String) -> Double raise {
  match text {
    "+Inf" => @double.infinity
    "-Inf" => @double.neg_infinity
    "NaN" => @double.not_a_number
    _ => {
      let ok = text != "" &&
        text.iter().all(c => c is ('0'..='9' | '.' | 'e' | 'E' | '+' | '-'))
      guard ok else { fail("not a value: \{line}") }
      @string.parse_double(text) catch {
        _ => fail("not a value: \{line}")
      }
    }
  }
}

///|
/// Fails unless `name` is a metric name, with `colon`, or a label name.
fn check_name(name : String, colon~ : Bool) -> Unit raise {
  let mut ok = name != ""
  for i, c in name {
    if !(c is ('a'..='z' | 'A'..='Z' | '_') ||
      (colon && c == ':') ||
      (i > 0 && c is ('0'..='9'))) {
      ok = false
    }
  }
  if !ok {
    fail(
      "not a \{if colon { "metric" } else { "label" }} name: \{name.escape()}",
    )
  }
}

///|
/// Fails when `line` has an escape the text format does not allow: only
/// `\\` and `\n` in help text, and `\"` too where `quote` is set.
fn check_escapes(line : String, quote~ : Bool) -> Unit raise {
  let chars = line.to_array()
  let mut i = 0
  while i < chars.length() {
    if chars[i] == '\\' {
      let ok = i + 1 < chars.length() &&
        (chars[i + 1] is ('\\' | 'n') || (quote && chars[i + 1] == '"'))
      if !ok {
        fail("a bad escape: \{line}")
      }
      i += 2
    } else {
      i += 1
    }
  }
}

///|
/// Fails unless every histogram is whole: for each series, `_bucket`
/// samples whose bounds increase to `le="+Inf"` and whose counts never go
/// down, then `_sum` and a `_count` equal to the `+Inf` bucket.
fn check_histograms(
  samples : Array[Sample],
  types : Map[String, String],
) -> Unit raise {
  // Per histogram series: the last bound and count of its buckets.
  let buckets : Map[String, (Double, Double)] = Map([])
  let counts : Map[String, Double] = Map([])
  let sums : Set[String] = Set([])
  for sample in samples {
    let metric = family(sample, types)
    guard types.get(metric) is Some("histogram") else { continue }
    let others = sample.labels.filter(label => label.0 != "le")
    let key = "\{metric}\{others.map(l => "\{l.0}=\{l.1.escape()}").join(",")}"
    if sample.name == "\{metric}_bucket" {
      guard sample.label("le") is Some(le) else {
        fail("a bucket without le: \{sample.line()}")
      }
      let bound = number(le, sample.line())
      if buckets.get(key) is Some((last_bound, last_count)) &&
        (!(bound > last_bound) || sample.value < last_count) {
        fail("buckets out of order: \{sample.line()}")
      }
      buckets[key] = (bound, sample.value)
    } else if sample.name == "\{metric}_sum" {
      sums.add(key)
    } else if sample.name == "\{metric}_count" {
      counts[key] = sample.value
    } else {
      fail("not a histogram sample: \{sample.line()}")
    }
  }
  for key, last in buckets {
    if !last.0.is_pos_inf() {
      fail("the buckets of \{key} do not end with +Inf")
    }
    if counts.get(key) != Some(last.1) {
      fail("the count of \{key} is not its +Inf bucket")
    }
    if !sums.contains(key) {
      fail("\{key} has no sum")
    }
  }
}

///|
test "the reader takes what Prometheus takes and rejects what it rejects" {
  let valid =
    #|# HELP a_total A counter, with \\ and \n.
    #|# TYPE a_total counter
    #|a_total{mock="x\"y",stub=""} 1
    #|a_total{mock="",stub="a\\b\nc",} 2 1700000000000
    #|# a comment
    #|
    #|# TYPE h histogram
    #|h_bucket{le="0.5"} 1
    #|h_bucket{le="+Inf"} 2
    #|h_sum 0.75
    #|h_count 2
    #|untyped_thing NaN
    #|
  let samples = parse_prometheus(valid)
  let out = [samples.map(sample => sample.line()).join("\n")]
  let invalid = [
    ("no final line feed", "a 1"),
    ("a bad metric name", "1a 1\n"),
    ("a bad label name", "a{1b=\"x\"} 1\n"),
    ("an unquoted label value", "a{b=x} 1\n"),
    ("a bad escape", "a{b=\"\\t\"} 1\n"),
    ("a label twice", "a{b=\"1\",b=\"2\"} 1\n"),
    ("a bad value", "a 1_000\n"),
    ("no value", "a{b=\"1\"}\n"),
    ("a series twice", "a 1\na 2\n"),
    ("TYPE twice", "# TYPE a counter\n# TYPE a counter\na 1\n"),
    ("TYPE after samples", "a 1\n# TYPE a counter\n"),
    ("lines apart", "# TYPE a counter\na{b=\"1\"} 1\nc 1\na{b=\"2\"} 1\n"),
    (
      "buckets going down", "# TYPE h histogram\nh_bucket{le=\"1\"} 2\nh_bucket{le=\"+Inf\"} 1\nh_sum 1\nh_count 1\n",
    ),
    (
      "no +Inf bucket", "# TYPE h histogram\nh_bucket{le=\"1\"} 1\nh_sum 1\nh_count 1\n",
    ),
    (
      "a count that is not the +Inf bucket", "# TYPE h histogram\nh_bucket{le=\"+Inf\"} 2\nh_sum 1\nh_count 1\n",
    ),
  ]
  for case in invalid {
    let (name, text) = case
    let verdict = try parse_prometheus(text) catch {
      _ => "rejected"
    } noraise {
      _ => "accepted"
    }
    out.push("\{name}: \{verdict}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|a_total{mock="x\"y",stub=""} 1
      #|a_total{mock="",stub="a\\b\nc"} 2
      #|h_bucket{le="0.5"} 1
      #|h_bucket{le="+Inf"} 2
      #|h_sum 0.75
      #|h_count 2
      #|untyped_thing NaN
      #|no final line feed: rejected
      #|a bad metric name: rejected
      #|a bad label name: rejected
      #|an unquoted label value: rejected
      #|a bad escape: rejected
      #|a label twice: rejected
      #|a bad value: rejected
      #|no value: rejected
      #|a series twice: rejected
      #|TYPE twice: rejected
      #|TYPE after samples: rejected
      #|lines apart: rejected
      #|buckets going down: rejected
      #|no +Inf bucket: rejected
      #|a count that is not the +Inf bucket: rejected
    ),
  )
}
