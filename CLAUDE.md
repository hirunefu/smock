## Agent skills

The skills themselves are not committed. `skills-lock.json` records where each one comes from; restore them into `.agents/skills/` (with links in `.claude/skills/`) with `npx skills experimental_install`.

### Issue tracker

Issues and specs live in GitHub Issues on `hirunefu/smock` (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
