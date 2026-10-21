// The time helpers, `now` and `nowMillis`. They read the time the request
// was received at, never the clock while rendering; in an event, plus the
// delays of the events up to and including it.

///|
/// A time helper, with the seconds it was checked to add.
priv enum TimeHelper {
  /// `now(s)`: seconds to add.
  Now(Int64)
  /// `nowMillis(s)`: seconds to add.
  NowMillis(Int64)
}

///|
/// The time helper that `site` calls, checked: its one argument, if it has
/// one, is an integer literal. `None` when it calls a helper of another
/// family.
fn time_helper(site : CallSite) -> Helper? raise Syntax {
  let helper = match site.name {
    "now" => Now(site.seconds())
    "nowMillis" => NowMillis(site.seconds())
    _ => return None
  }
  Some(Time(helper))
}

///|
/// The seconds a time helper adds: 0 without an argument, or its one
/// argument, an integer literal.
fn CallSite::seconds(self : CallSite) -> Int64 raise Syntax {
  match self.args.length() {
    0 => 0L
    1 => self.integer(0, -max_integer, max_integer)
    n =>
      raise Syntax(self.start, "\{self.name}() takes 0 or 1 argument, not \{n}")
  }
}

///|
/// What the time helper `helper` gives, inserted at `at`.
fn Context::time(
  self : Context,
  helper : TimeHelper,
  at : String,
) -> Json raise RenderError {
  match helper {
    Now(seconds) => {
      let ms = self.now + self.elapsed + seconds * 1000L
      // From 0000-01-01 to 9999-12-31, which RFC 3339 can write.
      if ms < -62_167_219_200_000L || ms > 253_402_300_799_999L {
        raise RenderError(
          at~,
          message="now(): the time is outside the years 0 to 9999",
        )
      }
      Json::string(@log.format_time(ms))
    }
    NowMillis(seconds) =>
      Json::number((self.now + self.elapsed + seconds * 1000L).to_double())
  }
}
