///|
test "a counter renders its help, its type and one sample per label set, in the order the sets first appeared" {
  // The order of these lines is smock's own choice, which the text format
  // 0.0.4 leaves free: its "Grouping and sorting" asks only that a metric's
  // lines come as one group, "with the optional `HELP` and `TYPE` lines
  // first (in no particular order)", and finds sorting "preferred but not
  // required". smock writes `# HELP` before `# TYPE`, the series in the
  // order they first appeared, `users` before `orders` here, and each
  // series' label pairs in the order of the label names.
  // `Registry::render`'s doc comment states the order of the metrics, of
  // their `# HELP` and `# TYPE` lines and of their series. The maintainer
  // confirmed on 2026-11-21 (#328) that the doc comment is the source and
  // that the order is not a promise to users, so no document states it.
  let registry = @metrics.Registry()
  let requests = registry.counter(
    "smock_requests_total",
    help="Requests served.",
    labels=["mock", "stub"],
  )
  requests.labels(["users", "get-user"]).inc()
  requests.labels(["orders", ""]).inc(by=2)
  // Prometheus's guidelines for client libraries: inc(double v) "MUST check
  // that v >= 0", so 0 is allowed, and leaves the counter as it was.
  requests.labels(["orders", ""]).inc(by=0)
  requests.labels(["users", "get-user"]).inc()
  inspect(
    registry.render(),
    content=(
      #|# HELP smock_requests_total Requests served.
      #|# TYPE smock_requests_total counter
      #|smock_requests_total{mock="users",stub="get-user"} 2
      #|smock_requests_total{mock="orders",stub=""} 2
      #|
    ),
  )
}

///|
test "a counter can follow a running total kept elsewhere, and never goes down with it" {
  let registry = @metrics.Registry()
  let cpu = registry
    .counter("process_cpu_seconds_total", help="CPU time.")
    .labels([])
  let out = []
  for total in [12.34, 12.5, 12.4, @double.not_a_number, 13] {
    cpu.advance_to(total)
    out.push(registry.render().split("\n").nth(2).unwrap_or("").to_owned())
  }
  inspect(
    out.join("\n"),
    content=(
      #|process_cpu_seconds_total 12.34
      #|process_cpu_seconds_total 12.5
      #|process_cpu_seconds_total 12.5
      #|process_cpu_seconds_total 12.5
      #|process_cpu_seconds_total 13
    ),
  )
}

///|
test "a gauge can be set, raised and lowered" {
  let registry = @metrics.Registry()
  let entries = registry.gauge(
    "smock_journal_entries",
    help="Journal entries held.",
    labels=["mock"],
  )
  entries.labels(["users"]).set(5)
  entries.labels(["users"]).add(-2)
  entries.labels(["orders"]).add(1.5)
  inspect(
    registry.render(),
    content=(
      #|# HELP smock_journal_entries Journal entries held.
      #|# TYPE smock_journal_entries gauge
      #|smock_journal_entries{mock="users"} 3
      #|smock_journal_entries{mock="orders"} 1.5
      #|
    ),
  )
}

///|
test "a metric without labels has its one series from the start, at 0, and metrics render in the order they were registered" {
  let registry = @metrics.Registry()
  let _ = registry.counter("smock_reloads_total", help="Reloads.")
  let up = registry.gauge("smock_up", help="Whether smock is up.")
  up.labels([]).set(1)
  inspect(
    registry.render(),
    content=(
      #|# HELP smock_reloads_total Reloads.
      #|# TYPE smock_reloads_total counter
      #|smock_reloads_total 0
      #|# HELP smock_up Whether smock is up.
      #|# TYPE smock_up gauge
      #|smock_up 1
      #|
    ),
  )
}

///|
test "a metric with labels renders nothing but its help and type before its first series" {
  let registry = @metrics.Registry()
  let _ = registry.counter("smock_requests_total", help="Requests.", labels=[
    "mock",
  ])
  inspect(
    registry.render(),
    content=(
      #|# HELP smock_requests_total Requests.
      #|# TYPE smock_requests_total counter
      #|
    ),
  )
}

