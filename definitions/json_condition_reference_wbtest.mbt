// `JsonCondition::matches` as it was before conditions were read into
// arrays when loaded, with pattern objects added, kept as the oracle for
// the one of today: for any condition value and any body, both must agree.
// The file also checks, with the same random values, what the
// shadowed-Stub warning needs of `JsonCondition`'s equality.

///|
fn reference_contains(actual : Json, expected : Json) -> Bool {
  match (expected, actual) {
    (Object(members), _) if members.length() == 1 &&
      members.get("pattern") is Some(String(source)) =>
      reference_pattern(source, actual)
    (Object(expected), Object(actual)) =>
      expected
      .iter()
      .all(entry => {
        actual.get(entry.0) is Some(value) && reference_contains(value, entry.1)
      })
    (Array(expected), Array(actual)) => {
      if expected.length() != actual.length() {
        return false
      }
      for i, value in expected {
        if !reference_contains(actual[i], value) {
          return false
        }
      }
      true
    }
    (Number(expected, repr=expected_text), Number(actual, repr=actual_text)) =>
      same_number(expected, expected_text, actual, actual_text)
    (String(expected), String(actual)) => expected == actual
    (True, True) | (False, False) | (Null, Null) => true
    _ => false
  }
}

///|
/// Whether the pattern `source` matches the whole of `actual`: a string as
/// it is, a number or a boolean as its JSON text.
fn reference_pattern(source : String, actual : Json) -> Bool {
  let text = match actual {
    String(text) => text
    Number(_) | True | False => actual.stringify()
    _ => return false
  }
  let regex = @re2.compile(source) catch { _ => abort("not a valid pattern") }
  regex.full_match(@utf8.encode(text))
}

///|
/// The `json` condition on `value`, read as a Stub's is.
fn json_condition(value : Json) -> JsonCondition {
  guard request_conditions({ "body": { "json": value } })
    is Ok({ body: Some(Json(condition)), .. }) else {
    abort("not a valid json condition")
  }
  condition
}

///|
/// A random JSON value, `depth` levels deep at most, over few keys and few
/// scalars, so that conditions and bodies often share parts: numbers equal
/// by value but written apart, integers too large for a Double, strings,
/// booleans, null and pattern objects. A `pattern` key gives literal
/// objects that look like pattern objects, and pattern objects too when it
/// is the only key and has a string.
fn random_json(rand : @random.Rand, depth : Int) -> Json {
  let scalars : Array[String] = [
    "1", "1.0", "10e-1", "2", "-0", "0", "12345678901234567890", "12345678901234567891",
    "1e400", "\"a\"", "\"b\"", "\"1\"", "true", "false", "null", "{\"pattern\":\"[0-9]+\"}",
    "{\"pattern\":\"a|true\"}", "{\"pattern\":\"(?s).*\"}", "{\"pattern\":\"1e400|-?0\"}",
  ]
  if depth == 0 || rand.int(limit=3) == 0 {
    return @json.parse(scalars[rand.int(limit=scalars.length())]) catch {
      _ => Json::null()
    }
  }
  if rand.int(limit=2) == 0 {
    let members = Map([])
    for _ in 0..<rand.int(limit=4) {
      members[["a", "b", "c", "pattern"][rand.int(limit=4)]] = random_json(
        rand,
        depth - 1,
      )
    }
    Json::object(members)
  } else {
    Json::array(
      Array::makei(rand.int(limit=3), _ => random_json(rand, depth - 1)),
    )
  }
}

///|
test "a json condition matches the bodies it matched before conditions were read into arrays" {
  let rand = @random.Rand::chacha8(seed=b"smock json condition reference!!")
  let differ = []
  let mut matched = 0
  for _ in 0..<20000 {
    let expected = random_json(rand, 3)
    let condition = json_condition(expected)
    for _ in 0..<5 {
      // Bodies that often extend the condition's value, so that some match.
      let actual = if rand.int(limit=2) == 0 {
        random_json(rand, 3)
      } else {
        grown(expected, rand)
      }
      let want = reference_contains(actual, expected)
      if condition.matches(actual) != want && differ.length() < 5 {
        differ.push((expected, actual))
      }
      if want {
        matched += 1
      }
    }
  }
  debug_inspect(differ, content="[]")
  assert_true(matched > 10000)
}

///|
/// `json` with members added to its objects, at any depth, and now and then
/// a value changed.
fn grown(json : Json, rand : @random.Rand) -> Json {
  if rand.int(limit=10) == 0 {
    return random_json(rand, 2)
  }
  match json {
    Object(members) => {
      let out = Map([])
      for key, value in members {
        out[key] = grown(value, rand)
      }
      if rand.int(limit=2) == 0 {
        out[["c", "d"][rand.int(limit=2)]] = random_json(rand, 1)
      }
      Json::object(out)
    }
    Array(items) => Json::array(items.map(item => grown(item, rand)))
    _ => json
  }
}

///|
/// `json` written another way, with the same value: some numbers as other
/// numbers of their value, and each object's members in reverse order.
fn rewritten(json : Json, rand : @random.Rand) -> Json {
  match json {
    Object(members) => {
      let out = Map([])
      for entry in members.iter().collect().rev() {
        out[entry.0] = rewritten(entry.1, rand)
      }
      Json::object(out)
    }
    Array(items) => Json::array(items.map(item => rewritten(item, rand)))
    Number(_) => {
      let alike : Array[Array[String]] = [
        ["1", "1.0", "10e-1"],
        ["0", "-0", "0.0"],
        ["2", "2.0", "0.2e1"],
        ["1e400", "10E+399"],
      ]
      let text = json.stringify()
      guard alike.iter().find_first(group => group.contains(text))
        is Some(group) else {
        return json
      }
      @json.parse(group[rand.int(limit=group.length())]) catch {
        _ => json
      }
    }
    _ => json
  }
}

///|
/// The shadowed-Stub warning takes a Stub's body condition to cover only an
/// equal one. The numbers drawn here never pair one kept as text with an
/// equal one that is not, such as 12345678901234567890 and
/// 1.2345678901234567890e19. `same_number` is not transitive on such
/// numbers: it compares two kept as text exactly and any other pair as
/// Doubles. So those two conditions are equal, yet a body's
/// 12345678901234567891 meets only the second. That gap has nothing to do
/// with patterns.
test "json conditions that are equal match the same bodies, patterns included, as the shadowed-Stub warning needs" {
  let rand = @random.Rand::chacha8(seed=b"smock json condition equality!!!")
  let differ = []
  let mut equal = 0
  for _ in 0..<10000 {
    // Mostly the same value written another way; now and then a shallow
    // value of its own, equal to it or not.
    let value = random_json(rand, 3)
    let other_value = if rand.int(limit=4) == 0 {
      random_json(rand, 1)
    } else {
      rewritten(value, rand)
    }
    let condition = json_condition(value)
    let other = json_condition(other_value)
    if condition != other {
      continue
    }
    equal += 1
    for _ in 0..<5 {
      let actual = if rand.int(limit=2) == 0 {
        random_json(rand, 3)
      } else {
        grown(value, rand)
      }
      if condition.matches(actual) != other.matches(actual) &&
        differ.length() < 5 {
        differ.push((value, other_value, actual))
      }
    }
  }
  debug_inspect(differ, content="[]")
  assert_true(equal > 7000)
}
