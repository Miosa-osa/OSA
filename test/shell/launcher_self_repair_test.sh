#!/usr/bin/env bash
# test/shell/launcher_self_repair_test.sh — the two ways bin/osa repairs ITSELF.
#
# 1. AUTO-RESTART OF A STALE BACKEND (plain `osa` launch)
#    OSA keeps a warm backend that deliberately outlives the TUI, so a daemon
#    started before a rebuild keeps serving the OLD code from memory while the
#    new code sits on disk. Single-process agents (Claude Code, Codex) cannot
#    have this bug — quit, relaunch, you are on the new code. OSA absorbs the
#    cost itself: the launch path RESTARTS a stale backend instead of telling
#    the user to run `osa stop`, which is not an instruction anyone should get.
#
# 2. RE-EXEC OF A REPLACED UPDATER (`osa update` on a source checkout)
#    `osa update` IS bin/osa running `git pull`, and bin/osa is one of the files
#    that pull rewrites. Bash already holds the OLD text, so the run that
#    FETCHES a fixed updater still EXECUTES the old one — observed live on the
#    v1.0.48 update, which pulled the daemon-restart fix and then skipped the
#    daemon restart. bin/osa now hands off to the script it just pulled.
#
# Everything runs against throwaway git repos and a fake toolchain under mktemp:
# no real repo, no real daemon, no network, no mix/elixir/cargo required.
#
# Usage: bash test/shell/launcher_self_repair_test.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/osa-launcher-self-repair.XXXXXX")"
cleanup() {
  local f p
  for f in "$TMP/daemon.pid" "$TMP/osahome/run/backend.pid"; do
    [ -f "$f" ] || continue
    p="$(cat "$f" 2>/dev/null || true)"
    [ -n "$p" ] && { kill -TERM -- "-${p}" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true; }
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok()  { echo "  ok — $1"; PASS=$((PASS + 1)); }
no_() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
assert()     { if [ "$2" = "0" ]; then ok "$1"; else no_ "$1"; fi; }
assert_not() { if [ "$2" != "0" ]; then ok "$1"; else no_ "$1"; fi; }

# ── Fake toolchain ──────────────────────────────────────────────────────────
# `mix osa.serve` becomes a sleeping process that publishes "<pid> <version>"
# to $TMP/healthy; the fake `curl` serves /health from that file and only while
# the recorded pid is really alive. So a daemon that is truly stopped truly
# stops answering — which is the property under test.
BINS="$TMP/fakebin"; mkdir -p "$BINS"

cat > "$BINS/mix" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "osa.serve" ]; then
  printf '%s %s\n' "\$\$" "\$(cat "\$OSA_TEST_TREE/VERSION")" > "$TMP/healthy"
  trap 'rm -f "$TMP/healthy"; exit 0' TERM INT
  sleep 120 & wait
  exit 0
fi
exit 0
EOF

cat > "$BINS/curl" <<EOF
#!/usr/bin/env bash
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a";; esac; done
case "\$url" in
  *"/health")
    [ -f "$TMP/healthy" ] || exit 22
    read -r p v < "$TMP/healthy"
    kill -0 "\$p" 2>/dev/null || exit 22
    printf '{"status":"ok","version":"%s"}' "\$v"
    exit 0;;
esac
exit 22
EOF

printf '#!/usr/bin/env bash\nexit 0\n' > "$BINS/cargo"
printf '#!/usr/bin/env bash\necho "Elixir 1.18.3 (compiled with Erlang/OTP 27)"\n' > "$BINS/elixir"
cp "$BINS/elixir" "$BINS/erl"
chmod +x "$BINS/mix" "$BINS/curl" "$BINS/cargo" "$BINS/elixir" "$BINS/erl"
# Deliberately minimal PATH: no lsof, no wget, no real toolchain, so every
# branch below is taken for a reason the test controls.
export PATH="$BINS:/usr/bin:/bin"

export OSA_HOME="$TMP/osahome"
mkdir -p "$OSA_HOME/run" "$OSA_HOME/logs"
echo "OSA_DEFAULT_PROVIDER=fake" > "$OSA_HOME/.env"
export OSA_PORT=19997
LOGF="$OSA_HOME/logs/backend.log"

