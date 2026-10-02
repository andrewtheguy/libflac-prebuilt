#!/usr/bin/env bash
# Build one static libFLAC, with the claims about it verified rather than assumed.
#
# Usage:
#   ./build.sh <target>
#
# Targets:
#   macos-arm64          libFLAC.a  (Apple silicon, deployment target 11.0)
#   linux-x86_64         libFLAC.a  (x86-64 baseline; SSE2..AVX2/FMA kernels dispatched at run time)
#   linux-aarch64        libFLAC.a  (ARMv8-A baseline, where NEON is mandatory)
#   windows-x86_64-msvc  FLAC.lib   (x86-64 baseline, as above; clang-cl, MSVC ABI, dynamic CRT)
#
# Output: dist/<target>/{lib,include}/… plus a MANIFEST naming the version, the checksums, the
# cmake line, the CPU floor and — measured rather than assumed — whether the archive needs libm
# and whether it needs a C++ runtime.
#
# **FLAC's own CMake build, on the machine the target is.** Nothing is cross-compiled: the
# checks below run the platform's own tools over the finished archive, and an archive nothing
# read back is one nobody can vouch for.
#
# **The Windows archive is compiled by clang-cl, not by cl, and that was measured.** Both write
# COFF objects for the MSVC ABI against the dynamic CRT, so the archive links into a Rust
# binary for `x86_64-pc-windows-msvc` either way. What differs is one kernel. FLAC's FMA
# autocorrelation is plain C the compiler is expected to vectorise, and it can only do that
# knowing the `double` sums it writes are not the `float` samples it reads — type-based
# aliasing, which cl never assumes and clang-cl assumes only when told. Without it the kernel
# is scalar and the encoder runs at a third of the speed (cl) or a little over half (clang-cl
# as it comes) of FLAC's own Windows release; with it, it matches. See the vectorisation gate
# below, which is what keeps that from coming back.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
# shellcheck source=flac.env
. ./flac.env
# shellcheck source=source.sh
. ./source.sh

target="${1:-}"
[ -n "$target" ] || {
  sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d; s/^# \{0,1\}//'
  exit 1
}

src="$here/build/flac-${FLAC_VERSION}"
out="$here/dist/$target"

# ---------------------------------------------------------------- source

# Downloaded, checksummed and unpacked fresh by source.sh, which sync-prebuilt.sh also uses to
# take the headers from — the pin is one implementation, not two.
ensure_source

# ---------------------------------------------------------------- configure

# Common to every target.
#
# `WITH_OGG=OFF`: the consumers frame FLAC themselves, and an archive that found a libogg on
# the builder would need one on every consumer. Asserted below, not trusted.
#
# `ENABLE_MULTITHREADING=OFF`: FLAC 1.5 can spread an encode over threads through pthreads,
# which the MSVC ABI does not have, so leaving it on makes the Windows archive a different
# library from the others. A desktop's sound is one stream of twenty-millisecond blocks coded
# hundreds of times faster than real time on one thread.
#
# `WITH_FORTIFY_SOURCE=OFF` and `WITH_STACK_PROTECTOR=OFF`: both are properties of a *link*,
# and the binary this goes into chooses its own. On they also add `__*_chk` references a
# consumer's libc then has to provide.
#
# The programs, the C++ wrapper, the examples, the tests and the documentation are not the
# library. `flac` and `metaflac` are GPL; libFLAC is BSD-3-Clause, and it is all that is built.
#
# No install prefix in here, and that is deliberate: it is the one argument whose value is this
# machine's absolute path, and the MANIFEST records this list. `cmake --install --prefix` takes
# it instead.
cmake_args=(
  -DCMAKE_BUILD_TYPE=Release
  -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DWITH_OGG=OFF -DENABLE_MULTITHREADING=OFF
  -DWITH_FORTIFY_SOURCE=OFF -DWITH_STACK_PROTECTOR=OFF
  -DBUILD_CXXLIBS=OFF -DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF
  -DBUILD_DOCS=OFF -DINSTALL_MANPAGES=OFF
  -DINSTALL_PKGCONFIG_MODULES=OFF -DINSTALL_CMAKE_CONFIG_MODULE=OFF
)
# What cmake is told that names this machine — a compiler's path — and so stays out of the
# MANIFEST for the reason the prefix does.
local_args=()

