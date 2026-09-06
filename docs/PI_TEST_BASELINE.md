# pi (terminal) suite baseline

The pi suite (`cd pi/packages/coding-agent && npx vitest run`) is the terminal
client's test signal. This file records what "green" means so a future session
does not chase ghosts.

## Expected counts

- **2023 passed, 50 skipped** (as of the Checkpoint 3/4 fix of the rename
  fall-out, branch `fleet/per-agent-identity`, commit `4ec4f38` + this one).
- Zero expected failures. The old "47 failures" baseline is GONE — it was the
  `.pi` → `.vertus` config-dir rename: the runtime renamed (package.json
  `piConfig.configDir: ".vertus"`), the test fixtures never did. Migrated in
  `e3d35e8`; the last six resolved in `4ec4f38`.

## Known flaky test (not ours)

- `test/footer-data-provider.test.ts > reftable branch detection` — an
  upstream watcher/timing test. Passes in isolation; fails intermittently
  under full-suite load. It is not rename- or VERTUS-related; do not "fix" it
  by loosening assertions. Re-run the file alone before assuming a regression.

## Hermetics that keep the suite machine-independent

- `session-file-invalid.test.ts` and `startup-session-name.test.ts` spawn a
  real one-shot CLI and set `VERTUS_NO_SERVER=1`. Without it, the fork's hub
  proxy (`src/vertus-server-client.ts`) intercepts the prompt whenever a hub
  happens to be running and the tests exit 0 without exercising local session
  handling — making the suite's result depend on machine state.
- `external-editor.test.ts` covers the quote-aware editor-command tokenizer
  (paths with spaces). The runtime fix lives in
  `src/modes/interactive/external-editor.ts`.

## Rebuild the bundle after touching pi sources

The REPL and one-shot CLI run the BUNDLE (`dist/bundle/cli.js`), not `src/`.
After any source change:

```bash
cd pi/packages/coding-agent && npm run build
```

`vertus doctor` now checks this (`pi.bundle` check): a bundle older than its
sources is a warn with the rebuild command. A stale bundle has bitten twice —
the suite tested code the running binary did not have.

## Running

```bash
cd pi/packages/coding-agent && npx vitest run   # full suite (~25s)
npx vitest run test/foo.test.ts                 # one file
```