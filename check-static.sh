#!/usr/bin/env bash
# Assert that a binary carries libFLAC inside it rather than expecting to find one.
#
#   ./check-static.sh target/release/libflac-e2e
#
# Three questions, and they fail in different directions:
#
#   positive — is libFLAC actually *in* there? libFLAC compiles in the vendor string it writes
#             into every stream's header, `reference libFLAC <version> <date>`, so finding it in
#             the file's bytes says yes, and says *which* — a stronger answer than grepping for
#             a symbol, which does not tell one build of a library from another.
#   negative — is there a *dynamic* dependency on libFLAC as well or instead? This is the one
#             that passes every test on the build machine and then fails on a machine without
#             the library installed, which is precisely the failure this repository exists to
#             remove.
#   the C++ runtime — build.sh measures whether the archive needs one and records the answer in
#             the MANIFEST. libFLAC is C, so the answer is `none`; when the MANIFEST says so,
#             this requires the finished binary to have no libstdc++/libc++ dependency either.
#
# Run in CI on every target. A binary that links a system libFLAC by accident behaves
# identically to a correct one until it is copied somewhere else.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bin="${1:?usage: ./check-static.sh <binary>}"
[ -f "$bin" ] || { echo "no such file: $bin" >&2; exit 1; }

# shellcheck source=flac.env
. "$here/flac.env"

fail=0

echo ">> $bin"

# `grep -a`: treat the executable as text, which is portable in a way `nm` and `strings` are not.
if grep -aq "reference libFLAC ${FLAC_VERSION} " "$bin"; then
  echo "   ok    libFLAC ${FLAC_VERSION}'s vendor string is compiled in"
else
  echo "   FAIL  no 'reference libFLAC ${FLAC_VERSION}' string in the binary — is libFLAC really" >&2
  echo "         linked, and is it the pinned version?" >&2
  fail=1
fi

case "$(uname -s)" in
  Darwin) deps="$(otool -L "$bin" | tail -n +2 || true)" ;;
  MINGW* | MSYS* | CYGWIN*)
    # Windows, under an MSYS bash. `dumpbin /dependents` needs an MSVC environment this
    # script does not set up, so the PE import table is read the crude way: a DLL a binary
    # imports has its name stored, in ASCII, in the file. Enough to catch an accidental
    # `libFLAC.dll` import — the mistake being looked for — and to see the C++ runtime's
    # `msvcp140.dll` below.
    deps="$(grep -aoiE '[a-z0-9_.-]+\.dll' "$bin" | sort -u || true)"
    ;;
  *)      deps="$(ldd "$bin" 2>/dev/null || true)" ;;
esac

if flac_deps="$(printf '%s\n' "$deps" | grep -iE '(^|[^a-z])(lib)?flac[^a-z]')" && [ -n "$flac_deps" ]; then
  echo "   FAIL  dynamic dependency on libFLAC:" >&2
  printf '           %s\n' "$flac_deps" >&2
  fail=1
else
  echo "   ok    no dynamic libFLAC dependency"
fi

# What did build.sh measure for this target? Looked up rather than assumed, and skipped rather
# than guessed when there is no MANIFEST to read — a check that invents its own expectation is
# worse than one that says it did not run. **This** machine's target, by name: a tree copied to
# a build box carries whatever other targets' caches were in it, and the last MANIFEST found
# would be another target's measurement.
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) host_target=macos-arm64 ;;
  Linux-x86_64) host_target=linux-x86_64 ;;
  Linux-aarch64 | Linux-arm64) host_target=linux-aarch64 ;;
  MINGW*-x86_64 | MSYS*-x86_64 | CYGWIN*-x86_64) host_target=windows-x86_64-msvc ;;
  *) host_target=unknown ;;
esac
manifest=""
for candidate in "$here/dist/$host_target/MANIFEST" \
                 "$here/crates/libflac-prebuilt-sys/prebuilt/$host_target/MANIFEST"; do
  if [ -f "$candidate" ]; then
    manifest="$candidate"
    break
  fi
done

if [ -n "$manifest" ]; then
  cxx_runtime="$(sed -n 's/^cxx_runtime //p' "$manifest")"
  echo "   note  $(basename "$(dirname "$manifest")") MANIFEST says cxx_runtime: ${cxx_runtime:-<absent>}"
  if [ "$cxx_runtime" = "none" ]; then
    # `msvcp140.dll` is MSVC's C++ standard library; `vcruntime140.dll` beside it is the C
    # runtime every /MD binary imports and is not evidence of C++.
    if cxx_deps="$(printf '%s\n' "$deps" | grep -iE 'libstdc\+\+|libc\+\+|msvcp[0-9]+')" && [ -n "$cxx_deps" ]; then
      echo "   FAIL  the archive needs no C++ runtime, but the binary links one:" >&2
      printf '           %s\n' "$cxx_deps" >&2
      echo "         Nothing in this repository should emit -lstdc++/-lc++; check whether" >&2
      echo "         libFLAC++ got into the artifact." >&2
      fail=1
    else
      echo "   ok    no C++ runtime dependency, as the measurement predicted"
    fi
  fi
else
  echo "   note  no MANIFEST found — skipping the C++ runtime check"
fi

exit "$fail"