# Note what no target passes: `-march`, `-mcpu`, `/arch`. Nothing may be tuned to the
# *builder's* CPU, because the archive is linked into binaries that run elsewhere, and nothing
# needs to be: FLAC gives each SIMD kernel its own target attribute and picks between them
# with cpuid at run time, so the archive runs on any x86-64 and uses AVX2 and FMA where the
# CPU has them. The verification below asserts the kernels are in there.
floor='unset'
deployment_target=''
# The archive's name follows the platform's convention — and rustc's: `static=FLAC` resolves
# to `FLAC.lib` on the MSVC target and to `libFLAC.a` everywhere else.
lib_name=libFLAC.a
# Set for the Windows target, whose tools are LLVM's and read paths spelled natively.
windows=0
np() { if [ "$windows" = 1 ]; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }

x86_floor='x86-64 baseline (runtime CPU detection: sse2..avx2 and fma kernels dispatched at run time)'
# GNU `ar`'s deterministic mode, named rather than left to how the distribution built binutils:
# without `D` each member carries an mtime and a uid, and two builds of identical objects
# differ. Apple's ar and LLVM's lib have no such flag to ask for, so the reproducibility job
# builds linux-x86_64 only.
deterministic_ar=(
  '-DCMAKE_C_ARCHIVE_CREATE=<CMAKE_AR> qcD <TARGET> <LINK_FLAGS> <OBJECTS>'
  '-DCMAKE_C_ARCHIVE_FINISH=<CMAKE_RANLIB> -D <TARGET>'
)

case "$target" in
  macos-arm64)
    # Named, so the archive does not inherit the builder's OS version as its minimum. Lower
    # than any consumer targets; the verification below reads it back off the archive.
    deployment_target=11.0
    cmake_args+=(-DCMAKE_OSX_ARCHITECTURES=arm64 "-DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target")
    floor='armv8-a (neon, which the architecture requires)'
    ;;
  linux-x86_64)
    cmake_args+=("${deterministic_ar[@]}")
    floor="$x86_floor"
    ;;
  linux-aarch64)
    cmake_args+=("${deterministic_ar[@]}")
    floor='armv8-a (neon, which the architecture requires)'
    ;;
  windows-x86_64-msvc)
    windows=1
    lib_name=FLAC.lib
    floor="$x86_floor"
    command -v clang-cl >/dev/null 2>&1 || {
      echo "clang-cl is not on PATH — install LLVM and put its bin directory on PATH" >&2
      exit 1
    }
    command -v nmake >/dev/null 2>&1 || {
      echo "nmake is not on PATH — run this from a VS developer environment" >&2
      exit 1
    }
    # NMake rather than the Visual Studio generator, which would compile with cl whatever
    # compiler is named. C++ is named too although nothing C++ is built: FLAC's project
    # enables both languages, and cmake refuses a clang-cl paired with cl.
    #
    # `-clang:-fstrict-aliasing` is the reason this target exists in this form — see the note
    # at the top. The dash spelling, because an MSYS shell rewrites an argument that starts
    # with a slash into a path.
    cmake_args+=(-G 'NMake Makefiles' -DCMAKE_C_FLAGS=-clang:-fstrict-aliasing)
    clang_cl="$(cygpath -m "$(command -v clang-cl)")"
    local_args+=("-DCMAKE_C_COMPILER=$clang_cl" "-DCMAKE_CXX_COMPILER=$clang_cl")
    ;;
  *)
    echo "unknown target: $target" >&2
    exit 1
    ;;
esac

rm -rf "$out" "build/$target"
mkdir -p "build/$target" "$out/lib"

echo ">> configuring libFLAC ${FLAC_VERSION} for $target"
# cmake's own chatter goes to a log that is shown only when a step fails: on success the lines
# worth reading are the ones this script prints.
log="build/$target/build.log"
run_logged() {
  "$@" >>"$log" 2>&1 || {
    cat "$log" >&2
    echo "failed: $*" >&2
    exit 1
  }
}
run_logged cmake -S "$(np "$src")" -B "$(np "$here/build/$target")" "${cmake_args[@]}" \
  "${local_args[@]+"${local_args[@]}"}"

echo ">> building"
jobs="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
if [ "$windows" = 1 ]; then
  # nmake takes no job count.
  run_logged cmake --build "$(np "$here/build/$target")" --target FLAC