///|
test "a histogram renders cumulative buckets up to +Inf, then the sum and the count, for each label set" {
  // The text format 0.0.4 fixes one order here, the buckets', "in
  // increasing numerical order of their label values". The rest is smock's
  // own choice, which the format leaves free ("Grouping and sorting"): the
  // series in the order they first appeared, so all of `users`' lines
  // before those of `orders`; `_sum` and `_count` after each series'
  // buckets; `# HELP` before `# TYPE`; and each series' label pairs in the
  // order of the label names, `le` last. `Registry::render`'s doc comment
  // states the order of the metrics, of their `# HELP` and `# TYPE` lines,
  // of their series and of a histogram's buckets, `_sum` and `_count`. The
  // maintainer confirmed on 2026-11-21 (#328) that the doc comment is the
  // source and that the order is not a promise to users, so no document
  // states it.
  // The counts and sums come from the text format's "Histograms and
  // summaries": a histogram `x` has a sample `x_bucket` with `{le="y"}` for
  // each bucket, "where `y` is the upper bound of the bucket", one with
  // `{le="+Inf"}` whose value "_must_ be identical to the value of
  // `x_count`", and the samples `x_sum` and `x_count`. Prometheus's metric
  // types page, "Histogram", makes the buckets "cumulative counters",
  // `<basename>_bucket{le="<upper inclusive bound>"}`, so 0.1 counts in the
  // bucket of 0.1, and `_sum` "the total sum of all observed values": for
  // `users`, 0.004 + 0.1 + 0.25 + 3, which is 3.354 as doubles too.
  let registry = @metrics.Registry()
  let latency = registry.histogram(
    "smock_request_duration_seconds",
    help="Time to answer a request.",
    labels=["mock"],
    buckets=[0.005, 0.1, 1],
  )
  latency.labels(["users"]).observe(0.004)
  latency.labels(["users"]).observe(0.1)
  latency.labels(["users"]).observe(0.25)
  latency.labels(["users"]).observe(3)
  latency.labels(["orders"]).observe(0.05)
  inspect(
    registry.render(),
    content=(
      #|# HELP smock_request_duration_seconds Time to answer a request.
      #|# TYPE smock_request_duration_seconds histogram
      #|smock_request_duration_seconds_bucket{mock="users",le="0.005"} 1
      #|smock_request_duration_seconds_bucket{mock="users",le="0.1"} 2
      #|smock_request_duration_seconds_bucket{mock="users",le="1"} 3
      #|smock_request_duration_seconds_bucket{mock="users",le="+Inf"} 4
      #|smock_request_duration_seconds_sum{mock="users"} 3.354
      #|smock_request_duration_seconds_count{mock="users"} 4
      #|smock_request_duration_seconds_bucket{mock="orders",le="0.005"} 0
      #|smock_request_duration_seconds_bucket{mock="orders",le="0.1"} 1
      #|smock_request_duration_seconds_bucket{mock="orders",le="1"} 1
      #|smock_request_duration_seconds_bucket{mock="orders",le="+Inf"} 1
      #|smock_request_duration_seconds_sum{mock="orders"} 0.05
      #|smock_request_duration_seconds_count{mock="orders"} 1
      #|
    ),
  )
}

///|
test "label values escape backslash, double quote and line feed; help text escapes backslash and line feed" {
  let registry = @metrics.Registry()
  let requests = registry.counter(
    "smock_requests_total",
    help="Requests, by Mock\nand Stub ID (C:\\ \"quoted\").",
    labels=["stub"],
  )
  requests.labels(["a\\b \"c\"\nd é"]).inc()
  inspect(
    registry.render(),
    content=(
      #|# HELP smock_requests_total Requests, by Mock\nand Stub ID (C:\\ "quoted").
      #|# TYPE smock_requests_total counter
      #|smock_requests_total{stub="a\\b \"c\"\nd é"} 1
      #|
    ),
  )
}

///|
test "values and bucket bounds are written as the text format reads them, infinities and NaN included" {
  let registry = @metrics.Registry()
  let values = registry.gauge("smock_value", help="A value.", labels=["case"])
  values.labels(["fraction"]).set(0.25)
  values.labels(["negative"]).set(-3)
  values.labels(["large"]).set(1.0e21)
  values.labels(["infinity"]).set(@double.infinity)
  values.labels(["negative infinity"]).set(@double.neg_infinity)
  values.labels(["not a number"]).set(@double.not_a_number)
  let sizes = registry.histogram("smock_size_bytes", help="A size.", buckets=[
    1024, 1.0e7,
  ])
  sizes.labels([]).observe(@double.infinity)
  inspect(
    registry.render(),
    content=(
      #|# HELP smock_value A value.
      #|# TYPE smock_value gauge
      #|smock_value{case="fraction"} 0.25
      #|smock_value{case="negative"} -3
      #|smock_value{case="large"} 1e+21
      #|smock_value{case="infinity"} +Inf
      #|smock_value{case="negative infinity"} -Inf
      #|smock_value{case="not a number"} NaN
      #|# HELP smock_size_bytes A size.
      #|# TYPE smock_size_bytes histogram
      #|smock_size_bytes_bucket{le="1024"} 0
      #|smock_size_bytes_bucket{le="10000000"} 0
      #|smock_size_bytes_bucket{le="+Inf"} 1
      #|smock_size_bytes_sum +Inf
      #|smock_size_bytes_count 1
      #|
    ),
  )
}

