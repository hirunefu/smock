// Seam 1 tests of the Admin API operations on Variables: listing the
// calling Session's Variables of a Mock, and setting and deleting one, each
// within the bound on per-Session state.

///|
/// The calling Session's Variables of `mock` as the engine lists them, as
/// a JSON object, or the error.
fn Harness::variables(
  self : Harness,
  mock : String,
  session : String?,
) -> String {
  let variables = self.engine.list_variables(mock~, session~) catch {
    err => return @debug.to_string(err)
  }
  Json::object(variables).stringify()
}

///|
test "list gives the calling Session's Variables of the Mock, those of no other Session" {
  let h = harness([who_logged_in])
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  step("test-a lists", h.variables("shop", Some("test-a")))
  step(
    "test-a logs in as ann",
    reply(h.send("POST", "/login", body="{\"user\":\"ann\"}", session="test-a")),
  )
  step("test-a lists", h.variables("shop", Some("test-a")))
  step("test-b lists", h.variables("shop", Some("test-b")))
  step("no Session lists", h.variables("shop", None))
  step("an unknown Mock", h.variables("nowhere", Some("test-a")))
  inspect(
    out.join("\n"),
    content=(
      #|test-a lists: {}
      #|test-a logs in as ann: 200 {"user":"ann","previous":null}
      #|test-a lists: {"previous":null,"user":"ann"}
      #|test-b lists: {}
      #|no Session lists: {}
      #|an unknown Mock: UnknownMock("nowhere")
    ),
  )
}

///|
/// Sets the Variable `name` of `mock` for `session` to `value`, given as
/// JSON text: `set`, or the error.
fn Harness::set_variable(
  self : Harness,
  mock : String,
  session : String?,
  name : String,
  value : String,
) -> String {
  self.engine.set_variable(mock~, session~, name~, @json.parse(value)) catch {
    err => return @debug.to_string(err)
  }
  "set"
}

///|
test "set writes one Variable for the calling Session, which its requests then read, and replaces the value it had" {
  let h = harness([who_logged_in])
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  step(
    "test-a sets user",
    h.set_variable("shop", Some("test-a"), "user", "\"ann\""),
  )
  step("test-a GET /me", reply(h.send("GET", "/me", session="test-a")))
  step("test-b GET /me", reply(h.send("GET", "/me", session="test-b")))
  step("no Session GET /me", reply(h.send("GET", "/me")))
  step(
    "test-a logs in as bob",
    reply(h.send("POST", "/login", body="{\"user\":\"bob\"}", session="test-a")),
  )
  step(
    "test-a sets user to an object",
    h.set_variable(
      "shop",
      Some("test-a"),
      "user",
      "{\"name\": \"cy\", \"roles\": [1, true]}",
    ),
  )
  step("test-a GET /me", reply(h.send("GET", "/me", session="test-a")))
  step(
    "test-a sets user to null",
    h.set_variable("shop", Some("test-a"), "user", "null"),
  )
  step("test-a GET /me", reply(h.send("GET", "/me", session="test-a")))
  step("no Session sets user", h.set_variable("shop", None, "user", "\"dee\""))
  step("no Session GET /me", reply(h.send("GET", "/me")))
  step("test-a lists", h.variables("shop", Some("test-a")))
  step("test-b lists", h.variables("shop", Some("test-b")))
  step("no Session lists", h.variables("shop", None))
  inspect(
    out.join("\n"),
    content=(
      #|test-a sets user: set
      #|test-a GET /me: 200 {"user":"ann"}
      #|test-b GET /me: 200 {"user":null}
      #|no Session GET /me: 200 {"user":null}
      #|test-a logs in as bob: 200 {"user":"bob","previous":"ann"}
      #|test-a sets user to an object: set
      #|test-a GET /me: 200 {"user":{"name":"cy","roles":[1,true]}}
      #|test-a sets user to null: set
      #|test-a GET /me: 200 {"user":null}
      #|no Session sets user: set
      #|no Session GET /me: 200 {"user":"dee"}
      #|test-a lists: {"previous":"ann","user":null}
      #|test-b lists: {}
      #|no Session lists: {"user":"dee"}
    ),
  )
}

///|
test "list gives the names in byte-wise order: - before digits, digits before capitals, capitals before _, _ before small letters, a prefix first" {
  let h = harness([who_logged_in])
  for name in ["b", "ab", "a", "B", "_x", "-y", "10", "9"] {
    ignore(h.set_variable("shop", Some("test-a"), name, "0"))
  }
  inspect(
    h.variables("shop", Some("test-a")),
    content=(
      #|{"-y":0,"10":0,"9":0,"B":0,"_x":0,"a":0,"ab":0,"b":0}
    ),
  )
}

