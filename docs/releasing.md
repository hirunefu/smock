# Making a release

A release publishes the image `ghcr.io/hirunefu/smock:<version>`, the Helm
chart `oci://ghcr.io/hirunefu/charts/smock` with version `<version>`, and a
GitHub release with the binaries `smock-<version>-linux-amd64` and
`smock-<version>-linux-arm64`, their SBOMs, `LICENSE` and `NOTICE`.
[Installing smock](installing.md) says how people use them. This page is
for the maintainer who makes one.

## What a tag does

Pushing a tag `v<major>.<minor>.<patch>` (or
`v<major>.<minor>.<patch>-<pre-release>`) runs
`.github/workflows/release.yml`. On an amd64 and an arm64 runner, each
building for its own architecture without emulation, it builds smock with
the toolchain in `.moonbit-version`, builds the image and runs
`scripts/smoke-test-image.sh` on it. Only then does it push, combine, sign
and attest the image, verify it with `scripts/verify-image.sh`, push and
sign the Helm chart packaged by `scripts/package-helm-chart.sh`, verify it
with `scripts/verify-chart.sh`, and create the GitHub release with notes
from `scripts/release-notes.sh`. It never runs on pull requests. Started
by hand from the Actions tab, it builds and smoke-tests everything and
keeps the binaries, images, chart and notes as workflow artifacts, but
publishes nothing. `scripts/check-release-workflow.sh`, run in CI, checks
those rules, and that the release's check of the weekly mutation run
knows each job of that run by the name `mutation-runs.yml` gives it.

The tag names the version. Keep the `version` in `moon.mod` the same. A
pre-release tag adds a suffix to that version: `v0.4.0-rc.1` was tagged
with `version = "0.4.0"`.

Before it builds anything, the workflow's first job, plan, checks that
the tag's version, without a pre-release suffix, is the `version` in
`moon.mod` (`scripts/check-tag-version.sh`), and, for a pushed tag, that
CI passed on the tagged commit (`scripts/check-ci-passed.sh`). CI does not
run on tags, so the run it looks for is CI's run on a push of that commit
to a branch, such as `main`.