# Populate a throwaway checkout at $1 with version $2.
make_tree() {
  local dir="$1" ver="$2"
  mkdir -p "$dir/bin" "$dir/priv/rust/tui/target/release" "$dir/priv"
  cp "$REPO_ROOT/bin/osa" "$dir/bin/osa"
  cp "$REPO_ROOT/bin/osa-update" "$dir/bin/osa-update"
  chmod +x "$dir/bin/osa" "$dir/bin/osa-update"
  echo "mix" > "$dir/mix.exs"
  echo "$ver" > "$dir/VERSION"
  cat > "$dir/priv/CHANGELOG.md" <<'MD'
# Changelog
## [Unreleased]
- UNRELEASED-MUST-NEVER-PRINT
## [1.0.49]
- real notes for 1.0.49
## [1.0.48]
- real notes for 1.0.48
MD
  # Fake TUI: reports the tree's VERSION (so _update_verify_tui is satisfiable)
  # and, when launched, prints the version the backend it attached to serves.
  cat > "$dir/priv/rust/tui/target/release/osagent" <<'EOF'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")/../../../../.." && pwd)"
case "${1:-}" in --version) echo "osagent v$(cat "$here/VERSION")"; exit 0;; esac
echo "TUI-ATTACHED-TO v$(curl -s "http://localhost:$OSA_PORT/health" | sed 's/.*"version":"\([^"]*\)".*/\1/')"
EOF
  chmod +x "$dir/priv/rust/tui/target/release/osagent"
}

echo "══ 1. Plain launch auto-restarts a stale backend ══"

TREE="$TMP/tree"
make_tree "$TREE" "1.0.49"
export OSA_TEST_TREE="$TREE"

# Plant a backend serving version $1, as if started before a rebuild.
plant_daemon() {
  ( printf '%s %s\n' "$BASHPID" "$1" > "$TMP/healthy"
    trap 'rm -f "$TMP/healthy"; exit 0' TERM INT
    sleep 120 & wait ) &
  local p=$!
  printf '%s %s\n' "$p" "$1" > "$TMP/healthy"
  echo "$p" > "$OSA_HOME/run/backend.pid"
  echo "$p" > "$TMP/daemon.pid"
  : > "$LOGF"; touch -d '1 hour ago' "$LOGF" 2>/dev/null || touch -t 202001010000 "$LOGF"
}
# Group kills: start_daemon runs the fake backend under setsid, so the bash
# wrapper is a process-group leader whose `sleep` child outlives a bare
# `kill <pid>`. Killing the GROUP reaps both and leaves no strays behind.
kill_daemon() {
  local f p n
  for f in "$TMP/daemon.pid" "$OSA_HOME/run/backend.pid"; do
    [ -f "$f" ] || continue
    p="$(cat "$f" 2>/dev/null || true)"
    [ -n "$p" ] || continue
    kill -TERM -- "-${p}" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
    # WAIT for it to actually die before moving on. Each fake daemon deletes
    # $TMP/healthy from its own TERM trap, so a straggler that exits late would
    # otherwise delete the health file the NEXT test case just planted — and
    # that test would see a cold backend instead of the daemon it planted.
    n=0
    while [ "$n" -lt 50 ] && kill -0 "$p" 2>/dev/null; do
      sleep 0.1; n=$((n + 1))
    done
  done
  rm -f "$TMP/healthy" "$OSA_HOME/run/backend.pid" "$TMP/daemon.pid"
}
launch() { ( cd "$TREE" && timeout 90 "$TREE/bin/osa" ) 2>&1; }

echo "-- stale (v1.0.48) + idle → restarted automatically, no user action"
plant_daemon 1.0.48
OUT="$(launch)"; RC=$?
grep -q "running an older build — restarting" <<<"$OUT"; assert "one calm restart line" $?
grep -q "TUI-ATTACHED-TO v1.0.49" <<<"$OUT"; assert "attached backend reports the INSTALLED version" $?
assert "launch exits 0" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
grep -qi "Fix with.*osa stop" <<<"$OUT"; assert_not "never prescribes 'osa stop' as the fix" $?
grep -q "A stale OSA backend" <<<"$OUT"; assert_not "no warning the user must act on" $?
grep -q "Stopping OSA backend (pid" <<<"$OUT"; assert_not "no pid chatter — the repair is quiet" $?
kill_daemon

