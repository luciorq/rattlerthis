# `rattlerthis` as a conforming `condathis` backend

## Context

`condathis` (sibling package, `github.com/luciorq/condathis`) is scoping out
a pluggable backend system so `create_env()`/`install_packages()`/`run()`/
etc. can dispatch to different engines — starting with its existing
`micromamba`-CLI implementation and this package's in-process `rattler`
engine, with container backends (`docker`/`singularity`) sketched for later.
That design lives in `condathis`'s own devdocs at
`.github/devdocs/feat-backend-abstraction/{PLAN,TODO}.md` and defines a
10-generic contract (decision 4 there): `backend_create_env()`,
`backend_install()`, `backend_remove_env()`, `backend_list_envs()`,
`backend_env_exists()`, `backend_list_packages()`, `backend_get_env_dir()`,
`backend_get_install_dir()`, `backend_resolve_run()`, `backend_available()`.

**Nothing on the `condathis` side has been implemented yet** — no registry,
no generics, no `register_backend()`. This document scopes (and then
implements) the `rattlerthis`-side half only: an adapter that maps this
package's existing public API onto that contract, written so it can be
built, tested, and exercised entirely standalone against the real
`rattler`/conda-forge network, with zero dependency on `condathis` existing
or being installed. Wiring the two together (real S3 method registration,
`.onLoad()` hookup) is explicitly deferred — tracked in `TODO.md` — until
`condathis`'s own registry milestone ships.

## Goals

- Implement all 10 contract functions as plain, non-exported, testable
  functions in `rattlerthis` — not yet as literal S3 methods, since the
  generics they'd dispatch on don't exist anywhere yet (see decision 1).
- Faithfully adapt `rattlerthis`'s actual current signatures (verified by
  reading `R/create-env.R`, `R/install.R`, `R/run.R`, `R/env-utils.R`,
  `R/result.R` directly, not from memory) to the contract's signatures,
  and be explicit — not silent — about every place the two don't line up
  1:1 (see decision 3).
- Keep this package's own public API and behavior for direct users
  (non-`condathis`) completely unchanged.
- Leave the adapter in a state where wiring it into `condathis` later is a
  small, mechanical step, not a rewrite.

## Non-goals (this round)

- Any change to `condathis` itself. That package doesn't exist as a
  dependency here (`Suggests`, even) yet — see decision 1.
- Implementing `env_file` (`environment.yml`) support just to satisfy the
  contract's `env_file` parameter — `rattlerthis::create_env()` doesn't
  support it today (tracked separately in this package's own `TODO.md`
  under "Deferred"), so the adapter surfaces that gap loudly instead of
  faking it (decision 3).
- A `"flexible"` `channel_priority` implementation — `resolvo` has no such
  mode; already a documented, deliberate deviation in this package's own
  `PLAN.md` ("Deliberate deviations from the original plan").

## Design decisions

1. **No `condathis` dependency, anywhere, yet.** The adapter functions are
   plain R functions with the contract's exact signature shape (`backend`
   as the first argument, otherwise matching), *not* `UseMethod()`-based S3
   methods, and not registered with anything. This is deliberate, not a
   shortcut: `condathis::register_backend()` and the `backend_*` generics
   don't exist yet, so there is nothing to register with or dispatch
   through. Because they're non-exported (`@keywords internal`, `@noRd`),
   defining a function literally named e.g. `backend_create_env` inside
   `rattlerthis`'s own namespace carries zero collision risk with anything
   `condathis` might define later — R namespaces are per-package, and an
   unexported symbol never appears on the search path even when both
   packages are attached with `library()`. When `condathis` ships its
   generics, turning these into real S3 methods is: define
   `backend_create_env.condathis_backend_rattler <- function(backend, ...)
   backend_create_env(backend, ...)` (or rename in place) plus a
   `.onLoad()` registration call — see `TODO.md`.

2. **New file: `R/condathis-backend.R`.** Holds the constructor
   (`new_backend_rattler()`, returning `structure(list(), class =
   c("condathis_backend_rattler", "condathis_backend"))` — this package
   keeps no real per-instance state today; its root directory is resolved
   process-globally via `get_install_dir()`'s option/env-var lookup, so the
   backend object itself carries nothing) and the 10 adapter functions.