For a pushed tag, plan also checks the latest weekly mutation run over
the pinned set (`scripts/check-weekly-run.py`; decision 7,
[ADR 0006](adr/0006-tests-are-judged-by-four-ledgers.md#what-l4-and-a-release-read)).
For each package that `mutation/l4-packages.txt` names on the tagged
commit, every job of that run that decides a verdict must have passed,
the run must show no unexplained survivor, stale-covered ones included,
and it must cover the commit. It covers it when it ran on the
tagged commit, or on an ancestor of it on `main` and each later change
to `main` meets one of two conditions. Either it touches no non-test
source of a package at L4, as a release commit does, or it merged a
branch whose changed-lines report covered its whole diff with no
unexplained survivor in a package at L4
([The changed-lines job](../CONTRIBUTING.md#the-changed-lines-job)). A
source change of a package at L4 pushed straight to `main` has no such
report. The monthly run over the full set is never read. While the list
names no package, the check reads no run and passes.
[The weekly mutation run](#the-weekly-mutation-run) says what the check
needs and how long a run takes.

When any of these checks fails, the workflow stops there and publishes
nothing. [When plan stops a release](#when-plan-stops-a-release) says
what to do then.

## Smoke-testing the image locally

To smoke-test the image on your machine (needs docker, curl, openssl,
readelf and jq):

```sh
scripts/build-release.sh
docker build --tag smock:dev .
scripts/smoke-test-image.sh smock:dev 0.0.0-dev "$(git rev-parse --short=12 HEAD)" "moonc $(moonc -v | cut -d' ' -f1)"
```

It runs the image as its own UID with a read-only root filesystem, no
capabilities and no privilege escalation, and checks `smock --version`, a
Stub on the plain port, HTTPS with a test certificate, and the Admin API
status operation with a token file, which must name the same build as
`smock --version`. Then, without certificate files, it checks HTTPS with
the self-signed certificate smock generates, on the same read-only root
filesystem. It also checks that the image adds nothing to its base but
the smock binary, `LICENSE` and `NOTICE`, and that the image is for the
machine it runs on.

## The first release

The first release also makes the repository and its packages public.
Work through these steps in order:

1. **Run Release by hand on `main`** from the Actions tab. It publishes
   nothing, and covers the build, the smoke test and the chart on both
   architectures.
2. **Check that no stale package is in the way.** No ghcr package `smock`
   or `charts/smock` may exist yet without a link to this repository. Reading
   packages needs the `read:packages` scope (`gh auth refresh -s read:packages`):

   ```sh
   gh api /users/hirunefu/packages/container/smock
   gh api /users/hirunefu/packages/container/charts%2Fsmock
   ```

   Each should answer 404, or name `hirunefu/smock` as its repository.
3. **Make the repository public, before any tag.** Each keyless
   signature's certificate records whether the repository is private, and
   the public Rekor transparency log keeps it for good, so a tag pushed
   while private would leave "private" there. It would also create the
   packages private, and the links in the release notes would answer 404.
   Then, under Settings → Security, turn on private vulnerability
   reporting, which [SECURITY.md](../SECURITY.md) tells reporters to use.
4. **Publish the JSON Schema.** In the repository settings, under Pages,
   set Source to GitHub Actions, then run `.github/workflows/schema-pages.yml`
   by hand. Going public does not start it, and the Schema's `$id`
   answers 404 until it has run.
5. **Add a tag ruleset for `v*`**, so that the tags that publish a release
   are protected. The ruleset `Release tags` forbids deleting and moving
   such a tag, and no one may bypass it. Rulesets answer 403 while the
   repository is private.
6. **Tag `v0.1.0-rc.1` first.** It is a pre-release, and it runs the
   publishing path of the release workflow for the first time.
7. **Make both packages public**, `ghcr.io/hirunefu/smock` and
   `ghcr.io/hirunefu/charts/smock`, in their package settings. GitHub
   creates them private, and making a package public cannot be undone.
   Then, from a machine that is not logged in to GitHub or ghcr.io, check
   that `docker pull ghcr.io/hirunefu/smock:0.1.0-rc.1`,
   `helm show chart oci://ghcr.io/hirunefu/charts/smock --version 0.1.0-rc.1`
   and [Installing smock](installing.md)'s `cosign verify` work.
8. **Tag `v0.1.0`**, the version `moon.mod` gives.
9. **Run `.github/workflows/latest-toolchain.yml` and
   `.github/workflows/benchmark.yml` by hand once.** Neither had run before
   the first release.

## Every release after

The release commit, on `main`, gives the new version in `moon.mod` and
the CHANGELOG section below. The tag names that commit, and the release
workflow stops before it builds anything unless `moon.mod` gives the
tag's version, CI's run on a push of that commit has passed, and the
latest weekly mutation run is clean in the packages at L4 and covers the
commit ([What a tag does](#what-a-tag-does)).

In [CHANGELOG.md](../CHANGELOG.md), move the entries under
`## [Unreleased]` to a new section `## [<version>] - <date>` below it,
leave `## [Unreleased]` empty, and update the links at the end. The
release notes include that section under "Changes", with each relative
link to a file of the repository turned into a link to the file at the
release's tag. Keep such links relative in CHANGELOG.md.
`scripts/release-notes.sh` fails the release workflow, before anything is
built, when a tag that is not a pre-release has no section of its own. A
pre-release tag, such as `v<version>-rc.1`, takes its own section if there
is one, else the section of `<version>`, else `Unreleased`.

[NOTICE](../NOTICE) names the toolchain and every MoonBit module the
build resolves, of any owner and transitive ones included. CI and the
release workflow fail when NOTICE leaves out a module the build resolves
or names one it does not, when it gives a module another
version than the build resolves, or another licence or source than the
module's own module file, or when it names another toolchain than
`.moonbit-version` (`scripts/check-notice.sh`). The section of a module
that the build resolves but compiles nothing from, such as moondate,
mooncrypt and moonbase, which moonhttp imports, says "smock compiles
nothing from it", and the check fails when that does not match the
build. When `.moonbit-version` or the modules changed since the last
release, check the rest by hand: the packages that each module's section
names, and the copyright lines and NOTICE files it quotes.

The runtime, mimalloc and simdutf come with the toolchain. The image's
SBOM takes their licences and mimalloc's version from NOTICE, and the
modules from what the build resolves
(`scripts/resolved-modules.sh --json`). CI fails when the SBOM and NOTICE
disagree, on those parts or on a module's version, licence or link, or
when NOTICE names another toolchain than `.moonbit-version`
(`scripts/check-sbom-notice.sh`). Nothing reads mimalloc's version from
the toolchain, so check it by hand after a toolchain update. mimalloc's
`mi_version` returns it as one number, 217 for 2.1.7, which this shows:

```sh
objdump -d --disassemble=mi_version ~/.moon/lib/libmoonbitrun.o
```

Before the release, start the monthly mutation run by hand on `main`,
and read its report, the artifact `mutation-report` of the run. It runs
the full set of mutants over the pure packages and reports only: its
survivors stop no release
([Bulk runs on Actions](../CONTRIBUTING.md#bulk-runs-on-actions)).

```sh
gh workflow run mutation-runs.yml -R hirunefu/smock --ref main -f mode=monthly
```

Push the release commit to `main`, and wait until CI's run on that push
has passed:

```sh
gh run list -R hirunefu/smock --workflow CI --event push --commit "$(git rev-parse HEAD)"
```

A pushed `v*` tag can be neither deleted nor moved (step 5 of
[The first release](#the-first-release)), so run what the job plan of the
release workflow checks on the release commit before you push one: that
the tag names the version in `moon.mod`, that CI passed on the commit,
that the latest weekly mutation run covers it, and that the release notes
can be written. The version of a tag is a SemVer 2.0 version with no
build metadata, so a number has no leading zero and a pre-release has no
empty part: `0.5.0-rc.1`, not `0.5.0-rc.01`.
`scripts/check-ci-passed.sh` needs jq, and gh logged in;
`scripts/check-weekly-run.py` needs gh logged in, and a clone with
`main`'s history:

```sh
tag=v0.5.0   # or a pre-release, such as v0.5.0-rc.1
scripts/check-tag-version.sh "${tag#v}"
GITHUB_REPOSITORY=hirunefu/smock scripts/check-ci-passed.sh "$(git rev-parse HEAD)"
GITHUB_REPOSITORY=hirunefu/smock python3 scripts/check-weekly-run.py "$(git rev-parse HEAD)"
scripts/release-notes.sh "${tag#v}" "$(git rev-parse --short=12 HEAD)" "moonc v$(cat .moonbit-version)" ghcr.io/hirunefu/smock >/dev/null
```

Then push the tag on that commit. A pre-release tag, such as
`v<version>-rc.1`, tries the publishing path first. The packages stay
public, so nothing else needs doing in their settings.

### The weekly mutation run

The weekly run over the pinned set runs on `main` every Friday at 20:23
UTC ([Bulk runs on Actions](../CONTRIBUTING.md#bulk-runs-on-actions)),
or when GitHub starts it, which may be hours later. GitHub started the
second weekly run, the first that its schedule started, at 01:36 UTC on
Saturday 2026-11-21, 5 h 13 min after its time, and it ended at 05:05
UTC; it started the third at 02:49 UTC on Saturday 2026-11-28, 6 h 26 min
after its time, and that one ended at 05:26 UTC. A release that waits for
Friday's run should not expect it before Saturday morning UTC.

The release's check of the weekly run (`scripts/check-weekly-run.py`)
reads only weekly runs on the tagged commit or on an ancestor of it on
`main`, wherever they were started; of those, the latest that has ended
decides.
It reads the jobs of that run's latest attempt, and not the run's
conclusion. Each job that decides a verdict must be there and have
passed:

- the plan, which also checks the site counts and lists the stale
  entries of the exclusion list;
- every shard, from `shard 1-of-<n>` to `shard <n>-of-<n>`;
- the canary's job;
- the properties with random seeds;
- the finish, which merges the shards into the report the check reads.

The coverage from the e2e tests only reports, and the job of the stale
entries opens or updates an issue: when either fails, the run's
conclusion is a failure, but the release goes ahead, and the check says
which job did not succeed. When it refuses, it names each job that
failed or that the run lacks. A job that the weekly run gains goes into
the check's list of jobs (`JOBS` in `scripts/check-weekly-run.py`), as
one that decides a verdict or one that does not: until it is there,
`scripts/check-release-workflow.sh` fails in CI.

It needs:

- that run's jobs, and its report, the artifact `mutation-report`, which
  GitHub keeps for 90 days;
- for each change to `main` after the run that changes non-test source of
  a package at L4, a run of the branch checks on the branch it merged,
  whose artifact `changed-lines` is kept for 90 days too: the report that
  [the merge check](merging-into-main.md) read before the merge;
- the history of `main` from the run's commit to the tagged one: the job
  plan checks out the whole history;
- gh, with the workflow's token, which may read the Actions API, or, run
  by hand, logged in.

A release on `main`'s head after Friday's run waits for nothing more when
each change since went through the branch checks or touches no source of
a package at L4. The release commit touches none. Otherwise, start a
weekly run on the release commit, and push the tag once it has passed,
two and a half to three and a half hours later. The second weekly run
([run 44851160701](https://github.com/hirunefu/smock/actions/runs/44851160701),
on `main` at 65831e4e) had 18,403 mutants in 20 shards at once, planned
at 16 s a mutant. Its report gives 3 h 28 min 41 s from its first job's
start to its last job's end, 2 h 59 min 21 s for its longest shard's
run, and 31 h 46 min of runner time over its 25 jobs. Its longest shard
ran on a runner slower than the others, and another, nearly as long,
started 36 minutes late: the canary's job, for 39 minutes, and two short
ones take three of the account's 20 jobs as the run starts, so three
shards wait for free jobs
([Bulk runs on Actions](../CONTRIBUTING.md#bulk-runs-on-actions)).
The third
([run 46099911582](https://github.com/hirunefu/smock/actions/runs/46099911582),
on `main` at 65831e4e, with the same mutants) and the fourth
([run 46113518423](https://github.com/hirunefu/smock/actions/runs/46113518423),
started by hand on `main` at 893484b5, with 18,363 mutants) give 2 h
37 min 17 s and 2 h 35 min 47 s from their first job's start to their
last job's end, 2 h 36 min 15 s and 2 h 34 min 46 s for their longest
shard's run, and 32 h 17 min and 34 h 42 min of runner time over their
25 jobs.
The first weekly run, started by hand on `main` on 2026-11-19
([run 44423781036](https://github.com/hirunefu/smock/actions/runs/44423781036)),
had the same mutants in 40 shards, two waves of 20, and its report gives
2 h 9 min from its first job's start to its last job's end, and 32 h
44 min of runner time over its 44 jobs. A weekly run holds all of the
account's 20 jobs for its first 40 minutes or so, and fewer as its
shards end: the second held half of them after an hour and a half, and
two from 2 h 16 min on. A push meanwhile waits for free jobs.

```sh
gh workflow run mutation-runs.yml -R hirunefu/smock --ref main -f mode=weekly     # while main is at the release commit
gh workflow run mutation-runs.yml -R hirunefu/smock --ref "$tag" -f mode=weekly   # once the tag is pushed
gh run list -R hirunefu/smock --workflow mutation-runs.yml   # its name is "Mutation runs: weekly"
```

### When plan stops a release

When plan fails, nothing has been published for the tag: every other job
of the release workflow needs plan, so none of them runs.

- **The tag came before CI's run on its commit had passed**, as when the
  commit and the tag are pushed together. The job plan fails with
  `check-ci-passed: CI has not passed on <commit>`. Wait until that CI run
  has passed, then re-run the tag's release run, which looks for CI's run
  again. If the CI run fails for a reason that another try can clear,
  re-run it before the release run: its failed jobs within 7 days of the
  run, or the whole run.

  ```sh
  tag=v0.5.0   # the tag that was pushed
  gh run list -R hirunefu/smock --workflow CI --event push --commit "$(git rev-parse "$tag^{commit}")"   # CI's run: wait until it has passed
  gh run rerun <CI run-id> -R hirunefu/smock --failed   # only if it failed; without --failed, the whole run
  gh run list -R hirunefu/smock --workflow release.yml --event push --branch "$tag"   # the tag's release run
  gh run rerun <release run-id> -R hirunefu/smock
  ```

- **No weekly run covers the tagged commit yet.** The job plan fails with
  `check-weekly-run: <commit> may not be released:` and the reason: no
  weekly run on the commit or an ancestor of it on `main` has ended, or a
  job of the latest one that decides a verdict failed or is missing (the
  reason names it), or a change to `main` after it changed non-test
  source of a package at L4 and no branch's changed-lines report covers
  that change, as for a change pushed straight to `main`. A weekly run on
  the tag covers the commit with no later change. Start one, or wait for
  the one still running, and once it has passed, two and a half to three
  and a half hours after it started
  ([The weekly mutation run](#the-weekly-mutation-run)), re-run the tag's
  release run, which reads the weekly runs again.

  ```sh
  gh workflow run mutation-runs.yml -R hirunefu/smock --ref "$tag" -f mode=weekly
  gh run list -R hirunefu/smock --workflow mutation-runs.yml --branch "$tag"   # wait until it has passed
  gh run rerun <release run-id> -R hirunefu/smock
  ```

- **The weekly run shows unexplained survivors in a package at L4.** The
  job plan fails with the packages and their counts, and the command that
  downloads the run's report, which lists the survivors. When the run is
  on an ancestor and later changes have since killed or excluded them, a
  weekly run on the tag shows none: start one, as above. Otherwise they
  are in the tagged code, and a re-run fails the same way, as below.

- **The tag names another version than `moon.mod`, CHANGELOG.md has no
  section for a tag that is not a pre-release, CI fails on the tagged
  commit for real, or the weekly run shows unexplained survivors in the
  tagged code.** A re-run checks the same commit, and fails the same
  way. The tag stays, without a release, since it can be neither deleted
  nor moved. Put the fix in a new commit, and release that under the next
  version: `v<version>-rc.2` after `v<version>-rc.1`, or, after
  `v<version>`, the next patch version. For a patch version, give it in
  `moon.mod` and rename the CHANGELOG section of the version that was not
  released, and its link, to it: no release carries the notes of a version
  that was not released.

## Dependency updates

Dependabot (`.github/dependabot.yml`) looks for updates every Monday and
proposes them as pull requests into `main`, one for each kind: one with
every update of the GitHub Actions that the workflows and the composite
actions under `.github/actions/` use, and one with the update of the
image's distroless base in `Dockerfile`.

- An action pinned by commit SHA, such as `sigstore/cosign-installer`,
  stays pinned by SHA, and its `# v<version>` comment moves with it, so
  the pull request names the version it moves to. An action pinned by its
  major tag, such as `actions/checkout@v5`, moves to the next major tag
  once there is one.
- The base stays pinned by the digest of its multi-architecture index,
  under its tag `nonroot`, and only the digest moves. Dependabot never
  moves to another image, such as the base of the next Debian release:
  make that change by hand.

These pull requests run CI like any other. On both architectures it
builds and tests smock, builds the image, smoke-tests it, makes its SBOM
and installs the Helm chart on kind. Merge them into `main` when CI is
green, without the runs of [Before merging into main](merging-into-main.md).
CI runs for the pull request, not for the push of its `dependabot/**`
branch, so `main`'s run after the merge runs every job: only a branch's
push run lets `main` skip the tests of the same tree
([Build and test](../CONTRIBUTING.md#build-and-test)).
A new base brings a new glibc and OpenSSL, which smock uses for TLS, into
the next release's image. It changes neither the binary nor the local
benchmark, which uses the host's libraries. Such updates are mostly
security fixes, so they do not wait for a pre-merge run. The next
pre-merge run on GKE builds smock's image on the new base, and so
measures it.

CI does not run every action. `sigstore/cosign-installer` runs only in
the release workflow's publishing jobs, for a pushed tag, and so does
`actions/download-artifact` with the inputs they give it: CI's SDK job
downloads one artifact by name, where they download several by pattern.
After either moved, make the next release a pre-release first.
`actions/upload-pages-artifact` and
`actions/deploy-pages` run when a Schema changes on `main`: after either
moved, run `.github/workflows/schema-pages.yml` by hand, which publishes
the same Schemas again.

### What Dependabot does not cover

- **The MoonBit toolchain** in `.moonbit-version`. The weekly Latest
  MoonBit workflow (`.github/workflows/latest-toolchain.yml`) builds and
  tests with the latest stable toolchain, and opens an issue when that
  fails. It builds the modules smock imports with the rest, moonhttp
  among them, so a toolchain release that breaks moonhttp shows there
  first. A scheduled run builds nothing when the latest toolchain is the
  pinned one and CI passed on a push of `main`'s head, the commit the
  scheduled run checks out, in the last 7 days, since it would only
  repeat that run; a run started by hand always builds and tests. The
  maintainer moves the pin by hand.
- **The MoonBit modules** imported in `moon.mod`. The maintainer moves
  them by hand, and checks NOTICE as
  [Every release after](#every-release-after) says. moonhttp moves only
  through its own gate: [Upgrading moonhttp](#upgrading-moonhttp).
- **The cosign and syft versions**, which the workflows pass to the
  actions that install them: cosign's once, as `COSIGN_RELEASE` in
  `release.yml`'s `env`, which the image's and the chart's jobs both
  pass as `cosign-release`, and syft's as `syft-version` (`release.yml`
  and `build-test.yml`). Dependabot moves the actions, not these inputs.
  The maintainer moves them by hand: when Dependabot moves
  `sigstore/cosign-installer` or `anchore/sbom-action`, check whether
  cosign or syft has a newer release too.
- **The load generator's image** of the GKE benchmark,
  `bench/gke/generator.Dockerfile` (`python:3.13-slim`), on purpose. It
  is not shipped, and a new base between two pre-merge runs on GKE would
  be one more difference between runs that should compare. The
  maintainer moves it by hand, knowing that the next comparison then
  differs by it too.
- **The tools that scripts install at pinned versions**: oha
  (`scripts/install-oha.sh`, whose version the benchmark's plans name
  too), helm, kubectl and kind (`scripts/install-kubernetes-tools.sh`),
  kind's node image (`scripts/test-helm-chart-on-kind.sh`) and
  check-jsonschema (`scripts/check-schema.sh`). The maintainer moves them
  by hand.
- **The SDKs of the SDK job** and its Python: openai-python and
  anthropic-sdk-python in `llm-sdks/requirements.in`, every package they
  need in `llm-sdks/requirements.txt`, by version and hash, and the Python
  in `llm-sdks/.python-version`. The maintainer raises them by hand, each
  raise a change of its own, as
  [llm-sdks/README.md](../llm-sdks/README.md#raising-a-pin) says. A change
  that a raise brings to what an existing `llm` Stub sends ships in a
  minor release with a CHANGELOG line, as does a change made to follow a
  vendor's documented form.

### Upgrading moonhttp

smock's HTTP/2 comes from moonbitstack/moonhttp, which `moon.mod` imports
at one exact version
([ADR 0005](adr/0005-http2-comes-from-moonhttp.md)). moon takes the
version that a module file gives an import as a minimum, and the build
resolves the highest version that any module asks for. So any change that
raises the moonhttp version the build resolves is an upgrade, even with
`moon.mod` unchanged: a new or upgraded module that needs a later moonhttp
raises it too. CI fails whenever the version the build resolves differs
from the one `moon.mod` names, and names both
(`scripts/check-moonhttp-pin.sh`). `moon tree` shows which module asks for
which version.

moonhttp is raised only on purpose, on an integration branch of its own
(`integration/<name>`): change its version in `moon.mod` there, with
whatever the new version needs in smock. Before that branch merges into
`main`, it needs:

- **h2spec** against both traffic ports, with every case passing but
  those its lists give a reason for, and none of them waiting for an
  issue. CI runs it against both
  ([Build and test](../CONTRIBUTING.md#build-and-test)).
- **The e2e tests**, which CI runs. They check the limits and rules that
  moonhttp enforces as well as smock's own, so an upgrade that drops one
  fails them.
- **The interop check by hand**, against a release build of the branch:
  - curl, with h2c by prior knowledge and over TLS;
  - Go, with h2c by prior knowledge and with its default transport over
    TLS;
  - the JVM, with OkHttp's h2c by prior knowledge, and Java's built-in
    client over TLS and on the plain port, where it gets HTTP/1.1;
  - a browser over TLS, with a certificate it trusts;
  - gRPC unary calls from grpc-java, on Netty, and from grpc-python, on
    gRPC's C core, each over h2c on the plain port and over TLS on the
    TLS port with smock's certificate: a call that gets an OK reply, one
    that gets an error with details and trailing metadata, and one whose
    deadline a Stub's delay outlasts.

  Each HTTP client gets the Stub's response, over the protocol that the
  HTTP/2 guide's [Clients](http2.md#clients) table gives, and each Journal
  entry's `version` says the same. Each gRPC client gets the reply and its
  metadata, the error's status, message, trailer and details, and
  DEADLINE_EXCEEDED at its deadline, before the delay ends
  ([Deadlines](grpc/state-and-faults.md#deadlines)). Each Journal entry's
  `grpcStatus` says the same. These calls check smock's trailers, its
  [Trailers-Only](grpc/metadata-and-status.md#trailers-only) answers and its
  deadlines with two gRPC stacks that share no code with moonhttp or
  grpcurl. The results, with each client's version, go in the merge record.
- **The pre-merge local and GKE benchmark runs**, compared with the
  previous runs, as [Before merging into main](merging-into-main.md) says
  for every integration branch.

On that branch, as on every other, CI also checks that moonhttp and the
modules it imports bring no C. `scripts/check-no-c.sh` scans every module
the build resolves outside moonbitlang, at the version the build resolves,
so a module that the upgrade adds is scanned too. It fails on a C source,
an `extern "C"`, a native stub, a C compiler or link flag, or a prebuild
script in any of them. CI also fails until NOTICE names each module the
upgrade adds, and drops each one the build no longer resolves, with the
versions the build resolves, as [Every release after](#every-release-after)
says. The image's SBOM follows on its own.