echo "-- daemon already matches the tree → attach, nothing restarted"
plant_daemon 1.0.49
OUT="$(launch)"
grep -q "attaching" <<<"$OUT"; assert "fast attach path taken" $?
grep -q "older build — restarting" <<<"$OUT"; assert_not "a matching daemon is never restarted" $?
grep -q "TUI-ATTACHED-TO v1.0.49" <<<"$OUT"; assert "TUI launched against v1.0.49" $?
kill_daemon

echo "-- stale AND busy, non-interactive → left alone (in-flight work survives)"
plant_daemon 1.0.48
touch "$LOGF"          # logged just now == mid-turn
OUT="$(launch)"
grep -q "A stale OSA backend" <<<"$OUT"; assert "warned instead of killing in-flight work" $?
grep -q "refreshed automatically once idle" <<<"$OUT"; assert "says it self-heals; no instruction to the user" $?
grep -q "TUI-ATTACHED-TO v1.0.48" <<<"$OUT"; assert "attached to the busy daemon rather than ending its work" $?
kill_daemon

echo "-- stale backend that will not stop → hard error, never attach to it"
# A live process bin/osa cannot find (no pidfile, no lsof on PATH), so nothing
# is signalled and :PORT keeps answering.
sleep 120 & UNKILLABLE=$!
printf '%s 1.0.48\n' "$UNKILLABLE" > "$TMP/healthy"
rm -f "$OSA_HOME/run/backend.pid"
: > "$LOGF"; touch -d '1 hour ago' "$LOGF" 2>/dev/null || touch -t 202001010000 "$LOGF"
OUT="$(launch)"; RC=$?
grep -q "would not stop" <<<"$OUT"; assert "fails loudly when the old backend survives" $?
grep -q "silently run the OLD build" <<<"$OUT"; assert "explains why it refuses" $?
grep -q "TUI-ATTACHED-TO" <<<"$OUT"; assert_not "never launches against the wrong build" $?
assert "non-zero exit" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
kill "$UNKILLABLE" 2>/dev/null; rm -f "$TMP/healthy"

echo ""
echo '══ 2. `osa update` re-execs the updater it just pulled ══'

ORIGIN="$TMP/origin"; CLONE="$TMP/clone"
make_tree "$ORIGIN" "1.0.48"
git -C "$ORIGIN" init --quiet -b main
git -C "$ORIGIN" config user.email test@example.com
git -C "$ORIGIN" config user.name Test
git -C "$ORIGIN" add -A >/dev/null
git -C "$ORIGIN" commit --quiet -m "v1.0.48"
git clone --quiet "$ORIGIN" "$CLONE"
export OSA_TEST_TREE="$CLONE"

# Publish a new upstream version whose bin/osa prints $1 from inside the
# post-pull phase — a marker the currently-running (old) script cannot print.
publish() {
  local marker="$1" ver="$2"
  python3 - "$ORIGIN/bin/osa" "$marker" <<'PY'
import re, sys
path, marker = sys.argv[1], sys.argv[2]
s = open(path).read()
s = re.sub(r'MARKER-GEN-\w+', marker, s)
if marker not in s:
    anchor = "  _update_build || return 1\n"
    assert s.count(anchor) >= 1, "anchor moved: update this test"
    s = s.replace(anchor, '  echo "%s"\n' % marker + anchor, 1)
open(path, "w").write(s)
PY
  echo "$ver" > "$ORIGIN/VERSION"
  git -C "$ORIGIN" add -A >/dev/null
  git -C "$ORIGIN" commit --quiet -m "$ver"
}
run_update() { ( cd "$CLONE" && timeout 120 "$CLONE/bin/osa" update "$@" ) 2>&1; }

echo "-- the pull replaces bin/osa → the NEW logic runs in the SAME invocation"
publish MARKER-GEN-A 1.0.49
rm -f "$TMP/healthy"
OUT="$(run_update)"
grep -q "handing off to the new one" <<<"$OUT"; assert "hand-off announced" $?
grep -q "Continuing under the updated" <<<"$OUT"; assert "successor announces where it resumed" $?
grep -q "MARKER-GEN-A" <<<"$OUT"; assert "NEW updater logic ran in this same run" $?
grep -c "MARKER-GEN-A" <<<"$OUT" | grep -qx 1; assert "ran exactly once (no re-exec loop)" $?
grep -q "Updated: v1.0.48 → v1.0.49" <<<"$OUT"; assert "reports the real version delta" $?
grep -q "real notes for 1.0.49" <<<"$OUT"; assert "prints the installed version's release notes" $?
grep -q "UNRELEASED-MUST-NEVER-PRINT" <<<"$OUT"; assert_not "never prints [Unreleased]" $?
kill_daemon

