#!/usr/bin/env bash
#
# mayhem/test.sh — BEHAVIORAL oracle for LitmusChaos' authentication credential
# validators. Runs the dynamically-linked KAT probe
# (/mayhem/litmus_sanitizers_kat, built by build.sh) that exercises the real
# chaoscenter/authentication/pkg/utils/sanitizers.go SanitizeString /
# ValidateStrictPassword / ValidateStrictUsername paths on fixed inputs, and
# asserts the EXACT results (values/error strings derived from the validation
# rules in sanitizers.go).
#
# Why not `go test` alone (netnew §4): a Go test binary is statically linked, so
# the gate's LD_PRELOAD sabotage shim cannot neuter it — the suite would survive
# sabotage while proving nothing. The KAT probe is cgo-linked (dynamic), so when
# the program is neutered to _exit(0) it prints nothing, every assertion misses,
# and test.sh FAILS — which is the point (§6.3).
#
# Emits a CTRF summary; exits non-zero iff failed>0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-${SRC:-/mayhem}/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PROBE=/mayhem/litmus_sanitizers_kat
passed=0; failed=0

# Unconditional: a missing probe is a build.sh bug — FAIL loudly, never skip.
if [ ! -x "$PROBE" ]; then
  echo "FAIL: KAT probe $PROBE missing or not executable (build.sh should have produced it)" >&2
  emit_ctrf "litmus-sanitizers-kat" 0 1
  exit 1
fi

OUT="$("$PROBE" 2>/dev/null)"
echo "--- KAT probe output ---"; printf '%s\n' "$OUT"; echo "------------------------"

assert() { # <desc> <expected-line>
  if printf '%s\n' "$OUT" | grep -qxF "$2"; then
    echo "PASS: $1"; passed=$((passed+1))
  else
    echo "FAIL: $1 (expected exact line: $2)"; failed=$((failed+1))
  fi
}

assert "SanitizeString trims whitespace"                 "KAT_SANITIZE=hello"
assert "ValidateStrictPassword(\"Aa1@bcde\") is valid"   "KAT_PW_VALID=true"
assert "ValidateStrictPassword(\"short\") length error"  "KAT_PW_SHORT=password length is less than 8 characters"
assert "ValidateStrictPassword(\"aaaaaaaa\") no digit"   "KAT_PW_NODIGIT=password does not contain digits"
assert "ValidateStrictPassword(\"aaaa1111\") no upper"   "KAT_PW_NOUPPER=password does not contain uppercase alphabets"
assert "ValidateStrictUsername(\"abc\") is valid"        "KAT_USER_VALID=true"
assert "ValidateStrictUsername(\"ab\") is invalid"       "KAT_USER_SHORT=false"
assert "ValidateStrictUsername(\"@bad\") is invalid"     "KAT_USER_BAD=false"

emit_ctrf "litmus-sanitizers-kat" "$passed" "$failed"
