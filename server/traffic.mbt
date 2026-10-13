// The request traffic metrics: the requests served on the plain and TLS
// ports and their latency, by Mock and Stub, and those that matched no
// Stub, by Mock. Their labels are bounded by the Definition files: never a
// path, a Host, a method or a Session.

///|
/// The upper bounds of the latency histogram's buckets, in seconds: from
/// 100 µs, so that sub-millisecond answers are told apart, to 5 minutes,
/// so that long injected delays and Server-Sent Event streams still fall
/// in a bucket of their own.
let latency_buckets : Array[Double] = [
  0.0001, 0.00025, 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5,
  1, 2.5, 5, 10, 30, 60, 120, 300,
]

///|
/// Measures a request's latency on a monotonic clock, which adjustments of
/// the system clock do not move. `@async.now()` is wall-clock milliseconds,
/// too coarse for buckets from 100 µs; core's benchmarking package has the
/// only public monotonic clock.
priv struct Stopwatch {
  /// When it started, in microseconds since `clock_origin`.
  started : Double
}

///|
/// The one timestamp of core's monotonic clock that smock takes, when it
/// starts; every reading is the time since it. Each timestamp the clock
/// gives is an object that is never freed (about 32 bytes with moonc
/// v0.10.14), so taking one per request would grow the process without
/// bound.
let clock_origin : @bench.Timestamp = @bench.monotonic_clock_start()

///|
/// A stopwatch that starts now.
fn Stopwatch::start() -> Stopwatch {
  { started: @bench.monotonic_clock_end(clock_origin), }
}

///|
/// The seconds since the stopwatch started.
fn Stopwatch::seconds(self : Stopwatch) -> Double {
  (@bench.monotonic_clock_end(clock_origin) - self.started) / 1.0e6
}

///|
/// The request traffic metrics of one process.
priv struct Traffic {
  /// `smock_requests_total`, by Mock and Stub.
  requests : @metrics.Counter
  /// `smock_request_duration_seconds`, by Mock and Stub.
  latency : @metrics.Histogram
  /// `smock_unmatched_requests_total`, by Mock.
  unmatched : @metrics.Counter
  /// The series of `requests` and `latency`, by Mock label and then by Stub
  /// label, kept so that recording a request builds no key.
  series : Map[
    String,
    Map[String, (@metrics.CounterSeries, @metrics.HistogramSeries)],
  ]
  /// The series of `unmatched`, by Mock label.
  unmatched_series : Map[String, @metrics.CounterSeries]
}

///|
/// Registers the request traffic metrics in `metrics`.
fn Traffic::register(metrics : @metrics.Registry) -> Traffic {
  {
    requests: metrics.counter(
      "smock_requests_total",
      help="Requests served on the plain and TLS ports, by the Mock that answered (mock=\"\" for none) and the Stub that matched: its ID for a Stub from a Definition file, stub=\"ephemeral\" for every Ephemeral Stub, stub=\"\" for none. Requests the HTTP/1.1 codec rejects (400, 413, 431, 501, 505) count with mock=\"\" and stub=\"\".",
      labels=["mock", "stub"],
    ),
    latency: metrics.histogram(
      "smock_request_duration_seconds",
      help="Time from a request being read in full (for a request the HTTP/1.1 codec rejects, from the read that brought what it rejects) to the last byte of its response being written, injected delays and Server-Sent Event streams included, in seconds, labelled as smock_requests_total.",
      labels=["mock", "stub"],
      buckets=latency_buckets,
    ),
    unmatched: metrics.counter(
      "smock_unmatched_requests_total",
      help="Requests served on the plain and TLS ports that matched no Stub, by the Mock that answered them (mock=\"\" for a Host no Mock answers). Requests the HTTP/1.1 codec rejects are not among them.",
      labels=["mock"],
    ),
    series: Map([]),
    unmatched_series: Map([]),
  }
}

///|
/// Counts a request the engine decided `outcome` for, which took `seconds`
/// from being read in full to the last byte of its response.
fn Traffic::record(
  self : Traffic,
  outcome : @engine.Outcome,
  seconds : Double,
) -> Unit {
  let mock = match outcome.resolution {
    ByHost(name) | ViaDefault(name) => name
    NoMock => ""
  }
  let stub = match outcome.matched {
    Some(FromFile(id)) => id
    Some(Ephemeral(_)) => "ephemeral"
    None => ""
  }
  self.count(mock, stub, seconds)
  if outcome.matched is None {
    let unmatched = match self.unmatched_series.get(mock) {
      Some(series) => series
      None => {
        let series = self.unmatched.labels([mock])
        self.unmatched_series[mock] = series
        series
      }
    }
    unmatched.inc()
  }
}

///|
/// Counts bytes the HTTP/1.1 codec rejected as a request, with `mock=""`
/// and `stub=""`, which took `seconds` from the read that brought them to
/// the last byte of the error response. They are not an unmatched request:
/// no Mock or Stub was tried.
fn Traffic::record_rejected(self : Traffic, seconds : Double) -> Unit {
  self.count("", "", seconds)
}

///|
/// Counts a request with the labels `mock` and `stub` that took `seconds`.
fn Traffic::count(
  self : Traffic,
  mock : String,
  stub : String,
  seconds : Double,
) -> Unit {
  let by_stub = match self.series.get(mock) {
    Some(by_stub) => by_stub
    None => {
      let by_stub = Map([])
      self.series[mock] = by_stub
      by_stub
    }
  }
  let (requests, latency) = match by_stub.get(stub) {
    Some(series) => series
    None => {
      let series = (
        self.requests.labels([mock, stub]),
        self.latency.labels([mock, stub]),
      )
      by_stub[stub] = series
      series
    }
  }
  requests.inc()
  latency.observe(seconds)
}