else
  run_logged cmake --build "build/$target" --target FLAC -j"$jobs"
fi
run_logged cmake --install "$(np "$here/build/$target")" --prefix "$(np "$out/prefix")"

# ---------------------------------------------------------------- collect

cp "$out/prefix/lib/$lib_name" "$out/lib/$lib_name"
# The whole installed `include/FLAC`, not a hand-picked list: FLAC's own build decides what its
# public headers are, and sync-prebuilt.sh diffs this directory against the committed one.
# `include/FLAC++` is installed beside it whether or not the C++ wrapper is built, and is left
# behind, since nothing here could link what it declares.
mkdir -p "$out/include"
cp -R "$out/prefix/include/FLAC" "$out/include/FLAC"
rm -rf "$out/prefix"
# libFLAC's licence and the names it asks to be kept with it, from the same verified tarball.
# Whoever links this redistributes libFLAC, and BSD-3-Clause requires the notice to go along.
cp "$src/COPYING.Xiph" "$src/AUTHORS" "$out/include/"

# ---------------------------------------------------------------- verify

# Which tools. GNU and Apple nm read their own platform's archives; a COFF `.lib` is read by
# LLVM's, which sit beside clang-cl.
case "$target" in
  windows-*)
    for tool in llvm-nm llvm-objdump llvm-readobj llvm-ar; do
      command -v "$tool" >/dev/null 2>&1 || {
        echo "$tool is not on PATH — install LLVM and put its bin directory on PATH" >&2
        exit 1
      }
    done
    nm_tool=llvm-nm
    ;;
  *) nm_tool="nm" ;;
esac
list_symbols() {
  # $1: --defined-only or --undefined-only. Member headers (`name.o:` lines) are dropped so a
  # symbol list is only symbols.
  "$nm_tool" "$1" "$(np "$out/lib/$lib_name")" | grep -v ':$'
}

if [ "$windows" = 1 ]; then
  # FLAC lists `version.rc` among the library's sources, for the DLL it usually is. The NMake
  # generator compiles it and archives the result, so the static library would hand every
  # binary that links it a VERSIONINFO naming it libFLAC — and a binary with a version
  # resource of its own a duplicate. It is taken out, by whatever name it was archived under,
  # and the check below then holds every remaining member to being object code.
  echo ">> removing the DLL's version resource from the archive"
  resources="$(llvm-ar t "$(np "$out/lib/$lib_name")" | tr -d '\r' | grep -E '\.res$' || true)"
  [ -n "$resources" ] || {
    echo "no .res member in $lib_name — FLAC's build changed; read this step again" >&2
    exit 1
  }
  while IFS= read -r member; do
    MSYS2_ARG_CONV_EXCL='*' llvm-ar d "$(np "$out/lib/$lib_name")" "$member"
    echo "   $member"
  done <<<"$resources"

  echo ">> verifying the archive holds x86-64 object code"
  # Every member, not a sample. An archive of anything else — LTO bitcode, were `-flto` ever
  # to reach the line — is one only the toolchain that wrote it can link.
  members="$(llvm-ar t "$(np "$out/lib/$lib_name")" | wc -l | tr -d ' ')"
  headers="$(llvm-readobj --file-headers "$(np "$out/lib/$lib_name")" 2>"build/$target/readobj.err" | grep -c '^Format: COFF-x86-64' || true)"
  if [ -s "build/$target/readobj.err" ] || [ "$headers" != "$members" ]; then
    echo "$lib_name: $headers of $members members are x86-64 COFF objects" >&2
    head -3 "build/$target/readobj.err" >&2 || true
    exit 1
  fi
  echo "   $members members, all COFF-x86-64"
fi

echo ">> verifying the entry points are in the archive"
# The calls a consumer coding a stream makes, the version string build.rs's consumers compare,
# and `set_do_md5`, which FLAC declares in a private header and exports all the same.
entry_points='FLAC__stream_encoder_new FLAC__stream_encoder_delete
              FLAC__stream_encoder_set_streamable_subset FLAC__stream_encoder_set_do_md5
              FLAC__stream_encoder_set_channels FLAC__stream_encoder_set_bits_per_sample
              FLAC__stream_encoder_set_sample_rate FLAC__stream_encoder_set_blocksize
              FLAC__stream_encoder_set_compression_level FLAC__stream_encoder_init_stream
              FLAC__stream_encoder_process_interleaved FLAC__stream_encoder_finish
              FLAC__stream_encoder_get_resolved_state_string
              FLAC__stream_decoder_new FLAC__stream_decoder_delete
              FLAC__stream_decoder_init_stream FLAC__stream_decoder_process_until_end_of_stream
              FLAC__stream_decoder_get_decode_position FLAC__stream_decoder_finish
              FLAC__stream_decoder_get_resolved_state_string FLAC__VERSION_STRING'

