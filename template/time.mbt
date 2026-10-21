// The time helpers, `now` and `nowMillis`, and the date helpers,
// `dateFormat` and `dateTimeShift`. The time helpers read the time the
// request was received at, never the clock while rendering; in an event,
// plus the delays of the events up to and including it. The date helpers
// read a date from any expression; what is not a date is missing. Formats,
// offsets and durations are literals, read when the template is parsed
// (dates.mbt).

///|
/// A time or date helper, with the literal arguments it was checked to
/// take.
priv enum TimeHelper {
  /// `now(s)`: seconds to add.
  Now(Int64)
  /// `nowMillis(s)`: seconds to add.
  NowMillis(Int64)
  /// `now(format)`: the format, read.
  NowFormatted(Array[DatePart])
  /// `dateFormat(date, format, offset?)`: the format, read, and the offset
  /// in minutes.
  DateFormatted(Array[DatePart], Int)
  /// `dateTimeShift(date, duration)`: the duration, read.
  DateShifted(Shift)
}

///|
/// The time or date helper that `site` calls, checked: the seconds of
/// `now` and `nowMillis` are integer literals, and formats, offsets and
/// durations are string literals, read. `None` when it calls a helper of
/// another family.
fn time_helper(site : CallSite) -> Helper? raise Syntax {
  let helper = match site.name {
    "now" =>
      match site.args {
        [(_, Literal(String(_)))] => NowFormatted(site.format(0))
        [(at, _)] => {
          let seconds = site.seconds() catch {
            _ =>
              raise Syntax(
                at,
                "now(): argument 1 must be a format, a string literal such as 'yyyy-MM-dd', or seconds, an integer literal from -\{max_integer} to \{max_integer}",
              )
          }
          Now(seconds)
        }
        _ => Now(site.seconds())
      }
    "nowMillis" => NowMillis(site.seconds())
    "dateFormat" => {
      site.count_between(least=2, most=3)
      site.check_kind(0, Date)
      let format = site.format(1)
      DateFormatted(
        format,
        if site.args.length() == 3 {
          site.offset(2)
        } else {
          0
        },
      )
    }
    "dateTimeShift" => {
      site.count(2)
      site.check_kind(0, Date)
      DateShifted(site.shift(1))
    }
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
/// What the time helper `helper` gives for the values of its arguments,
/// `values`, inserted at `at`: `None` when a date argument is not a date.
fn Context::time(
  self : Context,
  helper : TimeHelper,
  values : Array[Json],
  at : String,
) -> Json? raise RenderError {
  let json = match helper {
    Now(seconds) => {
      let ms = self.now + self.elapsed + seconds * 1000L
      check_years("now", ms, at)
      Json::string(@log.format_time(ms))
    }
    NowMillis(seconds) =>
      Json::number((self.now + self.elapsed + seconds * 1000L).to_double())
    NowFormatted(format) =>
      Json::string(written_date(format, self.now + self.elapsed, 0, "now", at))
    DateFormatted(format, offset) => {
      guard date_of(values[0]) is Some(ms) else { return None }
      check_years("dateFormat", ms, at)
      Json::string(written_date(format, ms, offset, "dateFormat", at))
    }
    DateShifted(shift) => {
      guard date_of(values[0]) is Some(ms) else { return None }
      check_years("dateTimeShift", ms, at)
      guard shifted(ms, shift) is Some(result) else {
        raise outside_years("dateTimeShift", at)
      }
      Json::string(@log.format_time(result))
    }
  }
  Some(json)
}

///|
/// Argument `k`, counted from 0, which must be a date format: a string
/// literal, read.
fn CallSite::format(self : CallSite, k : Int) -> Array[DatePart] raise Syntax {
  let (at, arg) = self.args[k]
  let wanted = "\{self.name}(): argument \{k + 1} must be a format, a string literal such as 'yyyy-MM-dd'"
  match arg {
    Literal(String(format)) =>
      match date_format(format) {
        Ok(parts) => parts
        Err(problem) => raise Syntax(at, "\{self.name}(): \{problem}")
      }
    Literal(json) => raise Syntax(at, "\{wanted}, not \{described(json)}")
    _ => raise Syntax(at, wanted)
  }
}

///|
/// Argument `k`, counted from 0, which must be an offset: a string
/// literal, read as minutes.
fn CallSite::offset(self : CallSite, k : Int) -> Int raise Syntax {
  let (at, arg) = self.args[k]
  let wanted = "\{self.name}(): argument \{k + 1} must be an offset, a string literal: 'Z', or '+HH:MM' or '-HH:MM' with HH up to 23 and MM up to 59"
  match arg {
    Literal(String(text)) if offset_of(text) is Some(minutes) => minutes
    Literal(json) => raise Syntax(at, "\{wanted}, not \{described(json)}")
    _ => raise Syntax(at, wanted)
  }
}

///|
/// Argument `k`, counted from 0, which must be an ISO 8601 duration: a
/// string literal, read.
fn CallSite::shift(self : CallSite, k : Int) -> Shift raise Syntax {
  let (at, arg) = self.args[k]
  let wanted = "\{self.name}(): argument \{k + 1} must be a duration, a string literal such as 'P1M', '-P2D' or 'PT90M'"
  match arg {
    Literal(String(text)) =>
      match shift_of(text) {
        Ok(shift) => shift
        Err(Some(problem)) => raise Syntax(at, "\{self.name}(): \{problem}")
        Err(None) => raise Syntax(at, "\{wanted}, not \{text.escape()}")
      }
    Literal(json) => raise Syntax(at, "\{wanted}, not \{described(json)}")
    _ => raise Syntax(at, wanted)
  }
}
