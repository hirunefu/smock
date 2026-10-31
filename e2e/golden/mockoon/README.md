# Lines the Mockoon CLI wrote

`probe.log` holds five lines that the Mockoon CLI wrote, copied byte for
byte. e2e/mockoon_golden_test.mbt compares smock's lines in the `mockoon`
log format with them.

- **Source.** The log file of the environment `probe` in a local Mockoon
  CLI trial on 2026-10-21, most likely Mockoon 9.9.0, the version of the
  local trials. The lines are the file's first three and the two of the
  request for `/t/upper-number`, in the file's order. The lines between
  are other requests of the trial, and the file has no `Server stopped`
  line.
- **Why they still hold.** The facts gathered on 2026-10-31 found
  Mockoon's logging code byte-identical at v9.10.0 (commit
  cc390a912a83799edfddadd537ed0a1bd50c6235): `logger.ts`,
  `events-listeners.ts`, `server-messages.constants.ts` and the redaction
  helpers in `utils.ts`. The one logging change from v9.9.0 to v9.10.0
  joins an array in `transaction.request.params`, which only
  `--log-transaction` writes. These lines have no `transaction` key.
- **What they show.** The keys sorted, the token redacted in the file,
  the error line before its `Transaction recorded` line, `routePath`
  without its leading `/`, and status 200 after a template error.

Do not edit `probe.log`. A new difference from Mockoon is decided first,
then written as a rule in the test.
