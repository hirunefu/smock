// Reloading the Definition files while smock serves: on each check of the
// watched definitions directory, read it whole, validate it, and swap the
// new snapshot in, or keep the current one and report why.

///|
/// Reloads the definitions directory into the engine, logs each reload and
/// counts it in the reload metric.
priv struct Reloader {
  dir : String
  body_file_dir : String
  engine : @engine.Engine
  logger : @log.Logger
  /// `smock_definition_reloads_total`, by result.
  reloads : @metrics.Counter
  /// The digest of the set read last, at startup or by the last reload,
  /// and the problems reading it.
  mut last_read : (String, Array[@definitions.Diagnostic])
  /// What follows each reload that swaps in a new set, such as the TLS
  /// port's warnings about Mocks it has certificates for, or a new
  /// self-signed certificate for new Hosts.
  after_swap : () -> Unit
}

///|
/// Registers the reload metric in `metrics`, with a series for each result.
fn register_reload_metric(metrics : @metrics.Registry) -> @metrics.Counter {
  let reloads = metrics.counter(
    "smock_definition_reloads_total",
    help="Reloads of the Definition files, by result: swapped (the new definition set is served), unchanged (it had the digest served) or failed (it was invalid, and the previous one is still served).",
    labels=["result"],
  )
  for outcome in @engine.ReloadOutcome::all() {
    reloads.labels([outcome.name()]).inc(by=0)
  }
  reloads
}

///|
/// Reloads on each check of `watch`, the watch of the definitions
/// directory, until the task is cancelled. Logs a warning when the
/// directory exists but cannot be watched, and is only polled. A check that
/// fails in an unforeseen way is logged, and the next one tries again: it
/// never stops smock.
async fn Reloader::run(self : Reloader, watch : @watch.Watch) -> Unit {
  let check = async fn(check : @watch.Check) {
    self.check(check) catch {
      err =>
        self.logger.error("definitions reload failed", fields={
          "error": Json::string(err.to_string()),
        })
    }
  }
  watch.run(check, on_error=err => {
    self.logger.warn(
      "cannot watch the definitions directory, only polling it",
      fields={
        "dir": Json::string(self.dir),
        "error": Json::string(err.to_string()),
      },
    )
  })
}

///|
/// Reads the definitions directory and reloads the engine from it.
///
/// A poll reloads only when the set read differs from the one read last:
/// it looks for a change that no event reported, so that a set that stays
/// the same, valid or not, does not log a reload every poll interval. A
/// check after events always reloads.
async fn Reloader::check(self : Reloader, check : @watch.Check) -> Unit {
  let (set, problems) = @defdir.read(self.dir, body_file_dir=self.body_file_dir)
  let read = (set.digest(), problems)
  if check is Poll && read == self.last_read {
    return
  }
  self.last_read = read
  let result = self.engine.reload(set, read_problems=problems, at=@async.now())
  self.reloads.labels([result.result.name()]).inc()
  match result.result {
    Swapped | Unchanged => {
      self.logger.info("definitions reloaded", fields={
        "result": Json::string(result.result.name()),
        "oldDigest": Json::string(result.old_digest),
        "newDigest": Json::string(result.new_digest),
      })
      // Nothing between the swap and here waits, so no connection is
      // accepted in between with a certificate for the previous Hosts.
      if result.result is Swapped {
        (self.after_swap)()
      }
    }
    Failed =>
      self.logger.error("definitions reload failed", fields={
        "result": Json::string(result.result.name()),
        "digest": Json::string(result.new_digest),
        "errors": diagnostics_json(result.errors),
      })
  }
}

///|
/// Problems in a definition set as JSON: `{file, pointer, message}` each.
fn diagnostics_json(diagnostics : Array[@definitions.Diagnostic]) -> Json {
  Json::array(
    diagnostics.map(diagnostic => {
      "file": Json::string(diagnostic.file),
      "pointer": Json::string(diagnostic.pointer),
      "message": Json::string(diagnostic.message),
    }),
  )
}
