#!/bin/bash
# Repro for issue #9: hook commands in hooks/hooks.json must survive a
# CLAUDE_PLUGIN_ROOT that contains a space (e.g. ~/Library/Application Support/...).
#
# Every hook command is run the two ways Claude Code may execute it:
#   env   - CLAUDE_PLUGIN_ROOT exported, the shell expands the variable
#   subst - ${CLAUDE_PLUGIN_ROOT} replaced textually before the shell sees it
# against a fake plugin root whose scripts are stubs that record they ran.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="$REPO/hooks/hooks.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/Application Support/Claude/plugins/keep-awake"
mkdir -p "$ROOT/scripts"
for s in "$REPO"/scripts/*.sh; do
  name="$(basename "$s")"
  printf '#!/bin/bash\necho "%s" >> "%s/ran"\n' "$name" "$TMP" > "$ROOT/scripts/$name"
done

fail=0
while IFS=$'\t' read -r event cmd; do
  script="$(printf '%s' "$cmd" | grep -o '[a-z-]*\.sh')"
  for mode in env subst; do
    rm -f "$TMP/ran"
    if [ "$mode" = env ]; then
      out="$(CLAUDE_PLUGIN_ROOT="$ROOT" sh -c "$cmd" </dev/null 2>&1)"
    else
      out="$(sh -c "${cmd//\$\{CLAUDE_PLUGIN_ROOT\}/$ROOT}" </dev/null 2>&1)"
    fi
    if [ "$(cat "$TMP/ran" 2>/dev/null)" = "$script" ]; then
      echo "PASS $event [$mode]"
    else
      echo "FAIL $event [$mode]: $script did not run; output: $out"
      fail=1
    fi
  done
done < <(jq -r '.hooks | to_entries[] | .key as $e | .value[].hooks[] | "\($e)\t\(.command)"' "$HOOKS")

exit $fail
