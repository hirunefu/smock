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
