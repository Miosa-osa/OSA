#!/usr/bin/env bash
# Build the isolated HOME the `no-skills` arm needs.
#
# SkillLoader scans Path.expand("~/.claude|.agents|.grok/skills") and
# Application.get_env(:skills_dir, "~/.osa/skills"). Both follow $HOME, so the
# only run-time way to empty the user-scope skill set is to give the backend a
# different $HOME. Everything else must be linked through, or the arm stops
# being one-variable:
#
#   * .asdf/.mix/.hex/.cache  — without these `mix` cannot run at all
#   * ~/.osa/*  EXCEPT skills/ — credentials, config, memory, trusted workspaces
#   * osa.db is deliberately NOT linked: the arm gets its own database rather
#     than writing into the one the user's daemon on 9089 is using.
#
# Verified on this checkout: with the scratch HOME the `## Custom Skills` block
# drops from 4,436 B to 1,668 B. The residue is priv/skills (10 bundled skills)
# which has no run-time switch.
set -euo pipefail
SH="${1:-$(cd "$(dirname "$0")" && pwd)/.scratch_home}"
mkdir -p "$SH/.osa/skills" "$SH/.claude" "$SH/.agents" "$SH/.grok"

for d in .asdf .mix .hex .cache .tool-versions; do
  [ -e "$HOME/$d" ] && ln -sfn "$HOME/$d" "$SH/$d"
done

for p in "$HOME"/.osa/* "$HOME"/.osa/.[!.]*; do
  [ -e "$p" ] || continue
  b=$(basename "$p")
  case "$b" in
    skills|osa.db|osa.db-shm|osa.db-wal) continue ;;
  esac
  ln -sfn "$p" "$SH/.osa/$b"
done

echo "scratch HOME ready: $SH"
echo "  user-scope skills: $(ls -A "$SH/.osa/skills" | wc -l) (want 0)"
echo "  .claude/skills   : $(ls -A "$SH/.claude" 2>/dev/null | wc -l) (want 0)"
echo "  own database     : $([ -e "$SH/.osa/osa.db" ] && echo LINKED-BAD || echo yes)"
echo
echo "use with:  HOME=$SH OSA_HOME=$SH/.osa OSA_SETTINGS=<arm.json> \\"
echo "           OSA_HTTP_PORT=19991 mix osa.serve"
