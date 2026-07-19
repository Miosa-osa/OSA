#!/usr/bin/env bash
# test/shell/self_update_test.sh — exercises bin/osa-update's stage -> build ->
# health-check -> atomic-swap -> rollback pipeline against a throwaway temp
# root. Never touches a real OSA install: --root is a scratch git repo and
# --home is a scratch OSA_HOME, both created under mktemp and removed on exit.
#
# Build/health checks are overridden via OSA_UPDATE_BUILD_CMD / OSA_UPDATE_HEALTH_CMD
# (see bin/osa-update's own --help) so this test runs in well under a second and
# has zero dependency on a working mix/elixir/cargo toolchain being present.
#
# Usage: bash test/shell/self_update_test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
UPDATER="$REPO_ROOT/bin/osa-update"

PASS=0
FAIL=0
assert() {
  local desc="$1" cond="$2"
  if [ "$cond" = "0" ]; then
    echo "  ok — $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL — $desc"
    FAIL=$((FAIL + 1))
  fi
}
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ok — $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL — $desc (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/osa-self-update-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

SRC="$TMP/repo"     # fake "ROOT" — the git checkout self-update fetches from
HOME_DIR="$TMP/home" # fake $OSA_HOME

mkdir -p "$SRC"
git -C "$SRC" init --quiet -b main
git -C "$SRC" config user.email "test@example.com"
git -C "$SRC" config user.name "Test"

echo "1.0.0" > "$SRC/VERSION"
echo "mix" > "$SRC/mix.exs"
git -C "$SRC" add -A
git -C "$SRC" commit --quiet -m "v1"
V1_REV="$(git -C "$SRC" rev-parse --short=12 HEAD)"

echo "1.0.1" > "$SRC/VERSION"
git -C "$SRC" add -A
git -C "$SRC" commit --quiet -m "v2"
V2_REV="$(git -C "$SRC" rev-parse --short=12 HEAD)"

echo "== bin/osa-update self-test =="
echo "  scratch root: $TMP"
echo ""

# ── syntax sanity ────────────────────────────────────────────────────────
command bash -n "$UPDATER"
assert "bin/osa-update passes bash -n" "$?"
command bash -n "$REPO_ROOT/bin/osa"
assert "bin/osa passes bash -n" "$?"

# ── 1. dry-run before any update: must not touch the filesystem ───────────
echo ""
echo "-- dry-run (no prior state) --"
out="$("$UPDATER" update --root "$SRC" --home "$HOME_DIR" --ref "$V2_REV" --dry-run)"
rc=$?
assert "dry-run exits 0" "$rc"
case "$out" in *"Planned staged update"*) assert "dry-run prints a plan" 0 ;; *) assert "dry-run prints a plan" 1 ;; esac
assert "dry-run creates no versions dir" "$([ -d "$HOME_DIR/versions" ] && echo 1 || echo 0)"

# ── 2. successful staged update (v1... bootstrap -> v2) ────────────────────
echo ""
echo "-- staged update: bootstrap -> $V2_REV --"
OSA_UPDATE_BUILD_CMD="true" OSA_UPDATE_HEALTH_CMD="true" \
  "$UPDATER" update --root "$SRC" --home "$HOME_DIR" --ref "$V2_REV"
assert "update to v2 exits 0" "$?"
assert "current is a symlink" "$([ -L "$HOME_DIR/current" ] && echo 0 || echo 1)"
assert_eq "current points at staged v2" "$HOME_DIR/versions/$V2_REV" "$(readlink "$HOME_DIR/current")"
assert "previous is a symlink" "$([ -L "$HOME_DIR/previous" ] && echo 0 || echo 1)"
prev_target="$(readlink "$HOME_DIR/previous")"
assert_eq "previous (bootstrap) resolves to the original root" "$SRC" "$(readlink -f "$prev_target")"

# ── 3. already up to date is a no-op ────────────────────────────────────
echo ""
echo "-- re-running the same update is a no-op --"
out="$(OSA_UPDATE_BUILD_CMD="true" OSA_UPDATE_HEALTH_CMD="true" \
  "$UPDATER" update --root "$SRC" --home "$HOME_DIR" --ref "$V2_REV")"
rc=$?
assert "no-op update exits 0" "$rc"
case "$out" in *"Already up to date"*) assert "no-op says already up to date" 0 ;; *) assert "no-op says already up to date" 1 ;; esac

