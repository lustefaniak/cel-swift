// libFuzzer's driver entry point (compiler-rt FuzzerInterface.h). SwiftPM links an executable's
// `main` to `<module>_main`, which keeps libFuzzer's own `main` out of the link, so each fuzz
// target calls the driver itself. See Fuzz/README.md.
#ifndef CEL_FUZZ_DRIVER_H
#define CEL_FUZZ_DRIVER_H

#include <stddef.h>
#include <stdint.h>

int LLVMFuzzerRunDriver(int *argc, char ***argv, int (*UserCb)(const uint8_t *Data, size_t Size));

#endif
