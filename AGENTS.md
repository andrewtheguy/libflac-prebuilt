# AGENTS.md

## Before `cargo` anything

Every crate here links the archive, so cargo cannot build until one exists:

```sh
./build.sh <target>     # the target this machine is (see build.sh's usage for the list)
./sync-prebuilt.sh      # dist/ -> crates/libflac-prebuilt-sys/prebuilt/
```

`./sync-prebuilt.sh --fetch` is the alternative once a release exists. Neither `clippy` nor
`test` works without one of the two, which is why CI runs clippy inside the build job rather
than beside it.

## This machine builds one target

`./build.sh` does not cross-compile: every check it makes reads the finished archive with the
platform's own tools. So a Mac builds `macos-arm64` and nothing else here, and the other targets
are exercised by `workflow_dispatch` on **Build libFLAC**, or on the machine each one is.

## Bootstrapping order

The download paths cannot pass before a release exists. On a fresh fork: run **Build libFLAC**
(`workflow_dispatch`, `targets: all`) by hand, then **Release libFLAC archives**. CI is green
from there on.

## What not to "fix"

- **No CPU floor on x86_64.** It is absent on purpose — libFLAC gives each SIMD kernel its own
  target attribute and dispatches at run time, so a `-march` floor costs compatibility and buys
  nothing. The README says why.
- **clang-cl on Windows, with `-clang:-fstrict-aliasing`.** Not cl, and not clang-cl as it
  comes: either leaves the FMA autocorrelation scalar, and the encoder two to three times
  slower than FLAC's own Windows release. Every symbol check still passes on such an archive,
  which is why `build.sh` reads the kernel's instructions. Do not replace that gate with a
  timing.
- **The `.res` member removed from the Windows archive** is the DLL's version resource, which
  FLAC's build archives into a static library too. Left in, every binary linking the archive
  inherits it.
- **`WITH_OGG=OFF` and `ENABLE_MULTITHREADING=OFF`** are deliberate and are real restrictions.
  A consumer that needs either wants `LIBFLAC_PREBUILT_DIR`.
- **No musl mapping in `build.rs`.** The glibc archives reference `fopen64` and its siblings
  from the encoder's and the decoder's own objects.
- **The `FILE*` calls left out of the bindings.** Binding them writes one libc's `FILE` layout
  into a file three platforms share.
