// Seam 1 tests of the encoding and JWT helpers: the worked example of their
// ticket, a claim read from `Authorization`, and the render errors they
// give, with the JSON Pointer of the field.

///|
/// The worked example: the caller's claims and encoded query values.
let claims_example : (String, String) = (
  "claims.yaml",
  (
    #|mocks:
    #|  - name: auth
    #|stubs:
    #|  - id: me
    #|    mock: auth
    #|    request: { method: GET, path: /me }
    #|    response:
    #|      status: 200
    #|      template: true
    #|      json:
    #|        user: ${jwtPayload(header.authorization).sub ?? 'anonymous'}
    #|        alg: ${jwtHeader(header.authorization).alg ?? null}
    #|        echo: ${base64url(query.token ?? '')}
    #|        next: ${urlEncode(query.q ?? '')}
  ),
)

///|
/// A token whose header is `{"alg":"HS256","typ":"JWT"}` and whose payload
/// is `{"sub":"u-42"}`, encoded apart from smock. Its signature is never
/// checked.
let u42_token : String = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1LTQyIn0.c2ln"

///|
test "worked example: the caller's sub claim from Authorization, or anonymous without a header or with a malformed token" {
  let h = harness([claims_example])
  let me = (headers : Array[(String, String)]) => {
    response(
      h.send(
        "GET",
        "/me?token=a%2Bb%2Fc%3F&q=%E6%9D%B1%E4%BA%AC+tower%26x%3D1",
        headers~,
      ),
    )
  }
  inspect(
    [
      me([("Authorization", "Bearer \{u42_token}")]),
      me([("Authorization", "bearer\t\{u42_token}")]),
      me([]),
      me([("Authorization", "Bearer not.a-token")]),
    ].join("\n"),
    content=(
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: auth; via=default
      #|{"user":"u-42","alg":"HS256","echo":"YStiL2M_","next":"%E6%9D%B1%E4%BA%AC%20tower%26x%3D1"}
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: auth; via=default
      #|{"user":"u-42","alg":"HS256","echo":"YStiL2M_","next":"%E6%9D%B1%E4%BA%AC%20tower%26x%3D1"}
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: auth; via=default
      #|{"user":"anonymous","alg":null,"echo":"YStiL2M_","next":"%E6%9D%B1%E4%BA%AC%20tower%26x%3D1"}
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: auth; via=default
      #|{"user":"anonymous","alg":null,"echo":"YStiL2M_","next":"%E6%9D%B1%E4%BA%AC%20tower%26x%3D1"}
    ),
  )
}

///|
test "a bad value for an encoding helper is the 500 template failed, with the JSON Pointer of the field; a malformed token is missing instead" {
  let h = one_response(
    (
      #|{ "status": 200, "template": true,
      #|  "headers": { "X-Text": "${base64Decode(query.b ?? 'b2s=')}" },
      #|  "json": {
      #|    "path": "${urlDecode(body.path ?? '%2F')}",
      #|    "user": "${jwtPayload(header.authorization).sub}" } }
    ),
  )
  let token = [("Authorization", "Bearer \{u42_token}")]
  inspect(
    [
      h.body("/", headers=token),
      h.body("/?b=b2s-", headers=token),
      h.body("/?b=b2s==", headers=token),
      h.body("/", headers=token, body="{\"path\":\"%2\"}"),
      h.body("/", headers=token, body="{\"path\":[\"%2F\"]}"),
      h.body("/", headers=[("Authorization", "Bearer x.y.z")]),
      h.body("/"),
    ].join("\n"),
    content=(
      #|{"path":"/","user":"u-42"}
      #|500 {"error":"template failed","stub":"s","at":"/response/headers/X-Text","message":"base64Decode(): character 4, \"-\", is not in the base64 alphabet"}
      #|500 {"error":"template failed","stub":"s","at":"/response/headers/X-Text","message":"base64Decode(): the padding has 2 \"=\", but a last group of 3 characters takes 1 or none"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/path","message":"urlDecode(): character 1, \"%\", is not followed by two hex digits"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/path","message":"urlDecode(): argument 1 must be a string, a number or a boolean, not an array"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/user","message":"jwtPayload(header.authorization) is missing"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/user","message":"header.authorization is missing"}
    ),
  )
}