# ── 4. rollback swaps current back to the bootstrap (original) root ───────
echo ""
echo "-- rollback --"
OSA_UPDATE_HEALTH_CMD="true" "$UPDATER" rollback --home "$HOME_DIR"
assert "rollback exits 0" "$?"
assert_eq "current now resolves back to the original root" "$SRC" "$(readlink -f "$HOME_DIR/current")"
assert_eq "previous now points at the (rolled-back-from) v2 stage" "$HOME_DIR/versions/$V2_REV" "$(readlink "$HOME_DIR/previous")"

# ── 5. forward update again (v3), exercising a *non-bootstrap* previous ───
echo ""
echo "-- staged update again: current(=bootstrap) -> v3 --"
echo "1.0.2" > "$SRC/VERSION"
git -C "$SRC" add -A
git -C "$SRC" commit --quiet -m "v3"
V3_REV="$(git -C "$SRC" rev-parse --short=12 HEAD)"
OSA_UPDATE_BUILD_CMD="true" OSA_UPDATE_HEALTH_CMD="true" \
  "$UPDATER" update --root "$SRC" --home "$HOME_DIR" --ref "$V3_REV"
assert "update to v3 exits 0" "$?"
assert_eq "current points at staged v3" "$HOME_DIR/versions/$V3_REV" "$(readlink "$HOME_DIR/current")"
prev_after_v3="$(readlink "$HOME_DIR/previous")"
assert "previous after v3 is the bootstrap link (not a raw repo path)" \
  "$(case "$prev_after_v3" in *"/versions/bootstrap-"*) echo 0;; *) echo 1;; esac)"

# ── 6. build failure aborts cleanly: current/previous untouched ───────────
echo ""
echo "-- build failure aborts, current/previous untouched --"
before_current="$(readlink "$HOME_DIR/current")"
before_previous="$(readlink "$HOME_DIR/previous")"
echo "1.0.3" > "$SRC/VERSION"
git -C "$SRC" add -A
git -C "$SRC" commit --quiet -m "v4 (will fail to build)"
V4_REV="$(git -C "$SRC" rev-parse --short=12 HEAD)"
set +e
OSA_UPDATE_BUILD_CMD="false" OSA_UPDATE_HEALTH_CMD="true" \
  "$UPDATER" update --root "$SRC" --home "$HOME_DIR" --ref "$V4_REV" >"$TMP/build-fail.log" 2>&1
rc=$?
set -e
assert "build-failure update exits non-zero" "$([ "$rc" != "0" ] && echo 0 || echo 1)"
assert_eq "current untouched after build failure" "$before_current" "$(readlink "$HOME_DIR/current")"
assert_eq "previous untouched after build failure" "$before_previous" "$(readlink "$HOME_DIR/previous")"
assert "failed stage dir was cleaned up" "$([ ! -d "$HOME_DIR/versions/$V4_REV" ] && echo 0 || echo 1)"

# ── 7. health-check failure aborts cleanly: current/previous untouched ────
echo ""
echo "-- health-check failure aborts, current/previous untouched --"
before_current="$(readlink "$HOME_DIR/current")"
before_previous="$(readlink "$HOME_DIR/previous")"
set +e
OSA_UPDATE_BUILD_CMD="true" OSA_UPDATE_HEALTH_CMD="false" \
  "$UPDATER" update --root "$SRC" --home "$HOME_DIR" --ref "$V4_REV" >"$TMP/health-fail.log" 2>&1
rc=$?
set -e
assert "health-failure update exits non-zero" "$([ "$rc" != "0" ] && echo 0 || echo 1)"
assert_eq "current untouched after health failure" "$before_current" "$(readlink "$HOME_DIR/current")"
assert_eq "previous untouched after health failure" "$before_previous" "$(readlink "$HOME_DIR/previous")"
assert "failed stage dir was cleaned up" "$([ ! -d "$HOME_DIR/versions/$V4_REV" ] && echo 0 || echo 1)"

