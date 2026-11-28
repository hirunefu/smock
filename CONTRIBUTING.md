# Contributing to smock

Bug reports and proposals are welcome as
[issues](https://github.com/hirunefu/smock/issues). Before a pull request
that changes code, open an issue and talk the approach over there, so that
the work fits where smock is going. Before merging a contributor's pull
request, the maintainer pushes its branch here, so that the
[weakening report](#the-weakening-report) and the
[changed-lines job](#the-changed-lines-job) run on it. Report a
vulnerability privately, as [SECURITY.md](SECURITY.md) says.

This document is for people who work on smock itself. It describes the
repository's layout, the pinned MoonBit toolchain, how to build and test
smock, how its tests are judged, the mutation runner, the weakening
report, the changed-lines job, how to measure the tests' costs on CI's
runners, and the release benchmark, and says where making a release is described. The
[Contributing to smock](docs/README.md#contributing-to-smock) list in
docs/README.md names the other documents for contributors: the
architecture decisions (ADRs), the glossary and the maintainer's
checklists.

## Contents

- [Layout](#layout)
- [Toolchain](#toolchain)
- [Build and test](#build-and-test)
- [How tests are judged](#how-tests-are-judged)
- [Mutation runner](#mutation-runner)
- [The weakening report](#the-weakening-report)
- [The changed-lines job](#the-changed-lines-job)
- [Test costs on CI's runners](#test-costs-on-cis-runners)
- [Benchmark](#benchmark)
- [Making a release](#making-a-release)

## Layout

The repository is a MoonBit workspace (`moon.work`) of seven modules:

| Directory | Module | What it is |
|---|---|---|
| `.` | `smock/smock` | smock itself. Its parts are packages of this module. |
| `grpc/` | `smock/grpc` | gRPC's wire rules: the content type, the 5-octet prefix that frames each message, the seventeen status codes with their names, the percent-encoding of a status message, the rules of reply metadata, and a call's `-bin` values without their padding. |
| `http1/` | `smock/http1` | The HTTP/1.1 codec. |
| `protobuf/` | `smock/protobuf` | Protobuf's wire format, a reader of Descriptor sets (FileDescriptorSets) that checks them and indexes their messages, fields, enums and methods for lookups, messages decoded into JSON and encoded from it, the well-known types in their ProtoJSON forms included, gRPC's `google.rpc.Status` encoded with error details, and JSON values checked against a field's type as smock prints it (documented in `protobuf/README.mbt.md`). |
| `re2/` | `smock/re2` | RE2-syntax regular expressions. |
| `xml/` | `smock/xml` | An XML parser that refuses DTDs, with simple paths that select values (documented in `xml/README.mbt.md`). |
| `yaml/` | `smock/yaml` | Safe-subset YAML: `parse` turns a document into the tree `@json.parse` gives for the equivalent JSON, and `write` turns a tree into a document, with comments, that `parse` reads back as the same tree. `parse` also has a YAML 1.2 mode for OpenAPI documents, which Definition files never use (documented in `yaml/yaml.mbt`). |

The six protocol modules do no I/O and do not depend on smock, so they can
be published on mooncakes on their own. `scripts/check-no-io.sh` checks
that.

`fixtures/protobuf/` holds the Descriptor sets and protobuf messages that
tests read, and the descriptor of gRPC's `health.proto` that smock embeds,
beside the `.proto` files they are built from.
`scripts/gen-protobuf-fixtures.sh` rebuilds them with the pinned protoc,
which `scripts/install-protoc.sh` installs, and CI checks on every push
that the committed ones are what their sources build; the README there
says how to add one.

Packages of `smock/smock`:

- `cmd/smock`: the `smock` binary. It ends with a status through
  `moonbitlang/x`'s `@sys.exit`, since neither core nor
  `moonbitlang/async` exposes one; smock itself binds no C for it.
- `settings`: the settings of `smock serve`, each a flag with a matching
  `SMOCK_<NAME>` environment variable, and the arguments of `smock check`,
  `smock render` and `smock import-openapi`; also the rule that derives the
  Journal's byte bound from a memory limit, which `server` reads from the
  cgroup at startup.
- `definitions`: reads a definition set, given as (name, bytes) pairs of
  JSON and YAML files, into an immutable snapshot, or into diagnostics
  (file, JSON Pointer, message). Its validation is written by hand and
  follows the JSON Schema. The snapshot holds each Mock's Stubs in matching
  order and their match index, which finds the Stubs a request can match
  by its method and exact path, each response's templates, parsed, and
  each Mock's Descriptor set, decoded.
- `engine`: decides the response to each request from the snapshot,
  including its Faults, and renders a named Stub's response for a sample
  request, for `smock render` and the Admin render operation. It also holds
  the Ephemeral Stubs, the Scenario state, the Variables and the copies of
  Data buckets per Mock and Session, and the Journal, with its bound,
  eviction counts and query filter, applies the Admin API operations on
  them (verification and the unmatched requests included), and reads the Session a request carries in its W3C Baggage header. `Engine(snapshot, match_index=false)` tries every Stub in
  matching order instead of using the index; tests check the index against
  it.
- `template`: response templates: text templates (`${ expr }` in a body,
  a body file, a header value or an event field) and structured templates
  (`json` with `$each` and `$if`), the expression grammar, the helpers by
  family (fake data with its word and name lists, time and dates,
  conversions, strings, encodings, JWTs, and arithmetic in exact decimal
  with integers only), and escaping by media type. It parses a template
  once, with the values of the environment variables `--template-env`
  lists, which its caller reads, and renders it for a request, the time,
  one 64-bit draw and the Variables and Data buckets it reads, and writes
  JSON with smock's own number form, compact for responses and indented
  for the files `smock import-openapi` writes. It renders the values of a
  Stub's `variables` as JSON too.
- `importopenapi`: converts an OpenAPI document into a Definition file,
  for `smock import-openapi`. It takes the documents as (name, bytes)
  pairs and returns the names of the documents it still needs, or the
  file's bytes with the warnings, or the errors, each with a JSON Pointer
  into a document. The output's name picks YAML, written with
  `smock/yaml` and with comments that map Stubs back to the document, or
  JSON. `cmd/smock` reads the documents it asks for, under `--ref-dir`,
  and writes the file. Before it returns a file, it loads it with
  `definitions`, as `smock check` would. Its parts, one file each, are
  listed in `importopenapi/import.mbt`.
- `llm`: LLM responses. It writes a reply declared by its content in one
  LLM API's wire form, from the declaration's strings, the request's JSON
  body, the time and the ids generator, and returns the headers smock sets
  with the body. It also holds each API's vocabulary and the load checks
  that `definitions` uses. It imports neither `definitions` nor `engine`,
  and draws no wait.
- `prng`: the seeded pseudo-random generator that Fault decisions and
  template helpers draw from. Its sequence for a seed is fixed, the same on
  every target.
- `cookies`: reads the cookies of a request from its `Cookie` fields, for
  cookie conditions, the Near miss and the `cookie` root of templates, so
  that all of them read cookies by the same rules.
- `unicode`: simple case mapping and the White_Space property, for the
  template helpers `uppercase`, `lowercase` and `trim`, from the data of
  one pinned Unicode version (18.0.0). `scripts/gen-unicode-data.py`
  generated the data from the Unicode Character Database; it changes only
  with a new format version. A workflow checks that the data is still what
  the script writes ([Build and test](#build-and-test)).
- `defdir`: reads the definitions directory and loads it, for
  `smock serve`, `smock check` and `smock render`, and takes the stamp of
  it that a poll compares (native).
- `server`: the listeners, the HTTP/1.1 and HTTP/2 connection loops and
  the Admin API (native). HTTP/2's framing, header compression and
  connection state come from the `http2` package of moonbitstack/moonhttp
  ([ADR 0005](docs/adr/0005-http2-comes-from-moonhttp.md)).
  On the TLS port the same loop reads and writes through a TLS stream; on
  the admin port it answers the Admin API. It reloads rotated certificates,
  and reads the SNI name from the ClientHello, with `serverparsers`, before
  OpenSSL sees it, so that the name chooses the certificate without a C
  callback. Its one C function, in `server/reset.c`, sets `SO_LINGER` so
  that the reset Fault ends a connection with an RST, the exception
  ADR 0001 makes for it.
- `serverparsers`: the parsers of `server` that do no I/O, in a package of
  their own so that in-process tests reach them, on `wasm-gc` as well as
  natively. It reads the host name that a TLS ClientHello asks for by SNI
  (RFC 6066, section 3) from the octets a client has sent so far, or tells
  that more octets are needed; `server` reads them from the socket and
  chooses the certificate by the name. It reads the Admin API's bearer
  token and path parameters, and makes smock's own checks of an HTTP/2
  request: whether HTTP/1.1's rules refuse it, and the body length its
  `content-length` declares. It builds the reply of a Mock's reflection
  service to the first request message of a call, which `server` sends,
  and reads when a certificate expires from its PEM, which `server`
  reports in the expiry metric. It imports no moonhttp
  ([ADR 0005](docs/adr/0005-http2-comes-from-moonhttp.md),
  [ADR 0006](docs/adr/0006-tests-are-judged-by-four-ledgers.md)): anything
  that needs it stays in `server`. Its tests read no files: the
  ClientHellos they start from, captured from a real client, are bytes in
  the test source, the reflection service's Descriptor sets and messages
  are protoc's, which `scripts/gen-protobuf-fixtures.sh` writes in hex
  there, and the certificates are RFC 7468's examples or built in the
  test.
- `watch`: polls the definitions directory and the certificate files
  every second, so that `server` can reload them (native). It uses no
  file-system events until a release of the async runtime fixes its file
  watcher ([Reloading](docs/definition-files.md#reloading) says why). Its
  `Schedule` keeps the poll interval, the 250 ms quiet period that lets a
  change settle before it is read, and the 10 s after which a change that
  never settles is read all the same, and decides which stamps lead to a
  read. It does no I/O and reads no clock. A poll reads nothing unless the
  `Stamp` of what the caller reads (the names it lists, and where the
  files it reads really are and their times) may have changed since the
  last one. It first takes a glance at the change time of each file and
  directory the last stamp looked at, one call each, and takes the stamp
  only when one changed, or every 10 s.
- `metrics`: the metrics registry: counters, gauges and histograms with
  fixed label names, rendered in the Prometheus text format. Features
  register their metrics in the one registry `smock serve` keeps.
- `usage`: understands what Linux says a process and its cgroup use, and
  how long the process waited for a CPU, in `/proc/self/stat`,
  `/proc/self/status`, `/proc/self/schedstat` and a cgroup v2's `cpu.stat`
  and `memory.peak`, for the process and cgroup metrics; the machine's
  steal time in `/proc/stat`; and where `/proc/self/cgroup` puts the
  process's cgroup, for those and for the memory limit the Journal's bound
  follows. It does no I/O: `server` reads the files and hands it their
  text.
- `openssl`: smock's own bindings to OpenSSL, the one C library ADR 0001
  allows (native). A TLS connection there does no I/O: it takes the bytes
  that arrive from the peer and hands out the bytes to send, and `server`
  carries them over the socket. It also generates self-signed certificates
  in memory. Its C is `openssl/openssl.c`. Its ALPN callback picks the
  server's first protocol that the client offers, and leaves `h2` out over
  a TLS 1.2 suite that HTTP/2 prohibits. The client side
  (`openssl/client.mbt`) offers ALPN: the e2e tests speak HTTP/2 over the
  TLS port with it, and the bindings' own tests run a client and a server
  in memory under the sanitizers, some with the client held to TLS 1.2 and
  chosen suites. That file also tells which protocol ALPN selected, which
  `server` asks of each TLS connection.
- `testcerts`: a test PKI (a root CA, an intermediate CA, RSA and ECDSA
  leaf chains for `localhost` and `127.0.0.1`, and ECDSA leaf chains for
  `users.example.com` and `orders.example.com`, each leaf with its own fixed
  expiry), used only by tests. `scripts/gen-test-certificates.sh`
  regenerates it.
- `log`: the JSON logger, one object per line, in smock's own shape or in
  the Mockoon CLI's envelope, the Mockoon-equivalent lines, and the RFC 3339
  times it writes, which the Admin API and the CLI also read.
- `buildinfo`: the version, commit and toolchain the binary was built with.
- `e2e`: tests that run the `smock` binary as a black box (native).
- `protobuf-conformance`: the testee of protobuf's conformance suite, a
  program built on `smock/protobuf`, with the list of the suite's cases
  that the module fails (native). smock's image does not hold it.
  `scripts/check-conformance.sh` runs the suite on it
  ([protobuf-conformance/README.md](protobuf-conformance/README.md)).
- `yaml-test-suite`: the testee of the YAML test suite, a program built on
  `smock/yaml` that reads each case in both of the parser's modes, with
  each mode's list of the suite's cases that do not pass (native). smock's
  image does not hold it. `scripts/check-yaml-test-suite.sh` runs the
  suite on it ([yaml-test-suite/README.md](yaml-test-suite/README.md)).
  The repository holds none of the suite: `scripts/fetch-yaml-test-suite.sh`
  fetches its pinned release and checks it against its SHA-256.
- `schema`: a test over every Definition-file fixture in
  `schema/v1/fixtures/` that needs no `smock` binary: each, written as YAML
  by `smock/yaml`, reads back as the same tree (native).

A package that does I/O or uses FFI declares `supported_targets = "native"`.
Every other package also builds for `wasm-gc`, and CI tests it there. The
packages that decide a response, `definitions`, `engine`, `template` and
`llm`, the ones they import, `prng`, `cookies`, `unicode` and `log`, the
OpenAPI converter, `importopenapi`, and the parsers of `server` that do no
I/O, `serverparsers`, must stay that way:
`scripts/check-no-io.sh` fails if one of them leaves out `wasm-gc`, reads
the environment, binds C or imports a package that does I/O.

`openapi/admin.json` is the OpenAPI 3.1 document of the Admin API, the
contract for it as the JSON Schema is for Definition files; a client can be
generated from it in any language.

`Dockerfile` packs the release binary into the container image, and
`.github/workflows/release.yml` publishes the image and the release binaries
(see [docs/installing.md](docs/installing.md)).
`charts/smock/` is the Helm chart, which the release workflow publishes too
(see [Helm chart](docs/installing.md#helm-chart)).

`schema/v1/definitions.json` is the JSON Schema of Definition files, the
contract for their format. `.github/workflows/schema-pages.yml` publishes it
on GitHub Pages, and `schema/v1/fixtures/` holds the Definition files that
CI checks with both the Schema and smock.

`bench/` is the release benchmark, and `.github/workflows/benchmark.yml`
runs it when started by hand; `scripts/gke-bench.sh` runs it on GKE
Autopilot before an integration branch is merged into `main` (see
[Benchmark](#benchmark)).

`.github/workflows/measure-costs.yml` measures what the tests cost on CI's
runners when started by hand, with `scripts/measure-costs.py`, and
`scripts/estimate-costs.py` recomputes the test review's cost model from
it (see [Test costs on CI's runners](#test-costs-on-cis-runners)).

`.github/workflows/e2e-repeat.yml`, started by hand, runs the e2e tests
many times on one runner, to show that a timing test holds on CI's
runners (see [Build and test](#build-and-test)).

`.github/workflows/mutation-runs.yml` runs the mutation runner's bulk
runs in shards on GitHub's runners and merges them into one report: the
weekly and the monthly runs on a schedule, the others when started by
hand (see [Bulk runs on Actions](#bulk-runs-on-actions)).

`scripts/h2spec/` holds the Definition file that CI serves to h2spec, the
HTTP/2 conformance tool, and the lists of h2spec's cases that do not pass on
the plain port and on the TLS port, each with its reason (see
[Build and test](#build-and-test)).

`scripts/grpcurl/` holds the definition set that CI serves to grpcurl, a
real gRPC client, and the calls grpcurl makes, each with what it prints
(see [Build and test](#build-and-test)).

`scripts/coverage-tests/` holds the small bisect reports, and the small
source tree they describe, that test the coverage report of
`scripts/coverage.sh` and the coverage ratchet (see
[Build and test](#build-and-test)); `e2e/` under it, those that test the
report of the coverage from the e2e tests, with the compiler's parse trees
of its files (see
[Coverage from the e2e tests](#coverage-from-the-e2e-tests)).

`coverage/` holds the coverage floors, each package's most uncovered
points, and the list of the raises of a floor that a change recorded (see
[The coverage floors](#the-coverage-floors)).

`exclusions.toml` is the exclusion list, which accepts a surviving mutant
or an uncovered point with a category, a reason and its reviewer, and
which both ledgers read (see [Exclusions](#exclusions)).

`scripts/mutation/` holds the mutation runner, its site finder, operator
set v1 (`operators.py`), the runner's self-test (`selftest.py`), the
site-count ratchet (`ratchet.py`), and the module their tests run on,
`scripts/mutation/fixture`, which is not a member of the workspace (see
[Mutation runner](#mutation-runner)).

## Toolchain

The MoonBit toolchain version is pinned in `.moonbit-version`, and CI installs
exactly that version, as does the release workflow; the release notes name
it. A weekly run also builds and tests with the latest stable MoonBit,
the modules smock imports included, and opens an issue when that fails
(`.github/workflows/latest-toolchain.yml`). A scheduled run builds nothing
when the latest toolchain is the pinned one and a CI run on a push of
`main`'s head, the commit the scheduled run checks out, succeeded and was
last updated within 7 days, since it would only repeat that run
(`scripts/latest-toolchain-plan.sh`); a run started by hand always builds.
moonbitstack/moonhttp is pinned to one exact version, and raised only on
purpose ([Upgrading moonhttp](docs/releasing.md#upgrading-moonhttp)).

## Build and test

To run a commit that no release holds yet, build it from a checkout:

```sh
moon build --target native
SMOCK_ADMIN_TOKEN=change-me _build/native/debug/build/smock/smock/cmd/smock/smock.exe serve --dir defs
```

The tests and checks:

```sh
moon test --target native      # every module
moon test --target wasm-gc     # every package that does no I/O
moon check --deny-warn --target all
moon fmt --check
moon bench -p smock/smock/engine --release   # match index lookups: 100 vs 10,000 Stubs
scripts/coverage.sh            # point coverage of the in-process tests, per package (needs python3)
python3 scripts/coverage-ratchet.py check _coverage/coverage.bisect   # each package's uncovered points against its floor, and the floors against the merge base with main (after scripts/coverage.sh; needs git)
scripts/check-no-io.sh         # no I/O in the protocol modules, the packages that decide a response, the OpenAPI converter and server's parsers
scripts/check-no-c.sh          # the C boundary of ADR 0001, in smock and in the modules it resolves (after moon check; needs jq)
scripts/check-moonhttp-pin.sh  # the build resolves the moonhttp that moon.mod names (needs jq)
scripts/check-notice.sh        # NOTICE names the toolchain and every module the build resolves (needs jq)
scripts/test-dependency-checks.sh    # the three checks above, on copies of the modules they read (after moon check; needs jq)
scripts/test-openssl-asan.sh   # the OpenSSL bindings under AddressSanitizer and LeakSanitizer
scripts/build-release.sh       # dist/smock
dist/smock --version
scripts/check-schema.sh dist/smock   # the JSON Schema and smock agree
scripts/install-jsonnet.sh     # the pinned jsonnet, into ~/.local/bin
python3 scripts/check-doc-examples.py dist/smock   # every whole Definition file in the user documents passes smock check, and the Mockoon guide's and the Jsonnet example's commands do what the documents say (needs jsonnet and jq)
scripts/install-h2spec.sh      # the pinned h2spec, into ~/.local/bin
scripts/check-h2spec.sh dist/smock   # h2spec's conformance cases against the plain and TLS ports (needs h2spec, python3 and jq)
scripts/install-grpcurl.sh     # the pinned grpcurl, into ~/.local/bin
scripts/check-grpcurl.sh dist/smock  # grpcurl calls smock on the plain and TLS ports, and the gRPC guide shows those calls (needs grpcurl, curl and jq)
scripts/test-check-grpcurl.sh dist/smock   # that check fails on each difference
docker build --tag smock:dev .
scripts/smoke-test-image.sh smock:dev 0.0.0-dev <commit> "moonc <version>"   # the container image
scripts/test-helm-chart-on-kind.sh smock:dev   # the chart on a kind cluster (needs kind, kubectl and helm)
scripts/check-release-workflow.sh    # the release workflow publishes only for tags, and only after its checks of the tag, and the check of the weekly mutation run knows each job of that run (needs yq, jq and python3)
scripts/test-check-release-workflow.sh   # that check, on copies of the workflows changed one thing at a time (needs yq, jq and python3)
scripts/test-release-notes.sh        # the release notes, with CHANGELOG.md's links at the release's tag
scripts/test-release-gates.sh        # the release workflow's checks that CI passed on a tag's commit, that the tag names moon.mod's version, and that the latest weekly mutation run passed its jobs that decide a verdict and is clean in the packages at L4, with fake gh runs on small git histories (needs python3, git and jq)
python3 scripts/check-weekly-run.py <commit>   # whether the latest weekly mutation run lets the commit be released (needs git and gh)
scripts/check-benchmark-workflow.sh  # the benchmark workflow runs only by hand (needs yq and jq)
scripts/check-measure-costs-workflow.sh   # the workflow that measures the tests' costs runs only by hand, with no C flags (needs yq and jq)
scripts/test-check-measure-costs-workflow.sh   # that check, on copies of the workflow changed one thing at a time (needs yq and jq)
scripts/test-measure-costs.sh        # the measurement of the tests' costs, against a fake moon (needs python3 and jq)
scripts/test-estimate-costs.sh       # the cost model recomputed from made-up measurements (needs python3)
scripts/check-e2e-repeat-workflow.sh       # the e2e repeat workflow runs only by hand, as many times as asked, on the architecture asked for (needs yq and jq)
scripts/test-check-e2e-repeat-workflow.sh  # that check, on copies of the workflow changed one thing at a time (needs yq and jq)
scripts/test-repeat-e2e.sh           # the script that runs the e2e tests again and again, with a fake moon
scripts/check-unicode-data-workflow.sh   # the Unicode data workflow runs when its files change and weekly, and runs the generator's check (needs yq and jq)
scripts/test-check-unicode-data-workflow.sh   # that check, on copies of the workflow changed one thing at a time (needs yq and jq)
scripts/check-ci-artifacts.sh        # when CI's jobs and steps run, and that it keeps the release binaries only from a run whose every job passed (needs yq and jq)
scripts/test-check-ci-artifacts.sh   # that check, on copies of the workflows changed one thing at a time (needs yq and jq)
scripts/test-ci-plan.sh              # the plan that skips the tests on main of a tree that already passed (needs git and jq)
scripts/test-latest-toolchain-plan.sh   # the plan that skips the weekly run with the latest MoonBit when it would repeat CI (needs jq)
scripts/check-branch-checks-workflow.sh   # the branch checks workflow writes the weakening report on each push to a branch but main (needs yq and jq)
scripts/test-check-branch-checks-workflow.sh   # that check, on copies of the workflow changed one thing at a time (needs yq and jq)
python3 scripts/weakening-report.py --base origin/main   # what this branch weakens, against its merge base with main (needs git)
scripts/test-weakening-report.sh     # the weakening report, on small git histories, and its list of the files that decide a verdict (needs python3, git and yq)
scripts/test-changed-lines.sh        # the changed-lines job of the branch checks, with a fake mutation runner on small git histories (needs python3, git and jq)
python3 scripts/check-merge.py <branch>   # whether the branch checks on the branch's head let it be merged into main, and its weakening report (needs git and gh)
scripts/test-check-merge.sh          # the merge check, with a fake gh and canned runs on a small git history (needs python3, git and jq)
scripts/check-mutation-canary-workflow.sh   # the mutation canary workflow runs only by hand or when the weekly mutation run calls it, and installs its commit's toolchain before the replay (needs yq and jq)
scripts/test-check-mutation-canary-workflow.sh   # that check, on copies of the workflow changed one thing at a time (needs yq and jq)
scripts/check-mutation-runs-workflow.sh   # the bulk mutation runs run only on their weekly and monthly schedules and by hand, named by their mode, in shards within the width and a job's 6 hours, on amd64, with the weekly run's canary, properties with random seeds and coverage from the e2e tests (needs yq and jq)
scripts/test-check-mutation-runs-workflow.sh   # that check, on copies of the workflow changed one thing at a time (needs yq and jq)
scripts/check-coverage-e2e-workflow.sh    # the coverage from the e2e tests runs only by hand or when the weekly mutation run calls it, on amd64, and keeps its report (needs yq and jq)
scripts/test-check-coverage-e2e-workflow.sh   # that check, on copies of the workflow changed one thing at a time (needs yq and jq)
scripts/test-sbom.sh                 # the SBOM scripts, and the check that the SBOM and NOTICE agree (needs jq)
scripts/test-h2spec-verdict.sh       # how a run of h2spec is judged against its list of cases
scripts/test-yaml-test-suite-verdict.sh   # how a run of yaml-test-suite is judged against its lists of cases
scripts/test-check-schema.sh         # the JSON Schema cross-check, with a fake validator and a fake smock (needs jq)
scripts/test-check-doc-examples.sh   # the check of the documents' examples, with a fake smock and a fake jsonnet (needs python3 and jq)
scripts/test-coverage-report.sh      # the coverage report, on small bisect reports (needs python3)
scripts/test-coverage-ratchet.sh     # the coverage ratchet, on small bisect reports in small git histories (needs python3 and git)
scripts/test-coverage-e2e.sh         # the report of the coverage from the e2e tests, on small bisect reports and parse trees (needs python3)
scripts/test-random-seeds.sh         # the script that writes random seeds into the properties, on a copy of re2's property and on small trees (needs python3)
python3 scripts/check-doc-links.py   # the documents' links into the repository lead to a file, and to a heading when they name one (needs git)
scripts/test-check-doc-links.sh      # that check, on small trees (needs python3 and git)
scripts/check-openapi.sh             # the Admin API document is valid OpenAPI 3.1
python3 bench/gen_definitions.py --check   # the benchmark's committed definitions are what their generator writes
python3 scripts/gen-unicode-data.py --check   # unicode/data.mbt is what its generator writes (downloads from unicode.org)
scripts/install-protoc.sh            # the pinned protoc, into ~/.local/bin, with its well-known types
PROTOC=~/.local/bin/protoc scripts/gen-protobuf-fixtures.sh --check   # the protobuf fixtures are what their sources build
PROTOC=~/.local/bin/protoc scripts/test-protobuf-fixtures.sh          # that check, on a copy of the working tree
python3 -m unittest discover -s bench -p test_compare.py -v   # the benchmark's comparison of two runs, which the merge checklist reads
python3 scripts/check-kept-tests.py   # every test that the keep list, mutation/kept-tests.toml, names is still there (needs Python 3.11 or later)
scripts/test-check-kept-tests.sh     # that check, on small trees
scripts/test-trace-links.sh          # the trace links of the removal proof (scripts/trace-links.py), on small git histories with a stand-in for gh (needs python3 and git)
python3 scripts/check-ledgers.py     # every test that the use-case and boundary ledgers, docs/ledgers/, name is still there, and each row's status agrees with what it names
scripts/test-check-ledgers.sh        # that check, on small trees
helm lint --strict charts/smock --set adminAuth.tokenSecret.name=smock-admin-token   # the Helm chart passes helm's lint (needs helm)
scripts/test-helm-chart.sh           # rendering tests of the Helm chart (needs helm, yq and jq)
python3 -m unittest discover -s bench -p test_gke_script.py -v   # scripts/gke-bench.sh against fake gcloud, kubectl and docker commands, about 5 minutes
scripts/build-conformance-runner.sh  # protobuf's conformance runner, from the pinned release, into ~/.local/bin (needs CMake and a C++17 compiler)
scripts/check-conformance.sh         # protobuf's conformance suite against smock/protobuf, judged by protobuf-conformance/failure_list.txt
scripts/fetch-yaml-test-suite.sh     # the pinned release of the YAML test suite, into _build/yaml-test-suite
scripts/check-yaml-test-suite.sh     # the YAML test suite against smock/yaml in both modes, judged by yaml-test-suite/safe.txt and openapi.txt (fetches the suite first)
scripts/check-llm-sdks.sh dist/smock # the official LLM SDKs, pinned by hash, read smock's LLM responses (needs python3 and PyPI)
python3 -m unittest discover -s scripts/mutation -v   # the mutation runner and its site finder, on a module whose mutants are known, the exclusion list and the bulk runs' steps (needs git, moon and moonc)
python3 scripts/mutation/exclusions.py check   # each entry of the exclusion list has a category and what it needs, no adversarial attempt is still pending, and the stale ones are listed (needs moonc)
python3 scripts/mutation/exclusions.py check --allow-pending   # the same on a ticket branch before the separate context has made the adversarial attempts, listing the pending ones
python3 scripts/mutation/exclusions.py review --base origin/main   # the entries this branch adds or changes, and those the maintainer reads (--seed <run ID of the packages run on the frozen tip> draws one in five)
python3 scripts/check-e2e-helpers.py   # no e2e test file uses what another test file defines (needs moon and moonc)
scripts/test-check-e2e-helpers.sh    # that check, on small modules (needs python3, moon and moonc)
python3 scripts/mutation/run.py --root scripts/mutation/fixture --self-test-only calc log   # the mutation runner's self-test, on its fixture (needs git, moon and moonc)
python3 scripts/mutation/ratchet.py write   # the site counts of each package, into mutation/site-counts/ (needs moonc)
python3 scripts/mutation/ratchet.py check --base origin/main   # the site counts are the commit's, and no package's sites drop beyond what the change deletes or changes (needs git and moonc)
```

To run one package's tests, name it with `-p`. The six protocol modules,
`grpc`, `http1`, `protobuf`, `re2`, `xml` and `yaml`, are modules of their
own in `moon.work`, so their packages are `smock/<name>`; every other
package is `smock/smock/<directory>`:

```sh
moon test --target wasm-gc -p smock/grpc
moon test --target native -p smock/smock/engine
```

A wrong package path runs no test and still exits with 0: moon only warns
that the package is not found, and reports `Total tests: 0`. So
`-p smock/smock/grpc` looks like a pass. Read the count of tests that the
run reports.

`scripts/test-helm-chart.sh` renders `charts/smock` for each delivery mode
of the Definition files and each Admin API authentication and TLS option,
and checks the manifests, the Restricted Pod Security Standard included,
the notes an install shows, and that the chart's README lists every value
with its default.
`scripts/test-helm-chart-on-kind.sh` creates a kind cluster, checks every
delivery mode against Kubernetes' own Pod Security admission, installs the
chart with the image into a namespace that enforces the Restricted
standard, and checks that a Stub answers and that a ConfigMap update is
served without a Pod restart; it deletes the cluster afterwards. CI splits
it in two, so that the cluster is created while smock builds:
`--start <state directory>` starts creating the cluster in the background
and returns, and `--cluster <state directory> <image>` waits for it and
does the rest. `scripts/install-kubernetes-tools.sh` installs the pinned
helm, kubectl and kind that CI uses.

`scripts/check-schema.sh` runs the external validator check-jsonschema
once over all the fixtures, through `uvx` (or `pipx`), and needs `jq`;
`scripts/check-openapi.sh` runs openapi-spec-validator the same way, on
the Admin API document. The Admin API tests in `e2e/` check
every response against `openapi/admin.json` (`e2e/contract_test.mbt`).
`e2e/import_openapi_golden_test.mbt` imports `openapi/admin.json`, the
example of [docs/importing-openapi.md](docs/importing-openapi.md) and the
OAI's Petstore (`e2e/golden/documents/`) with the binary, and compares each
result with its committed golden file. A change to what the import writes,
or to one of these documents, regenerates the golden file in the same
change, with the command that the failing test prints. The goldens in
`engine/llm_golden_*_test.mbt` compare what `llm` Stubs send with the
examples of the vendors' documents, through the comparison in
`engine/llm_golden_test.mbt`. Each example is copied there with its source
and the date it was read. Those from OpenAI's OpenAPI document come with
its licence, MIT. Anthropic's documents and OpenAI's guides grant none, so
their examples are short excerpts, used as test data only. Each golden
names the fields and events where smock differs on purpose; any other
difference fails the test. `e2e/mockoon_golden_test.mbt` compares smock's
lines in the `mockoon` log format with lines that the Mockoon CLI wrote in
a local trial, in `e2e/golden/mockoon/` with a note of their source, after
one rule for each difference decided on purpose; any other difference
fails the test. Adding a fixture file under
`schema/v1/fixtures/` adds it to the cross-check; the README there says
which directory a fixture belongs in.

`scripts/check-doc-examples.py` runs the examples of the user documents,
those that [docs/README.md](docs/README.md) lists before "Contributing to
smock", with a smock binary. A fenced block in YAML or JSON whose
top-level keys are all fields of a Definition file (`version`, `mocks`,
`stubs` and `data`) is a whole Definition file; every other block is a
fragment, and is set aside. `smock check` must pass on each whole file
alone, and the check prints how many it found and how many blocks it set
aside. An example that leaves something out, such as a Mock that another
block declares or a body file whose content it does not show, gets it
from `scripts/doc-examples/context.txt`. A line there names the example
by its document and its number among the document's whole Definition
files, as the check prints it, so a change that adds an example that
needs context, or moves one, changes the file in the same commit. The
check also runs the [Mockoon guide](docs/migrating-from-mockoon.md)'s
`smock check` and `smock render` commands as the guide writes them, in a
copy of `docs/examples/from-mockoon/`, and their output must be what the
guide shows after them. Last, it exports the
[Jsonnet example](docs/definition-files.md#writing-definition-files-in-another-configuration-language)
with the jsonnet that `scripts/install-jsonnet.sh` pins, checked against
its SHA-256, runs `smock check` on the export, and compares the export
with the fixture `schema/v1/fixtures/valid/users-from-jsonnet.json`. CI
runs it in the job `release`, on the binary that job builds, on both
architectures. To run it locally:

```sh
scripts/install-jsonnet.sh
scripts/build-release.sh
python3 scripts/check-doc-examples.py dist/smock
```

`mutation/kept-tests.toml` is the keep list of the test review
([Removing a test](#removing-a-test)): the tests that
removal rule (C) keeps for a reason that the kill matrix cannot see,
each with its reason and the source of what it checks, and for each reason
the searches that found its tests. A removal batch never proposes a test
on it. `scripts/check-kept-tests.py` fails when a test that the list names
is no longer there, so a change that renames, moves or removes a listed
test changes the list in the same commit.

`mutation/site-counts/` holds each package's count of mutation sites, per
definition and operator ([The site counts](#the-site-counts)). CI's job
`checks` fails when they are not what the site finder gives on the
commit, so a change to a package's source, other than to its tests, runs
`python3 scripts/mutation/ratchet.py write` and commits what it writes.

`mutation/shard-times.jsonl` records the shards of earlier bulk mutation
runs and how long each took, from which the bulk runs' planned time of a
mutant comes ([Bulk runs on Actions](#bulk-runs-on-actions)). The bulk
runs' tests fail when `SECONDS_PER_MUTANT` in `scripts/mutation/bulk.py`
is not what the record gives, so a change that adds a slower run raises
it too.

[`docs/ledgers/`](docs/ledgers/use-cases.md) holds the use-case and
boundary ledgers of the test review
([The four ledgers](#the-four-ledgers)): each documented feature, message
and limit, with its source and the tests that check it.
`scripts/check-ledgers.py` fails in the same way when a test that a ledger
names is no longer there, and when a row's status does not agree with what
it names.

`scripts/check-h2spec.sh` runs h2spec 2.6.0, the HTTP/2 conformance tool,
against a smock binary: every case of its `generic`, `http2` and `hpack`
sections, strict cases included, against the plain port, as h2c, and then
against the TLS port, as h2 by ALPN, with the self-signed certificate,
which h2spec does not verify. `scripts/check-h2spec.sh dist/smock tls` runs
one port alone. Both ports take under a second on CI's runners. smock serves `scripts/h2spec/definitions`, where a Stub at
`/`, the path h2spec requests, answers every method with 200 and a body of
4 KiB; without a body, h2spec would skip its flow-control cases.
`scripts/h2spec/plain.txt` and `scripts/h2spec/tls.txt` list the cases that
do not pass on each port, each with its reason: a case that h2spec skips, a case left out,
whose outcome does not count, or a case that fails until the issue named
beside it is done. A case that fails or is skipped without being listed so
fails the run, and so does a listed case that h2spec no longer has. The
output lists every listed case with its outcome and reason, and names each
listed case that passed, so that it can come off the list. h2spec checks
RFC 7540 and RFC 7541 only; the e2e tests cover what RFC 9113 adds to the
rules for header fields.

h2spec publishes a Linux binary for amd64 only. `scripts/install-h2spec.sh`
installs h2spec 2.6.0 into a directory, `~/.local/bin` unless one is given:
on amd64, the release binary, checked against its SHA-256; on arm64, a
build from h2spec's `v2.6.0` tag, checked against the tag's commit, with Go
1.27.3, which it downloads, checks against its SHA-256 and removes again.
The build needs `git` and downloads about 70 MB. `scripts/check-h2spec.sh`
runs the h2spec it finds on `PATH`. On either architecture, then:

```sh
scripts/install-h2spec.sh
scripts/build-release.sh
scripts/check-h2spec.sh dist/smock
```

`scripts/check-grpcurl.sh` calls a smock binary with grpcurl 1.9.4, a
real gRPC client. smock serves `scripts/grpcurl/definitions`: the Mock of
the [gRPC guide's quick start](docs/grpc.md#quick-start), with reflection
and health on, and a second Mock, so that only grpcurl's `-authority`
reaches the first. Each file of `scripts/grpcurl/calls` is one call: its
grpcurl command, as the guide writes it for the plain port, then what
grpcurl prints, and its exit status when it is not 0. Each call runs on
the plain port over h2c, and on the TLS port over h2 with the self-signed
certificate, which grpcurl's `-insecure` does not verify. They list and
describe the services through reflection, call with JSON and metadata,
make the same calls with `-protoset` and no reflection, print an error's
details with `-format-error`, check health through reflection, call
another Host, and call in a Session whose Ephemeral Stub the script adds
first. Any difference fails the run, which shows it and what grpcurl
printed. The script also checks the guide: each grpcurl command the guide
shows must be one of these calls, the output it shows after one must be
what grpcurl prints, and it must show the set's Definition file.
`scripts/test-check-grpcurl.sh` checks that each kind of difference fails
the check. To add a call, add its file, run the script, and compare what
it prints with what the file says. `scripts/install-grpcurl.sh` installs
grpcurl 1.9.4, checked against its SHA-256, into a directory,
`~/.local/bin` unless one is given, on linux/amd64 and linux/arm64:

```sh
scripts/install-grpcurl.sh
scripts/build-release.sh
scripts/check-grpcurl.sh dist/smock
```

`scripts/coverage.sh` runs every package's in-process tests with
coverage, in a target directory of its own, `_coverage` unless
`--target-dir` names another, and prints each package's points covered
of all, its uncovered points with their file, line and definition, and
line figures beside them; a line counts as covered only when every point
on it is. A summary gives the totals inside and outside `server` and
`cmd/smock`, which only the binary runs. The packages that build on
wasm-gc run there, except `yaml`, whose deepest nesting test overflows
wasm-gc's stack when instrumented; `yaml` and the native-only packages
run natively, with at most two build jobs (`--jobs`). `e2e` does not run,
nor does the mutation runner's fixture module, which is not a member of
the workspace.
`cmd/smock` has no tests, so its points come from an instrumented build
that nothing runs. The first run builds everything with coverage and
takes a few minutes; a later run rebuilds only what changed. It reads
every trace source in the target directory, so remove the directory
after removing a package.

What the e2e tests reach in the binary is counted apart. With
`SMOCK_COVERAGE_DUMP` set and not empty, smock writes its coverage
counters to stdout as it exits, after all else it writes there, in the
form core's coverage runtime prints them: the line
`----- BEGIN MOONBIT COVERAGE -----`, a JSON object of counts, and the
line `----- END MOONBIT COVERAGE -----`. A build without coverage writes
an empty object. Nothing else in what smock does changes, and the
variable is for these runs only, so the user documents leave it out. Build the instrumented binary in a target
directory of its own (`scripts/coverage.sh` builds the same one), then
run the e2e tests with `SMOCK_E2E_BINARY` naming it and
`SMOCK_COVERAGE_DUMP` naming an empty directory, each absolute or
relative to the module root:

```sh
moon build --target native --enable-coverage --target-dir _coverage cmd/smock
rm -rf _coverage/e2e
SMOCK_E2E_BINARY=_coverage/native/debug/build/smock/smock/cmd/smock/smock.exe \
  SMOCK_COVERAGE_DUMP=_coverage/e2e moon test --target native -p smock/smock/e2e
```

With `SMOCK_E2E_BINARY` set, the harness runs that binary and builds
nothing; without it, it builds and runs the native debug build, as
usual. Build the binary from the commit checked out: the test of
`smock --version` checks that it names that commit. With
`SMOCK_COVERAGE_DUMP` set, it gives the variable to every
smock it starts, `smock serve` and the one-shot commands alike, takes
the counters out of each one's stdout before a test reads it, and keeps
them in that directory as runtime logs, `moonbit_coverage_e2e_*.txt`.
The e2e package stays a plain build: its own coverage, of the clients
its tests run, is not smock's. Read the logs with the toolchain's
coverage reader directly, as `scripts/coverage.sh` does, with the target
directory's trace sources. A run leaves hundreds of logs, so join them
into one first: the reader counts a file of several sets of counters as
it counts the files apart. Give it that script's logs too to merge the
two:

```sh
find _coverage/e2e -name '*.txt' -exec cat {} + >_coverage/e2e.txt
find _coverage -name '*.trace.source' -exec moonrun "$(dirname "$(command -v moonrun)")/moon_cove.wasm" \
  -- -f bisect -o _coverage/e2e.bisect -t _coverage/e2e.txt {} +
python3 scripts/coverage-report.py _coverage/e2e.bisect
```

`scripts/coverage-e2e.sh --out <dir>` takes all these steps, the
in-process tests' included, and writes the report that the weekly run
keeps into `<dir>`
([Coverage from the e2e tests](#coverage-from-the-e2e-tests)).

A smock process writes no counters when it does not reach its exit:
when a signal it leaves at its default action ends it (SIGKILL, SIGINT
and SIGHUP, or an out-of-memory kill), when it aborts, and when it
prints the usage or the version (`smock`, `smock help`, `--help`,
`--version`), which the argument parser does and then exits itself. The
two tests that close and stall smock's stdout
(`e2e/mockoon_log_test.mbt`) get none either: its reading end is closed
by the time smock exits. The harness expects this: such a process leaves
no log.

CI runs all of these but `moon bench` and the tests of
`scripts/gke-bench.sh` on each push to a branch and on each pull request
(`.github/workflows/ci.yml`). It does not run on a pushed tag, since the
release workflow checks that CI passed on the tagged commit
([What a tag does](docs/releasing.md#what-a-tag-does)), nor on a push to a
`dependabot/**` branch, whose pull request runs it. A newer push to a
branch or a pull request cancels the run of the older one; on `main`,
every commit keeps its run. The job `scripts` runs the commands from
`scripts/check-release-workflow.sh` to `scripts/test-helm-chart.sh`, which
need no build of smock, on linux/amd64; a step that fails does not stop
the steps after it, so that one run shows every failure. The job
`yaml-test-suite` runs `scripts/check-yaml-test-suite.sh` beside it, on
linux/amd64: it fetches the suite and builds the testee
([yaml-test-suite/README.md](yaml-test-suite/README.md)). The job
`coverage` runs `scripts/coverage.sh` and then the coverage ratchet beside
them, on linux/amd64, whose native builds are about six times faster than
linux/arm64's, so that it stays off the path of the longest job, the native
tests on linux/arm64. It takes about a minute
([The coverage floors](#the-coverage-floors)).
`.github/workflows/build-test.yml` runs the rest, in jobs that run side by
side:

- `checks`, on linux/amd64 alone: `scripts/check-moonhttp-pin.sh`,
  `moon fmt --check`, `moon check`, `scripts/check-no-io.sh`,
  `scripts/check-no-c.sh`, `scripts/check-notice.sh`,
  `scripts/test-dependency-checks.sh`, the tests on wasm-gc and the tests
  of the mutation runner. None of them runs native code: the checks read
  text or run only the compiler's front end, and the tests run on
  wasm-gc. So they give the same answer on either machine.
- `test`, on linux/amd64 and linux/arm64: `moon test --target native`.
- `release-test`, on both: the engine's tests in a release build, and
  `scripts/test-openssl-asan.sh`.
- `release`, on both: the commands from `scripts/build-release.sh` to
  `scripts/test-helm-chart-on-kind.sh`, which build the release binary and
  the image and check both, and the check of the image's SBOM. h2spec and
  `scripts/test-check-grpcurl.sh` run on linux/amd64 alone: h2spec
  publishes a Linux binary for amd64 only, and the test checks the grpcurl
  check's own logic, which is the same on every machine. The job starts
  creating the kind cluster before it builds
  (`scripts/test-helm-chart-on-kind.sh --start`), so that the cluster is
  ready when the image is.
- `protobuf-conformance`, on linux/amd64: protobuf's conformance suite,
  with a runner that CI builds once and caches
  ([protobuf-conformance/README.md](protobuf-conformance/README.md)).
- `llm-sdks`, the SDK job, on linux/amd64 once `release` has passed:
  `scripts/check-llm-sdks.sh`, with the amd64 release binary built there,
  reads smock's [LLM
  responses](docs/definition-files/llm-responses.md#llm-responses) with
  the vendors' official SDKs, as applications call them
  ([llm-sdks/README.md](llm-sdks/README.md)).

`release` hands each release binary over as the workflow artifact
`release-linux-<arch>`. Then the job `keep` of `ci.yml`, which runs after
the jobs of `build-test.yml` and the jobs `scripts`, `yaml-test-suite` and
`coverage`, and only when each of them that ran has passed and the run
was not cancelled, keeps the binary of each architecture for 7 days as
`smock-linux-amd64` and `smock-linux-arm64`,
for a machine that cannot build it
([On GKE Autopilot](bench/README.md#on-gke-autopilot)). A run in which a
job failed keeps none; re-running its failed jobs within 7 days of the
run, or the whole run, keeps them once every job has passed.

On a push to `main` that merges a branch, the job `plan` skips `checks`,
`test` and `release-test` when the merge's tree is the merged branch
head's and a CI run on a push of that head, to a branch other than
`main`, succeeded and was last updated within 24 hours
(`scripts/ci-plan.sh`). That run tested the same tree, the workflows and
scripts included. `release`, `protobuf-conformance`, `llm-sdks` and the
jobs `scripts`, `yaml-test-suite` and `coverage` run in every run, so
`main`'s binaries are built and checked from `main`'s own commit, and
`keep` keeps
them once every job has passed.
Every other run, and a run whose plan fails, runs every job.

`.github/workflows/bench-tests.yml` runs the tests of `scripts/gke-bench.sh`
(`bench/test_gke_script.py`), which take about four minutes, only on a push
or pull request that changes that script, `scripts/install-oha.sh`,
`scripts/build-release.sh`, `Dockerfile`, `bench/` or the workflow itself.

`.github/workflows/unicode-data.yml` runs
`python3 scripts/gen-unicode-data.py --check`. It downloads the pinned
version of the Unicode Character Database from unicode.org, and fails when
`unicode/data.mbt` is not what the script writes from it. The table records
the SHA-256 of each file it comes from, so a file that unicode.org now
serves with other bytes fails it too. It runs on a push or pull request
that changes the table, the script or the workflow itself, once a week
(Tuesdays, 04:23 UTC), and when started by hand. It does not run in
`ci.yml`: a network failure would fail the job `scripts`, and `keep` would
keep no binaries. The job `scripts` runs
`scripts/check-unicode-data-workflow.sh` and its test on every push; they
check when the workflow runs and what it runs.

The native build links OpenSSL 3 (on Debian and Ubuntu, `libssl-dev`).
`prebuild.py`, which `moon` runs with `python3` before every native build,
adds `-lssl -lcrypto` to every executable that uses the bindings, tests
included, because link flags in a library's own `moon.pkg` do not reach the
packages that import it. It also brings the build information that
`smock --version` reports up to date, so every native build, release or
not, names the commit checked out and the toolchain in use.

A release build on arm64 fuses floating-point multiply-adds unless it is
told not to, and a seeded delay could then differ from the one wasm-gc
draws. `moon` passes `-ffp-contract=off` to each C compile itself, so
nothing in this repository adds it. The engine test "Fault arithmetic is
never fused into multiply-adds, so a seeded delay is the same on every
target" (`engine/faults_test.mbt`) fails if they are fused, and CI runs the
engine's tests in a release build on amd64 and on arm64 to check it.

Most tests drive the engine through its public interface, with in-memory
Definition files, a fixed clock and a seeded random source
(`engine/harness_test.mbt`). The tests in `e2e/` run the binary itself: each
one first runs `moon build --target native cmd/smock`, then starts smock with
its own temporary definitions directory and port 0 for each port, so they
run in parallel (`e2e/harness_test.mbt`). They need `moon`, `moonc`, `git`,
`kill`, `mkfifo` and `openssl` on `PATH`. The HTTPS tests use clients that
trust only the root CA of `testcerts`, and the HTTP/1.1 tests run on both
the plain and the TLS port. The HTTP/2 tests use moonhttp's client side
over TCP to the plain port, or over TLS to the TLS port through the OpenSSL
bindings' client side, which offers ALPN (`e2e/http2_harness_test.mbt`).
What several test files share, a helper, a value or a type, lives in a
harness file, whose name ends in `harness_test.mbt`: `e2e/harness_test.mbt`
for any test, the HTTP/2 and gRPC harness files, and those of the Admin
API's contract checker, the Prometheus reader, the TLS tests and the
`mockoon` log format. A test file holds only its own tests and what no
other file uses, so that removing it breaks no other.
`scripts/check-e2e-helpers.py` checks this with the compiler: it checks
the harness files with each test file alone.
The tests of the generated certificate (`e2e/self_signed_test.mbt`) read it
from the handshake with `openssl s_client` and then trust only it.
The test of the Journal's byte bound under a memory limit
(`e2e/journal_bound_test.mbt`) starts smock in a systemd user scope with
`MemoryMax`, as the benchmark does, so it needs `systemd-run` and a systemd
user manager with the `memory` controller delegated to it (see
[Run it on your machine](bench/README.md#run-it-on-your-machine)). Where a
scope cannot get the limit, it prints why it skipped and passes.

`moon` runs the async tests of a package in one process, on one event
loop, ten at a time. A test that computes without an await holds up the
timers and reads of every other test running then: in `e2e`, one that
computed for half a second made the timing tests beside it fail. So an e2e
test computes for no more than about 20 ms between awaits, and even ten
such tests in a row delay a timer less than the timing tests allow. A
timing test takes the time it measures from before it sends the request:
taken after an await, that time can come late, and what follows then looks
early, which the timing tests do not allow. Build a large input once, in a
top-level `let`, which runs as the test process starts, and cheaply: with
`String::make`, `Bytes::make` or by doubling, not with `String::repeat`,
which appends one piece at a time. The harness writes a large file 1 MiB
at a time. A check that must compute for longer, and needs no `smock`,
goes in a package of its own, whose tests get a process of their own, as
`schema` does.

`server` runs its async tests one at a time instead
(`max_concurrent_tests = 1` in its `moon.pkg`). Two of them check that the
process's resident memory stays flat: the stopwatch's test and the test of
stdout's lines. That memory counts what every test running beside them
holds. The first certificate pair a process loads grows it by about 5 MiB,
most of it OpenSSL's libraries read in, and a load that came between a
test's two readings once made the stopwatch's test fail on CI
([#427](https://github.com/hirunefu/smock/issues/427)). One at a time,
`server`'s tests take about 7 s instead of about 3.

A timing test that fails once in ten runs passes most single runs of CI.
The e2e repeat workflow (`.github/workflows/e2e-repeat.yml`) runs the e2e
tests a given number of times, one run after another, on one runner of the
architecture asked for, and keeps what each run printed, with a summary of
the runs that failed and the tests that failed in each, as the artifact
`e2e-repeat-linux-<arch>`. It runs only when started by hand, from the
Actions tab or with:

```sh
gh workflow run e2e-repeat.yml -f arch=amd64 -f runs=30
```

`scripts/repeat-e2e.sh <runs> <directory>` does the same on a machine, once
the e2e tests and `cmd/smock` are built.

`SMOCK_VERSION` and `SMOCK_COMMIT` set the version and the commit that a
native build, such as `scripts/build-release.sh`, records in the binary.

## How tests are judged

The test review ([#275](https://github.com/hirunefu/smock/issues/275))
judges smock's tests by what they would catch, not by a percentage.
[ADR 0006](docs/adr/0006-tests-are-judged-by-four-ledgers.md) records the
decision and why. This section holds the rules, for anyone who writes,
changes or removes a test. The review builds its tooling step by step:
until the coverage wrapper, the mutation runner and the branch checks
exist, the ledgers are kept by hand and none of them stops a merge, but
the rules for writing and removing tests apply already. The first to stop
one are the coverage floors, on every push
([The coverage floors](#the-coverage-floors)).

### Terms

- **Point**: an instrumentation point of moon's coverage, at a
  function's first statement, a then, else or match-arm body, or a call.
  It is covered when its counter is above zero.
- **Pure package**: a package of code that builds on wasm-gc. There were
  19 when the test review began: `buildinfo`, `cookies`, `definitions`,
  `engine`, `grpc`, `http1`, `importopenapi`, `llm`, `log`, `metrics`,
  `prng`, `protobuf`, `re2`, `settings`, `template`, `unicode`, `usage`,
  `xml` and `yaml`. `serverparsers`, made since from the parsers of
  `server`, is pure too. It goes to L4 as well, outside the two stages
  that take the 19 there (below), and the maintainer reads every
  exclusion in it, as in the protocol packages.
  `testcerts` builds there too, but it is data only, so it is not one.
  The native-only packages are `server`, `cmd/smock`, `defdir`, `watch`,
  `openssl`, `protobuf-conformance`, `yaml-test-suite`, `schema` and
  `e2e`.
- **Protocol packages**: `http1`, `grpc`, `yaml`, `re2`, `xml` and
  `protobuf`.
- **Site**: one change that one operator can make at one place.
  **Position**: a place that holds one or more sites. **Mutant**: the
  source with one site's change applied. A mutant **survives** when every
  test passes with it.
- **Pinned set**: one mutant per position, its alternative chosen by the
  rule of operator set v1 (two for INT in a comparison or an index).
  **Full set**: every alternative that an operator of v1 defines, at
  every position. The pinned set is part of it.
- **Equivalent mutant**: a mutant that no input can tell from the
  original.
- **BODY mutant**: a function's body replaced by a default value of its
  return type. A function whose BODY mutant survives is
  **pseudo-tested**.
- **Schema binary**: one build that holds many mutants, each switched on
  only when an environment variable, read once at startup, names it. It
  has nothing to do with the `schema` package.
- **Kill matrix**: for each mutant, the tests that kill it.
- **Exclusion**: an entry of the exclusion list that accepts an uncovered
  point or a surviving mutant, with a category and a reason.
- **Unexplained survivor**: a survivor that no test kills, no code change
  removed and no current exclusion other than DEFERRED covers. A survivor
  whose only covering entry is stale is **stale-covered**: the merge check
  reports it without stopping the merge, and the weekly run, the release
  check and every count for L4 treat it as unexplained.

### The four ledgers

"100%" means that nothing is left unexplained in four ledgers. No
percentage is a target or a gate: scores are reported per package, and
never gated. Each baseline below was measured at d953f320.

1. **Coverage**, necessary but not sufficient: no uncovered point in
   scope, outside exclusions that carry a reason. The measure is moon's
   point coverage, read from the bisect report (the default format of
   `moon coverage report`). Line figures overstate coverage, since a line
   that is only partly covered counts as covered, so they are only shown
   beside it. Baseline: 819 points uncovered outside `server` and
   `cmd/smock`; `server` 6.8% covered; `cmd/smock` 0%.
2. **Mutation**: no unresolved survivor over the pinned set. A survivor
   is resolved by a test that kills it, by a code change (a survivor can
   prove code redundant), or by a reviewed entry in the exclusion list.
   Baseline: of 250 mutants sampled from the pure packages, 243 compiled,
   and 77.4% of those were killed; of the 229 that are not equivalent,
   89.1% were killed when the importers' tests ran too.
3. **Boundaries**: every limit that a spec or smock's documents state is
   tested at the limit and just past it, with the smallest input that
   crosses it. A limit in the code that no document states is a finding:
   once the maintainer confirms it, the documents state it, and it is
   tested like the others. Baseline: about 33 of the 40 most important
   limits tested on both sides. The
   [boundary ledger](docs/ledgers/boundaries.md) lists each limit with its
   source and its tests.
4. **Use cases**: every documented feature has an automated test, or a
   recorded manual check with its reason. Every Definition-file example
   in the documents passes `smock check` in CI. Every message a user can
   see is asserted at least once. Baseline: of 99 documented features, 93
   covered, 2 partly and 4 not, as the survey counted them; 76 of the 77
   whole Definition files in the user documents pass once given the
   context they leave out, and the 77th once given the Descriptor set its
   text says to build (the survey counted 70 of 71, since it did not read
   the 6 in list items); 22 messages and the top-level help asserted by no
   test.
   A user can see 17 of the 22 messages: no input reaches 2 of the others,
   and only a package's interface shows 3 (the survey counted 20 that a
   user can see). The [use-case ledger](docs/ledgers/use-cases.md) lists
   each feature and each message with its source and its tests, and has
   the recheck of the survey's rows.

**Scope.** All non-test source of the workspace, except generated files
(the Unicode data table and the build information) and the test
certificates, which are data. A definition leaves the scope only through
the exclusion list, with a category, a reason and the maintainer's
approval. Its sites still appear in the site counts and in the counts of
sites skipped.

### Keeping the ledgers current

The use-case and boundary ledgers, in
[`docs/ledgers/`](docs/ledgers/use-cases.md), are kept current by each
change, not surveyed again before each release:

- A change that documents a feature, a limit or a message adds its row,
  with its source and the tests that check it, or the ticket or issue that
  adds them.
- A change that renames, moves or removes a test that a row names, or
  that adds a test for what a row still lacks, updates the row in the same
  commit, and its status with it.
- A gap that no ticket closes is filed as an issue, and its row names the
  issue.

`scripts/check-ledgers.py`, in CI's job `scripts`, fails a push on which a
ledger names a test that is no longer there, or a row whose status does
not agree with what it names. The weakening report lists every change to
the ledgers, for the maintainer to read before the merge into `main`. A
removal batch keeps the only test of a row unless it names another
([Removing a test](#removing-a-test)). No check sees a feature, a limit or
a message documented without a row: whoever reviews the change looks for
one. The boundary ledger records the search that listed its limits, which
anyone can run again
([The search for documented limits](docs/ledgers/boundaries.md#the-search-for-documented-limits)).
Step 3's close checks the ledgers against the documents once more
([#340](https://github.com/hirunefu/smock/issues/340)).

### The coverage floors

Each package has a floor: the most uncovered points its in-process tests
may leave, as `scripts/coverage.sh` counts them. `coverage/floors.txt`
holds them. They start at the counts committed there, first taken from
the report at d88929b2, as the maintainer decided on 2026-11-18, and
each change since lowers or raises them by the rules below. CI's job
`coverage` runs `scripts/coverage.sh` on every push and pull request, then
`scripts/coverage-ratchet.py check` on its bisect report, against the
merge base with `main`:

- A package whose uncovered points are above its floor fails the job. The
  ratchet names the package and its new uncovered points: those on the
  lines that the change adds or changes, or every uncovered point of the
  package when none is on such a line, as when a test that reached them
  is gone. At or below its floor, a package passes, so the job never asks
  a change for more than it touched.
- Below its floor, a package passes, and the ratchet says that the floor
  can be lowered. The change that lowers the count lowers the floor with
  it: run `scripts/coverage.sh`, then
  `python3 scripts/coverage-ratchet.py write _coverage/coverage.bisect`,
  which writes each package's count as its floor, and commit
  `coverage/floors.txt`.
- A floor rises only with the maintainer's approval. A floor above the
  one at the merge base, or a first floor above 0 for a new package, fails
  the job unless the change adds a line for that package to
  `coverage/approved-raises.txt`: `<package> <points> <reason>`, with the
  number of points the floor rises and why they cannot be covered now.
  That line is not the approval, since every commit here has the same
  author. The weakening report lists every changed floor and every
  recorded raise, and the maintainer's acknowledgment of it at the merge
  is the approval.
- A package without a floor, a floor of a package that the report no
  longer holds, and a malformed line fail the job too; `write` adds and
  removes such floors.

`server` and `cmd/smock` have floors too, of their in-process points. Most
of their code only the binary runs, so a change that adds code there that
only the e2e tests reach records a raise; e2e coverage is reported apart,
every week, and holds no floor
([Coverage from the e2e tests](#coverage-from-the-e2e-tests)).

The job writes the table of the packages, with their points and floors,
to its summary, and keeps the report and the bisect report as the
artifact `coverage-report` for 7 days, also when the ratchet fails. It
runs on linux/amd64 beside the other jobs, and `keep` waits for it, on
`main` too. Coverage counted the same points on linux/amd64 and
linux/arm64 when step 0 measured it
([#276](https://github.com/hirunefu/smock/issues/276)).

### Coverage from the e2e tests

Most of `server`'s and `cmd/smock`'s code only the binary runs, so the
in-process tests reach little of it. The weekly mutation run reports
their coverage from the e2e tests and the in-process tests together
([#342](https://github.com/hirunefu/smock/issues/342)), in the job
`coverage-e2e`, beside the mutation shards
([Bulk runs on Actions](#bulk-runs-on-actions)). The job is the workflow
`.github/workflows/coverage-e2e.yml`, which can also be started alone by
hand:

```sh
gh workflow run coverage-e2e.yml --ref main
gh run download <run id> --name coverage-e2e --dir coverage-e2e
```

It runs `scripts/coverage-e2e.sh` on an amd64 runner, which does what
[Build and test](#build-and-test) shows by hand:

- `scripts/coverage.sh` runs the in-process tests with coverage, and
  builds the instrumented binary in the same target directory: `cmd/smock`
  with coverage, the native debug build that step 0 found to work on
  amd64 ([#276](https://github.com/hirunefu/smock/issues/276));
- the e2e package is built as a plain build, in moon's own target
  directory, so the e2e tests' own process writes no coverage: its tests
  call `openssl`'s TLS client, `log`'s time parser, `http1`'s date cache
  and `re2` directly, which is not smock's behaviour;
- the e2e tests run with `SMOCK_E2E_BINARY` naming the instrumented
  binary and `SMOCK_COVERAGE_DUMP` naming a directory, where the harness
  keeps the counters of each smock process;
- moon_cove reads those logs, joined into one, with the trace sources
  that made the in-process report, and `scripts/coverage-e2e.py report`
  writes the report.

The report starts with how many e2e tests ran and how long each step
took. It then gives, for each package, its points, those the in-process
tests reach, those the e2e tests reach and those either reaches, and the
points neither reaches after the exclusion list. It lists, by file and
definition, the points that no test reaches in `server`, `cmd/smock`,
`defdir`, `watch` and `openssl`; a point that a DEFERRED entry covers is
listed with its issue, and the points the list's other entries accept
are listed apart. No package gets a percentage target here: the list is
for triage ([#343](https://github.com/hirunefu/smock/issues/343)).

It also decides which positions of `server` and `cmd/smock` the e2e
tests cover, which the run at operator level through e2e mutates
([#346](https://github.com/hirunefu/smock/issues/346)), and states the
rule in the report: a position counts as covered by e2e when the point
that starts the innermost function, then, else or match-arm body around
it has a count above zero in the e2e tests' report. A function is any
function, closures and local functions included, and holds its
parameters' default values; an else is an if's or a guard's; a match arm
is an arm of a match, a loop, a catch or a noraise. A loop's body is none
of these, nor is a body that the compiler started with no point, which
the report lists. A position in no such body, in a top-level value or a
constant, counts as covered when its package has a point that the e2e
tests reach, since the program initialises its values when it starts.
The positions come from the site finder, and the bodies from the
compiler's parse tree.

The job keeps the artifact `coverage-e2e` for 90 days: `report.md`,
which is also in the job's summary; the two bisect reports and their
merge (`in-process.bisect`, `e2e.bisect`, `either.bisect`); the
pinned set's mutants of `server` and `cmd/smock` at the positions e2e
covers, `covered-by-e2e.jsonl`, and at the others,
`not-covered-by-e2e.jsonl`, each a list of mutants by key that the
mutation runner reads (`run.py --list`); `unreached.json`, the points
that no test reaches; and what moon printed. The job reports only: a
failed e2e test fails nothing, and the report names it and says that the
e2e tests' report may then lack points. It fails only when there can be
no report, as when a build or an in-process test fails. The weekly run's
finish does not wait for it, and when it fails, the release's check of
the weekly run goes ahead ([The weekly mutation
run](docs/releasing.md#the-weekly-mutation-run)).

The first report's points that no test reaches in `server` and
`cmd/smock` are cut into triage tickets for #343 when there are more than
about 40, at most 40 each, a source file that holds fewer never split:

```sh
mkdir -p bodies
gh issue view 343 -R hirunefu/smock --json body --jq .body >bodies/343.md
python3 scripts/coverage-e2e.py triage --report coverage-e2e --bodies bodies --out tickets \
  --run-url <run link>
```

It writes a body per ticket into `tickets/`, with the ticket's points and
#343's triage criteria for them; `tickets.json` gives each ticket's
title, label, blockers (#342, #318 and #319) and the ticket it blocks,
#343, which gains each as a native blocker; `tickets.md` the count. Like
stage 1's, the tickets become sub-issues of the closing ticket they
block.

`scripts/test-coverage-e2e.sh`, in CI's job `scripts`, tests the report
on small bisect reports over a small tree whose points the pinned
compiler placed, with a position in each kind of body and one after an
if whose then-body did not run, and the triage on its output.
`scripts/check-coverage-e2e-workflow.sh`, with its test, checks that the
workflow runs only by hand or when the weekly run calls it, on amd64,
and keeps the report.

### The ladder

A package climbs four levels:

- **L1, coverage**: no uncovered point outside exclusions, in the pure
  packages and in the small native-only ones (`defdir`, `watch`,
  `openssl`, `protobuf-conformance`, `yaml-test-suite`). `server` and
  `cmd/smock` get no percentage: the pure parsers that move out of
  `server`, into a package without I/O, are covered in full in-process,
  and the rest is reported from e2e coverage.
- **L2, no pseudo-tested function**: every BODY mutant is killed or
  excluded.
- **L3, changed lines**: no unexplained survivor on the lines a branch
  changes.
- **L4, per package**: no unexplained survivor over the pinned set. The
  weekly run executes exactly this set, so it verifies L4.
  `mutation/l4-packages.txt` lists the packages at L4. It started empty,
  and a package joins it only with the maintainer's approval, in the
  ticket that takes it to L4.

All 19 pure packages go to L4, in two stages: first `yaml`, `http1`,
`xml`, `re2`, `grpc`, `cookies`, `settings`, `metrics`, `usage` and
`prng`, then the other nine. `serverparsers` goes to L4 too, by a climb of
its own ([#339](https://github.com/hirunefu/smock/issues/339)) that waits
for the ladder's tooling and for the parsers still to move out of
`server`, not for either stage. `server` and `cmd/smock` get coverage through
e2e, a BODY audit, and mutants at operator level through e2e, monthly and
before each release (decision 6). The maintainer confirmed that run on
2026-11-17, with step 0's measurement on CI's runners: every e2e test in
one process took 39.0 s on an amd64 runner, so a mutant of `server`
takes about 45 s through e2e, the run at operator level about 1.7 hours on
20 jobs, and the BODY audit about 17 minutes
([Test costs on CI's runners](#test-costs-on-cis-runners)). Native
mutation, e2e coverage and `server` through e2e run on amd64, whose native
builds are about six times faster than arm64's: a rebuild of `cmd/smock`
after one mutant in `engine` took 5.4 s there, against 42.0 s.

L4 and a release read the pinned set alone. The monthly run over the full
set is report-only: its survivors at the other alternatives are listed
apart, and they stop no merge and no release, and do not count towards
L4.

### Operator set v1

The operators that make the mutants are pinned as a version, v1. A
change to them, the rule that picks an alternative included, needs the
maintainer's approval, and shows in the weekly report.

- **BODY**: a function's body replaced by a default value of its return
  type.
- **ROR**: a comparison, always with the boundary alternative: `<` and
  `<=` swap, and `>` and `>=` swap.
- **IFC**: a condition or guard forced to true or to false.
- **LCR**: `&&` and `||` swap.
- **NOT**: a prefix `!` removed.
- **DEL**: a statement deleted.
- **BOOL**: `true` and `false` swap.
- **AOR**: `+` and `-` swap, and `*` and `/`, in their compound
  assignments too.
- **INT**: an integer literal, with both n+1 and n-1 where it is an
  operand of a comparison or an index, and one replacement elsewhere.
- **STR**: a string literal replaced by the empty string or with one
  character changed, in the protocol packages, in `server` and the parsers
  moved out of it (`serverparsers`), and in `log`'s line writers. A mock
  server's behaviour is mostly strings: header names, content types, JSON
  keys, status texts and log lines.

The pinned set holds one mutant per position, two for INT in a comparison
or an index, and a fixed rule chooses the alternative, so that a runner
cannot pick those that are easiest to kill. The full set adds every other
alternative: both of IFC's, all of INT's and both of STR's. One mutant
per line, chosen by operator priority, would not do: of the 24 survivors
of the sample first read as real, it would have picked another site for
16.

The pinned set takes these alternatives, for the reasons that
[ADR 0006](docs/adr/0006-tests-are-judged-by-four-ledgers.md) gives:

- **IFC** takes the alternative under which the code that the condition
  guards never runs: false for the condition of an `if` or an `else if`
  (its then-branch never runs), of a loop (its body never runs) and for a
  match arm's guard (the arm never matches), and true for the condition
  of a `guard` statement (its `else` never runs). The full set adds the
  other.
- **STR** changes one character: the first character of the literal's
  text, outside any interpolation, becomes `_`, or `-` when it already is
  `_`. An empty literal becomes `"_"`. The full set adds the empty string.
- **INT** has three alternatives: n+1, n-1, and 0 where n is not 0.
  Outside comparisons and indexes, the pinned set takes n+1, or n-1 where
  n+1 does not fit the literal's type. The full set adds the others there,
  and 0 in comparisons and indexes.
- **ROR** swaps only `<` and `<=`, and `>` and `>=`. It does not swap `==`
  and `!=`, in either set.

Where an operator needs more detail, v1 has this. The mutation runner's
ticket ([#299](https://github.com/hirunefu/smock/issues/299)) settled these
details, and the maintainer approved them as part of v1;
[ADR 0006](docs/adr/0006-tests-are-judged-by-four-ledgers.md) records why:

- **BODY** replaces the body of a top-level function or method, trait
  implementations included, not of `init`, `main`, a local function or a
  closure. The default values are `()`, `false`, `0` for every type of
  number, `'\u{0}'`, `""` for `String` and `StringView`, `b""` for
  `Bytes` and `BytesView`, `[]` for `Array`, `FixedArray` and
  `ArrayView`, `{}` for `Map`, `null` for `Json`, `Iter::empty()`, `None`
  for an option, `Ok` of the default for a `Result`, and a tuple of
  defaults. Any other type, such as a type parameter or a type of
  smock's own, has none. An implementation that does not write its
  return type has the one of core's trait (`Show`, `Eq`, `Compare`,
  `Hash` or `ToJson`). A body that already is the default value is no
  site.
- **IFC** forces the condition of an `if` or an `else if`, of a `while`
  loop or a `for` loop with a condition, a match arm's guard, and a
  `guard` statement's condition. A `for .. in` loop has none.
- **DEL** deletes a call or an assignment, compound ones and those to a
  field or an element included: one whose value its block drops, or the
  last one of a block whose value is `Unit` (the body of a function that
  returns `Unit`, of a loop, or of an `if` without an `else`). It does not
  delete the only statement of a function's body, whose BODY mutant is
  the same.
- **INT** is in a comparison or an index when it is an operand of `<`,
  `<=`, `>`, `>=`, `==` or `!=`, or the index of an element or a slice,
  directly or through `+`, `-`, `*`, `/` and `%`. An alternative must fit
  the literal's type: the one its suffix names, or `Int` without one (or
  the wider type that the value needs). So a `0` in a comparison takes
  `1` and `-1`, unless its type is unsigned.
- **STR** changes string and byte-string literals, interpolated ones and
  those over several lines included, but not character literals. An
  escape, such as `\t`, is one character. A literal that writes no
  character outside its interpolations gets `_` at the start of its text,
  as the empty literal does. STR's scope is the protocol packages,
  `server`, `serverparsers` and `log`, but `log/target.mbt`, the reader
  of request targets.
- **Not sites**: literals in patterns, ranges (`..<` and `..=`), and
  `not(...)` calls.
- **Skipped sites.** A rule skips a site that cannot be a mutant, and the
  reports count it: a BODY site without a default value, or whose
  function is foreign (FFI); a STR site outside STR's scope; IFC's `true`
  for a condition that binds a name with `is`, and LCR at an `&&` whose
  operand does, since the name would then be unbound where it is used;
  and an AOR site at a `+` with a string literal as an operand, since
  strings have no `-`. Such a condition is forced to false as
  `false && (condition)`, which keeps the name bound.
- **The same mutant.** Where two sites make the same mutant, as BODY's
  `{ false }` and BOOL's `false` do in a body that is only `true`, one is
  kept: the one in the pinned set, then the first of BODY, ROR, LCR, NOT,
  BOOL, AOR, INT, STR, IFC and DEL.

Sites come from a parser, not from a lexer. For each package, each report
gives the number of sites that each rule skipped (no default value for
BODY, a string outside STR's scope, FFI, a name that a condition binds, a
string operand) beside the number of survivors,
so that a "zero" always says what it is zero of. Each mutant has a stable
id: its file, its enclosing definition, its operator, its original text,
its replacement text and its ordinal. A report, an exclusion and a commit
message name a mutant by that id. Every site, record, summary and report
carries the operator set's version, `v1`, so a change to the set is a new
version.

### Outcomes and kill credit

- **Killed**: a test fails with the mutant on.
- **Timed out**: the run takes longer than 1.25 times the baseline run
  plus 4 s. A confirmed time-out counts as killed, and is listed.
- **Unconfirmed**: a kill or a time-out that kill confirmation (below)
  does not bear out. It counts neither as killed nor as survived, and is
  listed with the reason.
- **Unviable**: the mutant does not compile. It counts neither as killed
  nor as survived.
- **Survived**: every test passes: in the first run, or, when that run
  names no test and does not pass, in the run again (kill confirmation,
  below).

**Kill confirmation.** A kill counts only when the failing tests fail
again with the mutant on and pass with it off; when they pass in the run
again, or fail without the mutant too, the kill is recorded as
unconfirmed. A run that the time limit stops, or that fails without
naming a test (the test program stopped before its end), did not pass,
but names no test (#431). Such a run again repeats the kill, and no test
is counted as flaky by it. When the first run was such a run, the run
again decides: if it passes, the mutant survived, and is unexplained
until a test kills it or an entry covers it; if it does not, the mutant
is killed, by the tests the run again names. A time-out counts only when
the limit stopped both runs. The run without the mutant must finish
within the limit and name the tests that fail, or pass; otherwise the
kill or the time-out is unconfirmed. The baseline runs
twice before any mutant, and a test that fails in either run gives no
kill credit in that run. The runner records each test's flake rate, and a
test above the flake threshold, which the maintainer sets, gives no kill
credit until it is fixed. The flake threshold is 1% of a test's runs,
over the latest 10 runs whose flake records the runner reads;
`mutation/flakes.toml` holds both numbers.

**Kill credit for a pure package.** Any wasm-gc test of any package of
the workspace gives credit. The package's own tests run first. For the
survivors, the tests of every package that imports it, directly or
through another package, run too: in the sample, `engine`'s tests alone
killed 16 of the 25 survivors in `template`'s comparison code. An e2e
test gives no credit for a pure package. Only the kill-matrix mode, for a
package heading into a removal batch and for a snapshot audit, runs every
covering test for every mutant.

**Kill credit for a native-only package.** In-process and e2e tests give
credit.

**Backend.** The verdicts for pure packages are taken on wasm-gc. A site
that uses an unchecked array access is also judged natively, because
wasm-gc traps where the native binary does not, and for such a site the
native verdict taken on CI's amd64 runner decides (the runner's "Native
verdicts", in [Mutation runner](#mutation-runner)).

The runner never passes `-u` to `moon test`.

### Exclusions

The exclusion list is one file in the repository. No attribute in the
source excludes a mutant. An entry names its mutant by its id, and gives a
category, a reason and who reviewed it. Only the maintainer fills in the
reviewer, in a commit that the maintainer makes or acknowledges at the
merge. An entry goes stale when the text of its definition changes. Stale
entries are triaged again in a batch, which the first weekly run that
lists them opens as an issue. The uncovered points that the coverage
ledger accepts are in the same list, under the same categories:

- **EQUIVALENT**: an equivalent mutant, through the three steps below. The
  entry records the result of comparing the compiler's output and the
  adversarial attempt: the agent context that made it and the tests it
  tried.
- **ARID**: code whose change no user, document or test could notice,
  kept narrow: capacity hints, the fill values of empty arrays, abort
  messages. Logs, metrics and timeouts are features of a mock server, so
  they are not arid.
- **UNREACHABLE**: only for an arm that an invariant guards with an
  abort, or with a written argument that the maintainer approves.
- **FAULT**: reached only through an OpenSSL or file-system failure. It
  has nothing to do with a Stub's Fault. No C seam is added to inject
  such failures ([ADR 0001](docs/adr/0001-moonbit-with-c-only-for-tls.md)).
- **UB-NATIVE**: a mutant whose effect on the native binary is undefined,
  such as an unchecked array access out of bounds, so that no test can
  pin it there.
- **DEFERRED**: carries an issue number, and still counts as unresolved.

Dead code is deleted, not excluded, with the maintainer's approval. A
survivor that deletes a statement or makes a check always true, while
nothing a caller can see changes, is decided by what the code is for:

- Code that decides nothing, such as a check that is always true or a
  cap that never acts, is a candidate for deletion.
- A statement whose deletion works only by coincidence of what follows,
  such as a step past markup that the next loop would read as plain
  characters, stays, and its mutant is EQUIVALENT.

A triage context deletes no code. It proposes an EQUIVALENT entry either
way, and lists each candidate for the maintainer: what would go, the
survivors that go with it, and whether it is on the request path. The
maintainer decides a package's deletions in one round. An approved
deletion is then a commit of its own, which removes the entries it makes
needless; on the request path, it brings the pre-merge benchmarks
([Before merging into main](docs/merging-into-main.md)).

When a mutant does differ, but only where a caller of the package cannot
reach, such as a private function's own result when it is called alone
or an input outside a documented contract, the entry's reason says so in
plain words. Such an entry is accepted at the package's public interface,
or within the documented contract, and no white-box test is written for
a private function's own result.

An equivalence claim reaches the maintainer in three steps:

1. **Automatic.** The compiler's output for the mutated package is
   compared with the original's. Identical output marks the mutant
   equivalent, or a duplicate of another mutant. The mutation runner does
   this before any test runs ([The compiler's
   output](#mutation-runner)).
2. **Adversarial.** For each claim that remains, a separate agent context
   tries to write a test that kills the mutant, from the spec. Who writes
   what, and when:
   - The context that proposes the entry writes it whole, with the
     attempt still pending: its `adversarial` has a context that starts
     with `pending`, and the tests it ran itself, as in
     `adversarial = { context = "pending: a separate agent context, after <who proposed it>", tests = ["none yet; <its own check>"] }`.
   - The separate context, one that did not propose the entry, then
     replaces that with its own name and the tests it tried, which
     passed, on the same ticket branch. A test that kills the mutant goes
     in instead, and the entry goes.
   - Nothing pending reaches the integration branch.
     `exclusions.py check --allow-pending` passes a pending attempt on a
     ticket branch until the separate context has run; CI's check runs
     without it and fails on one, and a merger refuses a branch that
     still holds one.
3. **The maintainer.** What survives both goes to the maintainer: every
   entry in the protocol packages and in `serverparsers`, and one in five
   of the others, as a sample. The sample is drawn after the batch is
   frozen, with a seed that no agent can know before: the run ID that
   GitHub Actions gives the packages run of the bulk workflow on the
   frozen tip. No one picks the seed, so the batch's author cannot know
   which entries will be read. If a sampled entry is rejected, its author
   triages the whole batch again, and a new sample is drawn with the ID
   of the packages run on the batch's new frozen tip.

The list is `exclusions.toml`, at the root, and
`scripts/mutation/exclusions.py` reads it. Each entry is a table of the
array `exclusion`:

```toml
[[exclusion]]
file = "engine/crud.mbt"
definition = "crud_call"
position = "6:13"
text = "2e77cf0f70f849a0"
category = "UNREACHABLE"
reason = "An abort arm, which an invariant guards; its message: \"a CRUD Stub matched a request it does not serve\"."
reviewer = ""
```

- A mutant is named by its id (`mutant = "<id>"`); a point by its file,
  its definition, named as a mutant's id names it, and its position in
  the definition: its line, counted from the definition's first line,
  which is line 1, and its column in characters.
- `text` is the first 16 hexadecimal digits of the SHA-256 of the
  definition's text when the entry was made. An entry whose definition no
  longer has that text, or is gone, is stale.
- `reviewer` stays empty until the maintainer fills it in.
- An EQUIVALENT entry, of a mutant only, adds `compiler_output`, what the
  comparison found (`"differs"`, or `"not compared"` where the comparison
  cannot compare the mutant), and
  `adversarial = { context = "...", tests = ["..."] }`: the agent context
  that made the attempt and the tests it tried, which passed, or a
  context that starts with `pending` while the attempt is still to be
  made (step 2 above). An UNREACHABLE entry that is not a point at an
  abort adds `argument`, its written argument. A DEFERRED entry adds
  `issue`, its issue's number. UB-NATIVE is for a mutant only.

`python3 scripts/mutation/exclusions.py new <file>:<line>:<column>`, a
point as the coverage report names it, or `new <mutant id>`, prints a new
entry's stanza with the definition's text, for the author to fill in.
`python3 scripts/mutation/exclusions.py check`, in CI's job `checks`,
fails an entry in another category, without what its category needs, with
a field the list does not know, or a second entry for the same mutant or
point, and an EQUIVALENT entry whose adversarial attempt is still
pending; it lists the stale entries, and passes with them.
`check --allow-pending`, for a ticket branch before the separate context
has run, passes the pending entries too and lists them.

Both ledgers read the list. The coverage report and the coverage floors
count only the uncovered points that no current entry other than
DEFERRED accepts, and the report lists the accepted ones apart, with
their categories ([The coverage floors](#the-coverage-floors)). The
mutation runner gives each survivor its status: accepted by a current
entry other than DEFERRED; stale-covered, when its only entry is stale;
or unexplained. Its summary counts them per package, and its report lists
the unexplained survivors first, then the stale-covered ones, each beside
its stale entry's id, then the accepted ones. A stale entry accepts
nothing, so its point counts again, and the floor may fail until the
entry is triaged again.

`python3 scripts/mutation/exclusions.py review` lists the entries that a
branch adds or changes against its merge base with `main`, the batch, and
which of them the maintainer reads: every one in the protocol packages
and in `serverparsers`, and one in five of the others. Once a package's
batch of entries is frozen for its review, a packages run of the bulk
workflow (`-f mode=packages`, [Bulk runs on Actions](#bulk-runs-on-actions))
runs on the frozen tip, the tip where that batch was frozen, and its run
ID is the seed of the sample: `review --seed <run ID>`. GitHub Actions
gives that number only once the run starts, so no agent can know it
before. Later pushes of the branch, for other packages, do not draw that
package's sample again. A later batch of the branch is drawn alone:
`review --base <the tip where the batch before it was frozen> --seed <run ID>`
takes only the entries added or changed since that tip, so that one in
five is read among the new entries. The weakening report lists every
entry whose reviewer changed.

### Rules for the work

- **The oracle rule.** Each expected value a test adds comes from a named
  source: a spec section, a sentence of smock's documents, an issue's
  acceptance criterion, the output of a reference tool (protoc, the RE2
  reference, an official SDK), or the maintainer. The test, or its name,
  cites it. A snapshot is a fine form for the value, and the source
  decides its content: a snapshot that `moon test -u` fills is checked
  against its source before it is committed. A test that disagrees with
  the current code becomes an issue. It is never made green with `-u`.
- **Extend first.** Before adding a test, extend the existing test of the
  same behaviour. Random and differential tests exist already: `re2`'s
  comparison of its DFA with the Pike VM on random patterns, and
  `http1`'s tests of split invariance and random garbage. Work on
  properties converts and extends them, and adds no parallel tests.
- **Roles.** An agent that kills survivors may delete code only when a
  survivor proves it redundant, and with the maintainer's approval.
  Outside the removal batches, no change deletes, skips or weakens an
  existing test: a test that should go is proposed for a removal batch.
- **Commit subjects.** A commit's subject is a short summary in the
  imperative that ends with the issue it belongs to in parentheses, such
  as `(#275)`, or with each of them, such as `(#258, #43)`, when it
  belongs to two. The trace links of the removal proof
  ([Removing a test](#removing-a-test), `scripts/trace-links.py`) take a
  test's tickets from the subject of the commit that introduced it: the
  issues in that last parenthesis, or else every issue the subject names.
- **The weakening report.** For each branch, against its merge base with
  `main`, it lists the tests deleted; the tests moved or renamed; the
  assertion lines removed or changed in tests that stay; the snapshot
  lines changed; the other lines changed in tests that stay; the skip
  attributes added; the package settings that stop a test from running on
  wasm-gc; and any change to what decides a verdict: the exclusion list,
  the operator set, the runner and its committed data, the coverage
  floors and scope, the flake threshold, the lists of packages at L4 and
  of tests kept with their checks, the merge and release checks, the
  mutation and coverage workflows, the suites' lists of cases with their
  verdicts and the installs of their tools, and the tests of those
  scripts. The maintainer acknowledges it at the merge.
- **The mutator is governed too.** A ratchet on each package's number of
  sites, compared per definition: a package's sites may drop by at most
  as many as the base tree had in the definitions that a change deletes
  or changes, and any other drop needs the maintainer's approval
  ([The site counts](#the-site-counts)). A forced-fail self-test: a
  mutant switched on must be observable, or the run fails
  ([The self-test](#the-self-test)). A weekly canary replays the 250 mutants sampled at
  d953f320, whose verdicts are known, on that commit with the toolchain
  pinned there, and the maintainer accepts each difference once it is
  explained ([The canary](#the-canary)).
- **The held-out measure.** A set of mutants that no check gates on and
  that no agent writing tests ever sees: operators outside v1, such as
  swapped arguments and replaced match arms, and realistic mutants written
  by hand or by a model. It is kept outside the repository, on the
  maintainer's machine, and runs there. Nothing about a single mutant
  becomes public, only kill rates. Its mutants are keyed as exclusions
  are, so that they apply to later commits, and those whose text is gone
  are counted beside the rate. Its kill rate, measured at d953f320, at
  step 2's baseline, after steps 1, 3 and 5, after stage 1 and in each
  removal batch, is reported to the maintainer as the outcome of the
  review.
- **Seeds.** Each property runs with a fixed seed committed beside it: on
  every push, in mutation runs and in kill confirmations. Each week a
  separate job of the weekly mutation run
  ([Bulk runs on Actions](#bulk-runs-on-actions)) writes a random seed
  into a working copy, the way the
  runner applies a mutant, and prints it; a failure is rerun by
  committing that seed. No test reads the environment for a seed, so
  `scripts/check-no-io.sh` stays as it is.

  The seed is a constant of the property's test file, with a doc comment
  that names the property. It is alone on its line, in this form:

  ```
  const <NAME>_SEED : UInt64 = <digits>
  ```

  The value is decimal, without a suffix, and the property passes the
  constant to QuickCheck as `seed=<NAME>_SEED`. The first is
  `FULL_MATCH_SEED`, in `re2/full_match_wbtest.mbt`.
  `python3 scripts/random-seeds.py [<path>...]` finds every such constant
  in the test files under the paths, or under the current directory when
  none is given. It writes a random seed in place of each value and
  prints one line for each constant:
  `<file>:<line>: <NAME>_SEED = <seed>`. It rewrites the files in place,
  so run it only in a working copy that you throw away. A line that
  declares a `_SEED` constant in another form fails it, and it then
  writes nothing. To rerun a printed seed, set the constant to it and run
  the property's test, such as
  `moon test --target wasm-gc re2/full_match_wbtest.mbt`. The failure
  shows the smallest counterexample that QuickCheck found. Commit the
  seed with the fix, so that every push runs it.
- **Where the checks run.** smock merges branches locally, ticket
  branches into integration branches and those into `main`, and opens no
  pull requests; only Dependabot does. So the changed-lines job and the
  weakening report run on pushes to every branch but `main`, against the
  merge base with `main`, in a workflow of their own, which CI's job
  `keep` never waits for. An outside contributor's pull request goes the
  same way: before merging it, the maintainer pushes its branch here. The
  stop is in the merge procedure. It reports only, at first; once a
  package reaches L4, an unexplained survivor on lines of that package
  that the branch changes stops the merge into `main`. The merge check,
  `scripts/check-merge.py`, reads the report of the run on the branch
  head, as the release checks that CI passed on a tag's commit, and the
  [checklist before merging into main](docs/merging-into-main.md) runs it
  ([The changed-lines job](#the-changed-lines-job)). A diff too large for
  the changed-lines job is reported as not covered, and runs whole in a
  run started by hand; the merge check reads whichever run covered the
  whole diff.
- **Releases.** For the packages at L4, the latest weekly run over the
  pinned set must also show no unexplained survivor before a release, on
  the tag's commit or on an ancestor whose later changes the changed-lines
  reports cover or touch no non-test source of a package at L4, and its
  jobs that decide a verdict must have passed: a job that only reports,
  as the coverage from the e2e tests does, stops no release. The
  release checks it before it publishes, beside the check that CI passed
  on the tag's commit (`scripts/check-weekly-run.py`,
  [What a tag does](docs/releasing.md#what-a-tag-does)). So a release may
  wait for one weekly run. While no package is at L4, the check reads no
  run and passes.
- **Bulk runs go to Actions**: the baseline of 1,000 mutants, the weekly
  and monthly runs, `server` through e2e, and the kill matrices. On a
  developer's machine, only single mutants and the diff mode run, which
  checks one change's lines, and two named exceptions: step 1's replay of
  the 250 sampled mutants and the held-out runs on the maintainer's
  machine.

### Snapshot audits

When a package's turn comes to climb to L4, about ten of its snapshots
are audited. They are drawn among the tests that alone kill some mutant
in a kill-matrix run of the package (`-f mode=matrix`,
[Bulk runs on Actions](#bulk-runs-on-actions)), at least half of them
from the work's tests: a test is the work's when the work added it, or
changed a line of its block that is not a comment. The seed of the draw
is that kill-matrix run's ID, a number that GitHub Actions gives once the
run starts, so no agent can know it before and no one picks it. A separate
agent context, one that wrote none of that package's tests under these
rules, checks each against its source. The maintainer reads only the
snapshots that this context finds in disagreement with their source, and
each of those becomes an issue (a bug) or a corrected test.

`matrix.py draw` makes the draw from the run's matrices, in a checkout of
the commit that the run ran on:

```sh
gh run download <run ID> --name mutation-report --dir mutation-report
python3 scripts/mutation/matrix.py draw --seed <run ID> mutation-report/matrix/<package directory>.json...
```

- It draws among the tests that alone kill some mutant in the matrices
  given ([The kill matrix](#the-kill-matrix)).
- A test is the work's when the work added it, or changed a line of its
  block that is not a comment, since `d953f320`, the commit of `main` at
  which the test review began (`--base` names another). Its block runs
  from the `///|` at or before its line to the line before the next
  `///|`. A line whose first characters, after white space, are `//` is a
  comment, and a blank line is none of the test's lines. The lines added
  or changed are read from `git diff -U0 d953f320 HEAD`. A line that it
  adds or changes counts when it is neither a comment nor blank. Where a
  hunk changes or deletes a line that was neither, every line that the
  hunk adds counts too, or, when it adds none, the line at which it
  deletes. So a deletion of comments alone counts for no line.
- It draws ten (`--size` names another number), or every one when there
  are fewer. The tests are sorted by their names in the matrix.
  `random.Random(<run ID>)`, with the ID as text, samples half of the
  ten, rounded up, of the work's tests, or all of them when there are
  fewer. The same generator then samples the rest of the ten from every
  test not yet drawn. So the same matrices, run ID and base give the same
  tests, in the same order.
- It prints one JSON line per test, in the order of the draw: the test as
  the matrix lists it, its file (`path`), whether it is the work's
  (`work`), and the mutants it alone kills (`alone`).

Step 1's tests close the gaps that the review found before it had any
tooling. Every expected value they add is checked the same way: before
the merge into `main`, a separate agent context that wrote none of them
checks each value against the source it cites. The maintainer reads only
the values that this context finds in disagreement with their source,
and those whose source it finds unclear. Each disagreement becomes an
issue (a bug) or a corrected test, as in an audit.

### What makes a good test

- It drives a public interface, and survives a refactor that keeps the
  behaviour. The seams are the existing ones: in-process tests of a
  package's public interface (the harness in `engine/harness_test.mbt`
  for the engine), and e2e tests that run the binary over real sockets.
  The one new seam is the package without I/O that receives `server`'s
  pure parsers.
- Its expected value comes from a named source, which the test or its
  name cites (the oracle rule).
- A limit is tested at the limit and just past it, with the smallest
  input that crosses it. A recogniser is tested with inputs that almost
  match as well as with matches.
- It checks one behaviour, and the existing test of that behaviour is
  extended before a new one is added.
- e2e is for what only the binary shows: the process and its CLI,
  sockets, TLS, reloads, logs, the HTTP/2 loop, gRPC's wire behaviour,
  and the Admin API's routing, authentication and contract. The engine's
  semantics belong in the engine's in-process tests. The rule of about
  20 ms between awaits ([Build and test](#build-and-test)) still holds.
- A time bound is relative to the competing event or to the configured
  value, never to the runner's speed. A bound that says "X happens before
  Y" is written relative to Y, or to the configured value, for example
  under three times it. A fixed number stays only where a document states
  it as a tolerance, such as the 100 ms before a gRPC call's deadline in
  which a client's reset does not count
  ([Resets and the connection's defences](docs/grpc/state-and-faults.md#resets-and-the-connections-defences)).
- A property is grounded in a spec, as a round trip or agreement with a
  reference, reports its input classes, and shrinks.
- Killing a mutant is not enough: a test written for a survivor still
  states the behaviour from its source. The held-out measure checks that
  the tests did not merely fit the operators.
- Tests to learn from: `http1`'s split-invariance and random-garbage
  tests; `re2`'s conformance table; the codec tests on protoc's fixtures;
  the protobuf conformance job's failure list, as a model of a skip list;
  the goldens; the settings boundary pairs; `llm`'s size test (exactly
  1 MiB is within the bound, and one byte more is over it); the engine
  harness's fixed clock and seeded random source.

The e2e package may be built locally with one build job, so that work on
e2e tests need not go through CI:

```sh
moon test --target native -p smock/smock/e2e --build-only -j 1
```

Mutants, though, run locally only one at a time or in the diff mode, and
in the two exceptions that [Rules for the work](#rules-for-the-work)
names: every larger run goes to Actions.

### Removing a test

A test may go only under (A) or (B), and never when (C) holds.

- **(A) Mechanically redundant.** With the test removed, three sets stay
  the same:
  - the mutants killed over the full set, counting only tests in the same
    layer or a lower one: an e2e kill never justifies removing a unit
    test;
  - the covered points;
  - the trace links, derived mechanically: from the commit that
    introduced the test block (following moves and copies across files),
    to the tickets in its subject (Commit subjects, above), to those
    issues' acceptance criteria.
- **(B) Negative value.** It pins an implementation detail that a
  refactor keeping the behaviour would break, or restates a constant that
  no spec, document or user fixes. The default is to rewrite it, not to
  delete it.
- **(C) Keep reasons.** The test is:
  - the only test of a feature, an acceptance criterion, a rule of an ADR,
    a documented limit, or an Admin API reply's endpoint and status;
  - the only regression test of a closed bug;
  - the only e2e test of a feature a user sees;
  - a documented example that nothing else runs;
  - one of the deliberate overlaps: the HTTP/2 rules of
    [ADR 0005](docs/adr/0005-http2-comes-from-moonhttp.md), the contract
    checker's own tests, the goldens, the in-process codec tests on
    protoc's fixtures, the settings boundary pairs, and the reload tests
    with symlinks;
  - a test of a constant that a spec fixes, a vendor's published API
    reference included, such as the stop reasons of OpenAI's and
    Anthropic's APIs;
  - a test that the backends agree, or a test in a release build, such as
    the engine's tests of seeded floating-point results;
  - a test of behaviour that a dependency provides;
  - a test of smock's own C, the OpenSSL glue in `openssl/openssl.c` and
    the reset helper in `server/reset.c`. No mutant reaches that C, since
    the mutation runner skips FFI, so under (A) alone such a test could
    look redundant.

  The tests kept for the last five reasons are named in the keep list,
  [`mutation/kept-tests.toml`](mutation/kept-tests.toml).

An e2e test goes only when operator-level mutants of the `server` code on
its path are killed by the tests that remain, or when a named test at a
lower seam, together with one remaining e2e test, checks each of its
claims about the wire. Until the first run at operator level, only the
second way is open. A batch that removes e2e tests runs
`scripts/check-e2e-helpers.py` first: no test file uses what another
defines, so a test file can go whole without breaking another.

Each removal batch comes with its proof: the kill matrix, the point sets
and the trace links before and after, as CI artifacts, with an empty
difference; a replay of the real bug fixes
([#264](https://github.com/hirunefu/smock/issues/264),
[#60](https://github.com/hirunefu/smock/issues/60) and
[#59](https://github.com/hirunefu/smock/issues/59)) that first checks
that the full suite fails on each, and then checks the reduced one (a fix that cannot be reverted cleanly is replayed by bringing its
bug back in the smallest way, or left out with the maintainer's
approval); small commits that name the tests that take over; the
maintainer's approval; and a new measurement of the held-out set.

These never justify removing a test: coverage alone, text similarity,
smell detectors, a target count, or CI's speed.

## Mutation runner

The mutation runner makes, for a package, the mutants by which the tests
are judged ([How tests are judged](#how-tests-are-judged)), runs the
package's own tests on wasm-gc against each, then the tests of the
packages that import it against those that survive, and reports the
mutants that survive both. It has two parts, which only a line format
joins:

- `scripts/mutation/sites.py`, the site finder, reads source and prints
  one [site](#terms) per line, as JSON: the mutant's id, its file, its
  enclosing definition, its operator, its original text, its replacement
  text, its ordinal, its position (line and column), whether the pinned
  set takes it, the operator set's version, and whether its definition
  uses an unchecked array access (below). It finds the places in the
  parse tree, and `scripts/mutation/operators.py`, operator set v1, says
  what each place becomes.
- `scripts/mutation/run.py`, the runner, makes one mutant of each site
  that the finder prints, builds and tests it, and writes the records and
  the report.

The operators are those of [operator set v1](#operator-set-v1): BODY,
ROR, IFC, LCR, NOT, DEL, BOOL, AOR, INT and STR. `operators.py` holds
everything that decides what a "zero" means: the version, `v1`; each
operator's alternatives and which one the pinned set takes; STR's scope;
BODY's default values; and the rules that skip a site. A change to it is
a new version, and needs the maintainer's approval; the weakening report
lists it. The finder prints the pinned set (`--set pinned`, the default)
or the full set (`--set full`), and, besides the sites, each site that a
rule skipped, with the rule's reason (`"skipped"`) and no id, so that a
report can count it. Test files, test blocks and generated files have no
sites. A generated file is one whose first line says
`// Generated by <what>. Do not edit.`, as the Unicode data table
(`unicode/data.mbt`), the build information (`buildinfo/build_info.mbt`),
the test certificates (`testcerts/testcerts.mbt`) and the descriptor of
gRPC's `health.proto` (`server/health_set.mbt`) do.

**How sites are found.** Sites come from a parser, not from a lexer or a
regular expression, so that a string, a comment, a pattern or a range that
looks like an operator is never taken for one. The parser is the pinned
compiler's own: `moonc compile -dsource -show-loc <file>` writes the
file's parse tree beside it, with the position of every node, which gives
each operator's position and the extent of its operands. The finder copies
each file into a temporary directory and reads the tree there; the
compiler then fails to type the file, which it reads without its package,
and only a parse error fails the finder. This was chosen over a MoonBit
parser library, such as moonbitlang/parser, for two reasons:

- It parses exactly what the pinned compiler builds. A library has a
  grammar of its own, which can lag behind the compiler: the latest
  moonbitlang/parser when this was decided, 0.4.7, came out before moonc
  v0.10.20.
- It adds no module. moon resolves nothing new, so `NOTICE`, the image's
  SBOM and the dependency checks (`scripts/check-notice.sh`,
  `scripts/check-no-c.sh`, `scripts/check-moonhttp-pin.sh`) stay as they
  are.

What it costs: `-show-loc` is not in moonc's `-help`, and the format of
the tree is documented nowhere, so a new toolchain may change either. The
finder checks every site's original text against the source at the
position the tree gives, and fails rather than guess. Its tests run in
CI's job `checks`, which the weekly run with the latest MoonBit runs too,
so a change shows within a week. Should the dump go, a finder built on
moonbitlang/parser can replace this one without a change to the runner,
which reads only the finder's lines. That finder would be a module of its
own outside the workspace and away from the binary's modules, so its
dependencies would still not reach `NOTICE`, the SBOM or the dependency
checks, which read the modules the workspace resolves.

**Ids.** A mutant's id is its file, its enclosing definition, its
operator, its original text, its replacement text and its ordinal, joined
by commas, as in `usage/usage.mbt,resident_bytes,ROR,<=,<,0`. Inside a
field, a `\` escapes a comma or a `\`, and `\n`, `\r` and `\t` stand for
those characters. A text over several lines, such as a function's body,
which BODY replaces, is written in the id as its first line, `…` and its
last line, without the indentation: `{…}`. The definition is the
top-level one that holds the site: `f`, `Type::f`,
`impl Trait for Type with f`, `impl Trait with f` for a trait's default,
the name of a `let`, a `const`, a type or a trait, or `main` or `init`.
The ordinal counts, from 0, the sites of the same file, definition,
operator and texts that come before it, so an id stays the same as long
as the definition's sites of that kind keep their order. A report, an exclusion and a commit message
name a mutant by its id.

**A run.** The runner asks the finder for the full set, and runs the
pinned set (`--set pinned`, the default) or the full set (`--set full`).
A **position** is the place of one or more sites: their file, operator,
line and column. For each worker (`--workers`, 1 unless given), the runner
copies the workspace, the files git tracks and the untracked ones it does
not ignore, into `_build/mutation/tree-<n>`, and builds there into
`_build/mutation/target-<n>`: a build directory at a stable path, with a
target directory of the runner's own, so that a plain build and a mutant
build never rebuild each other. For each package, it first builds the
package's tests without a mutant and runs them twice. It stops if they do
not build, or if a run fails without naming a test that failed; a test
that fails in either run is listed, and gives no kill credit in this run.
The longer run sets the time limit. Then, for each mutant, it writes the
mutated file into the tree, builds the package's tests with
`moon test --target wasm-gc -p <package> --build-only`, and runs them. It
checks the build's exit status, so a mutant that does not build never
runs the binary of an earlier build, and it never passes `-u`.

**Confirmation.** A kill and a time-out are each checked once more, as
[Outcomes and kill credit](#outcomes-and-kill-credit) asks, by
`scripts/mutation/confirm.py`. The runner runs the tests again with the
mutant on, then without it. A kill counts only if some of the tests that
failed fail again and pass without the mutant, and the record then names
those tests alone; a time-out only if the mutant times out again and the
run without it finishes within the limit. A kill or a time-out that is
not borne out is **unconfirmed**, and its record says why. But a run
that the limit stops, or that fails without naming a test, did not pass,
and names no test (#431, the maintainer's twentieth round):

- a run again that ends so repeats the kill: the tests that failed in
  the first run kill the mutant if they pass without it, and no test is
  counted as flaky by it;
- when the first run ended so, the run again decides: one that passes,
  or in which only tests that give no kill credit fail, makes the mutant
  a survivor, which its importers' tests then run as any survivor's do;
  one that fails makes it killed, by the tests it names that pass
  without the mutant, or by none when it names none;
- the outcome is **timed out** only when the limit stopped both runs:
  where one of them failed within the limit, the mutant is killed;
- a run without the mutant that ends so shows neither that the tests
  pass without it nor that they finish in time: the kill or the time-out
  is unconfirmed.

So only a run again that finishes with the tests that failed now passing
makes a kill unconfirmed and counts those tests as flaky, whether the
package's own tests or its importers' ran. Each run is the whole
`moon test` of the package, as the first was, so properties run with
their committed seeds every time; the runner sets no seed. Each record
keeps how each of its runs ended (`ended`): the exit status, whether the
limit stopped it, and how many failed tests it named. A test whose
failures all give no kill credit makes no kill: the mutant survives, and
its record names those tests.

**Flake rates.** The runner counts each test's flaky results: a failure
without a mutant, in the two runs before any mutant or in the run that
confirms a kill, and a pass when a kill runs again with the mutant on. A
run again that the limit stops, or that fails without naming a test, is
no pass and no run of any test, nor is a run without the mutant that
ends so a run of the package's tests. Every test of a package runs
whenever its package's tests run without a
mutant, so a run's record counts those runs per package, and per test its
flaky results and its runs again with a mutant on. A test's flake rate is
its flaky results over its runs, across the latest runs that
`mutation/flakes.toml` names, and a test above the flake threshold there
gives no kill credit, until enough later runs without a flaky result have
pushed its flaky ones out of the latest. Each run writes `flakes.json`
beside its report: the latest runs' records, this one included, and the
rate of each test that had a flaky result among them. The next run reads
it with `--flakes <file>`. The records live in the artifact
`mutation-flakes` of the latest weekly run on GitHub Actions, which the
next weekly run downloads and passes to the runner
([Bulk runs on Actions](#bulk-runs-on-actions)). A run
made of shards, as the weekly run is, keeps one file: its shards each
read the same records, and
`python3 scripts/mutation/confirm.py merge <flakes.json>...` sums their
counts of this run into one record, as `scripts/mutation/merge.py` does
when it merges the shards' outputs. A run
without `--flakes`, as on a laptop, starts with no records, so only its
own two runs without a mutant take credit away.

**Importers' tests.** A mutant that survives the package's own tests runs
again, the same way, with the tests of the package's importers, which
gives a pure package the [kill credit](#outcomes-and-kill-credit) of any
wasm-gc test of the workspace. Its importers are the packages that import
it, in their source or their tests, directly or through other packages
whose source imports it. `scripts/mutation/importers.py` finds them in the
build's own package graph (`moon tree --package --json --target wasm-gc`),
not in a list kept by hand, before any mutant runs. The graph lists every
package on every backend, so it then asks moon whether each importer's
tests build on wasm-gc (`moon test --target wasm-gc -p <importer>
--dry-run`). Those that build only natively, `server`, `defdir`, `schema`,
`protobuf-conformance` and `e2e` among them, give no credit, since a pure
package's verdict is taken on wasm-gc. The importers' tests first run
twice without a mutant, as the package's own do, and their time limit
comes from those runs. A record names the package of each test that killed its
mutant, and the importers whose tests ran it again. To see a package's
importers: `python3 scripts/mutation/importers.py template`.

Each mutant's outcome, after both runs, is one of:

- **killed**: a test failed, and the kill is confirmed;
- **timed out**: the run took longer than 1.25 times the longer run
  without a mutant plus 4 s, and was stopped, and the time-out is
  confirmed. It counts as killed, and is listed apart;
- **unconfirmed**: a kill or a time-out that its confirmation did not
  bear out. It counts neither as killed nor as survived, and is listed
  with the reason and the mutant's diff;
- **unviable**: the mutant does not build. It counts neither as killed
  nor as survived;
- **survived**: every test that gives kill credit passed: in the first
  run, or, when the limit stopped that run or it failed without naming a
  test, in the run again (Confirmation, above).

A mutant that the compiler's output shows **equivalent**, or a
**duplicate** of another, has that outcome instead, and runs no tests
(below).

It writes into `_build/mutation/out/`: `mutants.jsonl`, one record per
mutant with its site, the set that ran, its outcome, the tests that
killed it, the importers whose tests ran it again, how its confirmation
went, the backend, the timings, and how each run ended (`ended`: its
run, its run again and its run without the mutant, and its importers'
runs under `importers`); `summary.json`, the operator set's
version and the set, the flake threshold with the tests above it and the
tests with a flaky result in this run, and per package the counts of
sites and positions in both sets, the sites each rule skipped, the counts
of each outcome and the runs without a mutant with the tests that failed
in them,
the same counts with the package's own tests alone, and its importers:
those on wasm-gc and those left out, the survivors their tests ran again
and how many the tests of each importer killed, and, when BODY mutants
ran, the **pseudo-tested functions**: those whose BODY mutant survived,
each with its status after the exclusion list; `report.md`, the same
counts, the time-outs, the kills confirmed by a run again that ended
otherwise than their run, the unconfirmed mutants, the pseudo-tested
functions, each survivor's diff with its whole enclosing definition
(and, for one whose run named no test and passed when run again, why
that was no kill), and the flaky tests, which the runner
also prints; and `flakes.json`, the flake records. A run of the full set counts
the mutants at the pinned alternatives and at the other alternatives
apart, and lists their survivors apart: L4 reads only the former.
`--sites-only` runs no mutant, and writes only the counts and the
mutants a run would make (`chosen.jsonl`). `--work` and `--out` choose
other directories.

**Shards, samples and listed sets.** Bulk runs choose among the mutants
with four more options, which `scripts/mutation/choice.py` implements.
Each summary says what chose its mutants (`selection`): the set, the
packages, the ids, the operators, the list's SHA-256, the sample and the
shard.

- `--operator OP`, once or more, runs only the set's mutants that those
  operators of v1 make, in the run's order. `--operator BODY` is a
  **BODY pass**: the BODY mutant of every function, which L2 reads. It
  takes no `--list`, which chooses its own mutants.

- `--shard k/n` runs the k-th of n parts of the mutants, in the run's
  order (the packages as given, then each package's sites), and the
  parts' sizes differ by one at most. Every mutant is in exactly one
  shard, and the same input gives the same shards. Each shard runs the
  tests of its packages without a mutant on its own, and a package with
  no mutant at all runs in the first shard.
  `python3 scripts/mutation/merge.py --out <dir> <shard>...` merges the
  outputs of every shard of one run into the output of the run without
  shards: the same records, counts and report, timings aside, the
  counts with the package's own tests alone, its importers' counts and
  the flake records included. One thing differs: each shard compares
  the compiler's output only among its own mutants, so a mutant that
  compiles as one in another shard runs its tests instead of being
  marked a duplicate, and both records hold the same digest. Each
  package's summary keeps each shard's run without
  a mutant, and its importers' run, under `shards`.
- `--sample N --seed S` takes N of the set's mutants, stratified by
  package. Each package gets its share of N, rounded down, and the
  mutants left over go to the packages whose shares lost the most in
  rounding (the first package given wins a tie). Within a package, the
  mutants taken are those whose ids, hashed with the seed by SHA-256,
  come first. So the same seed and tree give the same sample, whatever
  the version of Python. The seed is 0 unless given.
- `--list FILE` runs the mutants a file lists, in its order, in place of
  a set. Each line is a JSON object, a mutant by offset or by key:
  - **By offset**: `file`, `offset` (in characters, from 0), `original`
    (the text at the offset, which the mutant replaces), `replacement`,
    and `commit`, on which the offset holds; and `operator`, if the entry
    names one. The run stops unless the file holds its text on that
    commit and the original text at the offset.
  - **By key**: `file`, `definition`, `operator`, `original`,
    `replacement` and `ordinal`, the fields of an id, by which an
    exclusion names a mutant, with the texts whole. A key applies to any
    later commit where it still finds its text.

  A listed mutant that a site of operator set v1 makes is that site, with
  its id: by offset, one whose change is the site's, but for white space
  at its edges, as the finder tells two sites that make the same mutant.
  Any other is outside v1: its record says
  `"in_operator_set": false`. It is named as a site is, with the operator
  its entry gives (`OTHER` when an entry by offset gives none), and an
  ordinal that counts the places in its definition where the same
  original text starts before it, outside comments. So a key whose
  operator is one of v1's names a site of v1 by its id, and a mutant
  outside v1 takes an operator name of its own, such as `SWAP`. A key no
  longer applies when its file, its definition or its text is gone, or,
  for an operator of v1, its site. The run writes such a key, with why,
  to `unapplied.jsonl`, and the report counts it beside the outcomes of
  the others; with shards, the first shard counts them. The packages are
  those of the listed files, unless given: given packages leave the
  list's other mutants out.

  With `--totals-only`, which the held-out set needs, a listed run writes
  only `summary.json` and `report.md`, with counts per package and in
  total: listed, killed, timed out, survived, unviable, no longer
  applying, and the score. It prints no mutant's id, no output of a
  build or a test, and not the reason it stops, which may name a mutant.
  It removes from its output directory the files of an earlier run that
  name mutants, and from its work directory the workers' builds, which
  hold the last mutants. It takes no shard.

Without `--mutant`, `--operator`, `--list`, `--sample` or `--changed`,
every package given runs, as before; with one of them, only the packages
that hold one of the mutants.

**Mutants on the changed lines.** Before you push a branch, run the
mutants on the lines it changes. It is the one run larger than a single
mutant that is meant for a laptop:

```sh
python3 scripts/mutation/run.py --changed
python3 scripts/mutation/run.py --changed --base <ref>
```

`--changed` takes the merge base of `HEAD` with `main`, or with
`origin/main` where the checkout has no `main` branch (as CI's has not),
or with the ref that `--base` gives. Against it, it finds the lines that
the working tree adds or changes in the non-test `.mbt` files of the
[pure packages](#terms): your uncommitted changes count, and so does a
file that git does not track but does not ignore, since the runner copies
it. A generated file does not count, and a file that moved counts as
changed whole. A pure package here is a directory with a `moon.pkg` in a
module that `moon.work` lists, whose supported targets, if it names
any, hold wasm-gc. The runner then runs every mutant of the pinned set
whose original text holds one of those lines (so a function's BODY mutant
runs when any line of its body changed), with each package's own tests.
The report starts with the base, the merge base, the count of changed
lines and of the mutants that ran, and then lists the survivors with
their diffs. A change with no such line runs nothing and says so.
Package directories given limit the run to them. With `--sites-only`, it
counts the mutants on the changed lines and runs none, and with `--shard`
the shards merge as above. A change of 460 such lines, about the 75th
percentile of merges into `main`, had 174 mutants, which ran in 3.5
minutes on wasm-gc on an arm64 laptop with 8 cores. On each push, the
branch checks run the same mutants on GitHub's runners
([The changed-lines job](#the-changed-lines-job)).

**The compiler's output.** Before a mutant's tests run, the runner
compares the compiler's output for the mutated package with the output
without a mutant, and with the outputs of the mutants before it
(`scripts/mutation/compare.py`). This is the first of the three steps of
an equivalence claim ([Exclusions](#exclusions)). Identical output marks
the mutant **equivalent**, and output identical to an earlier mutant's
marks it a **duplicate** of that one. Neither runs tests, and neither
counts as killed or as survived. The output compared is the package
linked as a program on wasm-gc, the backend of the verdicts: `moonc
link-core` of the package's core IR, which the build of its tests made,
with the core IR of its dependencies, the package's public functions and
methods as the program's exports, the compiler's optimisations on, and
WAT, the text form of WebAssembly, as the output. This output was chosen
over the others for where it holds source positions:

- The core IR that `moon build` writes for a package holds the position of
  its code in a binary form, so a mutant that only makes its line longer
  or shorter changes it.
- The C of a native build names the source line of every statement, and
  the verdicts are taken on wasm-gc anyway.
- In WAT, only names hold positions. The compiler numbers its locals,
  labels and closures in the order it makes them, and a closure's name
  holds the line of its definition. Before the comparison, every name is
  replaced by a number in the order of its first use, which leaves the
  program as it was. Text that the program itself holds stays, such as
  the file, line and column that a call to `fail` puts in its message.
  So mutants keep the source's line breaks, and such text changes only on
  the mutant's own line: a deletion leaves its lines empty, a block keeps
  them before its closing brace, and another expression keeps them inside
  parentheses.

The link leaves out what the exports do not reach, inlines small
functions into their callers, and compiles a generic function once for
each type it is used with. So a mutant is compared only where both the
output without it and its own output hold a function of its own, by its
name, for the definition that holds the site. Such a function is compiled
once for every caller, so the same output means the same function for
any argument. Otherwise an implementation of a trait that no function of
the package uses would look equivalent, since the output lacks it with
the mutant and without it. A mutant in such a definition, in a function
inlined into each of its callers, in a generic function, or in a
constant or another value is **not compared**, and runs its tests.

Each record of a mutant that built says what the comparison found
(`compiler_output`): `identical`, `duplicate` (the record names the first
mutant in `duplicate_of`), `differs`, or `not compared` with the reason,
and the output's digest where it was compared. The summary and the report
count the equivalent mutants, the duplicates and the mutants not compared
per package, apart from the other outcomes and from exclusions. The
report lists the equivalent mutants and the duplicates, each duplicate
with the mutant it compiles as and that mutant's outcome. What this
costs: the names in `moonc link-core`'s output, like the finder's
`-show-loc`, are documented nowhere. If a new toolchain renames its
functions, their mutants are not compared, which is safe, and the
fixture's tests fail in the weekly run with the latest MoonBit.

**Native verdicts.** The verdicts for pure packages are taken on
wasm-gc, but wasm-gc traps on an unchecked array access out of bounds,
where the native binary reads on without a sign: a mutant there can be
killed on wasm-gc by the trap alone and survive natively
([Outcomes and kill credit](#outcomes-and-kill-credit), "Backend"). So
the finder marks each site whose enclosing definition calls an unchecked
array access, with `"unchecked_access": true` on its line. These are
core's methods that read or write the elements of an array, a string or
bytes, or make a view of them, without a bounds check, told by their
names, since the parse tree has no types: `unsafe_get`, `unsafe_set`,
`unsafe_view`, `unsafe_mut_view`, `unsafe_char_at`, `unsafe_charcode_at`,
`unsafe_substring`, `unsafe_range_equal`, `unsafe_pop`, `unsafe_pop_back`,
and those whose names start with `unsafe_blit`, `unsafe_read_`,
`unsafe_write_` or `unsafe_extract_`. `unsafe_to_char`,
`unsafe_reinterpret_as_bytes` and `unsafe_make` read no element, and mark
nothing. At d88929b2, 20 definitions in `http1`, `importopenapi`, `log`,
`protobuf` and `yaml` hold such a call, with 693 sites of the pinned set
(1,039 of the full set), 414 of them in `protobuf`.

A marked mutant whose tests ran on wasm-gc (it built, and the compiler's
output did not show it equivalent or a duplicate) runs again natively
(`scripts/mutation/native.py`), the same way: two runs without a mutant
first, then the package's own tests and, if it survives them, the tests
of the importers whose tests ran it on wasm-gc, with kill confirmation.
Its record gives both verdicts under `verdicts`: `wasm-gc` and `native`,
each with its outcome, the tests that killed it, its timings and its
confirmation, and the machine that took the native one. `backend` names
the verdict that counts. **Native verdicts are taken on CI's amd64
runner** (`ubuntu-24.04`): a mutant killed on wasm-gc that survives
natively there is a survivor, with its diff, until a test kills it
natively or an exclusion covers it (UB-NATIVE). One machine is the
reference so that anyone can reproduce a verdict: natively, an access
out of bounds is undefined behaviour, and what it does can change with
the machine and with the C compiler that built the test program. That
machine is CI's amd64 runner because native builds there are about six
times faster than on arm64
([Test costs on CI's runners](#test-costs-on-cis-runners)). A native
verdict taken anywhere else, as on a laptop, is for information. The
runner lets the native verdict decide on any amd64 machine, so that a
laptop's records read as CI's would; on arm64 it records the native
verdict and counts the wasm-gc one. Each package's summary (`native`)
gives the machine, whether its verdict decides, the marked mutants, how
many ran natively, their native outcomes and how many verdicts differ,
and the report lists the mutants whose verdicts differ between the
backends.

A package that builds only natively, which moon refuses to test on
wasm-gc, runs wholly natively: the two runs without a mutant, the
self-test and every mutant, with the package's own in-process tests. Its
compiler output is not compared, since the output compared is wasm-gc's,
and e2e's tests give it no credit in this run; the runs through e2e
([#344](https://github.com/hirunefu/smock/issues/344),
[#346](https://github.com/hirunefu/smock/issues/346)) give that.

Native runs build with no C flags. Before the first native build, the
runner unsets `MOON_CC`, `MOON_AR` and `MOON_CC_WRAPPER`, the variables
by which moon takes another C compiler, archiver or compiler wrapper, and
the summary and the report name those it unset. The runner sets none, and
its copy of the workspace is the workspace as it is. Natively, an abort
or a read out of bounds often stops the test program, so native runs
dump no core.

Each native mutant is built on its own, as on wasm-gc, not in one schema
build. On amd64, #276's run on CI's runners rebuilt `engine`'s native
tests after one mutant in 5.3 s and ran them in 3.8 s; `engine` is the
largest package. At that cost, with about four in five mutants killed,
as in the prototype's sample, and each kill confirmed by two more builds
and runs, the 693 marked mutants of the pinned set take at most about
4.6 hours of runner time, about 14 minutes on 20 jobs. A schema build
would save at most the rebuilds, about half of that, and would need a
read of an environment variable inside the pure packages, which do no
I/O, and a type check of each mutant before it enters. On arm64 the same
rebuild took 41.1 s. A laptop can still run one marked mutant natively,
with `--mutant`, and its verdict is for information.

To see the sites of a package, and to run one mutant, or the few mutants
of a small package (they need python3, git, moon and moonc):

```sh
python3 scripts/mutation/sites.py usage
python3 scripts/mutation/sites.py --set full usage
python3 scripts/mutation/run.py --sites-only usage
python3 scripts/mutation/run.py --mutant 'usage/usage.mbt,resident_bytes,ROR,<=,<,0' usage
python3 scripts/mutation/run.py usage
```

Run only that much on a laptop, besides the mutants on your changed
lines (above). Bulk runs, over many packages or the weekly and monthly
sets, go to GitHub Actions
([Bulk runs on Actions](#bulk-runs-on-actions)).

The tests (`python3 -m unittest discover -s scripts/mutation -v`) run the
finder and the runner on `scripts/mutation/fixture`, a module that is not
a member of the workspace. In its package `calc`, each mutant of the
pinned set has a known outcome, given beside the site with its reason:
some are killed, a few survive, one times out, and one does not compile.
In its package `log`, whose paths put it in STR's scope as smock's `log`
is, each mutant of the full set has one. The package `shapes` holds a
site in each kind of definition, and look-alikes that are not sites; the
package `forms` holds each form of each operator, and the tests copy its
strings into STR's scope too. In its package `units`, each mutant has a
known outcome with `units`' own tests and, for those that survive them,
with its importers' tests: `meter` imports `units`, `dial` imports
`meter`, for its tests only, and each kills one survivor; `probe` imports
`units` but builds only natively, so the one survivor that only its test
would kill stays a survivor. The tests of confirmation run calc's
mutants with a moon that answers the runs of tests from a script (a
failure, then a pass; a time-out, then a run within the limit), so that a
flaky failure and a time-out that does not repeat happen every time; the
real moon builds. `scripts/mutation/test_choice.py` runs the options
above on copies of the fixture, some in a small git history, and merges
shards; `scripts/mutation/test_changed.py` runs `--changed` on a small
git history of the fixture, with a branch, a later change on `main` and
a package that builds natively only. `moon fmt --check`
at the root does not read the fixture: run `moon fmt` inside it after a
change. In the fixture's package `bounds`, `dot_after` reads a character
with `unsafe_get`, and each mutant of the pinned set has a known outcome
on each backend, given beside the site: one is killed on wasm-gc by the
trap alone and survives natively, and another survives `bounds`' own
tests natively and is killed by those of `dots`, which imports `bounds`
for its tests. The package `host` builds only
natively. `scripts/mutation/test_native.py` runs both, with moon's
variables for another C compiler set to ones that do not exist, and the
shards of `bounds`, whose native verdicts merge.

In the fixture's package `same`, each mutant of the pinned set has a
known outcome and a known result of the comparison of the compiler's
output, given beside the site. Two mutants are equivalent: one makes its
line shorter, and the other deletes a call over three lines. One compiles
as another mutant does. Three are not compared: one in a constant, one in
an implementation of a trait that no function of the package calls, and
one that lets the compiler put a function into its caller.

### The self-test

Each run, in each package where it has a mutant to run, first switches
on a mutant that the package's tests must see, and stops unless a test
kills it. A runner that
applies no mutant, builds or tests another tree, runs the binary of an
earlier build, takes a failed test for a pass, or breaks every build
would otherwise report each mutant as survived or as unviable, and the
second is a "zero" that says nothing.

The rule that chooses the mutant: it puts `abort("mutation self-test")`
at the start of the body of every top-level function and method of the
package's non-test source whose body is MoonBit. Foreign functions,
`init` and `main` blocks, test blocks, test files and generated files are
left as they are. The functions come from the compiler's parse tree, as
the sites do, but not from the finder's lines. So the mutant depends on
the package's source alone, never on the finder's output or on a run's
outcome. The runner switches it on after the two runs without a mutant
and before the first mutant, with the time limit they set, and switches
it off again. Only a kill passes, by a test that gives kill credit in the
run: a self-test that survives, times out or does not build stops the
run, and so does a package with no function to change. The summary and the report give the self-test's record: the
functions it changed and how many tests failed.

A self-test that the package's own tests do not see runs again with the
tests of its importers that build on wasm-gc, as a mutant that survives
them does: their tests first run twice without it, which sets the time
limit, and the record then names those importers. `cookies` and `unicode`
have no tests of their own, so their self-test passes only so. A package
whose functions no test of its own or of its importers calls fails its
self-test, as does one whose only importers build natively.

`--self-test-only` runs, for each package, the runs without a mutant and
the self-test, and no mutant; it takes no option that chooses mutants. CI's job `checks` runs it on the fixture
module's packages that have tests, `calc` and `log`. The runner's tests
break the runner on purpose, with a moon that never fails a test, one
that tests another tree and one whose builds fail after the first, and
check that the self-test stops the run before any mutant.

### The site counts

`mutation/site-counts/<package>.jsonl` holds, for each package of the
workspace that has a site, one line per top-level definition that holds a
site, as JSON: its file, its name, a hash of its text (the first 16
hexadecimal digits of the SHA-256 of its lines, from the first to the
last), and its count of sites of each operator in the pinned set and in
the full set. `python3 scripts/mutation/ratchet.py write` writes them
from the site finder's lines. The packages are every directory with a
`moon.pkg` in the modules that `moon.work` lists; the runner's fixture
module is not one of them.

`python3 scripts/mutation/ratchet.py check --base origin/main`, in CI's
job `checks`, fails:

- when the committed counts are not what `write` writes on the commit,
  with the pinned toolchain. So a change that alters sites updates them
  in the same change. In the weekly run with the latest MoonBit, the same
  difference shows a compiler that finds other sites, and fails that run
  as its other checks do.
- when a package's sites drop, against the counts committed at the merge
  base with `main`, by more than the base's sites in the definitions that
  the change deletes or changes. The comparison is per definition. A
  definition that the change neither deletes nor changes is one whose
  text the package still has, in any of its files: a definition moved
  within its package is the same definition. For each such definition,
  each operator and each set, a count below the base's is a drop that
  only the list of approved drops allows. Such a drop comes from a change
  to the finder, to operator set v1 or to the toolchain, or from moving a
  definition out of STR's scope.

`mutation/approved-drops.txt` is the list of approved drops. For each
package, operator and set with such a drop, the change adds a line
`<package> <operator> <pinned|full> <sites> <reason>`, with the number of
sites that the check's message gives. Only the lines that a change adds
approve its drops, and each must name a drop that the change makes. Both
files are in `scripts/verdict-files.txt`, so the weakening report shows
their changes, and the maintainer's acknowledgment of the report at the
merge is the approval. A merge base with no committed counts, from before
this check, is compared with nothing; on `main`, the merge base is the
commit itself.

### The kill matrix

A [kill matrix](#terms) gives, for each mutant, every test that kills it.
Snapshot audits choose among the tests that alone kill some mutant
([Snapshot audits](#snapshot-audits)), and a removal batch compares the
matrix before and after its removals ([Removing a test](#removing-a-test)).
`--matrix` makes the runner build one:

```sh
python3 scripts/mutation/run.py --matrix usage
python3 scripts/mutation/run.py --matrix --set full usage
```

In this mode, each mutant runs once against the tests of its package and
of all the package's importers that build on wasm-gc together, whichever
would kill it first, with no early stop. A run without the mode runs the
importers' tests only against the survivors of the package's own. Each
test that fails is confirmed on its own: it is credited with the kill
only if it fails again with the mutant on and passes with it off, so a
flaky test drops out of the matrix while the other tests keep the kill.
Each record lists every test that kills its mutant, with its package and
its **layer**: `in-process` for the tests of every package but `e2e`,
whose tests are `e2e`. Removal rule (A) counts only the kills of tests in
the same layer as the test removed or a lower one, and `in-process` is the
lower. The mode runs over the pinned set or, for removal proofs, over the
full set, and with the other options that choose mutants; it takes no
`--totals-only` or `--self-test-only`. Its self-test runs with the
package's own tests, as in a run without the mode.

The tests of a matrix are those that moon's outline
(`moon test --outline`) lists for the package and its importers. The run
stops before any mutant if the outline lists two tests that the matrix
would name alike, and after the package's mutants if it lists a different
number of tests than the runs without a mutant ran. A test is named by its package, `/` and its file, then `:` and its name, as
in `smock/smock/usage/usage_test.mbt:<name>`, or, for a test with no name
such as a documentation test, `#` and its index in the file, as in
`smock/http1/target.mbt#0`. Confirmation and the flake records name such
a test by its index too, since moon tells it apart by nothing else.

A time-out names no test: the run stops whole at its limit, so which test
would have failed is not known. It stays a time-out in every answer of the
tool below, and a removal batch sees a lost time-out only in the matrix
after the removal.

Besides the usual output, the run writes
`_build/mutation/out/matrix/<package directory>.json`, the package's
matrix: the packages whose tests ran, its importers that build only
natively, every test that ran with its name, package, file, line, index,
name and layer, and each mutant with its outcome and the names of the
tests that kill it, and, for a duplicate, the mutant it compiles as. Every
run rewrites `matrix/`, so a run without the mode leaves none. The summary
says that the run was a kill matrix (`kill_matrix`), and gives, per
package, in place of the counts with its own tests alone and
with its importers' tests, the tests that ran, how many of them kill some
mutant, how many alone kill some mutant, and how many mutants the tests of
each package kill; the report gives the same counts. `merge.py` merges the
shards of a kill-matrix run into one matrix per package, and refuses a
shard of a run that is not one.

`scripts/mutation/matrix.py` reads matrices, given as files or as a run's
output directory, and prints JSON lines:

```sh
python3 scripts/mutation/matrix.py alone _build/mutation/out
python3 scripts/mutation/matrix.py alone --none _build/mutation/out
python3 scripts/mutation/matrix.py kills --without --test '<test>' _build/mutation/out
python3 scripts/mutation/matrix.py kills --package smock/smock/usage _build/mutation/out
python3 scripts/mutation/matrix.py kills --without --test '<test>' --layer in-process _build/mutation/out
python3 scripts/mutation/matrix.py draw --seed <run ID> _build/mutation/out
```

- `alone` lists the tests that alone kill some mutant, each with those
  mutants; `--none`, the other tests, each with the mutants it kills
  together with other tests. A duplicate counts as the mutant it compiles
  as.
- `kills` gives each mutant's outcome as if only a set of tests had run:
  the tests `--test` names and the tests of the packages `--package`
  names, or every other test with `--without`, and with `--layer`, only
  those of the set in that layer or a lower one. A mutant that the matrix
  holds as killed survives unless a test of the set kills it. So, with one
  test left out, the mutants that only it killed show as survivors, as
  they do in a run without that test.
- `draw` draws the tests of a snapshot audit, with the kill-matrix run's
  ID as the seed: the rule is in [Snapshot audits](#snapshot-audits).

The tests (`scripts/mutation/test_matrix.py`) run the mode on the
fixture's package `units`, whose mutants the tests of `units`, `meter` and
`dial` kill, some by several tests of several packages and some by one
test alone, while `probe`'s test, which builds only natively, never runs.
Two of `units`' tests have no name. A moon that answers from a script
makes one killing test flaky, or failing without the mutant, and the run
leaves that test out of the matrix. One run leaves `meter`'s test out and
gets the survivors that `kills --without` gives. The tool's other tests
read a matrix written by hand, with an e2e test, a duplicate and a
time-out. The draw's tests read two matrices written by hand against a
small git workspace laid out as smock's, with a base commit and the work
on top, and expect the draws that the script which drew the first three
audits gave there.

### The canary

The canary checks that the runner still sees what it saw, with known
answers. The throw-away prototype of the test review sampled 250 mutants
at d953f320 and recorded each one's verdict: with the package's own tests,
and, for 42 of the 55 that survived them, with the tests of the packages
that import it. `mutation/canary/mutants.jsonl` holds them, one per line,
as mutants by offset that `run.py --list` reads, each with its name in the
prototype's notes (such as `template-compare-arith-032`), its recorded
verdict (`killed`, `timed out`, `survived` or `unviable`) and the packages
whose tests gave it. 196 were killed, 8 timed out, 39 survived and 7 did
not build.

`python3 scripts/mutation/canary.py run` replays them on d953f320's
source. It checks that commit out into `_build/canary/source`, as a
worktree without a branch, and runs `scripts/mutation/run.py --list`
there, as any run: each package's own tests, then its importers' tests
for the survivors, kill confirmation and the comparison of the compiler's
output. It then compares each verdict with the recorded one, and writes
`canary.md` and `canary.json` beside the runner's output in
`_build/canary/out`. A verdict is compared as killed, survived, unviable
or unconfirmed:

- a confirmed time-out counts as killed, as it does in the score;
- a mutant that the comparison of the compiler's output marks equivalent
  matches a recorded survivor;
- a duplicate takes the verdict of the mutant it compiles as;
- an unconfirmed mutant matches nothing.

**The toolchain.** The replay runs with the toolchain that d953f320 pins in
`.moonbit-version`. It stops before it builds anything when `moonc` on
`PATH` is another. `python3 scripts/mutation/canary.py install` checks
the commit out and runs that commit's own
`scripts/install-moonbit.sh pinned`, which replaces the toolchain in
`$MOON_HOME`, or `~/.moon`. So it runs in a job of its own, not on a
laptop whose toolchain other work shares. When that toolchain can no
longer build that commit, or can no longer be installed, the replay stops
and says so. The canary then moves to a new commit with new recorded
verdicts, with the maintainer's approval.

**The site finder.** Each mutant within operator set v1 names the v1 site
that makes it (`"v1"`, the site's id). Each other mutant names the rule of
v1 that leaves it out (`"outside"`). `python3 scripts/mutation/canary.py
sites`, which every replay runs first, checks each mutant's original text
at its offset on the commit. It then runs the site finder's full set on
the commit's files. The finder must still give each named site, where the
mutant is, and no site may make a mutant recorded outside v1. So a
narrowed finder fails the replay, and so does a widened one. 214 of the
250 are within v1. 15 of those are made by a site that writes the same
mutant another way: an integer literal in the base the source writes it
in (`0x0UL` where the prototype wrote `0UL`), or BODY's `{ () }` where
the prototype deleted the only statement of a function. The 36 outside v1
are ROR's other alternatives (31: `<` to `>=` and the like, and `==` with
`!=`), two `&&` that join conditions binding a name with `is`, an integer
that its type cannot hold, a literal in a pattern, and the last statement
of an `if` body that has an `else`. The runner still runs them, as
mutants outside v1 (`"in_operator_set": false`) with the prototype's
operator names.

**Explained differences.** `mutation/canary/explained.toml` lists the
differences that were explained on #275 and that the maintainer accepted.
Each names the mutant, its recorded verdict, the verdict the replay gives,
a category, the reason and a link to the acceptance. The categories are a
flaky test, a time limit, a mutant that the parse-based site finder places
differently, and importers' tests that the recorded verdict did not run:
the prototype ran the tests of the packages that import a package
directly, and none for the survivors of `metrics` and `engine/range.mbt`,
while the runner runs those of every importer. A bug in the runner is
fixed instead. A
difference that is not on the list fails the replay. The report lists the
explained differences too, and those on the list that the replay did not
give. Both files are under `mutation/`, which `scripts/verdict-files.txt`
names, so the weakening report shows every change to the list and to the
recorded verdicts.

The whole replay is a bulk run, so it runs on GitHub Actions, in
`.github/workflows/mutation-canary.yml`, started by hand
(`gh workflow run mutation-canary.yml`), and the weekly mutation run calls
it. The workflow keeps the output as the artifact `mutation-canary`. On a
laptop, check the sites, or replay a few mutants by name:

```sh
python3 scripts/mutation/canary.py sites
python3 scripts/mutation/canary.py run --mutant cookies-000 --mutant template-compare-arith-007
python3 scripts/mutation/canary.py compare --mutant cookies-000 _build/canary/out
```

With `--shard k/n`, `run` runs one shard and compares nothing;
`scripts/mutation/merge.py` merges the shards' outputs, and `compare`
compares the merged one. The tests (`scripts/mutation/test_canary.py`)
check the committed data against d953f320, so they need the history down
to that commit, and run the replay, its toolchain check and the install
on a canary of the fixture's mutants in a git history of its own.

### Bulk runs on Actions

Bulk runs go to GitHub Actions, never to a laptop, but for the two named
exceptions: step 1's replay of the 250 sampled mutants and the held-out
runs on the maintainer's machine. `.github/workflows/mutation-runs.yml`
runs them when started by hand, from the Actions tab or with `gh`, and
on two schedules, the weekly run and the monthly run (below), never on
pushes or pull requests. GitHub runs a workflow on a schedule, or starts it by hand, only
once it is on the default branch; `--ref` picks the commit a run by hand
runs on:

```sh
gh workflow run mutation-runs.yml -f mode=sample -f size=1000 -f seed=<seed>
gh workflow run mutation-runs.yml -f mode=body
gh workflow run mutation-runs.yml -f mode=packages -f set=full -f packages='yaml http1'
gh workflow run mutation-runs.yml -f mode=matrix -f packages=usage
gh workflow run mutation-runs.yml -f mode=list -f list=<a file in the repository>
gh workflow run mutation-runs.yml -f mode=timing -f size=50 -f seed=<seed>
gh workflow run mutation-runs.yml --ref main -f mode=monthly
```

Its inputs:

- `mode`, what the run runs, with the runner's options above:
  - `sample`: a seeded sample of `size` mutants of the set, stratified by
    package (`--sample`);
  - `body`: a BODY pass (`--operator BODY`);
  - `packages`: every mutant of the set;
  - `list`: the mutants that `list`, a file in the repository, lists
    (`--list`), in place of a set;
  - `matrix`: a kill matrix (`--matrix`), for a snapshot audit or a
    removal batch;
  - `timing`: one shard, a seeded sample of `size` mutants, run three
    times, each on a runner of its own, with 1, 2 and 4 mutants built and
    tested at once (`--workers`);
  - `weekly` and `monthly`: the weekly run and the monthly run, below, by
    hand.
- `packages`: package directories, separated by spaces. Without them, a
  run takes the pure packages that have sites: the 19 and `serverparsers`
  ([Terms](#terms)); `testcerts` is data and has none. With a list, the
  packages of its files.
- `set`: `pinned`, the default, or `full`.
- `seed` and `size`: a sample's, 0 and 1,000 unless given.
- `width`: how many shards run at once, from 1 to 20, the default.
- `workers`: how many mutants each shard builds and tests at once, 1
  unless given. That is the baseline's measurement: in its timing
  ([run 44422395058](https://github.com/hirunefu/smock/actions/runs/44422395058),
  one shard of 50 mutants on `main`), 1, 2 and 4 at once took 6.9, 6.6
  and 7.2 s a mutant, with the same outcome for each mutant. Two at once
  gained 4% and four lost 5%, so bulk runs keep one at a time on each
  runner. `bulk.py`'s `WORKERS` and the workflow's input say so, and the
  workflow's check refuses another default.

A run runs the runner as any run does: each package's own tests, then
its importers' tests for the survivors, kill confirmation, the comparison
of the compiler's output, the self-test and the exclusion list. It has
three jobs, and `scripts/mutation/bulk.py` holds the steps they take:

- **plan** runs `run.py --sites-only` on the mode's selection, which runs
  no mutant, and cuts the mutants into shards: as many as the width, or
  more when a shard would not end within a job's time. A job on GitHub's
  runners stops after 6 hours; a shard's mutants may take 5 of them, at
  the planned time of a mutant, 16 s (below; `bulk.py plan
  --seconds-per-mutant` overrides it), so a shard holds at most 1,125
  mutants. The sixth hour is for the checkout and the setup, under a
  minute in the baseline, and is room to spare. More shards than the
  width run in waves, as jobs come free, so their count is then a
  multiple of the width, which fills each wave. A run never has more
  shards than mutants, and one that would need more than the 256 jobs a
  matrix makes is refused. The job's summary gives the run's mutants per
  package, and how many of them are at an unchecked access, and the plan
  is kept as the artifact `mutation-plan`.
- **shard** runs each shard (`bulk.py shard`), at most the width at once,
  on an amd64 runner (`ubuntu-24.04`) with the native setup. Verdicts of
  a pure package are taken on wasm-gc, which any runner gives alike, but a
  mutant at an unchecked access also runs natively, and its native
  verdict decides only on amd64 ([Native verdicts](#mutation-runner)). A
  shard stops after 6 hours. Its output, with `bulk.json`, which says how
  long its run took, is kept as the artifact `mutation-shard-<shard>` for
  7 days, also when it fails.
- **finish** merges the shards with `merge.py` (`bulk.py finish`) and
  starts the report with the run: its link, what it ran, its shards, its
  wall time, from the first job's start to the last job's end, and its
  runner time, the jobs' times added up, both read from GitHub's API, and
  how long the longest shard took. Then a line per package: mutants,
  killed, timed out, survived, unexplained and stale-covered survivors,
  unviable, unconfirmed, the kill rate, the pseudo-tested functions among
  the BODY mutants that ran, and the sites skipped. Then the merged report,
  with each package's sites skipped by rule, its survivors and its
  pseudo-tested functions. The kill rate is reported, never gated. The
  report is kept as the artifact `mutation-report` for 90 days, and shown
  in the job's summary when it fits. A shard that failed makes the merge
  fail; its own artifact holds what it wrote.

To read a run's report:

```sh
gh run download <run id> --name mutation-report --dir mutation-report
```

**The weekly run**, every Friday at 20:23 UTC, or when GitHub starts it,
which may be hours later (below), runs the pinned set over the pure
packages, the set over which L4 is defined, so it verifies L4.
Its shards run as any run does: each package's runs without a mutant
and its self-test first, then its own tests and its importers' tests, kill confirmation, the comparison of
the compiler's output, the exclusion list, and the native verdicts of the
mutants at an unchecked access. They run the properties with their
committed seeds, and read the flake records of the latest weekly run,
which the plan downloads. Beside them:

- the plan checks the site counts (`ratchet.py check`) and lists the
  stale entries of the exclusion list (`bulk.py stale`);
- the job `canary` calls `.github/workflows/mutation-canary.yml`, which
  replays [the canary](#the-canary) with the toolchain its commit pins;
- the job `coverage-e2e` calls `.github/workflows/coverage-e2e.yml`,
  which reports the coverage of `server` and `cmd/smock` from the e2e
  tests and the in-process tests together
  ([Coverage from the e2e tests](#coverage-from-the-e2e-tests)); it
  reports only: the finish does not wait for it, and the release's check
  does not read it;
- the job `seeds` runs the properties with random seeds
  (`bulk.py seeds`), in a working copy of its own that no shard reads: it
  writes a random seed into each seed constant
  (`scripts/random-seeds.py`), runs each test file that holds one, and
  reports each seed, and each failure with its seed and the command that
  runs it again ([Rules for the work](#rules-for-the-work), "Seeds"); its
  report is in its job's summary and in the artifact `mutation-seeds`;
- the job `stale-entries`, when the plan lists stale entries, opens an
  issue for their re-triage in a batch, "Stale entries of the exclusion
  list to triage again", or comments on the one already open. It is the
  workflow's one job that writes, and only issues, as the weekly run with
  the latest MoonBit reports its failures, and it runs nothing of the
  repository's.

Its report counts, per package, the unexplained survivors, those that a
DEFERRED entry covers included, and the stale-covered ones, which count
as unexplained, as L4 counts them; each stale-covered survivor's section
names its stale entry. A failed canary, self-test or property seed fails
the run, and the report starts with the jobs that did not succeed. The
report keeps this run's flake records as the artifact `mutation-flakes`
for 90 days, which the next weekly run reads.

Each run's name says its mode: "Mutation runs: weekly" for the weekly
run, whether its schedule or a person started it, and "Mutation runs:
monthly", "Mutation runs: sample" and so on for the others. The release
workflow's check of the latest weekly run
([What a tag does](docs/releasing.md#what-a-tag-does)) finds the weekly
runs by that name, those on `main` and one started by hand on a tag alike.
A run from before the workflow named its runs is called "Mutation runs"
alone, and the check does not read it.

**The monthly run**, on the 1st of each month at 22:43 UTC, and by hand
before a release, runs the full set over the pure packages. It reports
only: its report gives, per package, the unexplained survivors at the
pinned alternatives and at the other alternatives apart, and its
survivors at the other alternatives stop no merge and no release and do
not count towards L4 (decision 7). Step 5 adds `server` and `cmd/smock`
through e2e to it, in a job of its own
([#346](https://github.com/hirunefu/smock/issues/346)), and the small
native-only packages, which the runner runs wholly natively (`bulk.py`'s
`MONTHLY_NATIVE_ONLY`).

**When they run.** Both run at the full width, at a quiet hour: in the
evening UTC, when the repository has seen the fewest commits, and days
away from the weekly run with the latest MoonBit, on Mondays at 03:17
UTC. When the 1st is a Friday, the monthly run's time is two hours and
twenty minutes after the weekly one's. The weekly run took 2 h 9 min the
first time, in 40 shards
([run 44423781036](https://github.com/hirunefu/smock/actions/runs/44423781036)),
and 3 h 28 min the second, in 20 shards planned at 16 s a mutant
([run 44851160701](https://github.com/hirunefu/smock/actions/runs/44851160701)),
from its first job's start to its last job's end. Two hours and twenty
minutes after the second started, two of its shards, `engine`'s and
`protobuf`'s, still held their jobs, for 40 and 69 minutes more, so two
of a monthly run's first 20 shards started then would wait for them
that long. GitHub starts a scheduled run when it can, which may be hours
after its time: it started the second weekly run, the first that its
schedule started, at 01:36 UTC on Saturday, 5 h 13 min after its time.
So how the two runs meet depends on GitHub too. A push during either
waits for free jobs.
`bulk.py`'s `SCHEDULES` maps each schedule to its run, and the workflow's
check pins both.

**Stage 1's triage tickets.** A package with more than about 40
survivors in the weekly run gets triage tickets of at most about 40
survivors each, never splitting a source file that holds fewer. From the
first weekly run's report:

```sh
gh run download <run id> --name mutation-report --dir mutation-report
mkdir -p bodies
for n in 323 324 325 326 327 328 329; do
  gh issue view "$n" -R hirunefu/smock --json body --jq .body >"bodies/$n.md"
done
python3 scripts/mutation/bulk.py triage --report mutation-report --bodies bodies --out tickets \
  --run-url <run link>
```

For each of stage 1's closing tickets whose packages have more than 40
unexplained survivors together, stale-covered ones included, it writes a
body per ticket into `tickets/`: its survivors' ids, the closing ticket's
criteria Triage, Kills, Exclusions, Code and No weakening for those
survivors only, the time the agent spent, and its blockers, #314 and
#315, and #320 for settings. `tickets.json` gives each ticket's title,
label, blockers and the closing ticket it blocks; `tickets.md` the count
per closing ticket. The tickets become sub-issues of the closing ticket
they block, which gains each as a native blocker; the spec's issue holds
as many sub-issues as GitHub allows.

**The account's jobs.** GitHub runs at most 20 of the repository's jobs at
once. A run at the full width holds them all until its first shards
end, and a push meanwhile waits for free jobs: CI's jobs on that push
start as shards end. The second weekly run held all 20 for its first 40
minutes, about half of them after an hour and a half, and from 2 h
16 min on only its two longest shards, then one, until it ended after
3 h 28 min. A run started by hand while others are pushing takes a
smaller width, such as 10. It then has fewer shards, each longer, and
leaves the other jobs to CI.

**The baseline** of step 2 is a sample of 1,000 mutants of the pinned set
over the pure packages, whose survivor rate applies to positions as step
3's triage budget does, and a BODY pass over every pure function:
`-f mode=sample -f size=1000 -f seed=<seed>` and `-f mode=body`. The
mode `timing` times one shard of it, 50 mutants, with 1, 2 and 4 mutants
at once, and its report gives the time per mutant for each. The baseline
ran on `main` at 7eac627b: the sample in
[run 44417735318](https://github.com/hirunefu/smock/actions/runs/44417735318)
(20 shards of 50 mutants), the BODY pass in
[run 44419874781](https://github.com/hirunefu/smock/actions/runs/44419874781)
(20 shards of 67 or 68) and the timing in
[run 44422395058](https://github.com/hirunefu/smock/actions/runs/44422395058).
The runs' reports, with their links and their wall and runner times, are
posted on [#275](https://github.com/hirunefu/smock/issues/275). They set
the default of `workers` (above) and the planned time of a mutant.

**The planned time of a mutant** comes from the times of earlier runs'
shards, by a rule: the slowest shard that ran its mutants, by its run's
time over its mutants, rounded up to a whole second.
`mutation/shard-times.jsonl` records each shard of the runs it comes
from, one JSON object per line: its run, its name, its mutants at once,
the mutants it ran, how long its run took (`bulk.json`'s `wall_s`, which
holds everything `run.py` does) and how it exited. A shard that stopped,
or ran no mutant, says nothing of a mutant's time. The record holds the
baseline's 43 shards, the 40 of the first weekly run
([run 44423781036](https://github.com/hirunefu/smock/actions/runs/44423781036),
the pinned set on `main` at 7eac627b, planned at 20 s a mutant) and the
20 of the second
([run 44851160701](https://github.com/hirunefu/smock/actions/runs/44851160701),
the same mutants on `main` at 65831e4e, planned at 16 s). A mutant took
7.0 s of runner time on average over the baseline's sample, 6.3 s over
the first weekly run and 6.1 s over the second, but the slowest shards
took twice as long a mutant or more. In the baseline they were
`engine`'s: the BODY pass's shard 5-of-20 took 16 min 10 s for 68
mutants, 14.27 s each. In the first weekly run it was `protobuf`'s shard
20-of-40, whose 460 mutants, half of them at an unchecked access and so
also run natively, took 1 h 56 min 30 s, 15.19 s each. In the second it
was `engine`'s shard 3-of-20, 920 mutants in 2 h 59 min 21 s, 11.70 s
each. Its runner was slower than the others: it took 2.19 s to run
`engine`'s tests without a mutant, where the three other runners that ran
`engine` took 1.46 to 1.63 s, and each step of its mutants took 1.2 to
1.4 times as long as in the first weekly run. So bulk runs plan 16 s a
mutant (`bulk.py`'s `SECONDS_PER_MUTANT`); before the baseline they
planned 20 s, from #275's cost model. The rule takes the slowest shard,
not the average, because a shard holds a stretch of the run's order,
mostly one or two packages, and the costly stretches are not spread over
the shards; nor are the slower runners. At the average's 7 s, the
monthly run's shards would hold 1,331 mutants each: 5.6 hours at
15.19 s a mutant.

At 16 s, on 7eac627b's tree, the weekly run's 18,403 mutants go in 20
shards of 920 or 921, all at once, where 20 s cut them into 40 shards in
two waves. At the slowest pace a shard would take 3.9 hours. Each of the
20 holds exactly two of the first weekly run's 40 shards, whose times
added up to between 39 minutes and 2 hours 46 minutes. The second weekly
run ran them so, on 65831e4e, whose tree gives the same mutants: its
shards took 36 minutes to 2 h 59 min 21 s, and the run 3 h 28 min 41 s
from its first job's start to its last job's end, with 31 h 46 min of
runner time over its 25 jobs, where the first weekly run took 2 hours 9
minutes. Its longest shard was `engine`'s, on its slow runner (above),
and `protobuf`'s 10-of-20 ended last. The canary's job, the coverage from
the e2e tests and the properties with random seeds take three of the
account's 20 jobs as the run starts, so three shards wait for free jobs.
`protobuf`'s was one of them: it started 36 minutes late, when the
shortest shard ended, and then ran for 2 h 51 min. The
monthly run's 26,619 mutants go in 40 shards of 665 or 666, as at 20 s,
in two waves of 20: at most 2.8 hours a shard at the slowest pace. With
each mutant at the pace of the first weekly run's shard that held its
stretch of its package, the run takes about 3 hours 15 minutes
(*estimate*).

To add a later run's shards to the record, and see the time it gives:

```sh
gh run download <run id> --pattern 'mutation-shard-*' --dir shards
python3 scripts/mutation/bulk.py pace --run-url https://github.com/hirunefu/smock/actions/runs/<run id> shards/*
```

It prints the slowest shard of the record, then `slowest_s` and
`seconds_per_mutant`. A run that gives more than `SECONDS_PER_MUTANT`
raises it in the same change: the bulk runs' tests fail until the two
agree. A shard's artifact is kept for 7 days.

The tests (`scripts/mutation/test_bulk.py`) plan a run of each mode on
the fixture module and on smock's packages, run a plan's two shards and
its finish on the fixture's package `log`, whose report ends with the
report of the run without shards, and time a sample of `log`'s mutants
with 1, 2 and 4 at once. They run a weekly run of `log` that reads an
earlier run's flake records and a monthly run of it, list the fixture's
stale entry, run the properties with random seeds on a small module with
a moon that fails one, and cut made-up survivors into triage tickets.
They record made-up shards and check the planned time that the rule
gives, check that `SECONDS_PER_MUTANT` is what the committed record
gives, and that every shard of smock's weekly and monthly runs then ends
within 5 hours at the pace of the slowest recorded shard.
`scripts/check-mutation-runs-workflow.sh`, in CI's job `scripts` with its
test, checks when the workflow runs, that each run's name says its mode,
that it passes each input to the plan, that `workers` is 1 unless given,
that its shards take their matrix and their width from the plan and run
on amd64 within a job's time, the weekly run's other jobs, that the
finish does not wait for the coverage from the e2e tests, that only the
job of the stale entries writes, and only issues, and that it keeps the
merged report.

## The weakening report

Before the maintainer merges a branch into `main`, they read what it
weakens. On each push to a branch other than `main` and Dependabot's, the
branch checks workflow (`.github/workflows/branch-checks.yml`) runs
`scripts/weakening-report.py` against the branch's merge base with
`main`. The job takes seconds. It writes the report to the job summary
and keeps it as the artifact `weakening-report` for 90 days. It only
reports: it passes whatever the report lists, and fails only when the
report cannot be written or kept. The workflow is not part of `ci.yml`,
so `keep` never waits for it.

The report lists:

- **Tests deleted**: each test block of the base that no test of the head
  stands for. A test stays when its package keeps a test of its name;
  else when another package has a new test of its name, to which it
  moved; else when a new test of its package, or then of another, holds
  most of its body or has a name much like its own, as when a test is
  extended. So a test is deleted only when no test of its name is left
  for it.
- **Tests moved or renamed**: each test that stays in another file, of
  its package or of another, or under another name, with where it is now
  and whether its body changed. Its changed lines are in the sections
  below, under its old place, with a line that says where it is now. The
  helpers of a file whose tests moved to another package are followed to
  the file they moved to.
- **Assertions removed or changed in tests that stay**: in each test, and
  in each function or constant of a test file, that the head still has,
  the lines it removes or changes that assert something. Those are a call
  of `inspect`, `debug_inspect`, `json_inspect`, an `assert_` function,
  `fail`, `abort` or `panic`, a `guard`, an `if` whose block fails, and a
  line that compares two values. So an exact comparison made weaker and
  an upper bound raised show here. A line added inside an assertion is
  not listed here, since extending a test adds such lines: it is among
  the other lines.
- **Snapshot lines changed**: the lines a test removes from, changes in or
  adds to a snapshot. A snapshot is the `content=` of `inspect`,
  `debug_inspect` or `json_inspect`, a constant or a variable that a
  `content=` names, or a file in `__snapshot__`.
- **Other lines changed in tests that stay**: in the same tests,
  functions and constants, every other line of code that the head
  removes, changes or adds. A test that computes its result first and
  asserts it later can be loosened here alone: a wait raised, a
  condition changed in the list it builds, a fixture's delay or a call
  of a helper changed. So every test whose code changed is in the report.
  A comment or a blank line that changes alone is not listed.
- **Skip attributes and target settings added**: a `#skip` or `#cfg`
  attribute that a test gains, a package whose supported targets no
  longer let its tests run on wasm-gc, and a test file that its package's
  `targets` no longer build for wasm-gc.
- **Files that decide a verdict changed**: each change to a file that
  `scripts/verdict-files.txt` names, with its diff, and each change to
  that list.
- **Exclusion entries whose reviewer changed**: each entry of
  `exclusions.toml` whose reviewer the head fills in, changes or
  empties, and each entry it adds with a reviewer, by the entry's id.
  Only the maintainer fills in the reviewer ([Exclusions](#exclusions)).

Each changed line of a test is in one section only. A block of changed
lines that touches a snapshot is under the snapshots; else one that
touches an assertion is under the assertions; else it is among the other
lines. Lines are compared without their indentation, so a block moved
deeper changes nothing. A test's name is left out: a new name shows
among the tests moved or renamed.

`scripts/verdict-files.txt` names, by path, every file that decides a
verdict: the mutation runner and its data, the exclusion list, the
coverage wrapper with its floors and scope, the canary's verdicts, the
lists of packages at L4 and of tests kept, the checks of the keep list
and of the ledgers, the merge and release checks, the mutation and
coverage workflows, the lists of cases that protobuf's conformance suite,
h2spec and the YAML test suite may fail, the scripts that run those
suites and judge their results, and the scripts that install or build
their tools at the versions they pin: h2spec's install, and the build of
protobuf's conformance runner with the protoc it needs. It also names the
own test of each script it names, such as the merge check's, the coverage
ratchet's and the changed-lines job's, since a loosened test lets its
script change unseen. The list fixes the paths of the files that do not
exist yet, and each line names the issue that creates them. A change that
adds a file that decides a verdict puts it at a path the list names, or
adds its path to the list in the same change. The report reads the
base's list and the head's, so a file still shows when the same change
takes its path off the list.

The report's tests (`scripts/test-weakening-report.sh`) hold the list to
three rules, and fail when it leaves out a file that one of them names:

- **The verdict steps.** The steps of the workflows that judge a suite's
  results against its list of cases, the steps that test that judgment,
  the release's check of the latest weekly run, and the checks of the
  keep list and of the ledgers. The list names each script that such a
  step runs, and each script that one of those runs.
- **The tool steps.** The steps that install or build a verdict step's
  tool. The list names their scripts in the same way.
- **The own tests.** Each script the list names has its own test listed
  too: the script beside it named `test-<name>.sh` or `test_<name>.py`,
  `<name>` being the script's name without its extension, or, for a test
  named otherwise, the one the test's table names, as
  `scripts/test-release-gates.sh` is for `scripts/check-weekly-run.py`.

A new verdict step or tool step goes into that test's list of steps, and
a test named otherwise into its table.

The report reads MoonBit by its lines and by `moon fmt`'s layout, not as
the compiler does. So it may list a line that weakens nothing, such as a
comparison in a helper's loop. A changed call of a helper that asserts is
among the other lines, unless the call is an assertion itself; a change
to the helper's own lines is in the helper's entry. It reads only the
MoonBit tests test by test: the test of a listed script shows whole,
with its diff, among the files that decide a verdict.

To read it for a branch before pushing it:

```sh
python3 scripts/weakening-report.py --base origin/main
```

An outside contributor's pull request goes the same way as the project's
own branches: before merging it, the maintainer pushes its branch to a
branch here, so that the branch checks run on it. Dependabot's pull
requests keep their own path
([Before merging into main](docs/merging-into-main.md)).

## The changed-lines job

On each push to a branch other than `main` and Dependabot's, the branch
checks workflow (`.github/workflows/branch-checks.yml`) also runs every
mutant of the pinned set on the non-test lines that the branch changes in
the [pure packages](#terms), against its merge base with `main`, as
`python3 scripts/mutation/run.py --changed` does on a laptop
([Mutation runner](#mutation-runner)). The runner's rules all apply: the
package's own tests first, then, for the survivors, the tests of every
package that imports it and builds on wasm-gc; the compiler-output
comparison; kill confirmation; the native verdict for a site whose
definition uses an unchecked array access, which decides there, since the
mutants run on amd64; and the exclusion list. The job only reports, for
now: it passes whatever survives, and fails only when the mutants cannot
run or the report cannot be written. Once a package reaches L4, the merge
check makes an unexplained survivor on its changed lines stop the merge
into `main` ([Rules for the work](#rules-for-the-work), "Where the checks
run"). The job is not part of `ci.yml`, so neither CI's wall time nor
`keep` waits for it.

`scripts/changed-lines.py` runs it in three jobs:

- **The plan** (`changed-lines-plan`) counts the mutants on the changed
  lines (`run.py --changed --sites-only`) and plans the shards. On a push,
  a shard runs for each 50 mutants, and at most 3 run, so that a run
  leaves room among the account's 20 concurrent jobs beside CI's own. A
  diff with more than 600 mutants, as the merge of an integration branch
  can have, is not covered: no shard runs, and the report says so.
- **The shards** (`changed-lines`), one job each, run their parts of the
  mutants on amd64 (`run.py --changed --shard k/n`), against the plan's
  merge base, so that every shard runs on the plan's lines.
- **The report** (`changed-lines-report`) reads the shards' records,
  writes the report to the job summary, and keeps it as the artifact
  `changed-lines` for 90 days, with the plan and each shard's output. The
  report names the head, the base and the merge base, says whether the
  run was on a push or started by hand and whether it covered the whole
  diff, and counts each package's mutants, their outcomes, and the
  survivors that the exclusion list leaves unexplained, finds
  stale-covered and accepts. It lists each unexplained survivor, with its
  package, its enclosing definition and its diff, and each stale-covered
  one, with the id of its stale entry. `report.json` gives the same to
  the merge check.

The numbers are estimates from #275's cost model: the 75th-percentile
change to `main`, about 190 mutants, takes about 8.5 minutes of runner
time, about 2.7 s a mutant. So a shard of 50 mutants takes about as long
as its setup (the checkout, MoonBit and the runs without a mutant), and a
full shard of 200 about 9 minutes. The job reads no flake records yet, so
only each shard's own runs without a mutant take kill credit from a
flaky test.

**A run started by hand** runs the whole diff, however large, on 20
shards unless another number from 1 to 20 is given:

```sh
gh workflow run branch-checks.yml --ref <branch>
gh workflow run branch-checks.yml --ref <branch> -f shards=<n>
```

It writes the weakening report too, and its report says that it was
started by hand. The merge check reads whichever run on the branch head
covered the whole diff. As for any workflow, GitHub starts it by hand only
once `main` holds it, and a newer push to the branch cancels it, as it
cancels an older push's run.

`scripts/test-changed-lines.sh`, in CI's scripts job, runs the three steps
with a fake runner on small git histories, and
`scripts/check-branch-checks-workflow.sh` checks the jobs' commands,
conditions, runner and artifacts.

**The merge check.** Before merging a branch into `main`, the maintainer
runs `python3 scripts/check-merge.py <branch>`, as the
[checklist](docs/merging-into-main.md) says. It asks GitHub, with `gh`,
for the runs of the branch checks on the branch's head, and reads the
report that the latest run that passed and covered the whole diff kept.
It refuses the merge, and says why with the run's link, when no run is on
the head, none passed, none covered the whole diff, the run compared the
head with another base than `main` or from another merge base than the
head's with `main` now, or its report shows an unexplained survivor on
the changed lines of a package at L4: one that `mutation/l4-packages.txt`
names, on `main` or on the branch. The list started empty, so at first
the check only reported. It prints the unexplained survivors in the other
packages, and each stale-covered survivor with the id of its stale entry,
which does not block either: the stale entries are re-triaged in a batch.
Last, it prints the branch's weakening report, which the same run kept,
for the maintainer to read and acknowledge. `scripts/test-check-merge.sh`,
in CI's scripts job, tests it with a fake `gh` and canned runs.

## Test costs on CI's runners

`.github/workflows/measure-costs.yml` measures on CI's runners what the
cost model of the test review
([#275](https://github.com/hirunefu/smock/issues/275)) guesses. It runs on
a linux/amd64 and a linux/arm64 runner, and only when started by hand. It
sets no variable that gives moon another C compiler or flags, so that it
measures the builds as CI's test job makes them.
`scripts/measure-costs.py` measures in four parts:

- `e2e`: every e2e test run in one process, three times by default, after
  the builds of `cmd/smock` and the e2e package.
- `alone`: each e2e test run alone, in a `moon` process of its own
  (`moon test --target native e2e/<file> -i <index>`), since `moon` prints
  no time per test and runs a package's async tests ten at a time in one
  process. Each time holds moon's own work around a run, which the part
  `e2e` measures as a build with nothing to do.
- `rebuild`: from clean, in a target directory of its own, the native
  rebuild of engine's tests and of `cmd/smock` after one mutant in engine,
  and engine's tests on wasm-gc after it.
- `coverage`: builds and runs, plain and with `--enable-coverage`, of the
  native-only packages' tests, the pure packages' tests on wasm-gc but
  yaml's, yaml's natively, and the binary, each mode from clean; whether
  moon plans the system's C compiler or tcc for them; and the points the
  coverage build covers.

Start it from the Actions tab, or with `gh`. GitHub starts a workflow by
hand only once it is on the default branch; `--ref` picks the commit it
measures:

```sh
gh workflow run measure-costs.yml --ref main -f e2e-runs=3 -f alone-runs=1
```

`alone-runs=0` leaves the part `alone` out. Each architecture's results
are kept as the artifact `measurements-linux-amd64` or
`measurements-linux-arm64`, also when a measurement fails, and the job's
summary shows them. `scripts/estimate-costs.py` recomputes the cost model
from both, and prints it as Markdown with where it falls against decision
6's band:

```sh
gh run download <run id> --dir measurements
python3 scripts/estimate-costs.py --run-url <run link> \
  measurements/measurements-linux-amd64 measurements/measurements-linux-arm64
```

The first run, on `main` at 3a8d6997
([run 44078886586](https://github.com/hirunefu/smock/actions/runs/44078886586)),
and the cost model recomputed from it are on
[#275](https://github.com/hirunefu/smock/issues/275). On both
architectures, moon planned the system's C compiler and no tcc for the
native builds, plain and with coverage. So amd64's native builds call the
system's C compiler as arm64's do, and are about six times faster: the
binary from clean took 7.0 s, against 44.3 s. The single-process e2e run
took 39.0 s on amd64, and the run at operator level came to 1.69 hours on
20 jobs, both within decision 6's band, and the maintainer confirmed
decision 6 ([The ladder](#the-ladder)).

Each part also runs on a developer's machine:
`python3 scripts/measure-costs.py <part> <out dir>`, with `--jobs` for
moon's build jobs and `--file` for the tests of one e2e file alone. The
part `rebuild` changes `engine/range.mbt` while it runs, and puts it back
afterwards.

## Benchmark

`bench/` is the release benchmark. It measures smock's real request path,
realistic requests matched against a definition set with many Stubs with
the Journal on, over HTTP/1.1 and HTTP/2, at fixed arrival rates under the
CPU and memory limits of small GKE Autopilot Pods, and checks the
provisional performance targets. A gRPC variant of its definitions
measures gRPC unary calls over h2c in a run of its own, held to no target
([gRPC calls in the benchmark](bench/README.md#grpc-calls-in-the-benchmark)).
[bench/README.md](bench/README.md) says how to run it on a machine, on GKE
Autopilot and in CI, what a run writes and how to compare runs. The
[chart's sizing table](charts/smock/README.md#sizing) has what it measured.

## Making a release

[docs/releasing.md](docs/releasing.md) describes how a release is made and
published, for the maintainer, and which dependencies Dependabot keeps up
to date.