# No `2>/dev/null || true` on this: an nm that cannot read the archive would produce an empty
# symbol list, and an empty list makes every check below report a *missing* symbol. That is a
# measurement failure wearing the costume of a build failure, so it stops here.
symbols="$(list_symbols --defined-only)" || {
  echo "$nm_tool could not read $out/lib/$lib_name — nothing below was measured" >&2
  exit 1
}
# A here-string rather than `printf … | grep -q`: under `set -o pipefail`, grep -q exits on the
# first match, the writer takes SIGPIPE, and a *found* symbol reads as a missing one.
# `[ _]` because Mach-O prefixes every C symbol with an underscore and ELF and COFF do not.
defined() { grep -qE "[ _]$1$" <<<"$symbols"; }
for symbol in $entry_points; do
  defined "$symbol" || {
    echo "$symbol is not defined in $lib_name — this is not a complete libFLAC" >&2
    exit 1
  }
done
echo "   $(wc -w <<<"$entry_points" | tr -d ' ') entry points defined"

# The SIMD kernels, by name: the ones the encoder's dispatch picks on a current CPU. A count
# would pass an archive that kept some and lost the one that matters.
echo ">> verifying the SIMD kernels are in the archive"
case "$target" in
  linux-x86_64 | windows-x86_64-msvc)
    kernels='FLAC__lpc_compute_autocorrelation_intrin_fma_lag_8
             FLAC__lpc_compute_autocorrelation_intrin_fma_lag_12
             FLAC__lpc_compute_autocorrelation_intrin_fma_lag_16
             FLAC__lpc_compute_residual_from_qlp_coefficients_16_intrin_avx2
             FLAC__lpc_compute_residual_from_qlp_coefficients_intrin_avx2
             FLAC__lpc_compute_residual_from_qlp_coefficients_wide_intrin_avx2
             FLAC__precompute_partition_info_sums_intrin_avx2
             FLAC__fixed_compute_best_predictor_wide_intrin_avx2
             FLAC__fixed_compute_best_predictor_intrin_ssse3
             FLAC__lpc_compute_autocorrelation_intrin_sse2_lag_8
             FLAC__lpc_compute_residual_from_qlp_coefficients_intrin_sse41'
    kernel_name='SSE2..AVX2 and FMA'
    ;;
  macos-arm64 | linux-aarch64)
    kernels='FLAC__lpc_compute_autocorrelation_intrin_neon_lag_8
             FLAC__lpc_compute_autocorrelation_intrin_neon_lag_10
             FLAC__lpc_compute_autocorrelation_intrin_neon_lag_14
             FLAC__lpc_compute_residual_from_qlp_coefficients_intrin_neon
             FLAC__lpc_compute_residual_from_qlp_coefficients_wide_intrin_neon'
    kernel_name='NEON'
    ;;
esac
for symbol in $kernels; do
  defined "$symbol" || {
    echo "$symbol is not defined in $lib_name — the SIMD build did not happen" >&2
    exit 1
  }
done
simd_evidence="$(wc -w <<<"$kernels" | tr -d ' ') $kernel_name kernels"
echo "   $simd_evidence"