echo "-- bin/osa unchanged by the pull → no re-exec at all"
echo "1.0.50" > "$ORIGIN/VERSION"
git -C "$ORIGIN" add -A >/dev/null; git -C "$ORIGIN" commit --quiet -m 1.0.50
OUT="$(run_update)"
grep -q "handing off" <<<"$OUT"; assert_not "no hand-off when the updater did not change" $?
grep -q "Updated: v1.0.49 → v1.0.50" <<<"$OUT"; assert "the update still completes" $?
kill_daemon

echo "-- re-exec marker already set → refuses a second hand-off (loop guard)"
publish MARKER-GEN-C 1.0.51
OUT="$(OSA_UPDATE_REEXECED=1 run_update)"
grep -q "loop guard" <<<"$OUT"; assert "loop guard fires" $?
grep -q "handing off to the new one" <<<"$OUT"; assert_not "does NOT re-exec a second time" $?
grep -q "Updated: v1.0.50 → v1.0.51" <<<"$OUT"; assert "the update still completes under current logic" $?
kill_daemon

echo "-- dirty tree: the stash survives the re-exec boundary"
publish MARKER-GEN-D 1.0.52
echo "upstream line" > "$ORIGIN/upstream_only.txt"
git -C "$ORIGIN" add -A >/dev/null; git -C "$ORIGIN" commit --quiet -m upstream-file
printf 'MY LOCAL WORK\n' > "$CLONE/my_local_file.txt"     # untracked
printf 'tracked edit\n' >> "$CLONE/mix.exs"               # tracked
STASHES_BEFORE="$(git -C "$CLONE" stash list | wc -l)"
OUT="$(run_update)"
grep -q "Saving local changes to stash" <<<"$OUT"; assert "local work was stashed" $?
grep -q "handing off to the new one" <<<"$OUT"; assert "re-exec happened with local work in play" $?
grep -q "MARKER-GEN-D" <<<"$OUT"; assert "new updater logic ran" $?
grep -q "reintegrated cleanly" <<<"$OUT"; assert "local changes reported reintegrated" $?
[ "$(cat "$CLONE/my_local_file.txt" 2>/dev/null)" = "MY LOCAL WORK" ]
assert "untracked local file intact across the re-exec" $?
grep -q "tracked edit" "$CLONE/mix.exs"; assert "tracked local edit intact across the re-exec" $?
[ -f "$CLONE/upstream_only.txt" ]; assert "the upstream file arrived" $?
STASHES_AFTER="$(git -C "$CLONE" stash list | wc -l)"
[ "$STASHES_AFTER" = "$STASHES_BEFORE" ]
assert "no stash left dangling (applied and dropped): ${STASHES_BEFORE}→${STASHES_AFTER}" $?
kill_daemon

echo "-- the pulled bin/osa is not executable → fail loudly, never fall back"
publish MARKER-GEN-E 1.0.53
git -C "$ORIGIN" update-index --chmod=-x bin/osa 2>/dev/null || git -C "$ORIGIN" add --chmod=-x bin/osa
git -C "$ORIGIN" commit --quiet -m "drop exec bit"
OUT="$(run_update)"; RC=$?
grep -q "missing or not executable" <<<"$OUT"; assert "refuses loudly when the successor is unusable" $?
grep -q "MARKER-GEN-E" <<<"$OUT"; assert_not "does NOT silently continue under the old logic" $?
assert "non-zero exit on refusal" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
kill_daemon

echo ""
echo '══ 3. Prebuilt `osa update` replaces the LAUNCHER too ══'
#
# On a prebuilt install (`curl … install.sh | sh` — how most people install)
# `osa update` swapped the backend release and the TUI binary but never
# $OSA_HOME/bin/osa, the launcher itself. Every launcher fix therefore reached
# only the users who re-ran install.sh by hand: PERMANENT staleness, not the
# one-run staleness section 2 covers. The launcher now refreshes itself from
# `scripts/install.sh` at the RELEASE TAG (never `main`) and, because bash has
# already read the running file, hands the rest of the update to its successor.
#
# Everything below runs against a throwaway $OSA_HOME and a fake release
# server: no network, no real release, no real daemon.

