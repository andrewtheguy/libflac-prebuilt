//! Encode synthetic sound with the prebuilt libFLAC, then decode it back.
//!
//! Run by the pipeline on every target, and the reason it exists is that "the archive links" is
//! a much weaker claim than "the archive codes a stream another part of libFLAC decodes to the
//! same samples". A `cargo test` that only builds proves the symbols resolved; this proves the
//! codec runs, on the CPU the artifact was built for, set up the way the consumers set it up.
//!
//! What it checks, in order:
//!
//!   1. the linked library reports the version this repository pins;
//!   2. it was built as `build.sh` configures it: no Ogg, no encoder threads;
//!   3. every block comes out as one frame of its own, which is what a consumer framing the
//!      sound itself depends on;
//!   4. the stream is smaller than the samples it holds;
//!   5. the decoder gives back every sample, exactly. FLAC is lossless, so anything short of
//!      identical is a broken build rather than a tolerance.
//!
//! Nothing here is a benchmark. The encode's speed is printed because it is free and
//! occasionally diagnostic — it is where a kernel the compiler left scalar would show — and it
//! is not asserted, because a CI runner's wall clock is not a fact about the codec. `build.sh`
//! asserts the thing itself, on the archive's instructions.

use std::os::raw::c_void;
use std::time::Instant;

use flac_sys::*;

/// The stream: a desktop's sound, as the project this was built for codes it.
const RATE: u32 = 48_000;
const CHANNELS: u32 = 2;
const BITS: u32 = 16;
/// Twenty milliseconds.
const BLOCK: u32 = 960;
/// A minute of it: long enough that the speed printed is of the encoder rather than of its
/// start-up, short enough that every runner is done in a moment.
const BLOCKS: u32 = 3_000;

fn main() {
    println!(
        "libflac-e2e: libFLAC {} (pinned {})",
        flac_sys::version(),
        flac_sys::PREBUILT_VERSION
    );
    assert_eq!(
        flac_sys::version(),
        flac_sys::PREBUILT_VERSION,
        "the linked libFLAC is not the version this repository pins — something else won the link"
    );

    // (2) What `build.sh` configured out, asked of the library rather than of the MANIFEST.
    // SAFETY: an `int` libFLAC initialises statically and never writes, read by value.
    let ogg = unsafe { std::ptr::addr_of!(FLAC_API_SUPPORTS_OGG_FLAC).read() };
    assert_eq!(ogg, 0, "this libFLAC was built with Ogg, which the archive is configured without");

    let pcm = signal();
    let coded = encode(&pcm);

    // (3) One frame to a block; `encode` has already held each to a block's length.
    assert_eq!(
        coded.frames, BLOCKS,
        "{} frames for {BLOCKS} blocks — the encoder is not making one frame to a block",
        coded.frames
    );

    // (4) It compresses. The signal is tones and a little noise, which FLAC roughly halves.
    let raw = pcm.len() * (BITS as usize / 8);
    assert!(
        coded.bytes.len() < raw * 3 / 4,
        "{} bytes for {raw} bytes of samples — the encoder is storing the sound verbatim",
        coded.bytes.len()
    );

    // (5) And every sample comes back.
    let decoded = decode(&coded.bytes);
    assert_eq!(decoded.len(), pcm.len(), "the decoder returned a different number of samples");
    if let Some(at) = pcm.iter().zip(&decoded).position(|(a, b)| a != b) {
        panic!(
            "sample {at} decoded as {} and was {} — the round trip is not lossless",
            decoded[at], pcm[at]
        );
    }

    let seconds = f64::from(BLOCKS * BLOCK) / f64::from(RATE);
    println!();
    println!("| blocks | frames | bytes   | of raw | encode   | × real time |");
    println!("|--------|--------|---------|--------|----------|-------------|");
    println!(
        "| {:6} | {:6} | {:7} | {:5.1}% | {:5.0} ms | {:11.0} |",
        BLOCKS,
        coded.frames,
        coded.bytes.len(),
        100.0 * coded.bytes.len() as f64 / raw as f64,
        coded.seconds * 1000.0,
        seconds / coded.seconds
    );
    println!();
    println!("ok: {} samples round-tripped bit for bit", pcm.len());
}

