name = "smock/smock"

version = "0.1.0"

license = "Apache-2.0"

preferred_target = "native"

warnings = "-implicit_impl_as_method"

import {
  "smock/http1@0.1.0",
  "smock/re2@0.1.0",
  "smock/xml@0.1.0",
  "smock/yaml@0.1.0",
  "moonbitlang/async@0.22.4",
  "moonbitlang/x@0.5.5",
}

options(
  "--moonbit-unstable-prebuild": "prebuild.py",
)