///|
test "set refuses an unknown Mock and a name that is not 1 to 128 ASCII letters, digits, _ and -, and writes nothing" {
  let h = harness([who_logged_in])
  let out = []
  let long = "x".repeat(128)
  for
    case in [
      ("an unknown Mock", "nowhere", "user"),
      ("an empty name", "shop", ""),
      ("a space", "shop", "a b"),
      ("a dot", "shop", "a.b"),
      ("a letter outside ASCII", "shop", "é"),
      ("129 characters", "shop", "\{long}y"),
    ] {
    let (label, mock, name) = case
    let result = h.set_variable(mock, Some("test-a"), name, "1")
    out.push("\{label}: \{result.replace_all(old=long, new="x...x")}")
  }
  out.push("test-a lists: \{h.variables("shop", Some("test-a"))}")
  out.push(
    "128 characters: \{h.set_variable("shop", Some("test-a"), long, "1")}",
  )
  let listed = h.variables("shop", Some("test-a"))
  out.push("test-a lists: \{listed.replace_all(old=long, new="x...x")}")
  inspect(
    out.join("\n"),
    content=(
      #|an unknown Mock: UnknownMock("nowhere")
      #|an empty name: InvalidVariableName("")
      #|a space: InvalidVariableName("a b")
      #|a dot: InvalidVariableName("a.b")
      #|a letter outside ASCII: InvalidVariableName("é")
      #|129 characters: InvalidVariableName("x...xy")
      #|test-a lists: {}
      #|128 characters: set
      #|test-a lists: {"x...x":1}
    ),
  )
}

///|
test "set refuses a value above 1 MiB of compact JSON, the bound a Stub's write has, before the bound on per-Session state counts it, and writes nothing" {
  // A string of n characters takes n + 2 bytes of compact JSON, and an
  // array of one such string n + 4.
  let mib = 1024 * 1024
  let string = (bytes : Int32) => "\"\{"a".repeat(bytes - 2)}\""
  let array = (bytes : Int32) => "[ \"\{"a".repeat(bytes - 4)}\" ]"
  let h = harness([who_logged_in])
  let tight = harness([who_logged_in], state_max_bytes=1000)
  let out = []
  out.push(
    "a string of 1 MiB: \{h.set_variable("shop", Some("test-a"), "user", string(mib))}",
  )
  out.push(
    "a string 1 byte above: \{h.set_variable("shop", Some("test-a"), "user", string(mib + 1))}",
  )
  out.push(
    "an array 1 byte above: \{h.set_variable("shop", Some("test-a"), "user", array(mib + 1))}",
  )
  out.push("test-a lists \{h.variables("shop", Some("test-a")).length()} bytes")
  out.push(
    "above both bounds: \{tight.set_variable("shop", Some("test-a"), "user", string(mib + 1))}",
  )
  out.push(
    "refused by the state bound: \{tight.engine.state_stats().writes_refused}",
  )
  inspect(
    out.join("\n"),
    content=(
      #|a string of 1 MiB: set
      #|a string 1 byte above: VariableTooLarge(name="user", bytes=1048577)
      #|an array 1 byte above: VariableTooLarge(name="user", bytes=1048577)
      #|test-a lists 1048585 bytes
      #|above both bounds: VariableTooLarge(name="user", bytes=1048577)
      #|refused by the state bound: 0
    ),
  )
}

///|
test "set counts against the bound on per-Session state as a Stub's write does: one that would take the count above it writes nothing, and the bound counts the refusal" {
  let h = harness([shop_state], state_max_bytes=250)
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}; \{h.state_bytes()} bytes")
  }
  // The docs' example: the space of shop and run-42 counts 4 + 6 + 64, and
  // count: 1 counts 5 + 64 + 1 + 16.
  step("count: 1", h.set_variable("shop", Some("run-42"), "count", "1"))
  step("count: 1 again", h.set_variable("shop", Some("run-42"), "count", "1"))
  // last: "aaaaa" would count 4 + 64 + 7 + 16 = 91: 251 in all.
  step(
    "last: \"aaaaa\"",
    h.set_variable("shop", Some("run-42"), "last", "\"aaaaa\""),
  )
  step("listed", h.variables("shop", Some("run-42")))
  // One character less takes the count to the bound exactly, which fits.
  step(
    "last: \"aaaa\"",
    h.set_variable("shop", Some("run-42"), "last", "\"aaaa\""),
  )
  step(
    "last: \"aaaaa\" in its place",
    h.set_variable("shop", Some("run-42"), "last", "\"aaaaa\""),
  )
  // A Stub's write and a set share the one count.
  step("POST /count", reply(h.send("POST", "/count", session="run-42")))
  step("a smaller value", h.set_variable("shop", Some("run-42"), "last", "1"))
  step("listed", h.variables("shop", Some("run-42")))
  out.push("refused: \{h.engine.state_stats().writes_refused}")
  inspect(
    out.join("\n"),
    content=(
      #|count: 1: set; 160 bytes
      #|count: 1 again: set; 160 bytes
      #|last: "aaaaa": StateLimitReached("the writes would take per-Session state from 160 to 251 bytes, above its bound of 250 (--state-max-bytes)"); 160 bytes
      #|listed: {"count":1}; 160 bytes
      #|last: "aaaa": set; 250 bytes
      #|last: "aaaaa" in its place: StateLimitReached("the writes would take per-Session state from 250 to 251 bytes, above its bound of 250 (--state-max-bytes)"); 250 bytes
      #|POST /count: 204 ; 250 bytes
      #|a smaller value: set; 245 bytes
      #|listed: {"count":1,"last":1}; 245 bytes
      #|refused: 2
    ),
  )
}

