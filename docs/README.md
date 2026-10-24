# Documentation

These are smock's documents, grouped by who reads them. The
[README](../README.md) says what smock is and how to run it, and
[GLOSSARY.md](../GLOSSARY.md) defines the terms every document uses,
such as Mock, Stub and Session.

## Using smock

- The README's [Run](../README.md#run),
  [Sessions and Ephemeral Stubs](../README.md#sessions-and-ephemeral-stubs)
  and [The Journal](../README.md#the-journal) describe `smock serve` and
  its settings, HTTPS, the Admin API and its metrics, `smock check`,
  `smock render`, and how tests add Stubs and check what was called.
- [definition-files.md](definition-files.md) describes the format of
  Definition files: how Stubs match requests, what they answer,
  templates, Variables, Data buckets, CRUD Stubs, Faults and reloading.
- [importing-openapi.md](importing-openapi.md) turns an OpenAPI document
  into a Definition file with `smock import-openapi`, and says what is
  generated and how to regenerate it.
- [migrating-from-mockoon.md](migrating-from-mockoon.md) turns a Mockoon
  environment into Definition files, with a worked example and a mapping
  reference.
- [getting-started-on-gke.md](getting-started-on-gke.md) takes a reader
  who is new to smock to smock answering requests on GKE Autopilot.
- [examples/](examples/) holds the files that the OpenAPI and Mockoon
  guides use, and a Definition file written in Jsonnet.
- [`openapi/admin.json`](../openapi/admin.json) is the OpenAPI document
  of the Admin API, from which a client can be generated.
- [`schema/v1/definitions.json`](../schema/v1/definitions.json) is the
  JSON Schema of Definition files, for editors and validators.

## Operating smock

- [charts/smock/README.md](../charts/smock/README.md) describes the Helm
  chart: where the Definition files come from, the Admin API token and
  TLS, probes, sizing, and every value with its default.
- The README's
  [Container image and release binaries](../README.md#container-image-and-release-binaries)
  describes what each release publishes, and its
  [Verify the image](../README.md#verify-the-image) and
  [Verify the Helm chart](../README.md#verify-the-helm-chart) say how to
  check their signatures and fetch the image's SBOM.
- [SECURITY.md](../SECURITY.md) says which releases get security fixes,
  and how to report a vulnerability.
- [CHANGELOG.md](../CHANGELOG.md) records what changed in each release.

## Contributing to smock

- The README's [Layout](../README.md#layout),
  [Toolchain](../README.md#toolchain) and
  [Build and test](../README.md#build-and-test) describe the modules and
  packages, the pinned MoonBit toolchain, and how to build and test
  smock.
- [bench/README.md](../bench/README.md) describes the release benchmark:
  how to run it on a machine, on GKE Autopilot and in CI, what a run
  writes, and how to compare runs.
- [merging-into-main.md](merging-into-main.md) is the maintainer's
  checklist before an integration branch is merged into `main`.
- [releasing.md](releasing.md) says how the maintainer makes a release,
  and how the dependency updates that Dependabot proposes are merged.
- [adr/](adr/) holds the architecture decisions, one file each:
  - [ADR 0001](adr/0001-moonbit-with-c-only-for-tls.md) writes smock in
    MoonBit, with C only for TLS.
  - [ADR 0002](adr/0002-definition-files-are-the-source-of-truth.md)
    makes the Definition files the source of truth, with no state shared
    between replicas.
  - [ADR 0003](adr/0003-one-process-per-pod.md) runs one smock process
    per Pod, and scales by adding Pods.
  - [ADR 0004](adr/0004-journal-byte-bound-follows-the-memory-limit.md)
    makes the Journal's default byte bound follow the memory limit.
- [GLOSSARY.md](../GLOSSARY.md) defines the domain terms, and the words
  to avoid for each.
- [`schema/v1/fixtures/README.md`](../schema/v1/fixtures/README.md) says
  which directory a fixture of the JSON Schema cross-check belongs in.
- [`xml/README.mbt.md`](../xml/README.mbt.md) documents the XML parser
  and paths behind `xml` conditions, a module that does not depend on
  smock.
- [`re2/README.mbt.md`](../re2/README.mbt.md) documents the RE2-syntax
  regular expressions behind pattern conditions, a module that does not
  depend on smock.
- [agents/](agents/) tells coding agents where issues live, which triage
  labels to use, and how to read the glossary and the ADRs.
