// Seam 2 test of `xml` body conditions: a running smock matches a SOAP-style
// request by the values at paths into its body, and the Admin API shows a
// failed path in the Near miss. Every Admin API response is checked against
// the OpenAPI document (contract_test.mbt).

///|
async test "over HTTP, an xml condition matches a SOAP request whatever its prefixes and indentation; a failed path is in the Smock-Near-Miss header and the Journal" {
  let defs =
    #|{ "mocks": [{ "name": "users", "hosts": ["localhost"] }],
    #|  "stubs": [
    #|    { "id": "get-user", "mock": "users",
    #|      "request": { "method": "POST", "path": "/soap",
    #|        "body": { "xml": { "/Envelope/Body/GetUser/id": "42",
    #|          "/Envelope/Body/GetUser/@lang": { "$not": "fr" } } } },
    #|      "response": { "status": 200, "body": "user 42" } } ] }
  with_definitions([("users.json", defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let session = baggage("xml")
      let headers = [
        ("Host", "localhost"),
        session,
        ("Content-Type", "text/xml; charset=utf-8"),
      ]
      let pretty =
        #|<?xml version="1.0" encoding="UTF-8"?>
        #|<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
        #|  <soap:Body>
        #|    <u:GetUser xmlns:u="urn:users" u:lang="en">
        #|      <u:id>42</u:id>
        #|    </u:GetUser>
        #|  </soap:Body>
        #|</soap:Envelope>
      let compact = "<S:Envelope xmlns:S='urn:s'><S:Body><GetUser lang='fr'><id>7</id></GetUser></S:Body></S:Envelope>"
      inspect(
        [
          smock.request("POST", "/soap", headers~, body=pretty),
          smock.request("POST", "/soap", headers~, body=compact),
        ].join("\n---\n"),
        content=(
          #|HTTP/1.1 200 OK
          #|Content-Length: 7
          #|
          #|user 42
          #|---
          #|HTTP/1.1 404 Not Found
          #|Content-Type: application/json
          #|Smock-Near-Miss: get-user; failed=xml:%2FEnvelope%2FBody%2FGetUser%2Fid,xml:%2FEnvelope%2FBody%2FGetUser%2F%40lang
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
        ),
      )
      let unmatched = smock.admin(
        "GET",
        "/v1/journal/unmatched",
        headers=session_headers(Some("xml")),
      )
      inspect(unmatched.status, content="200")
      guard unmatched.json()
        is Object({ "entries": [Object({ "nearMiss": near_miss, .. })], .. }) else {
        fail("not one entry: \{unmatched.body}")
      }
      json_inspect(near_miss, content={
        "stub": "get-user",
        "stubSource": "file",
        "failed": [
          {
            "condition": "xml:/Envelope/Body/GetUser/id",
            "expected": "42",
            "actual": ["7"],
          },
          {
            "condition": "xml:/Envelope/Body/GetUser/@lang",
            "expected": { "$not": "fr" },
            "actual": ["fr"],
          },
        ],
      })
    })
  })
}
