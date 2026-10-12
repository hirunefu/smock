// Seam 1 tests of Session parsing: the Session key a request carries, by
// default in the `smock-session` member of its W3C `baggage` header.

///|
/// The Session of a request with `headers`, with the default settings: the
/// `smock-session` member of `baggage`.
fn session(headers : Array[(String, String)]) -> String {
  match
    @engine.session_of(headers, header="baggage", member_name="smock-session") {
    Some(key) => "Some(\{key.escape()})"
    None => "None"
  }
}

///|
test "the Session key is the value of the smock-session member of the baggage header" {
  inspect(
    session([
      ("Host", "users.example.com"),
      ("baggage", "smock-session=checkout-test-42"),
    ]),
    content=(
      #|Some("checkout-test-42")
    ),
  )
}

///|
/// Each case's name and the Session of a request with its headers, one
/// per line.
fn sessions(cases : Array[(String, Array[(String, String)])]) -> String {
  cases.map(case => "\{case.0}: \{session(case.1)}").join("\n")
}

///|
test "baggage is parsed as W3C Baggage: headers combined, members split on commas, properties ignored, values trimmed and percent-decoded" {
  inspect(
    sessions([
      (
        "among other members",
        [("baggage", "userId=alice,smock-session=test-a,isProduction=false")],
      ),
      (
        "in a later baggage header",
        [("baggage", "userId=alice"), ("Baggage", "smock-session=test-b")],
      ),
      (
        "with properties",
        [("baggage", "smock-session=test-c;ttl=60;sampled,userId=alice")],
      ),
      (
        "with whitespace around members, keys and values",
        [("baggage", " userId = alice ,\tsmock-session =  test-d \t; p = 1 ")],
      ),
      ("percent-encoded", [("baggage", "smock-session=t%C3%A9st%2Ce%3B%20f")]),
      (
        "percent-encoded bytes that are not UTF-8",
        [("baggage", "smock-session=a%FFb")],
      ),
      ("with = in the value", [("baggage", "smock-session=k=v==")]),
      (
        "with empty list members",
        [("baggage", ",, smock-session=test-e ,"), ("baggage", "")],
      ),
      ("the header name in another case", [("BAGGAGE", "smock-session=test-f")]),
    ]),
    content=(
      #|among other members: Some("test-a")
      #|in a later baggage header: Some("test-b")
      #|with properties: Some("test-c")
      #|with whitespace around members, keys and values: Some("test-d")
      #|percent-encoded: Some("tést,e; f")
      #|percent-encoded bytes that are not UTF-8: Some("a�b")
      #|with = in the value: Some("k=v==")
      #|with empty list members: Some("test-e")
      #|the header name in another case: Some("test-f")
    ),
  )
}

///|
test "the first smock-session member wins, across members and headers, even when its value is empty" {
  inspect(
    sessions([
      ("twice in one header", [("baggage", "smock-session=a,smock-session=b")]),
      (
        "once in each of two headers",
        [("baggage", "smock-session=a"), ("baggage", "smock-session=b")],
      ),
      ("first empty", [("baggage", "smock-session=,smock-session=b")]),
      ("first blank", [("baggage", "smock-session= \t;p,smock-session=b")]),
    ]),
    content=(
      #|twice in one header: Some("a")
      #|once in each of two headers: Some("a")
      #|first empty: None
      #|first blank: None
    ),
  )
}

///|
test "a request has no Session without the member, with an empty value or with a baggage header that is not W3C Baggage" {
  inspect(
    sessions([
      ("no headers", []),
      ("no baggage header", [("Host", "users.example.com")]),
      ("an empty baggage header", [("baggage", "")]),
      ("another member only", [("baggage", "userId=alice")]),
      ("the member's name in another case", [("baggage", "Smock-Session=a")]),
      (
        "the member's name as a prefix",
        [("baggage", "smock-session-id=a,x-smock-session=b")],
      ),
      ("the member only in a property", [("baggage", "k=v;smock-session=a")]),
      ("an empty value", [("baggage", "smock-session=")]),
      ("a member without =", [("baggage", "smock-session=a,userId")]),
      ("an empty key", [("baggage", "=x,smock-session=a")]),
      ("a key that is not a token", [("baggage", "user id=x,smock-session=a")]),
      ("a space inside the value", [("baggage", "smock-session=a b")]),
      ("a quote in the value", [("baggage", "smock-session=\"a\"")]),
      ("a backslash in the value", [("baggage", "smock-session=a\\b")]),
      ("a non-ASCII character in the value", [("baggage", "smock-session=té")]),
      (
        "a control character in the value",
        [("baggage", "smock-session=a\u{1}")],
      ),
      ("a % without two hex digits", [("baggage", "smock-session=a%2")]),
      ("a % before a non-hex digit", [("baggage", "smock-session=a%zz")]),
      (
        "a malformed member after the Session",
        [("baggage", "smock-session=a"), ("baggage", "userId")],
      ),
    ]),
    content=(
      #|no headers: None
      #|no baggage header: None
      #|an empty baggage header: None
      #|another member only: None
      #|the member's name in another case: None
      #|the member's name as a prefix: None
      #|the member only in a property: None
      #|an empty value: None
      #|a member without =: None
      #|an empty key: None
      #|a key that is not a token: None
      #|a space inside the value: None
      #|a quote in the value: None
      #|a backslash in the value: None
      #|a non-ASCII character in the value: None
      #|a control character in the value: None
      #|a % without two hex digits: None
      #|a % before a non-hex digit: None
      #|a malformed member after the Session: None
    ),
  )
}

///|
test "the header and the member are settings: another header or member carries the Session" {
  let headers = [
    ("baggage", "smock-session=from-baggage"),
    ("X-Test-Context", "run=7, test-id=from-context"),
  ]
  let out = [
    ("baggage", "smock-session"),
    ("x-test-context", "test-id"),
    ("X-TEST-CONTEXT", "run"),
    ("baggage", "test-id"),
  ].map(setting => {
    let (header, member_name) = setting
    let key = @engine.session_of(headers, header~, member_name~)
    "\{header} \{member_name}: \{@debug.to_string(key)}"
  })
  inspect(
    out.join("\n"),
    content=(
      #|baggage smock-session: Some("from-baggage")
      #|x-test-context test-id: Some("from-context")
      #|X-TEST-CONTEXT run: Some("7")
      #|baggage test-id: None
    ),
  )
}
