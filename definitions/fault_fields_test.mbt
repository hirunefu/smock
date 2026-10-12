// Validation of a Stub's `fault`: a delay drawn from a distribution, a
// connection Fault, each with a probability, and a seed.

///|
test "delays, close and partial connection Faults and seeds are read as the Schema defines them" {
  inspect(
    stub_problems([
      stub_with("fixed", "\"fault\": { \"delay\": { \"fixed\": 100 } }"),
      stub_with(
        "fixed-zero", "\"fault\": { \"delay\": { \"fixed\": 0, \"probability\": 0 } }",
      ),
      stub_with(
        "uniform",
        (
          #|"fault": { "delay": { "uniform": { "min": 50, "max": 150 },
          #|  "probability": 0.5 } }
        ),
      ),
      stub_with(
        "uniform-one-value", "\"fault\": { \"delay\": { \"uniform\": { \"min\": 7, \"max\": 7 } } }",
      ),
      stub_with(
        "lognormal",
        (
          #|"fault": { "delay": { "lognormal": { "median": 80, "sigma": 0.6 } },
          #|  "seed": 42 }
        ),
      ),
      stub_with(
        "close", "\"fault\": { \"connection\": { \"kind\": \"close\", \"probability\": 0.1 } }",
      ),
      stub_with(
        "partial",
        (
          #|"fault": { "connection": { "kind": "partial", "probability": 1 },
          #|  "delay": { "fixed": 2147483647, "probability": 1.0 },
          #|  "seed": 9007199254740991 }
        ),
      ),
      stub_with("seed-only", "\"fault\": { \"seed\": 0 }"),
      stub_with("empty", "\"fault\": {}"),
    ]),
    content="valid",
  )
}

///|
test "an invalid probability, duration, sigma or seed is a diagnostic at its JSON Pointer" {
  inspect(
    stub_problems([
      stub_with(
        "a",
        (
          #|"fault": { "delay": { "fixed": 10, "probability": 1.5 },
          #|  "connection": { "kind": "close", "probability": -0.1 } }
        ),
      ),
      stub_with(
        "b", "\"fault\": { \"delay\": { \"fixed\": 10, \"probability\": \"0.5\" } }",
      ),
      stub_with("c", "\"fault\": { \"delay\": { \"fixed\": -1 } }"),
      stub_with("d", "\"fault\": { \"delay\": { \"fixed\": 2.5 } }"),
      stub_with("e", "\"fault\": { \"delay\": { \"fixed\": 2147483648 } }"),
      stub_with(
        "f", "\"fault\": { \"delay\": { \"uniform\": { \"min\": \"1\", \"max\": -5 } } }",
      ),
      stub_with(
        "g", "\"fault\": { \"delay\": { \"lognormal\": { \"median\": 80, \"sigma\": -0.1 } } }",
      ),
      stub_with(
        "h", "\"fault\": { \"delay\": { \"lognormal\": { \"median\": 1.5, \"sigma\": \"1\" } } }",
      ),
      stub_with("i", "\"fault\": { \"seed\": -1 }"),
      stub_with("j", "\"fault\": { \"seed\": 1.5 }"),
      stub_with("k", "\"fault\": { \"seed\": 9007199254740992 }"),
      stub_with("l", "\"fault\": { \"seed\": \"42\" }"),
    ]),
    content=(
      #|a.json: /stubs/0/fault/delay/probability: must be a number from 0 to 1
      #|a.json: /stubs/0/fault/connection/probability: must be a number from 0 to 1
      #|a.json: /stubs/1/fault/delay/probability: must be a number from 0 to 1
      #|a.json: /stubs/2/fault/delay/fixed: must be an integer from 0 to 2147483647
      #|a.json: /stubs/3/fault/delay/fixed: must be an integer from 0 to 2147483647
      #|a.json: /stubs/4/fault/delay/fixed: must be an integer from 0 to 2147483647
      #|a.json: /stubs/5/fault/delay/uniform/min: must be an integer from 0 to 2147483647
      #|a.json: /stubs/5/fault/delay/uniform/max: must be an integer from 0 to 2147483647
      #|a.json: /stubs/6/fault/delay/lognormal/sigma: must be a number of 0 or more
      #|a.json: /stubs/7/fault/delay/lognormal/median: must be an integer from 0 to 2147483647
      #|a.json: /stubs/7/fault/delay/lognormal/sigma: must be a number of 0 or more
      #|a.json: /stubs/8/fault/seed: must be an integer from 0 to 9007199254740991
      #|a.json: /stubs/9/fault/seed: must be an integer from 0 to 9007199254740991
      #|a.json: /stubs/10/fault/seed: must be an integer from 0 to 9007199254740991
      #|a.json: /stubs/11/fault/seed: must be an integer from 0 to 9007199254740991
    ),
  )
}

