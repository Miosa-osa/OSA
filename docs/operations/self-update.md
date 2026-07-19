# Rollback-Safe Self-Update

`osa update` and its underlying engine `bin/osa-update` implement a
dual-symlink atomic-swap self-update for source checkouts — stage, build,
boot-probe, then swap — so a bad update can never leave a half-updated
install and can always be rolled back.

Reference: steal-list #15 (grok/codex parity: dual-symlink atomic swap
self-update). Test coverage: `test/shell/self_update_test.sh` exercises the
full pipeline against a throwaway root/home (never touches a real install).

---

## Layout

```
$OSA_HOME/                    (default: $HOME/.osa)
├── versions/<rev>/           A fully staged + built checkout at git commit <rev>
├── current    -> versions/<rev>   The live version (symlink)
└── previous   -> versions/<rev>   The version before the last swap (symlink)
```

---

## Update Flow (stage → health-check → atomic swap)

1. **Stage** — `git worktree add` a fresh, detached checkout of the target
   ref into `versions/<rev>`. This never touches `--root`'s working tree or
   index, so it's safe even with local uncommitted changes or a mid-rebase.
2. **Build** (gate #1) — `mix deps.get && mix compile`, plus `cargo build
   --release` for the TUI when present. A compile failure aborts here;
   `current` is never touched.
3. **Boot-probe** (gate #2) — start the built app briefly on an ephemeral
   port and poll its `/health` endpoint. A boot failure aborts here too.
4. **Atomic swap** — only if both gates pass: `current` is atomically
   repointed at the new version via temp-symlink-then-rename (`ln -sfn` +
   `mv -T`), so the swap is a single filesystem rename — never observable
   as a half-updated tree. The version `current` pointed at before the swap
   becomes `previous`, which is what makes rollback possible.
5. **Post-swap re-verify** — health is re-checked against `current` itself
   (belt-and-braces, catches swap-time surprises like a symlink race). If
   that fails, the tool automatically rolls back to `previous` so a bad swap
   can never be the last thing that happened.

If build or boot-probe fails, `current` (and the running install) is left
completely untouched. The failed stage directory is left on disk for
inspection unless `--keep` pruning removes it on a later successful run.

---

## Commands

```bash
osa update --staged              # rollback-safe update: stage, build, boot-probe, atomic-swap
osa update --staged --rollback   # swap current back to the previous version
osa update --staged --dry-run    # print the planned steps; never mutate any filesystem state
```

`osa update --rollback` and `osa update --dry-run` each imply `--staged`
(neither makes sense against the plain in-place download flow), so they can
be used without repeating the flag.

Calling `bin/osa-update` directly (used by tests / advanced use):

```
osa-update update   --root <git-checkout> [--home <osa-home>] [--ref <git-ref>]
                     [--keep <n>] [--dry-run]
osa-update rollback [--home <osa-home>] [--dry-run]
osa-update status   [--home <osa-home>]
```

| Flag | Default | Meaning |
|---|---|---|
| `--root <path>` | — | Git checkout to fetch the update from (required for `update`) |
| `--home <path>` | `$HOME/.osa` | OSA home holding `versions/current/previous` |
| `--ref <ref>` | `origin/main` | Git ref to update to |
| `--keep <n>` | `3` | Number of old staged versions to retain |
| `--dry-run` | off | Print the planned steps; never mutate any filesystem state |

## Rollback

`osa-update rollback` swaps `current` back to whatever `previous` points at
(and the old `current` becomes the new `previous`, so rollback can be
toggled back and forth). It re-verifies health after rolling back and
reports failure without further mutation if even the previous version won't
boot.

## Test Overrides

For test/CI use, the build and health-check commands are overridable:

```bash
OSA_UPDATE_BUILD_CMD='...'   # run inside the staged checkout to build it; receives $STAGE_DIR as cwd
OSA_UPDATE_HEALTH_CMD='...'  # boot-probe a staged/current checkout; receives $STAGE_DIR (cwd) and $PROBE_PORT (env)
```

Default health command is a short-lived `mix osa.serve` polled against
`/health`.

## Caveats

This does not verify a checksum or signature on the fetched commit/tag —
the same caveat steal-list #15 calls out for grok/codex's `--version`-only
self-update. It is a pure filesystem + git tool that only touches `--root`
(read-only: fetch + worktree add) and `--home` (`versions`/`current`/
`previous`); it never reads or writes any other OSA runtime state. Safe for
a trusted git remote over HTTPS; would need a signature check before ever
being used against a hostile network.

---

## See Also

- [Deployment](deployment.md)
- [CHANGELOG](../../CHANGELOG.md)
