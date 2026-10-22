// Tests of the JWT helpers, jwtPayload and jwtHeader, through the template
// package's public interface. The tokens were encoded apart from smock, by
// RFC 4648's base64url. They run on native and on wasm-gc, and give the
// same output on both.

///|
/// The header `{"alg":"HS256","typ":"JWT"}`, in base64url.
let jwt_header : String = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"

///|
/// The payload
/// `{"sub":"u-42","roles":["admin","dev"],"exp":1791882000,"name":"été"}`,
/// in base64url.
let jwt_payload : String = "eyJzdWIiOiJ1LTQyIiwicm9sZXMiOlsiYWRtaW4iLCJkZXYiXSwiZXhwIjoxNzkxODgyMDAwLCJuYW1lIjoiXHUwMGU5dFx1MDBlOSJ9"

///|
/// A token with that header and payload, and a signature that is never
/// checked: the base64url of `sig`.
let token : String = "\{jwt_header}.\{jwt_payload}.c2ln"

///|
/// A request with one `Authorization` field, `value`, and the body of
/// `encoded`.
fn authorized(value : String) -> @template.Input {
  { ..encoded, headers: [("Authorization", value)], }
}

///|
/// The `sub` claim of the token in `Authorization: value`, or `anonymous`.
fn claim(value : String) -> String {
  rendered(
    "${jwtPayload(header.authorization).sub ?? 'anonymous'}",
    input=authorized(value),
  )
}

///|
test "jwtPayload and jwtHeader decode a token without checking it, after a Bearer in any case followed by spaces or tabs" {
  inspect(
    [
      rendered_json(
        "{ \"payload\": \"${jwtPayload(header.authorization)}\", \"alg\": \"${jwtHeader(header.authorization).alg}\", \"role\": \"${jwtPayload(header.authorization).roles[1]}\" }",
        input=authorized("Bearer \{token}"),
      ),
      claim("Bearer \{token}"),
      claim("bearer \{token}"),
      claim("BEARER\t\{token}"),
      claim("BeArEr  \t \{token}"),
      claim(token),
      claim("Bearer\{token}"),
      claim("Bearer"),
      claim("Bearer "),
      claim("Basic \{token}"),
      claim(" Bearer \{token}"),
      claim("Bearer Bearer \{token}"),
      claim("\{token} "),
    ].join("\n"),
    content=(
      #|{"payload":{"sub":"u-42","roles":["admin","dev"],"exp":1791882000,"name":"été"},"alg":"HS256","role":"dev"}
      #|u-42
      #|u-42
      #|u-42
      #|u-42
      #|u-42
      #|anonymous
      #|anonymous
      #|anonymous
      #|anonymous
      #|anonymous
      #|anonymous
      #|anonymous
    ),
  )
}

