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

echo ""
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