PB_HOME="$TMP/pbhome"
SRV="$TMP/srv"                       # static tree the fake curl serves
mkdir -p "$PB_HOME/bin" "$PB_HOME/run" "$PB_HOME/logs" "$SRV"

# URL → filename, mirrored byte-for-byte inside the fake curl below.
srv_key() { printf '%s' "$1" | sed 's|https://||; s|[^A-Za-z0-9._-]|_|g'; }
serve()   { cp "$2" "$SRV/$(srv_key "$1")"; }

# A curl that answers BOTH /health (from $TMP/healthy, and only while the
# recorded pid is really alive) and the fake release server. Honours `-o`,
# because that is how the launcher's _download calls it.
cat > "$BINS/curl" <<EOF
#!/usr/bin/env bash
url=""; out=""; prev=""
for a in "\$@"; do
  if [ "\$prev" = "-o" ]; then out="\$a"; prev=""; continue; fi
  case "\$a" in -o) prev="-o" ;; http*) url="\$a" ;; esac
done
case "\$url" in
  *"/health")
    [ -f "$TMP/healthy" ] || exit 22
    read -r p v < "$TMP/healthy"
    kill -0 "\$p" 2>/dev/null || exit 22
    body="{\\"status\\":\\"ok\\",\\"version\\":\\"\$v\\"}"
    if [ -n "\$out" ]; then printf '%s' "\$body" > "\$out"; else printf '%s' "\$body"; fi
    exit 0 ;;
esac
key="\$(printf '%s' "\$url" | sed 's|https://||; s|[^A-Za-z0-9._-]|_|g')"
[ -f "$SRV/\$key" ] || exit 22
if [ -n "\$out" ]; then cp "$SRV/\$key" "\$out"; else cat "$SRV/\$key"; fi
exit 0
EOF
chmod +x "$BINS/curl"

RAW_BASE="https://raw.example.invalid/Miosa-osa/OSA"
API_URL="https://api.github.com/repos/Miosa-osa/OSA/releases/latest"
DL_BASE="https://github.com/Miosa-osa/OSA/releases/download"

# The launcher as install.sh generates it — the inverse of the heredoc.
extract_launcher() {
  awk '
    /^cat > "\$LAUNCHER" <</ { inb = 1; next }
    inb && $0 == "LAUNCHER_EOF" { exit }
    inb { print }
  ' "$1"
}

# An install.sh whose launcher prints $2 from inside the post-hand-off phase —
# a line the currently-running (old) launcher physically cannot print, so seeing
# it proves the NEW launcher finished the update in the SAME invocation.
marked_install_sh() {
  python3 - "$REPO_ROOT/scripts/install.sh" "$1" "$2" <<'PY'
import sys
src, dst, marker = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src).read()
anchor = '  if [ "${OSA_UPDATE_PHASE:-}" = "post-install" ]; then\n'
assert s.count(anchor) == 1, "anchor moved: update this test"
s = s.replace(anchor, anchor + '    echo "%s"\n' % marker, 1)
open(dst, "w").write(s)
PY
}

# Publish release $1 with the install.sh at $2 as its tagged launcher source.
publish_release() {
  local tag="$1" install_sh="$2" ver="${1#v}"
  local rel="$TMP/relsrc-$tag"
  rm -rf "$rel"; mkdir -p "$rel/bin"
  cat > "$rel/bin/osagent" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  serve)
    printf '%s %s\n' "\$\$" "$ver" > "$TMP/healthy"
    trap 'rm -f "$TMP/healthy"; exit 0' TERM INT
    sleep 120 & wait; exit 0 ;;
  version) echo "osagent $ver"; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$rel/bin/osagent"
  tar -czf "$TMP/osa-linux-x64-$tag.tar.gz" -C "$rel" .

  cat > "$TMP/tui-$tag" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in --version) echo "osagent v$ver"; exit 0 ;; esac