///|
/// Deletes the Variable `name` of `mock` for `session`: `deleted`, or the
/// error.
fn Harness::delete_variable(
  self : Harness,
  mock : String,
  session : String?,
  name : String,
) -> String {
  self.engine.delete_variable(mock~, session~, name~) catch {
    err => return @debug.to_string(err)
  }
  "deleted"
}

///|
test "delete unsets one of the calling Session's Variables, which its requests then miss, and refuses a name it has not set" {
  let h = harness([who_logged_in])
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  ignore(h.send("POST", "/login", body="{\"user\":\"ann\"}", session="test-a"))
  ignore(h.send("POST", "/login", body="{\"user\":\"bob\"}", session="test-b"))
  step("test-a deletes user", h.delete_variable("shop", Some("test-a"), "user"))
  step("test-a GET /me", reply(h.send("GET", "/me", session="test-a")))
  step("test-b GET /me", reply(h.send("GET", "/me", session="test-b")))
  step("test-a lists", h.variables("shop", Some("test-a")))
  step(
    "test-a deletes user again",
    h.delete_variable("shop", Some("test-a"), "user"),
  )
  step(
    "no Session deletes previous",
    h.delete_variable("shop", None, "previous"),
  )
  step(
    "test-c deletes previous",
    h.delete_variable("shop", Some("test-c"), "previous"),
  )
  step(
    "test-a deletes a name that is not a Variable name",
    h.delete_variable("shop", Some("test-a"), "a.b"),
  )
  step(
    "test-a deletes from an unknown Mock",
    h.delete_variable("nowhere", Some("test-a"), "previous"),
  )
  step(
    "test-a deletes previous",
    h.delete_variable("shop", Some("test-a"), "previous"),
  )
  step("test-a lists", h.variables("shop", Some("test-a")))
  step("test-b lists", h.variables("shop", Some("test-b")))
  inspect(
    out.join("\n"),
    content=(
      #|test-a deletes user: deleted
      #|test-a GET /me: 200 {"user":null}
      #|test-b GET /me: 200 {"user":"bob"}
      #|test-a lists: {"previous":null}
      #|test-a deletes user again: UnknownVariable(mock="shop", name="user")
      #|no Session deletes previous: UnknownVariable(mock="shop", name="previous")
      #|test-c deletes previous: UnknownVariable(mock="shop", name="previous")
      #|test-a deletes a name that is not a Variable name: InvalidVariableName("a.b")
      #|test-a deletes from an unknown Mock: UnknownMock("nowhere")
      #|test-a deletes previous: deleted
      #|test-a lists: {}
      #|test-b lists: {"previous":null,"user":"bob"}
    ),
  )
}

///|
test "delete gives the Variable's bytes back to the bound on per-Session state, and its space's bytes with the space's last Variable" {
  let h = harness([shop_state], state_max_bytes=250)
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}; \{h.state_bytes()} bytes")
  }
  let set = (name : String, value : String) => {
    h.set_variable("shop", Some("run-42"), name, value)
  }
  let delete = (name : String) => {
    h.delete_variable("shop", Some("run-42"), name)
  }
  // The space of shop and run-42 counts 74, count: 1 and other: 1 count 86
  // each, and last: "aaaa" 90.
  step("count: 1", set("count", "1"))
  step("last: \"aaaa\"", set("last", "\"aaaa\""))
  step("other: 1", set("other", "1"))
  step("delete count", delete("count"))
  step("other: 1", set("other", "1"))
  step("delete count again", delete("count"))
  step("delete other", delete("other"))
  step("delete last", delete("last"))
  step("listed", h.variables("shop", Some("run-42")))
  inspect(
    out.join("\n"),
    content=(
      #|count: 1: set; 160 bytes
      #|last: "aaaa": set; 250 bytes
      #|other: 1: StateLimitReached("the writes would take per-Session state from 250 to 336 bytes, above its bound of 250 (--state-max-bytes)"); 250 bytes
      #|delete count: deleted; 164 bytes
      #|other: 1: set; 250 bytes
      #|delete count again: UnknownVariable(mock="shop", name="count"); 250 bytes
      #|delete other: deleted; 164 bytes
      #|delete last: deleted; 0 bytes
      #|listed: {}; 0 bytes
    ),
  )
}