# ── 8. post-swap health failure triggers automatic rollback ───────────────
# The fake health command passes for the pre-swap stage probe (STAGE_DIR is
# the staged versions/<rev> dir) but fails for the post-swap re-check
# (STAGE_DIR is $HOME/current), forcing the "swap looked fine but the live
# symlink doesn't boot" path and its automatic rollback.
echo ""
echo "-- post-swap health failure triggers automatic rollback --"
before_current="$(readlink "$HOME_DIR/current")"
echo "1.0.4" > "$SRC/VERSION"
git -C "$SRC" add -A
git -C "$SRC" commit --quiet -m "v5 (fails only post-swap)"
V5_REV="$(git -C "$SRC" rev-parse --short=12 HEAD)"
set +e
OSA_UPDATE_BUILD_CMD="true" \
  OSA_UPDATE_HEALTH_CMD='case "$STAGE_DIR" in */current) exit 1 ;; *) exit 0 ;; esac' \
  "$UPDATER" update --root "$SRC" --home "$HOME_DIR" --ref "$V5_REV" >"$TMP/postswap-fail.log" 2>&1
rc=$?
set -e
assert "post-swap-failure update exits non-zero (reported as a failure)" "$([ "$rc" != "0" ] && echo 0 || echo 1)"
assert_eq "current auto-rolled-back to the pre-attempt version" "$before_current" "$(readlink "$HOME_DIR/current")"

# ── 9. status subcommand runs cleanly ──────────────────────────────────────
echo ""
echo "-- status --"
"$UPDATER" status --home "$HOME_DIR" >/dev/null
assert "status exits 0" "$?"

# ── 10. rollback dry-run makes no changes ──────────────────────────────────
echo ""
echo "-- rollback --dry-run --"
before_current="$(readlink "$HOME_DIR/current")"
before_previous="$(readlink "$HOME_DIR/previous")"
out="$("$UPDATER" rollback --home "$HOME_DIR" --dry-run)"
rc=$?
assert "rollback --dry-run exits 0" "$rc"
case "$out" in *"Planned rollback"*) assert "rollback --dry-run prints a plan" 0 ;; *) assert "rollback --dry-run prints a plan" 1 ;; esac
assert_eq "rollback --dry-run leaves current untouched" "$before_current" "$(readlink "$HOME_DIR/current")"
assert_eq "rollback --dry-run leaves previous untouched" "$before_previous" "$(readlink "$HOME_DIR/previous")"

# ── 11. lock contention: a second update refuses to run while one holds the
# lock, and never touches current/previous ─────────────────────────────────
echo ""
echo "-- lock contention: concurrent update is refused --"
before_current="$(readlink "$HOME_DIR/current")"
before_previous="$(readlink "$HOME_DIR/previous")"
echo "1.0.5b" > "$SRC/VERSION"
git -C "$SRC" add -A
git -C "$SRC" commit --quiet -m "v6b (lock-contention test, distinct from current)"
V6B_REV="$(git -C "$SRC" rev-parse --short=12 HEAD)"
mkdir -p "$HOME_DIR/.update.lock.d"
echo $$ > "$HOME_DIR/.update.lock.d/pid"   # this test process is definitely alive
set +e
out="$(OSA_UPDATE_BUILD_CMD="true" OSA_UPDATE_HEALTH_CMD="true" \
  "$UPDATER" update --root "$SRC" --home "$HOME_DIR" --ref "$V6B_REV" 2>&1)"
rc=$?
set -e
assert "concurrent update exits non-zero" "$([ "$rc" != "0" ] && echo 0 || echo 1)"
case "$out" in *"already running"*) assert "concurrent update reports the lock" 0 ;; *) assert "concurrent update reports the lock" 1 ;; esac
assert_eq "current untouched during lock contention" "$before_current" "$(readlink "$HOME_DIR/current")"
assert_eq "previous untouched during lock contention" "$before_previous" "$(readlink "$HOME_DIR/previous")"
rm -rf "$HOME_DIR/.update.lock.d"

# ── 12. stale lock (owning pid no longer alive) is auto-cleared, update
# proceeds normally ─────────────────────────────────────────────────────────
echo ""
echo "-- stale lock from a dead process is cleared automatically --"
mkdir -p "$HOME_DIR/.update.lock.d"
# A pid that is virtually guaranteed not to be running right now.
echo 999999 > "$HOME_DIR/.update.lock.d/pid"
echo "1.0.5" > "$SRC/VERSION"
git -C "$SRC" add -A
git -C "$SRC" commit --quiet -m "v6 (stale-lock test)"
V6_REV="$(git -C "$SRC" rev-parse --short=12 HEAD)"
out="$(OSA_UPDATE_BUILD_CMD="true" OSA_UPDATE_HEALTH_CMD="true" \
  "$UPDATER" update --root "$SRC" --home "$HOME_DIR" --ref "$V6_REV" 2>&1)"