# And that the FMA autocorrelation is *vectorised*, which its being present does not say.
#
# It is the one kernel written as plain C under a target attribute rather than with
# intrinsics, so the compiler decides what it becomes, and on a current CPU it is the largest
# single cost of an encode. Measured on the Windows archive: compiled without type-based
# aliasing it is scalar, takes half to three quarters of the encoder's time, and every symbol
# check above still passes. So the instructions are read: packed double-precision FMA, three
# times over — once in each of the three lags.
if [ "$kernel_name" != 'NEON' ]; then
  echo ">> verifying the FMA autocorrelation is vectorised"
  case "$target" in
    windows-*)
      # The one member, taken out of the archive first: asked for a symbol across the whole
      # archive, llvm-objdump warns once for every member that does not define it.
      fma_member="$(llvm-ar t "$(np "$out/lib/$lib_name")" | tr -d '\r' | grep -E 'lpc_intrin_fma\.c\.obj$')" || {
        echo "no lpc_intrin_fma member in $lib_name — whether it is vectorised was not measured" >&2
        exit 1
      }
      MSYS2_ARG_CONV_EXCL='*' llvm-ar p "$(np "$out/lib/$lib_name")" "$fma_member" > "build/$target/lpc_intrin_fma.obj"
      disassemble() { llvm-objdump -d --no-show-raw-insn "--disassemble-symbols=$1" "$(np "$here/build/$target/lpc_intrin_fma.obj")"; }
      ;;
    *) disassemble() { objdump -d --no-show-raw-insn "--disassemble=$1" "$out/lib/$lib_name"; } ;;
  esac
  for lag in 8 12 16; do
    kernel="FLAC__lpc_compute_autocorrelation_intrin_fma_lag_$lag"
    listing="$(disassemble "$kernel")" || {
      echo "could not disassemble $kernel — whether it is vectorised was not measured" >&2
      exit 1
    }
    packed="$(grep -cE 'vfn?m(add|sub)[0-9]+pd' <<<"$listing" || true)"
    [ "${packed:-0}" -gt 0 ] || {
      echo "$kernel has no packed FMA instruction — the compiler left it scalar, and the" >&2
      echo "  encoder built from this archive is two to three times slower than it should be." >&2
      exit 1
    }
  done
  simd_evidence="$simd_evidence, fma autocorrelation vectorised"
  echo "   packed FMA in all three lags"
fi

# Which runtime libraries this archive needs — measured, not assumed, because build.rs reads
# the answers out of the MANIFEST and emits link flags from them.
echo ">> measuring the runtime requirements"
# Again with nm's failure kept loud: "no undefined libm symbols" is a legitimate answer that
# goes into the MANIFEST as `libm none`, and an nm that failed silently produces the same list.
undefined_raw="$(list_symbols --undefined-only)" || {
  echo "$nm_tool could not read $out/lib/$lib_name — the runtime requirements were not measured" >&2
  exit 1
}
undefined="$(awk '{print $NF}' <<<"$undefined_raw" | sort -u)"

# The greps below are the one place where "found nothing" is an answer rather than a fault, so
# they accept exit 1 and nothing else: exit 2 is grep saying it could not search.
measure() {
  # $1: what is being measured, $2: the pattern. Echoes the matches on one line.
  local status=0 matches
  matches="$(grep -E "$2" <<<"$undefined")" || status=$?
  [ "$status" -le 1 ] || {
    echo "grep failed ($status) while measuring $1 — the requirement is unknown, not absent" >&2
    exit 1
  }
  tr '\n' ' ' <<<"$matches" | sed 's/ *$//'
}

# Ogg. `WITH_OGG=OFF` is on the line above; a libogg found anyway would show as these.
ogg="$(measure Ogg '^_?(ogg|oggpack)_')"
[ -z "$ogg" ] || {
  echo "the archive references libogg ($ogg) — WITH_OGG=OFF did not take" >&2
  exit 1
}
echo "   no Ogg, as configured"

# Threads, for the same reason.
threads="$(measure pthreads '^_?pthread_')"
[ -z "$threads" ] || {
  echo "the archive references pthreads ($threads) — ENABLE_MULTITHREADING=OFF did not take" >&2
  exit 1
}
echo "   no threads, as configured"

# libm. FLAC's windows and its bit estimates use cos, exp and log, so `required` is expected —
# and it is what makes the difference between a Linux consumer linking `-lm` and a page of
# undefined symbols.
libm_symbols="$(measure libm '^_?(pow|exp|log|log2|log10|sqrt|floor|ceil|fabs|atan2?|sin|cos|round|lround|fmod|frexp)f?$')"
case "$target" in
  windows-*)
    # The same functions are undefined here too, and they are in the CRT every Rust binary on
    # the target already links: there is no `m.lib`. `none` is the answer build.rs parses.
    libm='none'
    echo "   libm: none — ${libm_symbols:-nothing} undefined, and in the CRT"
    ;;
  *)
    if [ -z "$libm_symbols" ]; then
      libm='none'
      echo "   libm: none"
    else
      libm="required: $libm_symbols"
      echo "   libm: $libm_symbols"
    fi
    ;;