3. **Signature reconciliation — every place `rattlerthis`'s real API and
   the contract disagree, and what the adapter does about it:**

   - **`env_file`** (`backend_create_env`): `rattlerthis::create_env()` has
     no such parameter. If the caller passes a non-`NULL` `env_file`, the
     adapter `cli::cli_abort()`s with class
     `rattlerthis_backend_unsupported_env_file` rather than silently
     ignoring it — an ignored `environment.yml` would look like success
     while installing nothing the caller asked for.
   - **`additional_channels`** (`backend_create_env`, `backend_install`):
     `rattlerthis` has one `channels` vector, no separate
     "additional" concept (that split exists in `condathis` mainly so
     `additional_channels` can be appended without repeating the default
     `channels =` value). The adapter merges: `c(channels,
     additional_channels)` before calling `rattlerthis::create_env()`/
     `install()`.
   - **`channel_priority` vocabulary**: `condathis`'s contract vocabulary
     is `c("disabled", "strict", "flexible")`; `rattlerthis`'s solver
     (`resolvo`) only implements `c("strict", "disabled")` — `"flexible"`
     has no equivalent (this is an existing, deliberate deviation
     documented in `rattlerthis`'s own `PLAN.md`, not new). The adapter
     maps `"disabled"`/`"strict"` straight through and
     `cli::cli_abort()`s on `"flexible"` (class
     `rattlerthis_backend_unsupported_channel_priority`) instead of
     silently downgrading to `"strict"` or `"disabled"`, either of which
     would change solve semantics the caller didn't ask for.
   - **`verbose` on read-only queries** (`backend_list_envs`,
     `backend_env_exists`): `rattlerthis::list_envs()`/`env_exists()` take
     no `verbose` argument at all — they're a directory scan with nothing
     to report. The adapter accepts and drops it.
   - **`backend_resolve_run` must not execute anything** — see decision 4,
     the one place the adapter can't just call an existing public function
     because the existing public function (`rattlerthis::run()`) does more
     than the contract wants from this generic.
   - **`backend_available`**: since this code only runs at all once
     `rattlerthis`'s compiled `.so`/`.dll` has already loaded successfully
     (there is no lazy-load path — the Rust bridge is linked at package
     load time), there is nothing further to probe. Returns `TRUE`
     unconditionally. Documented explicitly as "trivially true, not a
     stub" so it isn't mistaken for an unfinished implementation later.

4. **`backend_resolve_run` needs new shared internal plumbing, extracted
   from `run()`.** `rattlerthis::run()` (`R/run.R`) currently does three
   things in sequence: (a) validate the environment exists, (b) resolve the
   activation env vars + executable path, (c) call `processx::run()`
   itself. The contract's `backend_resolve_run()` needs exactly (a) and
   (b), returning `list(command, args, env, dir)` *without* (c) — mirrors
   `condathis`'s own decision 4: only one call site (in `condathis`, or
   here in `rattlerthis::run()` itself) ever touches `processx` directly.
   Extract (a)+(b) into a new internal helper, `resolve_run_command(cmd,
   env_name)`, in a new file `R/resolve-run.R`; `run()` calls it and then
   does step (c) as before (behavior-preserving refactor — same error
   class `rattlerthis_run_missing_env`, same `bin/<cmd>` path resolution
   with a PATH fallback); `backend_resolve_run()` calls it and wraps the
   result with `args`/`dir`, doing nothing else.

5. **Testing: exercise the adapter directly, against the real network,
   mirroring this package's existing test conventions.** New
   `tests/testthat/test-condathis-backend.R`, using the same
   `skip_if_offline()`/`skip_on_cran()` guards as
   `tests/testthat/test-create-env.R`/`test-wheel.R`. Calls
   `backend_create_env(new_backend_rattler(), ...)` etc. directly (no
   `:::`  needed — tests run inside the package) and asserts against the
   same real conda-forge packages (`xz`) already used elsewhere in this
   suite, so no new network-fixture surface is introduced. Also covers
   every decision-3 mismatch case (`env_file` non-`NULL` errors,
   `channel_priority = "flexible"` errors, `additional_channels` merges
   correctly) without needing any network at all — those are pure
   input-validation paths.

## Known gap to flag upward (not fixed here, `condathis`'s problem to solve)

`rattlerthis::list_packages()` returns columns `name`, `version`, `build`,
`build_number`, `channel`. `condathis::list_packages()` (micromamba-backed)
returns a completely different column set: `base_url`, `build_number`,
`build_string`, `channel`, `dist_name`, `name`, `platform`, `version`.
`backend_list_packages()` here just passes `rattlerthis::list_packages()`'s
tibble straight through — reconciling this into one canonical schema across
backends is out of scope for this package (it's a `condathis`-side
dispatch-layer concern, not something one backend can unilaterally fix) but
worth flagging loudly now, before `condathis`'s own "rattlerthis as a
conforming backend" milestone assumes the columns already line up.

## File layout (this milestone)

```
rattlerthis/
  R/
    condathis-backend.R   # new_backend_rattler(), the 10 backend_* adapter
                           # functions (decisions 1-3)
    resolve-run.R          # new: resolve_run_command(cmd, env_name),
                            # extracted from run.R (decision 4)
    run.R                   # modified: run() calls resolve_run_command()
                             # instead of inlining steps (a)+(b)
  tests/testthat/
    test-condathis-backend.R   # new
```