echo "TUI-LAUNCHED v$ver ARGS:[\$*]"
EOF
  chmod +x "$TMP/tui-$tag"

  serve "$DL_BASE/$tag/osa-linux-x64.tar.gz" "$TMP/osa-linux-x64-$tag.tar.gz"
  serve "$DL_BASE/$tag/osagent-tui-linux-x64" "$TMP/tui-$tag"
  ( cd "$TMP" && sha256sum "osa-linux-x64-$tag.tar.gz" | awk '{print $1}' > "sum1-$tag" \
              && sha256sum "tui-$tag"                  | awk '{print $1}' > "sum2-$tag" )
  serve "$DL_BASE/$tag/osa-linux-x64.tar.gz.sha256" "$TMP/sum1-$tag"
  serve "$DL_BASE/$tag/osagent-tui-linux-x64.sha256" "$TMP/sum2-$tag"
  serve "$RAW_BASE/$tag/scripts/install.sh" "$install_sh"

  python3 - "$SRV/$(srv_key "$API_URL")" "$tag" <<'PY'
import json, sys
open(sys.argv[1], "w").write(json.dumps({
    "tag_name": sys.argv[2],
    "body": "RELEASE-NOTES-BODY for " + sys.argv[2],
}))
PY
}

# Lay down a prebuilt install at $1 whose launcher is generated from $2.
pb_install() {
  local stamp="$1" install_sh="$2"
  rm -rf "$PB_HOME/release"; mkdir -p "$PB_HOME/release/bin" "$PB_HOME/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$PB_HOME/release/bin/osagent"
  chmod +x "$PB_HOME/release/bin/osagent"
  printf '#!/usr/bin/env bash\ncase "${1:-}" in --version) echo "osagent %s"; exit 0;; esac\n' \
    "${stamp#v}" > "$PB_HOME/bin/osagent-tui"
  chmod +x "$PB_HOME/bin/osagent-tui"
  extract_launcher "$install_sh" > "$PB_HOME/bin/osa"
  chmod +x "$PB_HOME/bin/osa"
  printf '%s\n' "$stamp" > "$PB_HOME/version"
  rm -f "$PB_HOME/bin/osa.bak" "$PB_HOME/bin/osa.new"
}

# Run `osa update` against the prebuilt install. Stdin is /dev/null so the
# "Press Enter to launch" prompt and every y/N question take their non-tty path.
pb_update() {
  ( cd "$TMP" \
    && OSA_HOME="$PB_HOME" OSA_PORT="$OSA_PORT" \
       OSA_LAUNCHER_RAW_BASE="$RAW_BASE" \
       timeout 120 "$PB_HOME/bin/osa" update "$@" </dev/null ) 2>&1
}

pb_sum() { sha256sum "$PB_HOME/bin/osa" | awk '{print $1}'; }

PLAIN_SH="$TMP/install-plain.sh"
cp "$REPO_ROOT/scripts/install.sh" "$PLAIN_SH"
MARKED_A="$TMP/install-A.sh"; marked_install_sh "$MARKED_A" "LAUNCHER-GEN-A"

echo "-- a prebuilt update replaces the launcher and the NEW one finishes the job"
pb_install "v1.0.48" "$PLAIN_SH"
BEFORE_SUM="$(pb_sum)"
publish_release "v1.0.49" "$MARKED_A"
OUT="$(pb_update)"; RC=$?
grep -q "Refreshing the launcher for v1.0.49" <<<"$OUT"; assert "the launcher refresh is announced" $?
grep -q "Launcher updated" <<<"$OUT"; assert "the launcher was replaced" $?
grep -q "Handing off to the new launcher" <<<"$OUT"; assert "hands off rather than continuing on stale code" $?
grep -q "LAUNCHER-GEN-A" <<<"$OUT"; assert "the NEW launcher's logic ran in the SAME invocation" $?
grep -q "Continuing under the updated launcher" <<<"$OUT"; assert "the successor announces the resumption" $?
grep -qF "LAUNCHER-GEN-A" "$PB_HOME/bin/osa"; assert "the new launcher is what is on disk" $?
[ -x "$PB_HOME/bin/osa" ]; assert "the installed launcher is executable" $?
[ "$(pb_sum)" != "$BEFORE_SUM" ]; assert "the launcher really changed on disk" $?
[ -s "$PB_HOME/bin/osa.bak" ]; assert "a backup of the previous launcher was kept" $?
[ ! -e "$PB_HOME/bin/osa.new" ]; assert "no staging file left behind" $?
grep -q "Updated v1.0.48 → v1.0.49" <<<"$OUT"; assert "reports the real delta" $?
[ "$(grep -c "Updated v1.0.48 → v1.0.49" <<<"$OUT")" = "1" ]; assert "reports it exactly once (no double report)" $?
grep -q "RELEASE-NOTES-BODY for v1.0.49" <<<"$OUT"; assert "release notes survived the process boundary" $?
grep -q "Downloading osa-linux-x64.tar.gz" <<<"$OUT"
[ "$(grep -c "Downloading osa-linux-x64.tar.gz" <<<"$OUT")" = "1" ]
assert "the release is downloaded exactly once across the hand-off" $?
[ "$(cat "$PB_HOME/version")" = "v1.0.49" ]; assert "the version stamp advanced" $?
grep -q "TUI-LAUNCHED v1.0.49" <<<"$OUT"; assert "the update flows straight into a launch" $?
assert "exit 0" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
kill_daemon

