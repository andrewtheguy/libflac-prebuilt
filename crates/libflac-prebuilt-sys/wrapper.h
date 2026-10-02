// What bindgen reads: the stream encoder, which includes the stream decoder and, through it,
// the format. `metadata.h` is left out on purpose — its file iterators return `off_t`, which is
// one libc's type, and nothing coding a stream calls them.
#include <FLAC/stream_encoder.h>
