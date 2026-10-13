// `JsonCondition::matches` as it was before conditions were read into
// arrays when loaded, kept as the oracle for the one of today: for any
// condition value and any body, both must agree.

///|
fn reference_contains(actual : Json, expected : Json) -> Bool {
  match (expected, actual) {
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
/// A random JSON value, `depth` levels deep at most, over few keys and few
/// scalars, so that conditions and bodies often share parts: numbers equal
/// by value but written apart, integers too large for a Double, strings,
/// booleans and null.
fn random_json(rand : @random.Rand, depth : Int) -> Json {
  let scalars : Array[String] = [
    "1", "1.0", "10e-1", "2", "-0", "0", "12345678901234567890", "12345678901234567891",
    "1e400", "\"a\"", "\"b\"", "\"1\"", "true", "false", "null",
  ]
  if depth == 0 || rand.int(limit=3) == 0 {
    return @json.parse(scalars[rand.int(limit=scalars.length())]) catch {
      _ => Json::null()
    }
  }
  if rand.int(limit=2) == 0 {
    let members = Map([])
    for _ in 0..<rand.int(limit=4) {
      members[["a", "b", "c"][rand.int(limit=3)]] = random_json(rand, depth - 1)
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
    let condition = JsonCondition::new(expected)
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