echo "-- the user's argv survives the hand-off"
pb_install "v1.0.48" "$PLAIN_SH"
publish_release "v1.0.49" "$MARKED_A"
OUT="$(pb_update --overdrive)"
grep -q "Handing off to the new launcher" <<<"$OUT"; assert "handed off" $?
grep -q "ARGS:\[--overdrive\]" <<<"$OUT"; assert "--overdrive was replayed into the new launcher" $?
grep -q "OVERDRIVE (full auto)" <<<"$OUT"; assert "and still took effect" $?
kill_daemon

echo "-- an UNCHANGED launcher is not needlessly replaced"
# v1.0.50 ships the launcher that is already installed, byte for byte.
publish_release "v1.0.50" "$MARKED_A"
BEFORE_SUM="$(pb_sum)"
OUT="$(pb_update)"
grep -q "Launcher already current" <<<"$OUT"; assert "recognises an identical launcher" $?
grep -q "Launcher updated" <<<"$OUT"; assert_not "does not rewrite it" $?
grep -q "Handing off" <<<"$OUT"; assert_not "does not re-exec for nothing" $?
[ "$(pb_sum)" = "$BEFORE_SUM" ]; assert "the launcher is byte-identical afterwards" $?
grep -q "Updated v1.0.49 → v1.0.50" <<<"$OUT"; assert "the update itself still completed" $?
kill_daemon

echo "-- a TRUNCATED launcher download leaves the old launcher intact and errors"
# Cut the download off part-way THROUGH the launcher heredoc, which is what a
# real truncated transfer looks like: a plausible head, no body.
python3 - "$MARKED_A" "$TMP/install-trunc.sh" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines(True)
start = next(i for i, l in enumerate(lines) if l.startswith('cat > "$LAUNCHER" <<'))
open(sys.argv[2], "w").writelines(lines[: start + 120])
PY
publish_release "v1.0.51" "$TMP/install-trunc.sh"
BEFORE_SUM="$(pb_sum)"
OUT="$(pb_update)"; RC=$?
grep -qi "truncated" <<<"$OUT"; assert "names truncation as the reason" $?
grep -q "NOT touched" <<<"$OUT"; assert "says the working launcher was left alone" $?
grep -q "Launcher updated" <<<"$OUT"; assert_not "never claims success" $?
[ "$(pb_sum)" = "$BEFORE_SUM" ]; assert "the old launcher is byte-identical" $?
bash -n "$PB_HOME/bin/osa"; assert "the old launcher is still valid shell" $?
assert "non-zero exit" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
kill_daemon

echo "-- an HTML error page can never overwrite the launcher"
printf '<!DOCTYPE html>\n<html><body>404: Not Found</body></html>\n' > "$TMP/install-html.sh"
publish_release "v1.0.52" "$TMP/install-html.sh"
BEFORE_SUM="$(pb_sum)"
OUT="$(pb_update)"; RC=$?
grep -q "empty\|truncated\|not the OSA launcher\|shebang" <<<"$OUT"; assert "rejects a non-launcher body" $?
[ "$(pb_sum)" = "$BEFORE_SUM" ]; assert "the old launcher is byte-identical" $?
assert "non-zero exit" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
kill_daemon