///|
test "label values that run together the same way are still different series" {
  let registry = @metrics.Registry()
  let requests = registry.counter("smock_requests_total", help="Requests.", labels=[
    "mock", "stub",
  ])
  for values in [["a,b", "c"], ["a", "b,c"], ["a\u{0}", "b"], ["a", "\u{0}b"]] {
    requests.labels(values).inc()
  }
  inspect(
    registry
    .render()
    .split("\n")
    .filter(line => line.has_prefix("smock_requests_total{"))
    .count(),
    content="4",
  )
}

///|
test "a metric name is a Prometheus metric name: one with a colon, a capital Z or a 0 after the first character" {
  // The Prometheus text exposition format 0.0.4 writes a metric name as an
  // identifier with "the usual Prometheus expression language restrictions",
  // which Prometheus's data model writes as `[a-zA-Z_:][a-zA-Z0-9_:]*`: `:`,
  // as in a recording rule's name, letters up to `Z`, and digits from `0`
  // after the first character. `Registry::counter`, which `gauge` follows:
  // "A name with `:` is accepted, though Prometheus keeps `:` for recording
  // rules", as #278's acceptance criterion asks ("accepted where the format
  // allows them") and the maintainer confirmed on 2026-11-17 (#275). The
  // data model's note is known, and smock does not follow it: "Colons (':')
  // are reserved for user-defined recording rules. They SHOULD NOT be used
  // by exporters or direct instrumentation." Each gauge renders a sample of
  // 0 at once, as Prometheus's guidelines for client libraries ask: "Gauges
  // MUST start at 0" and "Metrics without labels MUST always be
  // initialized". `a0` has its digit as early as the regex allows one, as
  // the second character.
  // The four groups come in the order the gauges were registered, each with
  // `# HELP` before `# TYPE`: smock's own choice, which the text format
  // 0.0.4 leaves free ("Grouping and sorting": the `HELP` and `TYPE` lines
  // come first "in no particular order", and sorting is "preferred but not
  // required"). `Registry::render`'s doc comment states that order. The
  // maintainer confirmed on 2026-11-21 (#328) that the doc comment is the
  // source and that the order is not a promise to users, so no document
  // states it.
  let registry = @metrics.Registry()
  for name in ["job:smock_requests:sum", "smock_A_Z", "smock_0_9", "a0"] {
    let _ = registry.gauge(name, help="A name.")
  }
  inspect(
    registry.render(),
    content=(
      #|# HELP job:smock_requests:sum A name.
      #|# TYPE job:smock_requests:sum gauge
      #|job:smock_requests:sum 0
      #|# HELP smock_A_Z A name.
      #|# TYPE smock_A_Z gauge
      #|smock_A_Z 0
      #|# HELP smock_0_9 A name.
      #|# TYPE smock_0_9 gauge
      #|smock_0_9 0
      #|# HELP a0 A name.
      #|# TYPE a0 gauge
      #|a0 0
      #|
    ),
  )
}

// The label names of a metric are fixed when it is registered. Getting it
// wrong is a mistake in smock's code, not in its input, so it aborts.

///|
/// Prometheus's guidelines for client libraries: `labels()` "takes either
/// a list of the label values or a map from label name to label value",
/// and "Client libraries SHOULD NOT allow users to have different label
/// names for the same metric"; `Counter::labels` takes its values "one for
/// each label name, in order". One value for the label names `mock` and
/// `stub` would give the series other label names than the metric's, so it
/// is refused. client_golang refuses it too: its `WithLabelValues` panics
/// with "expected %d label values but got %d".
test "panic: a series needs one value for each label name" {
  let registry = @metrics.Registry()
  let requests = registry.counter("smock_requests_total", help="Requests.", labels=[
    "mock", "stub",
  ])
  requests.labels(["users"]).inc()
}

