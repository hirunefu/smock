// Where a smock process is in its life, as the probes on the admin port
// report it to Kubernetes: starting, serving or draining after SIGTERM.

///|
/// Where the process is in its life.
priv enum Phase {
  /// From startup until the plain and TLS ports listen.
  Starting
  /// The plain and TLS ports serve the Mocks.
  Serving
  /// From SIGTERM until exit: the listeners close, and the connections
  /// still open finish or are cut.
  Draining
}

///|
/// The life of one smock process.
priv struct Lifecycle {
  mut phase : Phase
  /// The engine, once the first definition set has loaded.
  mut engine : @engine.Engine?
  /// Signalled when the drain starts.
  draining : @async.CondVar
}

///|
fn Lifecycle::new() -> Lifecycle {
  { phase: Starting, engine: None, draining: @async.CondVar::Cond(), }
}

///|
/// Marks the first definition set as loaded into `engine`: startup is
/// complete.
fn Lifecycle::started(self : Lifecycle, engine : @engine.Engine) -> Unit {
  self.engine = Some(engine)
}

///|
/// Marks the plain and TLS ports as serving, unless smock already drains.
fn Lifecycle::serving(self : Lifecycle) -> Unit {
  if self.phase is Starting {
    self.phase = Serving
  }
}

///|
/// Starts the drain, from any phase: readiness fails from now on.
fn Lifecycle::drain(self : Lifecycle) -> Unit {
  self.phase = Draining
  self.draining.broadcast()
}

///|
/// Whether smock drains.
fn Lifecycle::is_draining(self : Lifecycle) -> Bool {
  self.phase is Draining
}

///|
/// Waits until the drain starts.
async fn Lifecycle::wait_for_drain(self : Lifecycle) -> Unit {
  while !self.is_draining() {
    self.draining.wait()
  }
}
