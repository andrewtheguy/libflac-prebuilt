# libflac-prebuilt

Static **libFLAC 1.5.0**, built once so that nothing which *links* it needs a build system, and
nothing which *ships* it needs to bring a shared library along.

```toml
flac-sys = { package = "libflac-prebuilt-sys", git = "https://github.com/andrewtheguy/libflac-prebuilt", tag = "v1.5.0-…" }
```

No cmake, no pkg-config, no libclang, and nothing to set in the environment — not in a
Dockerfile, not in a packaging script, not in CI. `build.rs` downloads the archive for its target
from this repository's latest release, checks it, and emits the link flags. There is one
variable, `LIBFLAC_PREBUILT_DIR`, and it is an opt-in override for an archive you built yourself
([below](#local-loop)); the default path needs none.

That is the whole point. The alternatives all move work onto every consumer, or onto every
package that carries the consumer:

| approach | what it costs |
|---|---|
| a system libFLAC via `pkg-config` | libFLAC and its headers installed to build, and a runtime dependency in the finished binary |
| loading the shared library at run time | nothing to build — and a package dependency, a bundled `.dylib` or a bundled `.dll` for every artifact, with two library versions to stay compatible with |
| **this** | curl and tar, once, at build time |

## Layout

```
flac.env                         the pin: version, tarball checksum, upstream, release repo
source.sh                        download + check the checksum (sourced by the two scripts below)
build.sh <target>                cmake, build, verify, write dist/<target>/MANIFEST
sync-prebuilt.sh                 dist/ -> the crate's cache; --headers; --check; --fetch
check-static.sh <binary>         assert a finished binary carries libFLAC and links none
crates/libflac-prebuilt-sys/     the FFI crate: committed headers, committed bindings, build.rs
  gen-bindings.sh                regenerate or --check the bindings (bindgen 0.72.1)
  bindgen-stubs/stdio.h          what bindgen reads instead of the C library's, so no libc's FILE is bound
crates/libflac-e2e/              a consumer that encodes and decodes, run on every target in CI
```

Targets: `macos-arm64`, `linux-x86_64`, `linux-aarch64`, `windows-x86_64-msvc`. The Windows
archive is `FLAC.lib`, MSVC-ABI objects against the dynamic CRT (`/MD`), for
`x86_64-pc-windows-msvc` only, and it is compiled by clang-cl ([below](#windows-is-compiled-by-clang-cl)).
No musl: the glibc archives reference glibc's 64-bit file calls.

## The chain

Every link is checked, and CI checks all of them:

```
flac.env pins a tarball's sha256
  -> source.sh checks it before anything is unpacked
    -> build.sh compiles that tree and writes sha256(library) into a MANIFEST
      -> the release publishes the archive plus SHA256SUMS
        -> build.rs verifies the download against SHA256SUMS
          -> and the extracted library against the MANIFEST beside it, on every path
```

Separately, and this is the part a reviewer can read:

```
include/FLAC/   is byte-identical to the pinned release's headers   (sync-prebuilt.sh --check)
                and to what the install step produced in a real build (the same, with dist/ present)
src/bindings.rs is what bindgen 0.72.1 makes of those headers       (gen-bindings.sh --check)
```

## What is in the archive

libFLAC, whole, and only it: the stream encoder and decoder and the metadata interfaces. No
`flac`, no `metaflac`, no libFLAC++. **No Ogg** and **no encoder threads**
(`WITH_OGG=OFF`, `ENABLE_MULTITHREADING=OFF`): the project this was built for frames FLAC
itself and codes one stream of twenty-millisecond blocks, and threads through pthreads would
make the Windows archive a different library from the others.

The build then asserts what it configured, rather than trusting it:

- the calls a consumer coding a stream makes are defined, `FLAC__stream_encoder_set_do_md5`
  among them — FLAC declares it in a private header and exports it all the same;
- the archive references neither libogg nor pthreads;
- the SIMD kernels the encoder dispatches to are present **by name**: eleven on x86-64, five on
  arm64;
- on x86-64, the FMA autocorrelation is **vectorised**, read off its instructions
  ([below](#windows-is-compiled-by-clang-cl));
- `libm` and the C++ runtime requirements are *measured* from the undefined symbols, and
  `build.rs` emits `-lm` on Linux because of what was measured rather than because of a guess;
- on macOS the deployment target is read back off the finished archive (`minos 11.0`);
- on Windows every member is an x86-64 COFF object naming the dynamic CRT and no PDB, and the
  DLL's version resource, which FLAC's build archives into a static library too, has been
  taken out.

## No CPU floor, deliberately

This repository names no floor above the x86-64 baseline. libFLAC gives each of its SSE2, SSSE3,
SSE4.1, SSE4.2, AVX2 and FMA kernels its own target attribute and picks between them with cpuid
when an encoder or decoder is set up, so a `-march` floor cannot decide whether they are
compiled or whether they are called. The archive runs on any x86-64 and uses AVX2 and FMA where
the CPU has them, and what the build asserts instead is that the kernels are in there.

## Windows is compiled by clang-cl

Not by cl, and that was measured. One of libFLAC's kernels — the FMA autocorrelation, the
largest single cost of an encode on a current CPU — is written as plain C under a target
attribute and left to the compiler to vectorise. It can only do that knowing the `double` sums
the loop writes are not the `float` samples it reads: type-based aliasing, which cl never
assumes and clang-cl assumes only when told. Encoding ten minutes of 48 kHz stereo in
960-sample blocks, on one machine:

| build | × real time |
|---|---|
| cl | 154–158 |
| clang-cl as it comes | 282–307 |
| clang-cl with `-clang:-fstrict-aliasing` | 554–574 |
| FLAC's own Windows release (`libFLAC.dll`, MinGW) | 446–534 |

Every one of the three static builds contains every kernel, so no symbol check tells them apart.
`build.sh` therefore disassembles the kernel and requires packed FMA instructions in each of
its three lags: none in the first two builds, dozens in the third.

## Local loop

```sh
./build.sh <target>             # -> dist/<target>/{lib,include,MANIFEST}
./sync-prebuilt.sh              # -> crates/libflac-prebuilt-sys/prebuilt/, what cargo will link
cargo run --release -p libflac-e2e
./check-static.sh target/release/libflac-e2e
```

`<target>` is the one this machine *is*. `./build.sh` does not cross-compile; the others are a
`workflow_dispatch` on **Build libFLAC** away. On Windows it runs under a bash (Git's or MSYS2's)
inside a VS developer environment, with LLVM's `bin` on PATH.

A build that has already resolved an archive keeps it: cargo runs `build.rs` again when
`prebuilt/`, `flac.env` or `LIBFLAC_PREBUILT_DIR` changes, and not when a new release is
published. `cargo clean -p libflac-prebuilt-sys` in the consuming project makes the next build
ask which release is latest.

`./sync-prebuilt.sh --fetch` pulls the latest release's archives instead, for working offline
afterwards or for a target this machine cannot build. `LIBFLAC_PREBUILT_DIR=/prefix` is the one
variable a consumer ever sets, and it is never required: it points `build.rs` at an archive you
built yourself instead of at a downloaded one — the escape hatch for an unsupported target, for
Ogg, or for encoder threads — and `build.rs` warns that nothing about it was checked.

## Bootstrapping

The download-based paths cannot pass before the first release exists, so the order for a fresh
fork is: run **Build libFLAC** by hand (`workflow_dispatch`, `targets: all`), then **Release
libFLAC archives**. CI is green from that point on.

## Which library got linked

```sh
cargo build -vv 2>&1 | grep 'libFLAC '
```

`build.rs` emits the provenance, the version, the checksum result, the CPU floor and the SIMD
evidence as `cargo:info` lines — not warnings, because this is the normal case and a warning on
every build teaches people to ignore warnings. At run time `flac_sys::version()` returns what
the archive itself reports, and `flac_sys::PREBUILT_VERSION` is what this repository pinned; the
e2e binary asserts they agree, which is how a system library winning the link would be caught.

## Licensing

libFLAC is **BSD-3-Clause** — `COPYING.Xiph` in FLAC's tree, shipped in every archive beside
`AUTHORS` and at this repository's root as `LICENSE`. The `flac` and `metaflac` programs are GPL
and FLAC's documentation is under the GFDL; neither is built or shipped here.