esac

# The C++ runtime. libFLAC is C and `BUILD_CXXLIBS=OFF` keeps libFLAC++ out, so the answer
# should be `none`, which is a property worth keeping rather than assuming.
case "$target" in
  windows-*) cxx_pattern='^(\?\?[23]@YA|\?.*@std@@|__CxxFrameHandler|_CxxThrowException)' ;;
  *) cxx_pattern='^_?(_Zn[wa]|_Zd[la]|_ZN?St|__cxa_|__gxx_personality|_Unwind_)' ;;
esac
cxx_undefined="$(measure 'the C++ runtime' "$cxx_pattern")"
if [ -z "$cxx_undefined" ]; then
  cxx_runtime='none'
  echo "   cxx_runtime: none — the archive needs no libstdc++/libc++"
else
  cxx_runtime="required: $cxx_undefined"
  echo "   cxx_runtime: $cxx_runtime"
fi

# The CRT, read back off the archive. Every object compiled for the MSVC ABI records the CRT it
# was compiled against as a `/DEFAULTLIB` directive: `msvcrt` is the dynamic one Rust links,
# `libcmt` the static one that would fail the consumer's link.
crt='n/a'
if [ "$windows" = 1 ]; then
  echo ">> verifying the CRT the objects name"
  directives="$(llvm-readobj --coff-directives "$(np "$out/lib/$lib_name")" | grep -ioE 'DEFAULTLIB:"?[A-Za-z0-9_.]+' | tr -d '"' | sort -uf)"
  grep -qiE 'DEFAULTLIB:msvcrt(\.lib)?$' <<<"$directives" || {
    echo "no /DEFAULTLIB:msvcrt directive in $lib_name — the objects do not name the dynamic CRT" >&2
    printf '  %s\n' "$directives" >&2
    exit 1
  }
  if grep -qi 'DEFAULTLIB:libcmt' <<<"$directives"; then
    echo "a /DEFAULTLIB:libcmt directive is in $lib_name — some object was built against the static CRT" >&2
    printf '  %s\n' "$directives" >&2
    exit 1
  fi
  crt='dynamic (MSVCRT)'
  echo "   $crt, and no LIBCMT"

  # Debug information, the same way. An object compiled with it records the path of a PDB that
  # is not shipped, and a consumer's linker warns LNK4099 once per member looking for it.
  echo ">> verifying the objects name no PDB"
  if grep -aqE '[A-Za-z0-9_:./\\-]+\.pdb' "$out/lib/$lib_name"; then
    echo "$lib_name was compiled with debug information and names a PDB that is not shipped:" >&2
    grep -aoE '[A-Za-z0-9_:./\\-]+\.pdb' "$out/lib/$lib_name" | sort -u >&2
    exit 1
  fi
  echo "   none"
fi

# The deployment target, read back off the archive rather than trusted from the flag.
if [ -n "$deployment_target" ]; then
  echo ">> verifying the deployment target"
  minos="$(otool -l "$out/lib/$lib_name" 2>/dev/null | awk '/minos/ {print $2}' | sort -u)"
  [ "$minos" = "$deployment_target" ] || {
    echo "the archive claims minos '$minos', not $deployment_target" >&2
    echo "  (more than one value means some objects missed the flag)" >&2
    exit 1
  }
  echo "   minos $minos on every member"
  floor="$floor, macOS $deployment_target"
fi

echo ">> checksumming the archive"
# The library's own hash, not the tarball's. A .tar.gz is not reproducible — gzip stamps an
# mtime into its header — so the wrapper's checksum can only say "these are the bytes that
# were published". This one says *this is the same library*, comparable across runs.
lib_sha="$(sha256_of "$out/lib/$lib_name")"
echo "   $lib_sha"

{
  echo "libflac $FLAC_VERSION"
  echo "target $target"
  echo "sha256(source) $FLAC_SHA256"
  echo "sha256(library) $lib_sha"
  echo "library lib/$lib_name"
  echo "cpu_floor $floor"
  echo "libm $libm"
  echo "cxx_runtime $cxx_runtime"
  echo "crt $crt"
  echo "simd_evidence $simd_evidence"
  echo "cmake_args ${cmake_args[*]}"
} > "$out/MANIFEST"

echo ">> wrote $out"
cat "$out/MANIFEST"
