# rattlerthis

<!-- badges: start -->
<!-- badges: end -->

`rattlerthis` runs any CLI tool inside a reproducible, isolated 'Conda'
environment — a modern, native successor to
[`condathis`](https://github.com/luciorq/condathis).

Where `condathis` downloads a `micromamba` binary and shells out to it,
`rattlerthis` links the [`rattler`](https://github.com/conda/rattler) Rust
library (the engine behind `pixi`) directly into the R package via
[`rextendr`](https://extendr.github.io/rextendr/). Environment solving,
package installation, and shell activation all happen in-process — no
external package manager binary to download or manage.

See [`PLAN.md`](PLAN.md) for design decisions and [`TODO.md`](TODO.md) for
the current status and roadmap.

## Installation

```r
# requires a Rust toolchain (cargo/rustc >= 1.75) to compile from source
pak::pak("luciorq/rattlerthis")
```

## Usage

```r
library(rattlerthis)

create_env(packages = "xz", env_name = "rattlerthis-demo")
run("xz", "--version", env_name = "rattlerthis-demo")
remove_env("rattlerthis-demo")
```
