name = "smock/smock"

version = "0.1.0"

license = "Apache-2.0"

preferred_target = "native"

warnings = "-implicit_impl_as_method"

import {
  "smock/http1@0.1.0",
  "moonbitlang/async@0.22.4",
}

options(
  "--moonbit-unstable-prebuild": "prebuild.py",
)
