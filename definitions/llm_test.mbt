// Tests of LLM responses in Definition files and Ephemeral Stubs: how
// `llm` is read and checked.

///|
test "llm is a body kind of a response: api is required, and a response gives at most one of the five" {
  inspect(
    problems([
      (
        "a.json",
        (
          #|{ "mocks": [{ "name": "m" }],
          #|  "stubs": [
          #|    { "id": "ok", "mock": "m",
          #|      "response": { "status": 200, "llm": { "api": "openai-chat", "text": "Hi" } } },
          #|    { "id": "no-text", "mock": "m",
          #|      "responses": [{ "status": 200, "llm": { "api": "openai-chat" } }] },
          #|    { "id": "no-api", "mock": "m",
          #|      "response": { "status": 200, "llm": { "text": "Hi" } } },
          #|    { "id": "unknown-api", "mock": "m",
          #|      "responses": [
          #|        { "status": 429, "json": { "error": "slow down" } },
          #|        { "status": 200, "llm": { "api": "gemini" } } ] },
          #|    { "id": "api-not-a-string", "mock": "m",
          #|      "response": { "status": 200, "llm": { "api": ["openai-chat"] } } },
          #|    { "id": "unknown-field", "mock": "m",
          #|      "response": { "status": 200,
          #|        "llm": { "api": "openai-chat", "text": "Hi", "stream": true } } },
          #|    { "id": "text-not-a-string", "mock": "m",
          #|      "response": { "status": 200, "llm": { "api": "openai-chat", "text": 1 } } },
          #|    { "id": "not-an-object", "mock": "m",
          #|      "response": { "status": 200, "llm": "openai-chat" } },
          #|    { "id": "beside-json", "mock": "m",
          #|      "response": { "status": 200, "json": {},
          #|        "llm": { "api": "openai-chat" } } },
          #|    { "id": "beside-events", "mock": "m",
          #|      "responses": [{ "status": 200, "events": [{ "data": "x" }],
          #|        "llm": { "api": "openai-chat" } }] },
          #|    { "id": "no-status", "mock": "m",
          #|      "response": { "llm": { "api": "openai-chat" } } } ] }
        ),
      ),
    ]),
    content=(
      #|a.json: /stubs/2/response/llm: needs "api"
      #|a.json: /stubs/3/responses/1/llm/api: must be "openai-chat"
      #|a.json: /stubs/4/response/llm/api: must be "openai-chat"
      #|a.json: /stubs/5/response/llm/stream: is not a known field
      #|a.json: /stubs/6/response/llm/text: must be a string
      #|a.json: /stubs/7/response/llm: must be an object
      #|a.json: /stubs/8/response: has "json" and "llm"; give at most one of "body", "bodyFile", "json", "events" and "llm"
      #|a.json: /stubs/9/responses/0: has "events" and "llm"; give at most one of "body", "bodyFile", "json", "events" and "llm"
      #|a.json: /stubs/10/response: needs "status"
    ),
  )
}

///|
/// A wait of `timing` as the Definition file gives it, or `none`.
fn wait(distribution : @definitions.Distribution?) -> String {
  match distribution {
    None => "none"
    Some(Fixed(ms)) => "fixed \{ms}"
    Some(Uniform(min~, max~)) => "uniform \{min} to \{max}"
    Some(Lognormal(median~, sigma~)) =>
      "lognormal, median \{median}, sigma \{sigma}"
  }
}

///|
/// The `timing` of the `llm` of each response of the first Stub in the
/// Definition file `file`, one line per response, or the problems that
/// loading it reports.
fn llm_timings(file : String) -> String {
  let set : @definitions.DefinitionSet = {
    files: [("a.json", @utf8.encode(file))],
    body_files: [],
  }
  match @definitions.load(set) {
    Err(diagnostics) => diagnostics.map(d => d.to_string()).join("\n")
    Ok(snapshot) => {
      guard snapshot.mocks[0].stubs[0].serves is Ordinary(ordinary) else {
        return "not an ordinary Stub"
      }
      let out = []
      for i, weighted in ordinary.responses {
        guard weighted.response.body is Llm(reply) else {
          out.push("\{i}: not an LLM reply")
          continue
        }
        out.push(
          "\{i}: first \{wait(reply.timing.first)}, interval \{wait(reply.timing.interval)}",
        )
      }
      out.join("\n")
    }
  }
}

