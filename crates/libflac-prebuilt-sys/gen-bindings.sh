#!/usr/bin/env bash
# Regenerate the bindings for *this platform family* from the committed libFLAC headers.
#
#   ./gen-bindings.sh            # rewrite src/bindings.rs, or src/bindings_windows.rs on Windows
#   ./gen-bindings.sh --check    # fail if that file is not what the headers say
#
# Why generated and committed rather than generated at build time: bindgen needs libclang, and
# a `-sys` crate whose entire selling point is that a consumer needs no C toolchain cannot then
# require an LLVM installation to build.
#
# One file for macOS and both Linux architectures, and that is sound rather than lucky: bindgen
# emits `::std::os::raw::c_int`, `c_long` and `c_char` as *aliases*, which each target resolves
# for itself, and what is left of the headers once the `FILE*` calls are out (below) is
# fixed-width integers, pointers and enums.
#
# **Windows is a second file, and that was measured rather than assumed.** The MSVC ABI packs
# bit-fields differently: `FLAC__StreamMetadata_CueSheet_Track`, whose two one-bit flags sit
# between a `char[13]` and a byte, is 40 bytes there and 32 everywhere else, and the layout
# assertion for it fails to *compile* against the other file (which is the assertion doing its
# job). A C enum is also always `int` to that ABI, where clang on the other targets types one
# with no negative values `unsigned` — only an alias, but one `--check` would report as drift
# on every run. So `bindings_windows.rs` is generated on Windows and lib.rs selects it by
# `cfg(windows)`. Both files come from the same committed headers.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../flac.env
. ../../flac.env

# Pinned, because bindgen's output is not stable across its own versions — field ordering, the
# shape of the generated enum constants and the layout tests have all changed between releases.
# An unpinned generator turns `--check` into a test of which bindgen the runner happened to
# install.
BINDGEN_VERSION=0.72.1

# Which file this machine generates: the committed file should be what the platform's own SDK
# produces, and that is also what CI checks it against.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) out=src/bindings_windows.rs; platform=windows ;;
  *) out=src/bindings.rs; platform=unix ;;
esac

command -v bindgen >/dev/null 2>&1 || {
  echo "bindgen is not installed. cargo install bindgen-cli --version $BINDGEN_VERSION --locked" >&2
  exit 1
}
actual_version="$(bindgen --version | awk '{print $2}')"
[ "$actual_version" = "$BINDGEN_VERSION" ] || {
  echo "bindgen $actual_version is installed but this file is generated with $BINDGEN_VERSION" >&2
  echo "  cargo install bindgen-cli --version $BINDGEN_VERSION --locked --force" >&2
  exit 1
}

# The output is LF regardless of where it was made: on Windows rustfmt writes CRLF, and a
# committed file with two line-ending conventions across three platforms would be one that
# `--check` reports stale on whichever platform did not write it.
generate() { generate_raw | tr -d '\r'; }
generate_raw() {
  # Layout checks kept, deliberately — no `--no-layout-tests`. They are what makes committing
  # *one* bindings.rs for three targets an assertion rather than an assumption:
  # `FLAC__StreamMetadata` and `FLAC__Frame` are structures a callback reads by field while
  # libFLAC wrote them by offset. bindgen 0.72 emits the checks as
  # `const _: () = { ["Size of X"][size_of::<X>() - N]; }`, which fails at **compile** time, so
  # a consumer who never runs a test still cannot build against a struct that packs
  # differently on their target.
  #
  # `--default-enum-style consts` rather than rustified enums: libFLAC hands its states and
  # statuses back as C enums a later release may extend. A Rust enum with an unlisted
  # discriminant is undefined behaviour; a constant is a number.
  #
  # `--rust-target` pinned for the same reason the bindgen version is, and it is the one flag
  # that decides this crate's MSRV: from 1.82 bindgen emits `unsafe extern "C" { … }` blocks,
  # which do not parse on an older compiler.
  #
  # **The `FILE*` calls are left out**, and with them the C library's `FILE`: the four
  # `…_init_FILE` and `…_init_ogg_FILE` functions take a stream the caller opened, and binding
  # them writes one libc's private `FILE` layout into a file three platforms share. Blocking
  # the functions is not enough — bindgen still emits the types their signatures reach, under
  # a different name on every libc — so `bindgen-stubs/stdio.h` stands in for the real header
  # and gives `FILE` one name with nothing behind it, which is blocked too. `…_init_file`,
  # which takes a path, stays.
  #
  # `-DFLAC__NO_DLL`: the archive is static, and without it the Windows headers declare every
  # function `dllimport`.
  #
  # `MSYS2_ARG_CONV_EXCL`: bindgen is a native Windows program, and MSYS2 rewrites arguments
  # that look like POSIX paths on the way to one. Nothing here is an absolute path, so
  # conversion is turned off for the call; elsewhere the variable is unread. The allowlist regex
  # accepts both path separators for the same reason: on Windows clang reports the header as
  # `include\FLAC\format.h`.
  MSYS2_ARG_CONV_EXCL='*' bindgen wrapper.h \
    --rust-target 1.81 \
    --allowlist-file '.*[/\\]FLAC[/\\].*' \
    --blocklist-function '.*_init(_ogg)?_FILE' \
    --blocklist-type 'FILE' \
    --blocklist-type 'FLAC_SYS_NO_FILE' \
    --default-enum-style consts \
    --no-doc-comments \
    --raw-line "// @generated by gen-bindings.sh from the libFLAC $FLAC_VERSION headers in" \
    --raw-line "// include/FLAC/ — do not edit. Regenerate with bindgen $BINDGEN_VERSION on a $platform host." \
    --raw-line "//" \
    --raw-line "// \`--allowlist-file\` restricts this to items declared by libFLAC's own headers," \
    --raw-line "// and the calls that take a C \`FILE*\` are left out with the type they need." \
    --raw-line "#![allow(non_upper_case_globals, non_camel_case_types, non_snake_case)]" \
    -- -I bindgen-stubs -I include -DFLAC__NO_DLL
}

if [ "${1:-}" = "--check" ]; then
  # Compared as text rather than by regenerating in place and asking git: this has to work in a
  # CI job that has not necessarily checked out with a clean tree, and the diff is worth
  # printing either way.
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  generate > "$tmp"
  if diff -u --strip-trailing-cr "$out" "$tmp"; then
    echo "$out matches the committed libFLAC $FLAC_VERSION headers"
    exit 0
  fi
  echo "$out is stale — run gen-bindings.sh" >&2
  exit 1
fi

# Generated beside the target and renamed onto it, rather than redirected straight into it: a
# `> "$out"` truncates the committed bindings *before* bindgen runs, so a failed generation —
# a missing header, a clang that cannot parse one — leaves the crate with an empty bindings.rs
# and no way back except git.
tmp="$(mktemp "$out.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
generate > "$tmp"
chmod 644 "$tmp"
mv "$tmp" "$out"
trap - EXIT
echo "wrote $out ($(wc -l < "$out" | tr -d ' ') lines from libFLAC $FLAC_VERSION)"
