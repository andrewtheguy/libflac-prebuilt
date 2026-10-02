// What bindgen reads in place of the C library's <stdio.h>, which FLAC's headers include for
// one name: `FILE`, in the four `…_init_FILE` calls. Nothing compiles against this.
//
// The real header declares `FILE` as a structure private to one libc — `_IO_FILE`, `__sFILE`,
// `_iobuf` — and bindgen writes down whichever one the generating machine has, layout and all,
// into a file other platforms share. Here it is a name with nothing behind it, the same on
// every machine, and gen-bindings.sh then leaves the name and the four calls out.
//
// `size_t` is the other thing those headers were getting from <stdio.h>, and <stddef.h> is the
// compiler's own header rather than a libc's.
#include <stddef.h>
typedef struct FLAC_SYS_NO_FILE FILE;