/// Two tones a channel and a little noise, interleaved: something a predictor has work to do
/// on, and the same on every machine — the noise is a fixed linear congruential sequence.
fn signal() -> Vec<i32> {
    let frames = (BLOCKS * BLOCK) as usize;
    let mut pcm = Vec::with_capacity(frames * CHANNELS as usize);
    let mut seed = 1u32;
    for i in 0..frames {
        let t = i as f64 / f64::from(RATE);
        seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
        let noise = f64::from((seed >> 16) & 0x7fff) / 32_768.0 - 0.5;
        let tau = std::f64::consts::TAU;
        let left = 0.4 * (tau * 440.0 * t).sin() + 0.2 * (tau * 1337.0 * t).sin() + 0.05 * noise;
        let right = 0.4 * (tau * 554.0 * t).sin() + 0.2 * (tau * 90.0 * t).sin() + 0.05 * noise;
        pcm.push((left * 32_767.0) as i32);
        pcm.push((right * 32_767.0) as i32);
    }
    pcm
}

struct Coded {
    bytes: Vec<u8>,
    /// Writes that carried samples: frames, as against the stream's header.
    frames: u32,
    seconds: f64,
}

/// What the encoder's write callback is handed: where the stream goes, and what it saw of
/// the frames.
struct Sink {
    bytes: Vec<u8>,
    frames: u32,
    /// A frame that did not hold exactly one block.
    odd_frame: bool,
}

unsafe extern "C" fn keep(
    _encoder: *const FLAC__StreamEncoder,
    buffer: *const FLAC__byte,
    bytes: usize,
    samples: u32,
    _frame: u32,
    client: *mut c_void,
) -> FLAC__StreamEncoderWriteStatus {
    // SAFETY: `client` is the `Sink` `encode` passed to `init_stream` and keeps alive, exclusive
    // to this call because the encoder calls back on the thread inside `process`; `buffer` is
    // `bytes` long for the call.
    let sink = unsafe { &mut *client.cast::<Sink>() };
    sink.bytes.extend_from_slice(unsafe { std::slice::from_raw_parts(buffer, bytes) });
    // `samples` is zero for the stream's header and the block's length for a frame.
    if samples != 0 {
        sink.frames += 1;
        sink.odd_frame |= samples != BLOCK;
    }
    FLAC__StreamEncoderWriteStatus_FLAC__STREAM_ENCODER_WRITE_STATUS_OK
}

fn encode(pcm: &[i32]) -> Coded {
    let mut sink = Sink { bytes: Vec::new(), frames: 0, odd_frame: false };
    let started;
    // SAFETY: the encoder is used on this thread alone, between `new` and `delete`; `sink`
    // outlives it; and each `process` is given a whole block of interleaved samples.
    unsafe {
        let encoder = FLAC__stream_encoder_new();
        assert!(!encoder.is_null(), "libFLAC could not allocate an encoder");

        // (2) Threads were configured out, and the library says so itself.
        assert_eq!(
            FLAC__stream_encoder_set_num_threads(encoder, 2),
            FLAC__STREAM_ENCODER_SET_NUM_THREADS_NOT_COMPILED_WITH_MULTITHREADING_ENABLED,
            "this libFLAC was built with encoder threads, which the archive is configured without"
        );

        // As the consumers set a stream up: no streamable subset, so a frame need not restate
        // the rate, and no MD5 of samples for a stream header nobody is sent.
        FLAC__stream_encoder_set_streamable_subset(encoder, 0);
        FLAC__stream_encoder_set_do_md5(encoder, 0);
        FLAC__stream_encoder_set_channels(encoder, CHANNELS);
        FLAC__stream_encoder_set_bits_per_sample(encoder, BITS);
        FLAC__stream_encoder_set_sample_rate(encoder, RATE);
        FLAC__stream_encoder_set_blocksize(encoder, BLOCK);
        let status = FLAC__stream_encoder_init_stream(
            encoder,
            Some(keep),
            None,
            None,
            None,
            std::ptr::addr_of_mut!(sink).cast(),
        );
        assert_eq!(
            status, FLAC__StreamEncoderInitStatus_FLAC__STREAM_ENCODER_INIT_STATUS_OK,
            "the encoder refused the stream"
        );

        started = Instant::now();
        for block in pcm.as_chunks::<{ (BLOCK * CHANNELS) as usize }>().0 {
            assert_ne!(
                FLAC__stream_encoder_process_interleaved(encoder, block.as_ptr(), BLOCK),
                0,
                "the encoder failed on a block"
            );
        }
        assert_ne!(FLAC__stream_encoder_finish(encoder), 0, "the encoder failed to finish");
        FLAC__stream_encoder_delete(encoder);
    }
    let seconds = started.elapsed().as_secs_f64();
    assert!(!sink.odd_frame, "a frame did not hold exactly one block of {BLOCK}");
    Coded { bytes: sink.bytes, frames: sink.frames, seconds }
}