///|
test "a token is three base64url parts, padding optional, the first two JSON objects in UTF-8; anything else is missing, so ?? applies" {
  let payload = (token : String) => {
    rendered_json("{ \"p\": \"${jwtPayload(body.token) ?? 'missing'}\" }", input={
      ..encoded,
      body: @utf8.encode("{ \"token\": \{Json::string(token).stringify()} }"),
    })
  }
  inspect(
    [
      payload("eyJhbGciOiJub25lIn0.eyJhIjoxfQ."),
      payload("eyJhbGciOiJub25lIn0=.eyJhIjoxfQ==."),
      payload("eyJhbGciOiJub25lIn0.eyJhIjoxfQ=."),
      payload("eyJhbGciOiJub25lIn0==.eyJhIjoxfQ."),
      payload("eyJhbGciOiJub25lIn0.eyJhIjoxfQ.c2ln="),
      payload("\{jwt_header}.eyJzdWIiOiJhIiwieCI6MSwic3ViIjoiYiJ9.c2ln"),
      payload("\{jwt_header}.IHsgInN1YiIgOiAidyIgfSA.c2ln"),
      payload(
        "eyJhbGciOiJSU0EtT0FFUCIsImVuYyI6IkEyNTZHQ00ifQ.a2V5.aXY.Y2lwaGVy.dGFn",
      ),
      payload("\{jwt_header}.\{jwt_payload}"),
      payload("\{jwt_header}.\{jwt_payload}.c2ln.c2ln"),
      payload("\{jwt_header}.eyJzdWIiOg.c2ln"),
      payload("\{jwt_header}.WzFd.c2ln"),
      payload("\{jwt_header}.Ingi.c2ln"),
      payload("WzFd.\{jwt_payload}.c2ln"),
      payload("\{jwt_header}.eyJzdWIiOiL_In0.c2ln"),
      payload("\{jwt_header}.\{jwt_payload}.c2ln!"),
      payload("\{jwt_header}.\{jwt_payload}.c2+n"),
      payload("\{jwt_header}.\{jwt_payload}.c"),
      payload(""),
      payload(".."),
      rendered(
        "${jwtPayload(body.object) ?? 'missing'} ${jwtHeader(body.none) ?? 'missing'} ${jwtPayload(42) ?? 'missing'} ${jwtHeader(true) ?? 'missing'}",
        input=encoded,
      ),
    ].join("\n"),
    content=(
      #|{"p":{"a":1}}
      #|{"p":{"a":1}}
      #|{"p":"missing"}
      #|{"p":"missing"}
      #|{"p":"missing"}
      #|{"p":{"sub":"b","x":1}}
      #|{"p":{"sub":"w"}}
      #|{"p":"missing"}
      #|{"p":"missing"}
      #|{"p":"missing"}
      #|{"p":"missing"}
      #|{"p":"missing"}
      #|{"p":"missing"}
      #|{"p":"missing"}
      #|{"p":"missing"}
      #|{"p":"missing"}
      #|{"p":"missing"}
      #|{"p":"missing"}
      #|{"p":"missing"}
      #|{"p":"missing"}
      #|missing missing missing missing
    ),
  )
}

///|
test "a missing token or claim is an error without a fallback, and a call with the wrong arguments is an error when loading" {
  inspect(
    [
      rendered("${jwtPayload(header.authorization)}", input=encoded),
      rendered(
        "${jwtPayload(header.authorization).sub}",
        input=authorized("Basic \{token}"),
      ),
      rendered(
        "${jwtHeader(header.authorization).kid}",
        input=authorized(token),
      ),
      rendered("${jwtPayload(header.authorization)}", input=authorized(token)),
      rendered(
        "${json(jwtHeader(header.authorization))}",
        input=authorized(token),
      ),
      rendered("${jwtPayload(null)}", input=encoded),
      rendered("${jwtHeader()}", input=encoded),
      rendered("${jwtHeader('a', 'b')}", input=encoded),
    ].join("\n"),
    content=(
      #|error at /response/body: header.authorization is missing
      #|error at /response/body: jwtPayload(header.authorization) is missing
      #|error at /response/body: jwtHeader(header.authorization).kid is missing
      #|error at /response/body: an object or an array cannot be written as text; write it with json(…)
      #|{"alg":"HS256","typ":"JWT"}
      #|problem at /response/body: template: column 14: jwtPayload(): argument 1 must be a string, a number or a boolean, not null
      #|problem at /response/body: template: column 3: jwtHeader() takes 1 argument, not 0
      #|problem at /response/body: template: column 3: jwtHeader() takes 1 argument, not 2
    ),
  )
}

///|
test "a payload or a header that takes more than 1 MiB as compact JSON is a render error" {
  // The payload {"a":"x…x"} with `n` x, a multiple of 3, takes n + 8 bytes
  // as compact JSON: in base64url, eyJhIjoi, then eHh4 for each xxx, then
  // In0 for "}.
  let sized = (n : Int) => {
    rendered("${len(jwtPayload(bodyText).a)}", input={
      ..request,
      body: @utf8.encode("e30.eyJhIjoi\{"eHh4".repeat(n / 3)}In0."),
    })
  }
  inspect(
    [sized(3), sized(1048566), sized(1048569)].join("\n"),
    content=(
      #|3
      #|1048566
      #|error at /response/body: jwtPayload(): the result takes more than 1 MiB
    ),
  )
}