echo "-- a launcher with broken shell syntax is refused by sh -n / bash -n"
python3 - "$MARKED_A" "$TMP/install-broken.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
# Break the launcher BODY only — install.sh's own syntax must stay valid, so
# this really exercises the candidate's `bash -n` and not the download.
assert s.count("\nLAUNCHER_EOF\n") == 1
s = s.replace("\nLAUNCHER_EOF\n", "\nif [ ; then\nLAUNCHER_EOF\n", 1)
open(sys.argv[2], "w").write(s)
PY
publish_release "v1.0.53" "$TMP/install-broken.sh"
BEFORE_SUM="$(pb_sum)"
OUT="$(pb_update)"; RC=$?
grep -q "not valid shell" <<<"$OUT"; assert "names invalid shell as the reason" $?
grep -q "Launcher updated" <<<"$OUT"; assert_not "never claims success" $?
[ "$(pb_sum)" = "$BEFORE_SUM" ]; assert "the old launcher is byte-identical" $?
assert "non-zero exit" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
kill_daemon

echo "-- a body that is valid shell but is NOT the OSA launcher is refused"
{ printf '#!/usr/bin/env bash\n'; for i in $(seq 1 400); do printf 'echo "line %s"\n' "$i"; done; } \
  > "$TMP/decoy.sh"
{ printf 'cat > "$LAUNCHER" <<%sLAUNCHER_EOF%s\n' "'" "'"; cat "$TMP/decoy.sh"; printf 'LAUNCHER_EOF\n'; } \
  > "$TMP/install-decoy.sh"
publish_release "v1.0.54" "$TMP/install-decoy.sh"
BEFORE_SUM="$(pb_sum)"
OUT="$(pb_update)"; RC=$?
grep -q "not the OSA launcher" <<<"$OUT"; assert "the sentinel check catches a plausible impostor" $?
[ "$(pb_sum)" = "$BEFORE_SUM" ]; assert "the old launcher is byte-identical" $?
assert "non-zero exit" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
kill_daemon

echo "-- the loop guard holds"
MARKED_B="$TMP/install-B.sh"; marked_install_sh "$MARKED_B" "LAUNCHER-GEN-B"
publish_release "v1.0.55" "$MARKED_B"
BEFORE_SUM="$(pb_sum)"
# Exported, not a temporary function-call assignment: the launcher is an
# external command and only ever sees the exported environment.
export OSA_UPDATE_REEXECED=1
OUT="$(pb_update)"
unset OSA_UPDATE_REEXECED
grep -q "loop guard" <<<"$OUT"; assert "loop guard fires" $?
grep -q "Handing off to the new launcher" <<<"$OUT"; assert_not "does NOT re-exec a second time" $?
grep -q "LAUNCHER-GEN-B" <<<"$OUT"; assert_not "does NOT run the successor's logic" $?
[ "$(pb_sum)" = "$BEFORE_SUM" ]; assert "and does not swap the launcher underneath itself" $?
grep -q "Updated v1.0.54 → v1.0.55" <<<"$OUT"; assert "the update still completes under current logic" $?
kill_daemon

echo "-- a stale launcher is repaired even when the binaries are already current"
# The only route by which an already-latest install can recover: nothing else
# in the install would ever notice that bin/osa is out of date.
pb_install "v1.0.55" "$PLAIN_SH"
printf '#!/usr/bin/env bash\ncase "${1:-}" in --version) echo "osagent v1.0.55"; exit 0;; esac\necho "TUI-LAUNCHED v1.0.55 ARGS:[$*]"\n' \
  > "$PB_HOME/bin/osagent-tui"
chmod +x "$PB_HOME/bin/osagent-tui"
BEFORE_SUM="$(pb_sum)"
OUT="$(pb_update)"
grep -q "Launcher updated" <<<"$OUT"; assert "refreshes the launcher on the up-to-date path" $?
grep -q "LAUNCHER-GEN-B" <<<"$OUT"; assert "the new launcher finishes the run" $?
grep -q "Already up to date" <<<"$OUT"; assert "and still reports the truth about the binaries" $?
grep -q "Updated v" <<<"$OUT"; assert_not "does not invent an upgrade that did not happen" $?
[ "$(pb_sum)" != "$BEFORE_SUM" ]; assert "the launcher changed on disk" $?
kill_daemon

echo ""
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
