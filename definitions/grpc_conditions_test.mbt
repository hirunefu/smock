// gRPC Stubs' `json` body conditions at load: checked against the input
// type of the Stub's method, and normalised to smock's decoded form, the
// form in which a call's message reaches the Stubs. The set is
// fixtures/protobuf/users/users.proto (users_set_test.mbt), which
// scripts/gen-protobuf-fixtures.sh builds with protoc.

///|
/// Loads `a.yaml`, which declares the Mock `users`, whose set is
/// users.proto, and the Mock `plain`, with no set, and then `stubs`, the
/// lines of its `stubs` array. Renders what the loader makes of them: every
/// problem, one per line, as `smock check` prints it; or, for a valid set,
/// each Stub's `json` body condition as matching sees it, then each
/// warning.
fn conditions(stubs : String) -> String raise {
  let yaml =
    #|mocks:
    #|  - { name: users, grpc: { descriptorSet: users.binpb } }
    #|  - { name: plain }
    #|stubs:
    #|
  match
    @definitions.load({
      files: [("a.yaml", @utf8.encode(yaml + stubs))],
      body_files: [("users.binpb", set_bytes(users_set))],
    }) {
    Ok(snapshot) => {
      let lines = []
      for mock in snapshot.mocks {
        for stub in mock.stubs {
          let condition = match stub.serves {
            Ordinary({ request: { body: Some(Json(condition)), .. }, .. }) =>
              condition.to_json().stringify()
            _ => "no json condition"
          }
          lines.push("\{stub.id}: \{condition}")
        }
      }
      for warning in snapshot.warnings() {
        lines.push(warning.to_string())
      }
      lines.join("\n")
    }
    Err(problems) => problems.map(problem => problem.to_string()).join("\n")
  }
}