///|
test "panic: a metric name can be registered once" {
  let registry = @metrics.Registry()
  let _ = registry.counter("smock_requests_total", help="Requests.")
  let _ = registry.gauge("smock_requests_total", help="Requests.")
}

///|
test "panic: a metric name is a Prometheus metric name" {
  let _ = @metrics.Registry().counter("smock-requests", help="Requests.")
}

///|
/// The text format 0.0.4 writes a metric name unquoted, with "the usual
/// Prometheus expression language restrictions": the data model's
/// `[a-zA-Z_:][a-zA-Z0-9_:]*`, one character at least.
test "panic: a metric name is not empty" {
  let _ = @metrics.Registry().counter("", help="Requests.")
}

///|
/// The data model's `[a-zA-Z_:][a-zA-Z0-9_:]*`: a digit only after the
/// first character.
/// That regex alone no longer decides it: since Prometheus 3.0 the data
/// model says "Metric names MAY use any UTF-8 characters", and only that
/// they "SHOULD match the regex". The text format 0.0.4, which smock serves
/// (`text/plain; version=0.0.4`), decides it: smock writes a name unquoted,
/// as its `metric_name = identifier`, and an `identifier` "carries the
/// usual Prometheus expression language restrictions", those of the regex,
/// so it does not start with a digit.
test "panic: a metric name does not start with a digit" {
  let _ = @metrics.Registry().counter("2xx_requests_total", help="Requests.")
}

///|
test "panic: a label name is a Prometheus label name" {
  let _ = @metrics.Registry().counter("smock_requests", help="Requests.", labels=[
    "stub id",
  ])
}

///|
/// The text format 0.0.4 writes a label name unquoted, with "the usual
/// Prometheus expression language restrictions": the data model's
/// `[a-zA-Z_][a-zA-Z0-9_]*`, which has no `:`, unlike a metric name's.
test "panic: a label name has no colon, which only a metric name may have" {
  let _ = @metrics.Registry().counter("smock_requests", help="Requests.", labels=[
    "mock:stub",
  ])
}

///|
test "panic: le is the bucket label of a histogram" {
  let _ = @metrics.Registry().histogram(
    "smock_size_bytes",
    help="A size.",
    labels=["le"],
    buckets=[1],
  )
}

///|
test "panic: bucket bounds increase" {
  let _ = @metrics.Registry().histogram("smock_size_bytes", help="A size.", buckets=[
    10, 1,
  ])
}

///|
/// The text format 0.0.4: "The buckets of a histogram ... must appear in
/// increasing numerical order of their label values", and two equal bounds
/// would be two buckets with the same `le`.
/// The rule that decides it is the format's "Each line must have a unique
/// combination of a metric name and labels", which two lines
/// `smock_size_bytes_bucket{le="1"}` would break: "increasing" alone could
/// be read to allow equal bounds. client_golang agrees: its bounds "must be
/// sorted in strictly increasing order".
test "panic: bucket bounds increase strictly: two equal bounds abort" {
  let _ = @metrics.Registry().histogram("smock_size_bytes", help="A size.", buckets=[
    1, 1,
  ])
}

///|
/// The text format 0.0.4: "A histogram _must_ have a bucket with
/// `{le="+Inf"}`", which `Registry::histogram` adds last, so a bound of
/// `+Inf` would be a second one, not in increasing order.
test "panic: a bucket bound is not +Inf, the bucket every histogram has last" {
  let _ = @metrics.Registry().histogram("smock_size_bytes", help="A size.", buckets=[
    @double.infinity,
  ])
}

///|
/// NaN is neither below nor above any bound (IEEE 754), so no order of the
/// text format's "increasing numerical order" holds for a bucket of it.
test "panic: a bucket bound is not NaN" {
  let _ = @metrics.Registry().histogram("smock_size_bytes", help="A size.", buckets=[
    @double.not_a_number,
  ])
}

///|
test "panic: the label names of a metric differ" {
  let _ = @metrics.Registry().counter("smock_requests", help="Requests.", labels=[
    "mock", "mock",
  ])
}

///|
test "panic: a counter never goes down" {
  let registry = @metrics.Registry()
  registry
  .counter("smock_requests_total", help="Requests.")
  .labels([])
  .inc(by=-1)
}
