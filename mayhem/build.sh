#!/usr/bin/env bash
#
# mayhem/build.sh — build a sanitized libFuzzer target for LitmusChaos' GraphQL server
# (chaoscenter/graphql/server/pkg/chaos_infrastructure/service.go: QueryServerVersion; OSS-Fuzz Go
# path: go-118-fuzz-build -libfuzzer archive + clang++ ASan link), plus a dynamically-linked KAT
# oracle probe for mayhem/test.sh to run.
#
# Runs inside the commit image (GO mayhem/Dockerfile) as `mayhem` in /mayhem.
# GOROOT/GOPATH/GOMODCACHE are pinned by the Dockerfile ENV under /opt/toolchains
# (absolute, $HOME-independent — so the offline PATCH re-run finds the cache).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (online) fills $GOMODCACHE (the server module's deps + the /testing shim).
#   - GOPROXY points at the in-image module cache's file proxy FIRST, network LAST, so the offline
#     re-run resolves entirely from the cache; GOSUMDB=off keeps go.sum verification local.
#
# HARNESS STAGING: the harness and the KAT probe are copied into _mayhem_harness/ INSIDE the server
# module (they import its pkg/ packages). The shim dependency is added to a COPY of go.mod/go.sum
# (-modfile), so upstream's go.mod and go.sum stay untouched.
set -euo pipefail

: "${SRC:=/mayhem}"

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}"
: "${CXX:=clang++}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

# Sanitizers (§6.1): the OSS-Fuzz Go path is ASan-only for the libFuzzer link.
# Honor the knob — an explicit empty SANITIZER_FLAGS yields an un-sanitized build.
: "${SANITIZER_FLAGS=-fsanitize=address}"
export SANITIZER_FLAGS
GO_SAN="-fsanitize=address"
[ -n "${SANITIZER_FLAGS}" ] || GO_SAN=""

# Debug-info contract (§6.2 item 10): gc always emits DWARF4 with no knob, so we
# force the clang-compiled cgo C shims to DWARF3 (CGO_CFLAGS/CGO_CXXFLAGS) AND
# prepend a DWARF3 anchor.o at the final clang++ link so the FIRST .debug_info CU
# (what the gate reads) is DWARF < 4. $GO_DEBUG_FLAGS threads any base pins.
export GO_DEBUG_FLAGS="${GO_DEBUG_FLAGS:--gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:-} ${GO_DEBUG_FLAGS}"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:-} ${GO_DEBUG_FLAGS}"

# Resolve modules offline-first from the in-image cache; network only as fallback.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOSUMDB="${GOSUMDB:-off}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"

go version

TARGET="fuzz_serverversion"
SERVER="$SRC/chaoscenter/graphql/server"
STAGE="$SERVER/_mayhem_harness"
BUILD="$SRC/mayhem-build"

# Pseudo-version of the go-118-fuzz-build /testing shim that the Dockerfile's
# `go install ...@a70c2aa677fa...` already resolved + cached (a raw commit hash would force a
# proxy.golang.org round trip — fatal on the air-gapped PATCH re-run).
GO118_SHIM_VERSION="v0.0.0-20250520111509-a70c2aa677fa"

rm -rf "$STAGE" "$BUILD"
mkdir -p "$STAGE/serverversion" "$STAGE/kat" "$BUILD"
cp "$SRC/mayhem/harness_serverversion.go.src" "$STAGE/serverversion/harness.go"
cp "$SRC/mayhem/kat_serverversion.go.src"     "$STAGE/kat/main.go"

# Alternate module files: the shim requirement lands here, not in upstream's go.mod/go.sum.
cp "$SERVER/go.mod" "$BUILD/server.mod"
cp "$SERVER/go.sum" "$BUILD/server.sum"
export GOFLAGS="-mod=mod -modfile=$BUILD/server.mod"

(
  cd "$SERVER"
  go get "github.com/AdamKorcz/go-118-fuzz-build/testing@${GO118_SHIM_VERSION}"
)

# ── Build the libFuzzer archive from the staged package ────────────────────────
echo "=== go-118-fuzz-build $TARGET (func FuzzQueryServerVersion) ==="
(
  cd "$STAGE/serverversion"
  go-118-fuzz-build -func FuzzQueryServerVersion -o "$BUILD/$TARGET.a" .
)

# ── DWARF3 anchor FIRST, then clang++ ASan+fuzzer link ─────────────────────────
printf 'int __mayhem_dwarf3_anchor;\n' > "$BUILD/anchor.c"
$CC $GO_DEBUG_FLAGS -c "$BUILD/anchor.c" -o "$BUILD/anchor.o"
$CXX $GO_SAN $LIB_FUZZING_ENGINE \
     "$BUILD/anchor.o" "$BUILD/$TARGET.a" -o "/mayhem/$TARGET"
echo "built /mayhem/$TARGET"

# ── KAT oracle probe: dynamically-linked (cgo) so the sabotage shim can neuter it ─
export CGO_ENABLED=1
(
  cd "$STAGE/kat"
  go build -o /mayhem/litmus_serverversion_kat .
)
file /mayhem/litmus_serverversion_kat | grep -q 'dynamically linked' \
  || { echo "FATAL: /mayhem/litmus_serverversion_kat is not dynamically linked — oracle would be reward-hackable"; exit 1; }
echo "built /mayhem/litmus_serverversion_kat (dynamically linked)"

echo "build.sh complete"
