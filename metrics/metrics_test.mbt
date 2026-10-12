///|
test "a counter renders its help, its type and one sample per label set, in the order the sets first appeared" {
  let registry = @metrics.Registry()
  let requests = registry.counter(
    "smock_requests_total",
    help="Requests served.",
    labels=["mock", "stub"],
  )
  requests.labels(["users", "get-user"]).inc()
  requests.labels(["orders", ""]).inc(by=2)
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

// The label names of a metric are fixed when it is registered. Getting it
// wrong is a mistake in smock's code, not in its input, so it aborts.

///|
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
test "panic: a label name is a Prometheus label name" {
  let _ = @metrics.Registry().counter("smock_requests", help="Requests.", labels=[
    "stub id",
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
