// The shared library of a build without Rust, for WebAssembly (webR).
//
// tools/config.R writes a src/Makevars that compiles only this file on
// webR, where rattler cannot be built (see the comment at the top of
// tools/config.R). It registers no routines, so none of the `.Call()`
// wrappers in R/extendr-wrappers.R resolve, and `.onLoad()` registers a
// backend that is never available (see `rattler_rust_available()` and
// `new_backend_rattler()`).

#include <R.h>
#include <R_ext/Rdynload.h>

void R_init_rattlerthis(DllInfo *dll) {
    R_registerRoutines(dll, NULL, NULL, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
}