///|
test "a malformed fault, delay or connection Fault is a diagnostic at its JSON Pointer" {
  inspect(
    stub_problems([
      stub_with("a", "\"fault\": [\"delay\"]"),
      stub_with("b", "\"fault\": { \"delay\": 100, \"connection\": \"close\" }"),
      stub_with("c", "\"fault\": { \"delay\": { \"probability\": 0.5 } }"),
      stub_with(
        "d", "\"fault\": { \"delay\": { \"fixed\": 1, \"uniform\": { \"min\": 0, \"max\": 1 }, \"lognormal\": { \"median\": 1, \"sigma\": 1 } } }",
      ),
      stub_with(
        "e", "\"fault\": { \"delay\": { \"uniform\": { \"min\": 0 }, \"lognormal\": { \"sigma\": 1 } } }",
      ),
      stub_with(
        "f", "\"fault\": { \"delay\": { \"uniform\": [0, 1], \"lognormal\": 1 } }",
      ),
      stub_with("g", "\"fault\": { \"connection\": { \"probability\": 1 } }"),
      stub_with("h", "\"fault\": { \"connection\": { \"kind\": \"timeout\" } }"),
      stub_with(
        "i",
        (
          #|"fault": { "delayMs": 100,
          #|  "delay": { "uniform": { "min": 0, "max": 1, "mean": 1 }, "ms": 1 },
          #|  "connection": { "kind": "close", "after": 1 } }
        ),
      ),
      stub_with(
        "j", "\"fault\": { \"delay\": { \"lognormal\": { \"median\": 1, \"sigma\": 1, \"mu\": 0 } } }",
      ),
    ]),
    content=(
      #|a.json: /stubs/0/fault: must be an object
      #|a.json: /stubs/1/fault/delay: must be an object
      #|a.json: /stubs/1/fault/connection: must be an object
      #|a.json: /stubs/2/fault/delay: needs one of "fixed", "uniform" and "lognormal"
      #|a.json: /stubs/3/fault/delay: has "fixed" and "uniform" and "lognormal"; give exactly one of "fixed", "uniform" and "lognormal"
      #|a.json: /stubs/4/fault/delay/uniform: needs "max"
      #|a.json: /stubs/4/fault/delay/lognormal: needs "median"
      #|a.json: /stubs/4/fault/delay: has "uniform" and "lognormal"; give exactly one of "fixed", "uniform" and "lognormal"
      #|a.json: /stubs/5/fault/delay/uniform: must be an object
      #|a.json: /stubs/5/fault/delay/lognormal: must be an object
      #|a.json: /stubs/5/fault/delay: has "uniform" and "lognormal"; give exactly one of "fixed", "uniform" and "lognormal"
      #|a.json: /stubs/6/fault/connection: needs "kind"
      #|a.json: /stubs/7/fault/connection/kind: must be "reset", "close" or "partial"
      #|a.json: /stubs/8/fault/delayMs: is not a known field
      #|a.json: /stubs/8/fault/delay/uniform/mean: is not a known field
      #|a.json: /stubs/8/fault/delay/ms: is not a known field
      #|a.json: /stubs/8/fault/connection/after: is not a known field
      #|a.json: /stubs/9/fault/delay/lognormal/mu: is not a known field
    ),
  )
}

///|
test "a Stub has at most one connection Fault kind" {
  inspect(
    stub_problems([
      stub_with(
        "a", "\"fault\": { \"connection\": [{ \"kind\": \"close\" }, { \"kind\": \"partial\" }] }",
      ),
      stub_with(
        "b", "\"fault\": { \"connection\": { \"kind\": [\"close\", \"partial\"] } }",
      ),
      // Duplicate keys in JSON: the last one wins, as for any member.
      stub_with(
        "c", "\"fault\": { \"connection\": { \"kind\": \"close\", \"kind\": \"partial\" } }",
      ),
    ]),
    content=(
      #|a.json: /stubs/0/fault/connection: must be an object
      #|a.json: /stubs/1/fault/connection/kind: must be "reset", "close" or "partial"
    ),
  )
}

///|
test "a uniform delay's min must not exceed its max" {
  inspect(
    stub_problems([
      stub_with(
        "a", "\"fault\": { \"delay\": { \"uniform\": { \"min\": 150, \"max\": 50 } } }",
      ),
      stub_with(
        "b", "\"fault\": { \"delay\": { \"uniform\": { \"min\": 50, \"max\": 50 } } }",
      ),
    ]),
    content=(
      #|a.json: /stubs/0/fault/delay/uniform: "min" (150) must not exceed "max" (50)
    ),
  )
}

///|
test "the reset connection Fault is rejected as not supported yet" {
  inspect(
    stub_problems([
      stub_with(
        "a", "\"fault\": { \"connection\": { \"kind\": \"reset\", \"probability\": 1 } }",
      ),
    ]),
    content=(
      #|a.json: /stubs/0/fault/connection/kind: "reset" is not supported yet
    ),
  )
}
