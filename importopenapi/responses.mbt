///|
/// A key of a Responses Object.
priv enum ResponseKey {
  /// An explicit status code from 100 to 599, such as `404`.
  Code(Int)
  /// A range from `1XX` to `5XX`, by its first digit.
  Range(Int)
  Default
  /// An `x-` extension, which is ignored.
  Extension
  /// Anything else, which is left out with a warning.
  Malformed
}

///|
/// What a response key is.
fn response_key(key : String) -> ResponseKey {
  if key == "default" {
    return Default
  }
  if key.has_prefix("x-") {
    return Extension
  }
  match key.to_array() {
    [first, 'X', 'X'] if first >= '1' && first <= '5' =>
      Range(first.to_int() - '0'.to_int())
    [a, b, c] if is_digits(key) => {
      let code = (a.to_int() - '0'.to_int()) * 100 +
        (b.to_int() - '0'.to_int()) * 10 +
        (c.to_int() - '0'.to_int())
      if code >= 100 && code <= 599 {
        Code(code)
      } else {
        Malformed
      }
    }
    _ => Malformed
  }
}

///|
/// Whether `key` is an informational response, which smock cannot answer:
/// its statuses are from 200 to 599.
fn ResponseKey::is_informational(self : ResponseKey) -> Bool {
  match self {
    Code(code) => code < 200
    Range(digit) => digit == 1
    _ => false
  }
}

///|
/// A response an operation answers: its key as the document writes it, and
/// the status it answers with.
priv struct Response {
  key : String
  status : Int
  /// Whether it is the main response, which a request gets without
  /// `Smock-Status`. A request gets any other one with `Smock-Status: <key>`.
  main : Bool
  /// What it answers with besides its status.
  answers : Answers
}

///|
/// The main response among `keys`: the lowest explicit 2xx code, then
/// `2XX`; else `default`; else the lowest explicit code from 300 to 599,
/// then `3XX`, `4XX` and `5XX`. An explicit code answers itself, `default`
/// answers 200, and a range its first code. `None` when there is none.
fn main_of(keys : Array[(String, ResponseKey)]) -> Response? {
  let mut lowest_success : (String, Int)? = None
  let mut lowest_other : (String, Int)? = None
  let ranges : Array[String?] = [None, None, None, None, None, None]
  let mut default = None
  for entry in keys {
    match entry.1 {
      Code(code) if code >= 200 && code < 300 =>
        if !(lowest_success is Some((_, lowest)) && lowest <= code) {
          lowest_success = Some((entry.0, code))
        }
      Code(code) if code >= 300 =>
        if !(lowest_other is Some((_, lowest)) && lowest <= code) {
          lowest_other = Some((entry.0, code))
        }
      Range(digit) => ranges[digit] = Some(entry.0)
      Default => default = Some(entry.0)
      _ => ()
    }
  }
  if lowest_success is Some((key, status)) {
    return Some({ key, status, main: true, answers: no_answers(), })
  }
  if ranges[2] is Some(key) {
    return Some({ key, status: 200, main: true, answers: no_answers(), })
  }
  if default is Some(key) {
    return Some({ key, status: 200, main: true, answers: no_answers(), })
  }
  if lowest_other is Some((key, status)) {
    return Some({ key, status, main: true, answers: no_answers(), })
  }
  for digit in 3..<=5 {
    if ranges[digit] is Some(key) {
      return Some({
        key,
        status: digit * 100,
        main: true,
        answers: no_answers(),
      })
    }
  }
  None
}

///|
/// Reads the responses of the operation at `pointer`, for the method
/// `meth`, and returns those it answers, with what each sends: the other
/// responses, in the order the document writes them, then the main one.
/// `None` when the operation is left out or its responses cannot be read.
/// An explicit code answers itself, a range its first code, and
/// `default`, when it is not the main response, 500. Problems come in the
/// order of the responses.
fn Conversion::responses(
  self : Conversion,
  pointer : Place,
  meth : String,
  operation : Map[String, Json],
) -> Array[Response]? {
  let responses_pointer = pointer.child("responses")
  let responses = match operation.get("responses") {
    None => return self.no_responses(pointer)
    Some(Object(responses)) => responses
    Some(_) => {
      self.error_at(responses_pointer, "must be an object")
      return None
    }
  }
  let keys = []
  for key, _ in responses {
    keys.push((key, response_key(key)))
  }
  let main = main_of(keys)
  let answered = []
  let mut main_answers = no_answers()
  for entry in keys {
    let (key, kind) = entry
    let response_pointer = responses_pointer.child(key)
    let status = match kind {
      Extension => continue
      Malformed => {
        self.warning_at(
          response_pointer, "left out: a response key is a status code from 100 to 599, a range from 1XX to 5XX, default or an x- extension",
        )
        continue
      }
      Code(code) if code >= 200 => code
      Range(digit) if digit >= 2 => digit * 100
      Default => 500
      // 1XX, or an explicit code from 100 to 199.
      _ => {
        if main is Some(_) {
          self.warning_at(
            response_pointer, "left out: smock answers with a status from 200 to 599",
          )
        }
        continue
      }
    }
    // A response that is not informational makes a main one.
    guard main is Some(main) else { continue }
    let is_main = key == main.key
    let answers = self.response_parts(
      response_pointer,
      responses.get(key).unwrap_or(Json::null()),
      status=if is_main { main.status } else { status },
      meth~,
    )
    if is_main {
      main_answers = answers
    } else {
      answered.push({ key, status, main: false, answers, })
    }
  }
  match main {
    Some(main) => {
      answered.push({ ..main, answers: main_answers, })
      Some(answered)
    }
    None if keys.iter().any(entry => entry.1.is_informational()) => {
      self.warning_at(
        responses_pointer, "left out: the operation has only 1xx responses, and smock answers with a status from 200 to 599",
      )
      None
    }
    None => self.no_responses(responses_pointer)
  }
}

///|
/// The responses of an operation that has none, after a warning at `at`:
/// one main 200 with an empty body.
fn Conversion::no_responses(self : Conversion, at : Place) -> Array[Response]? {
  self.warning_at(
    at, "has no responses: the operation answers 200 with an empty body",
  )
  Some([{ key: "200", status: 200, main: true, answers: no_answers(), }])
}