/// What the decoder's callbacks are handed: the stream and how far it has been read, and the
/// samples so far.
struct Source<'a> {
    bytes: &'a [u8],
    at: usize,
    pcm: Vec<i32>,
    /// What went wrong, for `decode` to report once libFLAC has returned: a callback cannot
    /// unwind through C.
    fault: Option<String>,
}

unsafe extern "C" fn read(
    _decoder: *const FLAC__StreamDecoder,
    buffer: *mut FLAC__byte,
    bytes: *mut usize,
    client: *mut c_void,
) -> FLAC__StreamDecoderReadStatus {
    // SAFETY: `client` is the `Source` `decode` passed to `init_stream`, exclusive to this
    // call; `buffer` has room for `*bytes`, which is the decoder's to read back.
    let source = unsafe { &mut *client.cast::<Source>() };
    let left = &source.bytes[source.at..];
    let take = left.len().min(unsafe { *bytes });
    unsafe {
        std::ptr::copy_nonoverlapping(left.as_ptr(), buffer, take);
        *bytes = take;
    }
    source.at += take;
    if take == 0 {
        FLAC__StreamDecoderReadStatus_FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM
    } else {
        FLAC__StreamDecoderReadStatus_FLAC__STREAM_DECODER_READ_STATUS_CONTINUE
    }
}

unsafe extern "C" fn write(
    _decoder: *const FLAC__StreamDecoder,
    frame: *const FLAC__Frame,
    buffer: *const *const FLAC__int32,
    client: *mut c_void,
) -> FLAC__StreamDecoderWriteStatus {
    // SAFETY: `client` as in `read`; `frame` is valid for the call, and `buffer` holds a pointer
    // for each of the frame's channels to `blocksize` samples.
    let source = unsafe { &mut *client.cast::<Source>() };
    let header = unsafe { &(*frame).header };
    if header.channels != CHANNELS || header.blocksize != BLOCK || header.bits_per_sample != BITS {
        source.fault = Some(format!(
            "a decoded frame is {} channels of {} samples at {} bits",
            header.channels, header.blocksize, header.bits_per_sample
        ));
        return FLAC__StreamDecoderWriteStatus_FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }
    let channels: Vec<&[i32]> = (0..CHANNELS as usize)
        .map(|c| unsafe { std::slice::from_raw_parts(*buffer.add(c), BLOCK as usize) })
        .collect();
    for i in 0..BLOCK as usize {
        source.pcm.extend(channels.iter().map(|channel| channel[i]));
    }
    FLAC__StreamDecoderWriteStatus_FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE
}

unsafe extern "C" fn error(
    _decoder: *const FLAC__StreamDecoder,
    status: FLAC__StreamDecoderErrorStatus,
    client: *mut c_void,
) {
    // SAFETY: `client` as in `read`.
    let source = unsafe { &mut *client.cast::<Source>() };
    source.fault.get_or_insert(format!("the decoder reported error status {status}"));
}

fn decode(bytes: &[u8]) -> Vec<i32> {
    let mut source = Source { bytes, at: 0, pcm: Vec::new(), fault: None };
    // SAFETY: the decoder is used on this thread alone, between `new` and `delete`, and
    // `source` outlives it.
    let finished = unsafe {
        let decoder = FLAC__stream_decoder_new();
        assert!(!decoder.is_null(), "libFLAC could not allocate a decoder");
        let status = FLAC__stream_decoder_init_stream(
            decoder,
            Some(read),
            None,
            None,
            None,
            None,
            Some(write),
            None,
            Some(error),
            std::ptr::addr_of_mut!(source).cast(),
        );
        assert_eq!(
            status, FLAC__StreamDecoderInitStatus_FLAC__STREAM_DECODER_INIT_STATUS_OK,
            "the decoder refused the stream"
        );
        let finished = FLAC__stream_decoder_process_until_end_of_stream(decoder);
        FLAC__stream_decoder_finish(decoder);
        FLAC__stream_decoder_delete(decoder);
        finished
    };
    if let Some(fault) = source.fault {
        panic!("{fault}");
    }
    assert_ne!(finished, 0, "the decoder stopped before the end of the stream");
    source.pcm
}
