# TODO

Status of `rattlerthis` as condathis's backend. See `PLAN.md` here and
`.github/devdocs/feat-initial-impl/PLAN.md` for the design.

## Done (history, short)

- **2026-07-15, standalone adapter** for condathis's first contract (10
  plain functions), tested against conda-forge without condathis.
- **2026-08-13, registration** with condathis's `register_backend()`, from
  `.onLoad()` and a condathis `onLoad` hook; unregistered on unload.
- **2026-10-22, conformance** with condathis 0.2.0.9009: function formals
  equal to the generics', result shapes, shared error classes, the six
  `list_packages()` columns; `test-condathis-conformance.R`.
- **2026-10-23, condathis's API consistency round**: overwrite semantics,
  strict missing-environment policy, backend-neutral failure classes,
  `condathis_backend_unsupported`; several bugs fixed on condathis's side
  (children got micromamba's directories, rattler-only use installed
  micromamba, `create_base_env()` ignored `method`).
- **2026-10-26**: keep/refuse checks copied from condathis (removed again
  with contract v2).
- **2026-10-27 / 28, contract v2**:
  - [x] Rust jobs, interrupts, fork safety, pins, prefix lock, history,
        link-script detection, cache cleaning, environment files (RT-1,
        RT-2).
  - [x] Package reshape: no exports, no options or variables, 7 backend
        functions, `Imports: condathis (>= 0.2.0.9010)`; condathis loads
        the package on demand (RT-3).
  - [x] Tests through condathis with `method = "rattler"`, and parity with
        `method = "micromamba"` (RT-4).
  - [x] CI (`R-CMD-check.yaml`, `win-arm64.yaml`), README and these
        devdocs (RT-5).
  - [x] Review fixes: requesting `pip` brings `python` (libmamba's second
        pip rule); two R sessions reading one channel's cached metadata on
        Windows no longer fail; `ps` and `parallel` in Suggests; the CI
        test gate counts skips and failures outside `test_that()`; the
        tests the reviews asked for (second Ctrl-C during a link, an
        updated channel read by two sessions, `additional_channels`,
        `run(timeout =)`, quotes in state values, file modes, byte order
        marks, R-28, R-12); `?rattlerthis` corrected (a failing
        `post-link` script fails neither backend).

## Open

- [x] `Remotes: luciorq/condathis` in `DESCRIPTION`: the condathis tree
      with contract v2 (`feat-strict-defaults`) is merged into condathis's
      `main`. CI installs condathis from that branch.
- [ ] Before condathis's next CRAN release, once rattlerthis is public:
      condathis declares `Enhances: rattlerthis` plus
      `Additional_repositories` (spec decision Q22).
- [ ] The follow-ups outside this package listed in `PLAN.md`.