///|
test "the ticket's example: a proto name becomes its JSON name and an enum number its name; a misspelt key, and an int64 written as a string, are problems, the second suggesting the number" {
  inspect(
    conditions(
      (
        #|  - id: example
        #|    mock: users
        #|    request: { path: /users.Users/Find, body: { json: { user_id: 42, status: 1 } } }
        #|    response: { json: { id: found } }
      ),
    ),
    content=(
      #|example: {"userId":42,"status":"ACTIVE"}
    ),
  )
  inspect(
    conditions(
      (
        #|  - id: misspelt
        #|    mock: users
        #|    request: { path: /users.Users/Find, body: { json: { usr_id: 42 } } }
        #|    response: { json: { id: found } }
        #|  - id: a-string
        #|    mock: users
        #|    request: { path: /users.Users/Find, body: { json: { user_id: "42" } } }
        #|    response: { json: { id: found } }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/request/body/json/usr_id: is not a field of users.Query
      #|a.yaml: /stubs/1/request/body/json/user_id: must be written 42, as smock prints it: the field user_id of users.Query has the type int64
    ),
  )
}

///|
test "each key must name a field of the type at its place, by its proto name or its JSON name, once; patterns and operators are allowed in any place, their operands checked" {
  inspect(
    conditions(
      (
        #|  - id: keys
        #|    mock: users
        #|    request:
        #|      path: /users.Users/Find
        #|      body:
        #|        json:
        #|          userId: { $not: 7 }
        #|          profile: { display_name: { pattern: "T.*" }, scores: { $exists: true } }
        #|          history: { $includes: 2 }
        #|          labels: { $not: { "7": { $exists: false } } }
        #|          token: { pattern: ".*" }
        #|    response: { json: { id: found } }
        #|  - id: patterns-anywhere
        #|    mock: users
        #|    request:
        #|      path: /users.Users/Find
        #|      body: { json: { profile: { pattern: x }, history: { $last: ENABLED }, status: { $not: { $not: 2 } } } }
        #|    response: { json: { id: found } }
        #|  - id: a-pattern
        #|    mock: users
        #|    request: { path: /users.Users/Find, body: { json: { pattern: "\\{.*" } } }
        #|    response: { json: { id: found } }
      ),
    ),
    content=(
      #|keys: {"userId":{"$not":7},"profile":{"displayName":{"pattern":"T.*"},"scores":{"$exists":true}},"history":{"$includes":"SUSPENDED"},"labels":{"$not":{"7":{"$exists":false}}},"token":{"pattern":".*"}}
      #|patterns-anywhere: {"profile":{"pattern":"x"},"history":{"$last":"ACTIVE"},"status":{"$not":{"$not":"SUSPENDED"}}}
      #|a-pattern: {"pattern":"\\{.*"}
    ),
  )
  inspect(
    conditions(
      (
        #|  - id: unknown
        #|    mock: users
        #|    request:
        #|      path: /users.Users/Find
        #|      body:
        #|        json:
        #|          profile: { displayName: Tom, display: Tom, scores: { math: 1 } }
        #|          "[users.extra]": 1
        #|          $$user_id: 42
        #|          status: { $not: { name: ACTIVE } }
        #|          history: { $includes: { user_id: 42 } }
        #|    response: { json: { id: found } }
        #|  - id: twice
        #|    mock: users
        #|    request:
        #|      path: /users.Users/Find
        #|      body: { json: { user_id: 42, userId: 42, profile: { displayName: a, display_name: b } } }
        #|    response: { json: { id: found } }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/request/body/json/profile/display: is not a field of users.Profile
      #|a.yaml: /stubs/0/request/body/json/[users.extra]: is not a field of users.Query
      #|a.yaml: /stubs/0/request/body/json/$$user_id: is not a field of users.Query
      #|a.yaml: /stubs/0/request/body/json/status/$not: must be the name of a value of users.Status, or an integer from -2147483648 to 2147483647: the field status of users.Query has the type users.Status
      #|a.yaml: /stubs/0/request/body/json/history/$includes: must be the name of a value of users.Status, or an integer from -2147483648 to 2147483647: the elements of the field history of users.Query have the type users.Status
      #|a.yaml: /stubs/1/request/body/json/userId: names the field user_id of users.Query, as "user_id" does: give a field once, by its proto name or its JSON name
      #|a.yaml: /stubs/1/request/body/json/profile/display_name: names the field display_name of users.Profile, as "displayName" does: give a field once, by its proto name or its JSON name
    ),
  )
}

///|
test "an enum number or alias becomes the enum's first name and a float literal the nearest 32-bit float, as smock prints them; map keys are data, never rewritten" {
  inspect(
    conditions(
      (
        #|  - id: enums
        #|    mock: users
        #|    request:
        #|      path: /users.Users/Find
        #|      body: { json: { status: ENABLED, history: [1, ENABLED, SUSPENDED, 7, ACTIVE] } }
        #|    response: { json: { id: found } }
        #|  - id: tenth
        #|    mock: users
        #|    request: { path: /users.Users/Find, body: { json: { ratio: 0.1 } } }
        #|    response: { json: { id: found } }
        #|  - id: nine-ninety-nine
        #|    mock: users
        #|    request: { path: /users.Users/Find, body: { json: { ratio: 9.99 } } }
        #|    response: { json: { id: found } }
        #|  - id: rounded
        #|    mock: users
        #|    request: { path: /users.Users/Find, body: { json: { ratio: 16777217 } } }
        #|    response: { json: { id: found } }
        #|  - id: specials
        #|    mock: users
        #|    request: { path: /users.Users/Find, body: { json: { ratio: { $not: NaN }, user_id: 1e3 } } }
        #|    response: { json: { id: found } }
        #|  - id: map-keys
        #|    mock: users
        #|    request:
        #|      path: /users.Users/Find
        #|      body:
        #|        json:
        #|          labels: { "-7": seven, "10": ten }
        #|          profile: { display_name: Tom, scores: { math_score: 90, mathScore: 80, $$cash: 1 } }
        #|    response: { json: { id: found } }
      ),
    ),
    content=(
      #|enums: {"status":"ACTIVE","history":["ACTIVE","ACTIVE","SUSPENDED",7,"ACTIVE"]}
      #|tenth: {"ratio":0.1}
      #|nine-ninety-nine: {"ratio":9.99}
      #|rounded: {"ratio":16777216}
      #|specials: {"ratio":{"$not":"NaN"},"userId":1000}
      #|map-keys: {"labels":{"-7":"seven","10":"ten"},"profile":{"displayName":"Tom","scores":{"math_score":90,"mathScore":80,"$$cash":1}}}
    ),
  )
}

///|
test "each literal must be a value of its field's type as smock prints it: one that can never match is a problem at its pointer, and one that ProtoJSON reads but smock never prints suggests the printed form" {
  inspect(
    conditions(
      (
        #|  - id: wrong-types
        #|    mock: users
        #|    request:
        #|      path: /users.Users/Find
        #|      body:
        #|        json:
        #|          user_id: 1.5
        #|          status: BOGUS
        #|          ratio: 3.5e38
        #|          token: "!!"
        #|          labels: [seven]
        #|          history: ACTIVE
        #|          profile: Tom
        #|    response: { json: { id: found } }
        #|  - id: deeper
        #|    mock: users
        #|    request:
        #|      path: /users.Users/Find
        #|      body:
        #|        json:
        #|          user_id: null
        #|          labels: { "7": 7, seven: seven }
        #|          history: [ACTIVE, null, "1"]
        #|          profile: { display_name: [Tom], scores: { math: "90" } }
        #|    response: { json: { id: found } }
        #|  - id: not-a-message
        #|    mock: users
        #|    request: { path: /users.Users/Find, body: { json: [42] } }
        #|    response: { json: { id: found } }
        #|  - id: printed-forms
        #|    mock: users
        #|    request:
        #|      path: /users.Users/Find
        #|      body:
        #|        json:
        #|          user_id: "-42"
        #|          ratio: "0.1"
        #|          labels: { "007": seven, "+7": seven }
        #|    response: { json: { id: found } }
        #|  - id: unpadded
        #|    mock: users
        #|    request: { path: /users.Users/Find, body: { json: { token: "+/8" } } }
        #|    response: { json: { id: found } }
        #|  - id: url-safe
        #|    mock: users
        #|    request: { path: /users.Users/Find, body: { json: { token: "-_8=" } } }
        #|    response: { json: { id: found } }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/request/body/json/user_id: must be an integer from -9223372036854775808 to 9223372036854775807: the field user_id of users.Query has the type int64
      #|a.yaml: /stubs/0/request/body/json/status: must be the name of a value of users.Status, or an integer from -2147483648 to 2147483647: the field status of users.Query has the type users.Status
      #|a.yaml: /stubs/0/request/body/json/ratio: must be a number within the range of a float, or "NaN", "Infinity" or "-Infinity": the field ratio of users.Query has the type float
      #|a.yaml: /stubs/0/request/body/json/token: must be a string of standard base64, with padding: the field token of users.Query has the type bytes
      #|a.yaml: /stubs/0/request/body/json/labels: must be an object: the field labels of users.Query is a map
      #|a.yaml: /stubs/0/request/body/json/history: must be an array: the field history of users.Query is repeated
      #|a.yaml: /stubs/0/request/body/json/profile: must be an object: the field profile of users.Query has the type users.Profile
      #|a.yaml: /stubs/1/request/body/json/user_id: must be an integer from -9223372036854775808 to 9223372036854775807: the field user_id of users.Query has the type int64
      #|a.yaml: /stubs/1/request/body/json/labels/7: must be a string of Unicode text: the values of the map field labels of users.Query have the type string
      #|a.yaml: /stubs/1/request/body/json/labels/seven: must be an integer from -2147483648 to 2147483647: the keys of the map field labels of users.Query have the type int32
      #|a.yaml: /stubs/1/request/body/json/history/1: must be the name of a value of users.Status, or an integer from -2147483648 to 2147483647: the elements of the field history of users.Query have the type users.Status
      #|a.yaml: /stubs/1/request/body/json/history/2: must be the name of a value of users.Status, or an integer from -2147483648 to 2147483647: the elements of the field history of users.Query have the type users.Status
      #|a.yaml: /stubs/1/request/body/json/profile/display_name: must be a string of Unicode text: the field display_name of users.Profile has the type string
      #|a.yaml: /stubs/1/request/body/json/profile/scores/math: must be written 90, as smock prints it: the values of the map field scores of users.Profile have the type int32
      #|a.yaml: /stubs/2/request/body/json: must be an object: the message is a users.Query
      #|a.yaml: /stubs/3/request/body/json/user_id: must be written -42, as smock prints it: the field user_id of users.Query has the type int64
      #|a.yaml: /stubs/3/request/body/json/ratio: must be written 0.1, as smock prints it: the field ratio of users.Query has the type float
      #|a.yaml: /stubs/3/request/body/json/labels/007: must be written "7", as smock prints it: the keys of the map field labels of users.Query have the type int32
      #|a.yaml: /stubs/3/request/body/json/labels/+7: must be an integer from -2147483648 to 2147483647: the keys of the map field labels of users.Query have the type int32
      #|a.yaml: /stubs/4/request/body/json/token: must be written "+/8=", as smock prints it: the field token of users.Query has the type bytes
      #|a.yaml: /stubs/5/request/body/json/token: must be written "+/8=", as smock prints it: the field token of users.Query has the type bytes
    ),
  )
}

///|
test "gRPC Stubs' conditions are compared once normalised: a later gRPC Stub whose conditions include all of an earlier one's gets the warning, however each spells them" {
  inspect(
    conditions(
      (
        #|  - id: by-proto-name
        #|    mock: users
        #|    request: { path: /users.Users/Find, body: { json: { user_id: 42, status: 1 } } }
        #|    response: { json: { id: first } }
        #|  - id: by-json-name
        #|    mock: users
        #|    request:
        #|      path: /users.Users/Find
        #|      headers: { x-tenant: acme }
        #|      body: { json: { userId: 42, status: ENABLED } }
        #|    response: { json: { id: second } }
        #|  - id: rounded
        #|    mock: users
        #|    request: { path: /users.Users/Find, body: { json: { ratio: 16777216 } } }
        #|    response: { json: { id: third } }
        #|  - id: as-written
        #|    mock: users
        #|    request: { path: /users.Users/Find, body: { json: { ratio: 16777217 } } }
        #|    response: { json: { id: fourth } }
        #|  - id: another-user
        #|    mock: users
        #|    request: { path: /users.Users/Find, body: { json: { user_id: 43, status: 1 } } }
        #|    response: { json: { id: fifth } }
        #|  - id: http
        #|    mock: plain
        #|    request: { path: /users.Users/Find, body: { json: { user_id: 42, status: 1 } } }
        #|    response: { status: 200 }
        #|  - id: http-again
        #|    mock: plain
        #|    request: { path: /users.Users/Find, body: { json: { userId: 42, status: ACTIVE } } }
        #|    response: { status: 200 }
      ),
    ),
    content=(
      #|by-proto-name: {"userId":42,"status":"ACTIVE"}
      #|by-json-name: {"userId":42,"status":"ACTIVE"}
      #|rounded: {"ratio":16777216}
      #|as-written: {"ratio":16777216}
      #|another-user: {"userId":43,"status":"ACTIVE"}
      #|http: {"user_id":42,"status":1}
      #|http-again: {"userId":42,"status":"ACTIVE"}
      #|a.yaml: /stubs/1: warning: the Stub "by-json-name" can never match: the Stub "by-proto-name" at a.yaml: /stubs/0 is tried first and matches every request this one would
      #|a.yaml: /stubs/3: warning: the Stub "as-written" can never match: the Stub "rounded" at a.yaml: /stubs/2 is tried first and matches every request this one would
    ),
  )
}