rc=$?
assert "update past a stale lock exits 0" "$rc"
case "$out" in *"stale update lock"*) assert "stale lock is reported and cleared" 0 ;; *) assert "stale lock is reported and cleared" 1 ;; esac
assert_eq "current advanced to v6 despite the stale lock" "$HOME_DIR/versions/$V6_REV" "$(readlink "$HOME_DIR/current")"
assert "lock released after a successful run" "$([ ! -d "$HOME_DIR/.update.lock.d" ] && echo 0 || echo 1)"

# ── 13. interrupted mid-build (SIGINT) leaves current/previous exactly as
# they were, releases the lock, and cleans up ──────────────────────────────
# Job control (`set -m`) is enabled for this one block: without it, a
# non-interactive/non-job-control shell puts asynchronous ("&") commands'
# SIGINT handling into SIG_IGN before exec, which a real interactive
# terminal (where a user would actually hit Ctrl+C on `osa update`) never
# does. Enabling job control here makes the test match how a real terminal
# delivers the signal, instead of exercising a bash scripting quirk that has
# nothing to do with bin/osa-update's own interrupt handling.
echo ""
echo "-- interrupted update (SIGINT during build) leaves current untouched --"
before_current="$(readlink "$HOME_DIR/current")"
before_previous="$(readlink "$HOME_DIR/previous")"
echo "1.0.6" > "$SRC/VERSION"
git -C "$SRC" add -A
git -C "$SRC" commit --quiet -m "v7 (interrupt test)"
V7_REV="$(git -C "$SRC" rev-parse --short=12 HEAD)"
set +e
set -m
OSA_UPDATE_BUILD_CMD="sleep 5" OSA_UPDATE_HEALTH_CMD="true" \
  "$UPDATER" update --root "$SRC" --home "$HOME_DIR" --ref "$V7_REV" >"$TMP/interrupt.log" 2>&1 &
UPDATE_PID=$!
# Give it time to acquire the lock and get into the build phase, then interrupt.
for _i in 1 2 3 4 5 6 7 8 9 10; do
  [ -d "$HOME_DIR/.update.lock.d" ] && break
  sleep 0.2
done
kill -INT "$UPDATE_PID" 2>/dev/null || true
wait "$UPDATE_PID" 2>/dev/null
rc=$?
set +m
set -e
assert "interrupted update exits non-zero" "$([ "$rc" != "0" ] && echo 0 || echo 1)"
assert_eq "current untouched after SIGINT" "$before_current" "$(readlink "$HOME_DIR/current")"
assert_eq "previous untouched after SIGINT" "$before_previous" "$(readlink "$HOME_DIR/previous")"
assert "lock released after interrupt" "$([ ! -d "$HOME_DIR/.update.lock.d" ] && echo 0 || echo 1)"
assert "no stray tmp symlink left behind after interrupt" \
  "$([ -z "$(find "$HOME_DIR" -maxdepth 1 -name '*.tmp.*' 2>/dev/null)" ] && echo 0 || echo 1)"

# ── 14. permission-denied on versions dir aborts cleanly, current untouched ─
echo ""
echo "-- permission denied on versions dir aborts cleanly --"
before_current="$(readlink "$HOME_DIR/current")"
before_previous="$(readlink "$HOME_DIR/previous")"
chmod 555 "$HOME_DIR/versions"
echo "1.0.7" > "$SRC/VERSION"
git -C "$SRC" add -A
git -C "$SRC" commit --quiet -m "v8 (permission test)"
V8_REV="$(git -C "$SRC" rev-parse --short=12 HEAD)"
set +e
out="$(OSA_UPDATE_BUILD_CMD="true" OSA_UPDATE_HEALTH_CMD="true" \
  "$UPDATER" update --root "$SRC" --home "$HOME_DIR" --ref "$V8_REV" 2>&1)"
rc=$?
set -e
chmod 755 "$HOME_DIR/versions"
assert "permission-denied update exits non-zero" "$([ "$rc" != "0" ] && echo 0 || echo 1)"
case "$out" in *"permission"*|*"Permission"*|*"cannot create"*) assert "permission-denied update reports the failure plainly" 0 ;; *) assert "permission-denied update reports the failure plainly" 1 ;; esac
assert_eq "current untouched after permission failure" "$before_current" "$(readlink "$HOME_DIR/current")"
assert_eq "previous untouched after permission failure" "$before_previous" "$(readlink "$HOME_DIR/previous")"

echo ""
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
