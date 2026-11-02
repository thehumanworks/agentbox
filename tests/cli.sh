# Offline tests for the agentbox CLI that need no container runtime.
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME=$work/home XDG_CONFIG_HOME=$work/config
mkdir -p "$HOME"

"$AGENTBOX" help | grep -q 'Usage: agentbox' || fail "help"

cat >"$work/env" <<'ENV'
# comment

export QUOTED="quoted value"
PLAIN=plain=with=equals
SINGLE='it''s'
  SPACED = trailing name space
WIN=crlf
ENV
printf 'WIN=crlf\r\n' >>"$work/env"

decode() {
  "$AGENTBOX" _encode-env "$work/env" | while IFS=$'\t' read -r name value; do
    printf '%s=%s\n' "$name" "$(printf '%s' "$value" | base64 -d)"
  done
}
expected='QUOTED=quoted value
PLAIN=plain=with=equals
SINGLE=it'"''"'s
SPACED= trailing name space
WIN=crlf
WIN=crlf'
actual=$(decode)
[[ $actual == "$expected" ]] || fail "env parsing: got
$actual"

printf '1BAD=x\n' >"$work/bad"
if "$AGENTBOX" _encode-env "$work/bad" 2>/dev/null; then
  fail "invalid names must be rejected"
fi

# Backend selection honours the override and reports a missing CLI.
if AGENTBOX_BACKEND=podman PATH=/nonexistent "$AGENTBOX" backend 2>"$work/err"; then
  fail "missing podman must fail"
fi
grep -q 'CLI was not found' "$work/err" || fail "missing-CLI message"

printf 'cli tests passed\n'
