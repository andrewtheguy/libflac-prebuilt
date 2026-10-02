//! Raw FFI for libFLAC's stream encoder and decoder, linked from a prebuilt static archive.
//!
//! This crate builds no C. `build.rs` finds an archive that was already built — by `./build.sh`
//! locally, or by this repository's release pipeline — verifies it against its own MANIFEST,
//! and emits the link flags. A consumer needs no cmake, no pkg-config and no LLVM, and the
//! binary it builds loads no `libFLAC.so`, `.dylib` or `.dll`.
//!
//! Everything public comes from [`bindings`], which is bindgen's output over the headers
//! committed in `include/FLAC/` and re-exported at the crate root, so
//! `flac_sys::FLAC__stream_encoder_new` reads the way the C does. One call is declared here by
//! hand, [`FLAC__stream_encoder_set_do_md5`].
//!
//! # Which library is linked
//!
//! [`version`] returns what the archive itself reports. libFLAC compiles its own version string
//! in, so asking the library is how a consumer checks it is talking to the libFLAC this crate
//! was generated against rather than to a system one that won the link.
//!
//! # What is in the archive, and what is not
//!
//! libFLAC, whole: the stream encoder and decoder and the metadata interfaces. **No Ogg** —
//! `FLAC_API_SUPPORTS_OGG_FLAC` is zero and the `…_init_ogg_…` calls return their
//! unsupported-container status — and **no encoder threads**, so
//! `FLAC__stream_encoder_set_num_threads` reports that it was built without them. The bindings
//! leave out `metadata.h` and the four calls that take a C `FILE*`; the archive has them, and a
//! consumer that wants them declares them itself.
//!
//! # Safety
//!
//! Nothing here is safe. An encoder or decoder is a pointer `…_new` allocates and `…_delete`
//! frees exactly once; a setter is refused once `…_init_…` has run; and every callback is
//! called on the thread that called `…_process…`, with pointers that are valid only until it
//! returns — the bytes of a frame the encoder hands a write callback, and the samples the
//! decoder hands one, both belong to libFLAC.

// bindgen's own header already carries the allow attributes these names need.
//
// Two generated files, not one, and the split was measured. The headers are fixed-width
// integers, pointers and enums, and every `c_int` and `c_long` is an alias each target resolves
// for itself — which is why one file covers macOS and both Linux architectures — but the MSVC
// ABI packs bit-fields its own way, so `FLAC__StreamMetadata_CueSheet_Track` is 40 bytes there
// and 32 elsewhere, which the layout assertions exist to catch. A C enum is also always `int`
// to that ABI where clang on the others makes an unsigned-valued one `unsigned`: only a type
// alias, but what `--check` would otherwise report as drift on every run.
//
// clippy is not asked about either: the files are bindgen's, regenerated rather than edited,
// and its bitfield accessors transmute a type to itself.
#[allow(clippy::all)]
#[cfg_attr(windows, path = "bindings_windows.rs")]
mod bindings;

pub use bindings::*;

extern "C" {
    /// Whether the encoder computes the MD5 of the samples it is given, which the stream
    /// header carries: on by default, and a cost on every block that a stream sent without
    /// its header never collects on.
    ///
    /// Declared by hand because FLAC declares it in `include/share/private.h`, which is not
    /// installed, while exporting it from the library all the same — the `flac` program calls
    /// it. `build.sh` asserts the archive defines it.
    pub fn FLAC__stream_encoder_set_do_md5(
        encoder: *mut FLAC__StreamEncoder,
        value: FLAC__bool,
    ) -> FLAC__bool;
}

/// What the linked libFLAC says it is, e.g. `1.5.0`.
///
/// Reads `FLAC__VERSION_STRING`, which libFLAC compiles in from its own source tree. The
/// version this crate's bindings were generated against is [`PREBUILT_VERSION`] — comparing
/// the two is how a consumer notices it is linked against something other than the archive
/// this repository publishes.
pub fn version() -> &'static str {
    // SAFETY: `FLAC__VERSION_STRING` is a pointer libFLAC initialises statically and never
    // writes, to a NUL-terminated string constant in the archive's read-only data — so the
    // lifetime is genuinely 'static and there is nothing to free. It is read by value through
    // a raw pointer, so no reference to the `static mut` is formed.
    let ptr = unsafe { std::ptr::addr_of!(FLAC__VERSION_STRING).read() };
    assert!(!ptr.is_null(), "FLAC__VERSION_STRING is null");
    // SAFETY: as above.
    unsafe { std::ffi::CStr::from_ptr(ptr) }.to_str().expect("libFLAC's version string is ASCII")
}

/// The libFLAC version this crate's bindings and archives are built from, from `flac.env`.
pub const PREBUILT_VERSION: &str = env!("LIBFLAC_PREBUILT_VERSION");