///|
test "timing takes one distribution of the delay Fault for first and for interval, in whole milliseconds, and either may be left out" {
  inspect(
    llm_timings(
      (
        #|{ "mocks": [{ "name": "m" }],
        #|  "stubs": [{ "id": "s", "mock": "m", "responses": [
        #|    { "status": 200, "llm": { "api": "openai-chat" } },
        #|    { "status": 200, "llm": { "api": "openai-chat", "timing": {} } },
        #|    { "status": 200, "llm": { "api": "openai-chat",
        #|      "timing": { "first": { "fixed": 400 }, "interval": { "fixed": 0 } } } },
        #|    { "status": 200, "llm": { "api": "openai-chat",
        #|      "timing": { "first": { "uniform": { "min": 100, "max": 300 } } } } },
        #|    { "status": 200, "llm": { "api": "openai-chat",
        #|      "timing": { "interval": { "uniform": { "min": 15, "max": 40 } } } } },
        #|    { "status": 200, "template": true, "llm": { "api": "openai-chat",
        #|      "timing": { "first": { "lognormal": { "median": 400, "sigma": 0.5 } },
        #|        "interval": { "lognormal": { "median": 25, "sigma": 0 } } } } } ] }] }
      ),
    ),
    content=(
      #|0: first none, interval none
      #|1: first none, interval none
      #|2: first fixed 400, interval fixed 0
      #|3: first uniform 100 to 300, interval none
      #|4: first none, interval uniform 15 to 40
      #|5: first lognormal, median 400, sigma 0.5, interval lognormal, median 25, sigma 0
    ),
  )
}

///|
test "timing refuses probability, an unknown or a second distribution, a negative or fractional wait and an unknown member, as a delay does" {
  inspect(
    problems([
      (
        "a.json",
        (
          #|{ "mocks": [{ "name": "m" }],
          #|  "stubs": [{ "id": "s", "mock": "m", "responses": [
          #|    { "status": 200, "llm": { "api": "openai-chat",
          #|      "timing": { "first": { "fixed": 400, "probability": 0.5 } } } },
          #|    { "status": 200, "llm": { "api": "openai-chat",
          #|      "timing": { "interval": { "exponential": { "mean": 20 } } } } },
          #|    { "status": 200, "llm": { "api": "openai-chat",
          #|      "timing": { "first": { "fixed": 1, "uniform": { "min": 1, "max": 2 } } } } },
          #|    { "status": 200, "llm": { "api": "openai-chat",
          #|      "timing": { "first": { "fixed": -1 }, "interval": { "fixed": 2.5 } } } },
          #|    { "status": 200, "llm": { "api": "openai-chat",
          #|      "timing": { "interval": { "uniform": { "min": 40, "max": 15 } } } } },
          #|    { "status": 200, "llm": { "api": "openai-chat",
          #|      "timing": { "first": { "fixed": 400 }, "last": { "fixed": 0 } } } },
          #|    { "status": 200, "llm": { "api": "openai-chat", "timing": 400 } },
          #|    { "status": 200, "llm": { "api": "openai-chat",
          #|      "timing": { "first": 400 } } } ] }] }
        ),
      ),
    ]),
    content=(
      #|a.json: /stubs/0/responses/0/llm/timing/first/probability: is not a known field
      #|a.json: /stubs/0/responses/1/llm/timing/interval/exponential: is not a known field
      #|a.json: /stubs/0/responses/1/llm/timing/interval: needs one of "fixed", "uniform" and "lognormal"
      #|a.json: /stubs/0/responses/2/llm/timing/first: has "fixed" and "uniform"; give exactly one of "fixed", "uniform" and "lognormal"
      #|a.json: /stubs/0/responses/3/llm/timing/first/fixed: must be an integer from 0 to 2147483647
      #|a.json: /stubs/0/responses/3/llm/timing/interval/fixed: must be an integer from 0 to 2147483647
      #|a.json: /stubs/0/responses/4/llm/timing/interval/uniform: "min" (40) must not exceed "max" (15)
      #|a.json: /stubs/0/responses/5/llm/timing/last: is not a known field
      #|a.json: /stubs/0/responses/6/llm/timing: must be an object
      #|a.json: /stubs/0/responses/7/llm/timing/first: must be an object
    ),
  )
}
