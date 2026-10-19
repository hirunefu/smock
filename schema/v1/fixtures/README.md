# Definition-file fixtures

`scripts/check-schema.sh` checks every file here twice, each alone in a
definitions directory: with an external JSON Schema validator against
`../definitions.json`, and with `smock check`. Both verdicts must match the
directory the file is in, so CI fails as soon as smock and the Schema
disagree.

| Directory | The Schema | smock |
|---|---|---|
| `valid/` | accepts it | accepts it |
| `invalid/` | rejects it | rejects it |
| `invalid-beyond-schema/` | accepts it | rejects it, for a reason the Schema cannot see |

- `invalid-beyond-schema/` holds files that break a rule the Schema cannot
  express, such as a rule across the Mocks and files of a definition set:
  duplicate Mock names or Stub IDs, two Mocks that claim the same Host
  after normalisation, more than one Mock marked `default`, or a Stub that
  names a Mock no file declares.
  Files that are invalid only because of an RE2 pattern, a missing body
  file, a uniform delay whose `min` exceeds its `max`, or a Host that no
  request can carry (such as `:8080`, which normalises to no name, or
  `users:http`) belong here too, as do a response's or a `noMatch`'s
  `headers` that give two names that differ only in case, and JSON files
  that repeat a key in one object, which a JSON Schema validator reads as
  the last of them.

A field joins the Schema only together with smock's support for it, so no
fixture is accepted by the Schema and rejected by smock for a field smock
lacks.

Each definitions directory also gets the files under `body-files/` as its
body-file subdirectory (`files/`, the default), so a fixture can refer to
`users/1.json` with `bodyFile`. A fixture whose `bodyFile` names a file that
is not there belongs in `invalid-beyond-schema/`.

Adding a fixture is adding a file, named after what it shows and ending in
`.json`, `.yaml` or `.yml`. `valid/users-from-jsonnet.json` is exported from
the Jsonnet example in `docs/definition-files.md`.
