// The metrics of the bound on per-Session state: the bytes it counts and
// the writes it refused. They are read from the engine when /metrics is
// scraped, as the Journal's are, so a write costs nothing for them.

///|
/// The metrics of the bound on per-Session state. They carry no label: no
/// Session, Mock or path.
priv struct StateMetrics {
  /// `smock_state_bytes`.
  bytes : @metrics.GaugeSeries
  /// `smock_state_writes_refused_total`.
  refused : @metrics.CounterSeries
  /// The refusals the counter has counted so far.
  mut counted : Int64
}

///|
/// Registers the metrics of the bound on per-Session state in `metrics`.
fn StateMetrics::register(metrics : @metrics.Registry) -> StateMetrics {
  let bytes = metrics
    .gauge(
      "smock_state_bytes",
      help="Bytes the per-Session state takes, as the bound on it counts them (--state-max-bytes).",
      labels=[],
    )
    .labels([])
  let refused = metrics
    .counter(
      "smock_state_writes_refused_total",
      help="Requests and Admin API sets whose writes to per-Session state were refused with 507, since they would pass its bound (--state-max-bytes).",
      labels=[],
    )
    .labels([])
  refused.inc(by=0)
  { bytes, refused, counted: 0L, }
}

///|
/// Brings the metrics up to date with `stats`, what the bound counts now.
fn StateMetrics::update(
  self : StateMetrics,
  stats : @engine.StateStats,
) -> Unit {
  self.bytes.set(stats.bytes.to_double())
  if stats.writes_refused > self.counted {
    self.refused.inc(by=(stats.writes_refused - self.counted).to_double())
    self.counted = stats.writes_refused
  }
}
