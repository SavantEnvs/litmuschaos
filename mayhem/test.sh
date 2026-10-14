#!/usr/bin/env bash
#
# mayhem/test.sh — BEHAVIORAL oracle for LitmusChaos' GraphQL server version query. Runs the
# dynamically-linked KAT probe (/mayhem/litmus_serverversion_kat, built by build.sh) that calls the real
# chaos_infrastructure QueryServerVersion with a stubbed server-config store and asserts the EXACT
# result for a stored version string, and that a database error, a missing "version" document and a
# non-string value are never reported as a success.
#
# A missing document or a non-string value panics before the upstream fix (the code this layer mines)
# and returns an error after it; both count as "not a success" here, so the suite passes on either side
# of the fix while still failing on a build that answers with a made-up version.
#
# Why not `go test` alone (netnew §4): a Go test binary is statically linked, so the gate's LD_PRELOAD
# sabotage shim cannot neuter it. The KAT probe is cgo-linked (dynamic), so when the program is
# neutered to _exit(0) it prints nothing, every assertion misses, and test.sh FAILS (§6.3).
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

PROBE=/mayhem/litmus_serverversion_kat
passed=0; failed=0

# Unconditional: a missing probe is a build.sh bug — FAIL loudly, never skip.
if [ ! -x "$PROBE" ]; then
  echo "FAIL: KAT probe $PROBE missing or not executable (build.sh should have produced it)" >&2
  emit_ctrf "litmus-serverversion-kat" 0 1
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
assert_re() { # <desc> <ERE the whole line must match>
  if printf '%s\n' "$OUT" | grep -qE "$2"; then
    echo "PASS: $1"; passed=$((passed+1))
  else
    echo "FAIL: $1 (expected a line matching: $2)"; failed=$((failed+1))
  fi
}

assert    "QueryServerVersion returns the stored version"        "KAT_VERSION=ok version/3.1.0"
assert    "a database error is returned as that error"           "KAT_DBERR=error: boom"
assert_re "a missing version document is not a success"          '^KAT_ABSENT=(panic|error: .+)$'
assert_re "a non-string version value is not a success"          '^KAT_NONSTRING=(panic|error: .+)$'

emit_ctrf "litmus-serverversion-kat" "$passed" "$failed"
