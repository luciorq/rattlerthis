#!/usr/bin/env just
# shellcheck shell=bash

package_name := 'rattlerthis'

github_org := 'luciorq'

@default:
  just --choose

# >>> rstats-package-dev-tasks >>>

# =============================================================================
# General R Package Development Tasks
# =============================================================================

# Update Package Documentation
document:
  #!/usr/bin/env bash
  \builtin set -euo pipefail;
  R -q -s -e 'devtools::load_all(quiet=TRUE);usethis::use_tidy_description();';
  R -q -s -e 'devtools::load_all(quiet=TRUE);devtools::document(quiet=TRUE);';
  \builtin echo "Documentation updated!";

# Lint R Package Code and Documentation
lint:
  #!/usr/bin/env bash
  \builtin set -euo pipefail;
  R -q -s -e 'devtools::load_all(quiet=TRUE);withr::with_options(list(styler.quiet=TRUE),code={styler::style_pkg(exclude_dirs=c("packrat","renv","revdep"))});';
  air format ./R/ || true;
  air format ./tests/ || true;
  (jarl check . --select ALL || jarl check . --select ALL --statistics) || true;
  # TODO: @luciorq: This is not capturing lines where `@return` has a line break just after it it.
  find ./R/ -type f -name "*.R" -exec sed -i -e "s|^#' \@return |#' \@returns |g" {} +
  find ./R/ -type f -name "*.R" -exec sed -i -e "s|^#' \@return$|#' \@returns|g" {} +
  just document;
  # Remove duplicate lines from .gitignore and .Rbuildignore without changing their order
  awk '!seen[$0]++' .gitignore > .gitignore.tmp && \mv .gitignore.tmp .gitignore;
  awk '!seen[$0]++' .Rbuildignore > .Rbuildignore.tmp && \mv .Rbuildignore.tmp .Rbuildignore;
  \builtin echo "Linting done!";

# Run All Unit Tests
test: lint
  #!/usr/bin/env bash
  \builtin set -euo pipefail;
  R -q -s -e 'withr::with_envvar(new=list(`TESTTHAT_CPUS`=4),code={devtools::load_all(quiet=TRUE);devtools::run_examples();});';
  R -q -s -e 'withr::with_envvar(new=list(`TESTTHAT_CPUS`=4),code={withr::with_options(list(crayon.enabled=FALSE,cli.unicode=FALSE),code={devtools::load_all(quiet=TRUE);devtools::test(pkg=".");})});';
  \builtin echo "All tests passed!";

# Build and Lint README File
build-readme: lint
  #!/usr/bin/env bash
  \builtin set -euo pipefail;
  # Lint markdown files
  [[ -f ./README.Rmd ]] && cat ./README.Rmd | rumdl check --stdin --disable 'MD046' || true;
  [[ -f ./README.qmd ]] && cat ./README.qmd | rumdl check --stdin --disable 'MD046' || true;
  just install-deps;
  R -q -s -e 'pak::local_install(upgrade=TRUE, dependencies=TRUE);';
  # R -q -s -e 'devtools::install(pkg = ".", build_vignettes = TRUE, dependencies = c("Imports", "Suggests", "Depends"), upgrade = "always");';
  [[ -f ./README.Rmd ]] && R -q -s -e 'devtools::load_all(quiet=TRUE);if(file.exists("README.Rmd")){rmarkdown::render("README.Rmd", encoding="UTF-8")};' || true;
  [[ -f ./README.qmd ]] && quarto render README.qmd --to gfm || true;
  # Lint Final README.md
  sed -i -e 's|[[:blank:]]*$||g' README.md;
  sed -i -e '/./,$!d' README.md;
  sed -i '/<!-- badges: start -->/{n; /^\s*$/d}' README.md;
  rumdl check README.md || true;
  markdownlint README.md || true;
  markdownlint-cli2 --no-globs README.md || true;
  \builtin echo "README built and linted!";

# Run All Examples in the Documentation Including `dontrun`
test-all-examples: document
  #!/usr/bin/env bash
  \builtin set -euo pipefail;
  R -q -s -e 'devtools::load_all(quiet=TRUE);devtools::document(quiet=TRUE);devtools::run_examples(run_dontrun = TRUE, run_donttest = TRUE);';

# Run Tests from a Specific Test File
test-file file_name:
  #!/usr/bin/env bash
  \builtin set -euo pipefail;
  R -q -s -e 'devtools::load_all(quiet=TRUE);devtools::test_active_file("tests/testthat/test-{{ file_name }}.R")';

# Run R CMD Check on the Package With Cran Like Checks
check: test test-all-examples build-readme
  #!/usr/bin/env bash
  \builtin set -euo pipefail;
  R -q -s -e 'rcmdcheck::rcmdcheck(args = c("--as-cran"), repos = c(CRAN = "https://cloud.r-project.org"));';

# Force GitHub Actions Checks to start for the main branch
check-gha-trigger:
  #!/usr/bin/env bash
  \builtin set -euo pipefail;
  gh workflow run "r-cmd-check" --ref main;

# Print latest GitHub Actions Checks results for the main branch
monitor-gha:
  #!/usr/bin/env bash
  \builtin set -euo pipefail;
  gh run list;
  latest_job_id="$(gh run list -w "r-cmd-check" --json databaseId --jq '.[0].databaseId')";
  gh run view "${latest_job_id}";

# Tag the Latest Commit with Version from the DESCRIPTION File
git-tag:
  #!/usr/bin/env bash
  \builtin set -euo pipefail;
  git pull origin --tags || true;
  git pull upstream --tags || true;
  __r_pkg_version="$(R -q --no-echo --silent -e 'suppressMessages({pkgload::load_all(quiet=TRUE)});cat(as.character(utils::packageVersion("{{ package_name }}")));')";
  \builtin echo -ne "Tagging version: ${__r_pkg_version}\n";
  git tag -a "v${__r_pkg_version}" HEAD -m "Version ${__r_pkg_version} released";
  # git push --tags;
  # git pull upstream --tags;
  # git push upstream --tags;

# Build Vignettes
build-vignettes:
  #!/usr/bin/env bash
  \builtin set -euo pipefail;
  R -q -s -e 'devtools::load_all(quiet=TRUE);devtools::document(quiet=TRUE);';
  just install-deps;
  just install-local;
  # TODO: `devtools::install()` changed completely its signature by using
  # + `pak::local_install_deps()` for managing dependencies.
  # R -q -s -e 'devtools::install(pkg = ".", build_vignettes = TRUE, dependencies = c("Imports", "Suggests", "Depends"), upgrade = "always");';
  R -q -s -e 'devtools::install(pkg = ".", build_vignettes = TRUE, dependencies = TRUE, upgrade = TRUE);';
  R -q -s -e 'print(vignette(package = "{{ package_name }}"));';

# Install Package Development Dependencies Including Suggests
install-deps:
  #!/usr/bin/env bash
  \builtin set -euo pipefail;
  R -q -s -e 'if(!requireNamespace("pak", quietly=TRUE)) {install.packages("pak")};';
  R -q -s -e 'pak::local_install_dev_deps(upgrade=TRUE, dependencies=TRUE);';

# Install Local Version of the Package With All Dependencies
install-local:
  #!/usr/bin/env bash
  \builtin set -euo pipefail;
  R -q -s -e 'if(!requireNamespace("pak", quietly=TRUE)) {install.packages("pak")};';
  R -q -s -e 'pak::local_install(upgrade=TRUE, dependencies=TRUE);';

# Install Dev Environment Dependencies
install-dev-deps: install-deps
  #!/usr/bin/env bash
  \builtin set -euo pipefail;
  R -q -s -e 'pak::local_install_dev_deps(dependencies="Config/Needs/dev", upgrade=TRUE)';

# Build the pkgdown Website
build-pkgdown-website: install-deps
  #!/usr/bin/env bash
  \builtin set -euo pipefail;
  R -q -s -e 'pak::pak("pkgdown", upgrade=TRUE, dependencies=TRUE);';
  R -q -s -e 'pkgdown::build_favicons(overwrite=FALSE);';
  R -q -s -e 'devtools::document(quiet=TRUE);devtools::load_all(quiet=TRUE);pkgdown::build_site();';
  # Steps for manually deploying the pkgdown website,
  # + not necessary if using GitHub Actions.
  # git add docs/;
  # git add pkgdown/;
  # git add _pkgdown.yml;
  # git commit -m "chore: update pkgdown website";
  # git push;

# Release a New Version on GitHub Releases Using Content From NEWS.md
release-github:
  #!/usr/bin/env bash
  \builtin set -euo pipefail;
  # Using `gh` cli to create a new release.
  # e.g.: `gh release create v0.1.0 --title "v0.1.0" --notes "First Zenodo archiving release"`.
  # Using `usethis` to create a new release.
  # First, change the NEWS.md header temporarily to make usethis happy
  # + Check: <https://github.com/r-lib/pkgdown/issues/2897>
  # + <https://github.com/r-lib/usethis/issues/2130>
  # + <https://github.com/tidyverse/style/issues/245#issuecomment-2959459898>
  sed -i -e "s|^## {{ package_name }}|# {{ package_name }}|g" NEWS.md;
  R -q -e 'devtools::load_all(quiet=TRUE);usethis::use_github_release();';
  sed -i -e "s|^# {{ package_name }}|## {{ package_name }}|g" NEWS.md;
  \builtin echo "Check the GH Releases!";

# Steps to Run Before Releasing a New Version
pre-release:
  #!/usr/bin/env bash
  \builtin set -euo pipefail;
  # TODO: Update version on NEWS.md and DESCRIPTION files.
  # TODO: If using changelog links, also perform a git push and tag,
  # + so `url_check()` do not fail.
  # git commit -m "chore: prepare for vX.Y.Z release";
  # git push;
  # just git-tag;
  # git push --tags;
  # git push upstream --tags;
  R -q -s -e 'urlchecker::url_check()';
  # R -q -s -e 'devtools::build_readme()';
  just build-readme;
  R -q -s -e 'withr::with_options(list(repos = c(CRAN = "https://cloud.r-project.org")), {devtools::check(remote = TRUE, manual = TRUE)})';
  R -q -s -e 'devtools::check_win_devel()';
  # R -q -s -e 'if(!requireNamespace("revdepcheck", quietly=TRUE)) pak::pak("r-lib/revdepcheck");';
  # R -q -s -e 'revdepcheck::revdep_reset();';
  # R -q -s -e 'revdepcheck::revdep_check(num_workers = 4);';
  # TODO: Update CRAN comments with output from `check`.
  # cat ./cran-comments.md;
  # usethis::use_version('patch')
  # devtools::build_rmd("vignettes/my-vignette.Rmd")
  # just build-vignettes;
  \builtin echo "Pre-release checks done!";
  # TODO: This step needs to be run manually, from R.
  # + Wait for previous `check_win_devel()` to finish.
  # devtools::submit_cran();
  # TODO: Check your email! Click the link, and check all boxes!
  # TODO: When accepted run:
  # just release-github;
  # TODO: Update Zenodo archive with the new release.
  # + Update the DOI badge in the README file.
  \builtin echo "Release successful!";

# Link current branch devdocs to project root
link-dev-docs branch_name:
  #!/usr/bin/env bash
  \builtin set -euo pipefail;
  # Example usage: `just link-dev-docs feat-new-feature`
  dev_docs_dir='.github/devdocs/{{ branch_name }}';
  if [[ ! -d "${dev_docs_dir}" ]]; then
    \mkdir -p "${dev_docs_dir}";
  fi;
  for file_name in PLAN.md TODO.md; do
    # Check if the file exists in the devdocs directory
    if [[ ! -f ${dev_docs_dir}/${file_name} ]]; then
      \builtin echo -ne "${file_name} does not exist in the devdocs directory for branch: {{ branch_name }}\n";
      \builtin continue;
    fi
    if [[ ! -f "${file_name}" && ! -L "${file_name}" ]]; then
      \builtin echo -ne "${file_name} does not exist in the project root. Creating symlink from ${dev_docs_dir}/${file_name} to project root\n";
      \ln -s "${dev_docs_dir}/${file_name}" ./"${file_name}";
      \builtin continue;
    fi
    # Check if file_name is a symlink but pointing to a different file
    if [[ -L "${file_name}" && "$(readlink "${file_name}")" != "${dev_docs_dir}/${file_name}" ]]; then
      \builtin echo -ne "${file_name} is a symlink but pointing to a different file. Check it's content.\n";
      \builtin continue;
    fi
    diff_res="$(diff "${file_name}" "${dev_docs_dir}/${file_name}")";
    diff_exit_code=${?:-1};
    if [[ ${diff_exit_code} -ne 0 && -n "${diff_res}" && -f "${dev_docs_dir}/${file_name}" ]]; then
      \builtin echo -ne "Differences found in ${file_name} for branch: {{ branch_name }}. Check before continuing.\n";
      \builtin echo -ne "${diff_res}\n";
      \builtin continue;
    fi
    # Check if none of them are symlinks and there is no difference, then create symlinks from devdocs to project root
    if [[ ${diff_exit_code} -eq 0 && -f "${dev_docs_dir}/${file_name}" && ! -L "${file_name}" ]]; then
      \builtin echo -ne "No differences found in ${file_name} for branch: {{ branch_name }}\n";
      \builtin echo -ne "Creating symlink from ${dev_docs_dir}/${file_name} to project root\n";
      \rm -f ./"${file_name}";
      \ln -s "${dev_docs_dir}/${file_name}" ./"${file_name}";
    fi
  done

# <<< rstats-package-dev-tasks <<<

# =============================================================================
# Rattlerthis specific Tasks
# =============================================================================

# Report the dependency graph's true MSRV and check it against both the value
# declared in `src/rust/Cargo.toml`/`DESCRIPTION` and CRAN's own floor.
#
# CRAN's lowest Rust across active build flavours is the real budget here
# (1.91.1 on macOS arm64 oldrel as of 2026-08-12; other machines run
# 1.92-1.94 -- see <https://extendr.rs/publishing/cran-msrv/>). Dependency
# bumps silently raise the graph's requirement, so this is worth re-running
# after every `just update-vendor`: the failure mode is not a build error
# here, it's a rejected CRAN submission on the one machine that lags.
check-msrv cran_floor='1.91.1':
  #!/usr/bin/env bash
  \builtin set -euo pipefail;
  cargo metadata --format-version 1 --manifest-path src/rust/Cargo.toml \
    | CRAN_FLOOR='{{ cran_floor }}' python3 -c '
  import json, os, sys
  m = json.load(sys.stdin)
  def norm(v):
      p = [int(x) for x in v.split(".")]
      return tuple(p + [0] * (3 - len(p)))
  rv = [(p["rust_version"], p["name"], p["version"]) for p in m["packages"] if p.get("rust_version")]
  rv.sort(key=lambda r: norm(r[0]), reverse=True)
  graph = rv[0][0]
  declared = next(p["rust_version"] for p in m["packages"] if p["name"] == "rattlerthis")
  floor = os.environ["CRAN_FLOOR"]
  print("Crates driving the MSRV:")
  for r in rv[:6]:
      print(f"  rust {r[0]:8}  {r[1]} {r[2]}")
  print()
  print(f"  graph requires : {graph}")
  print(f"  declared       : {declared}")
  print(f"  CRAN floor     : {floor}")
  print()
  bad = False
  if norm(declared) < norm(graph):
      print(f"FAIL: declared {declared} is BELOW what the graph needs ({graph}).")
      print("      Users between the two get a doomed build instead of a clean error.")
      bad = True
  if norm(graph) > norm(floor):
      print(f"FAIL: graph needs {graph}, above CRAN floor {floor}.")
      print("      The lagging CRAN machine cannot build this. Pin deps back.")
      bad = True
  if not bad:
      print(f"OK: {graph} <= {floor}, declared as {declared}.")
  sys.exit(1 if bad else 0)
  '

# Regenerate `src/rust/vendor.tar.xz`, the offline vendored Rust dependency
# tree used for CRAN builds (see `Makevars.in` / `tools/config.R`). It is not
# in git: a build without it downloads the crates, as CI does. Run this
# after bumping any Rust dependency in `src/rust/Cargo.toml` -- especially
# the rattler family, which TODO.md says to bump together. Filters vendored
# crates down to the platforms rattlerthis actually ships for and to
# `native-tls` (not `rustls`); see PLAN.md "Vendoring and CRAN size" for why.
# Requires network access (fetches crate sources) and `cargo`; installs
# `cargo-vendor-filterer` if missing.
update-vendor:
  #!/usr/bin/env bash
  \builtin set -euo pipefail;
  if ! command -v cargo-vendor-filterer >/dev/null 2>&1; then
    \builtin echo "Installing cargo-vendor-filterer...";
    cargo install cargo-vendor-filterer --locked;
  fi;
  work_dir="$(\mktemp -d)";
  trap '\rm -rf "${work_dir}"' EXIT;
  \builtin echo "Vendoring (platform-filtered, no-dev, default features)...";
  # Windows triples must match the `.windows_target` branches in
  # tools/config.R. `i686-pc-windows-gnu` is deliberately absent: DESCRIPTION
  # requires R >= 4.2, which dropped 32-bit Windows, and including it pulls
  # back the ~52MB winapi-i686 import libraries for nothing.
  # The --exclude-crate-path entries strip directories that are never
  # compiled when a crate is built *as a dependency* (cargo only builds the
  # lib/build targets): test suites, benchmarks, examples, bundled test
  # fixtures, and CI config. ~31MB unpacked (~16%) at the time of adding.
  # The tool rewrites each crate's .cargo-checksum.json to match, which is
  # what makes this safe -- hand-deleting the same files would fail cargo's
  # vendor checksum verification. The offline rebuild below is the guard
  # against a crate that needs one of these at build time -- not
  # hypothetical: `*#docs` broke `fancy-regex`, whose lib.rs does
  # `#![doc = include_str!("../docs/...")]`, making its docs a compile
  # input. Anything added here must survive that rebuild.
  #
  # One run per platform, merged below. With several --platform flags,
  # cargo-vendor-filterer (0.5.18) applies --keep-dep-kinds to the host's
  # dependency graph only, so every crate that only another platform needs
  # (security-framework on macOS; schannel, windows-sys and the windows
  # import libraries on Windows) came out as an empty stub. The Linux
  # offline rebuild below cannot see that; the macOS and Windows builds
  # failed. A single-platform run filters correctly.
  platforms=(
    x86_64-unknown-linux-gnu
    aarch64-unknown-linux-gnu
    x86_64-apple-darwin
    aarch64-apple-darwin
    x86_64-pc-windows-gnu
    x86_64-pc-windows-gnullvm
    aarch64-pc-windows-gnullvm
  );
  for platform in "${platforms[@]}"; do
    \builtin echo "  ${platform}";
    cargo vendor-filterer \
      --manifest-path=src/rust/Cargo.toml \
      --platform="${platform}" \
      --keep-dep-kinds=no-dev \
      --exclude-crate-path='*#tests' \
      --exclude-crate-path='*#test-macros' \
      --exclude-crate-path='*#benches' \
      --exclude-crate-path='*#examples' \
      --exclude-crate-path='*#test-data' \
      --exclude-crate-path='*#testdata' \
      --exclude-crate-path='*#test_data' \
      --exclude-crate-path='*#fuzz' \
      --exclude-crate-path='*#ci' \
      --exclude-crate-path='*#.github' \
      "${work_dir}/per-platform/${platform}" > "${work_dir}/vendor-config.toml";
  done;
  # Every run holds the same crate directories, each either a full copy or
  # a stub (only Cargo.toml and an empty src/lib.rs). The merge keeps a full
  # copy whole, so its .cargo-checksum.json still matches its files. Then it
  # fails if a crate that any platform builds is missing or still a stub:
  # the check the Linux-only rebuild cannot make. The crates come from
  # `cargo tree --target`, which resolves features as a real build does
  # (`cargo metadata` unifies them across targets and dependency kinds, and
  # so lists crates that no build compiles).
  python3 -I -c '
  import hashlib, json, os, re, shutil, subprocess, sys
  out, manifest, root = sys.argv[1:4]
  platforms = sorted(os.listdir(root))
  empty = hashlib.sha256(b"").hexdigest()
  def is_stub(path):
      with open(os.path.join(path, ".cargo-checksum.json")) as f:
          files = json.load(f)["files"]
      return set(files) == {"Cargo.toml", "src/lib.rs"} and files["src/lib.rs"] == empty
  names = sorted({n for p in platforms for n in os.listdir(os.path.join(root, p))})
  os.makedirs(out)
  for name in names:
      copies = [os.path.join(root, p, name) for p in platforms]
      copies = [c for c in copies if os.path.isdir(c)]
      full = [c for c in copies if not is_stub(c)]
      shutil.copytree((full or copies)[0], os.path.join(out, name), symlinks=True)
  def vendored_version(path):
      with open(os.path.join(path, "Cargo.toml")) as f:
          found = re.search(r"\[package\][^\[]*?^version = \"([^\"]+)\"", f.read(), re.M)
      return found.group(1) if found else None
  def vendor_dir(pkg):
      for d in (pkg["name"] + "-" + pkg["version"], pkg["name"]):
          path = os.path.join(out, d)
          if os.path.isdir(path) and vendored_version(path) == pkg["version"]:
              return path
      return None
  bad = []
  for platform in platforms:
      # Default features and all features: the two builds verified below.
      for features in ([], ["--all-features"]):
          tree = subprocess.run(
              ["cargo", "tree", "--offline", "--manifest-path", manifest,
               "--target", platform, "--edges", "no-dev", "--prefix", "none",
               "--format", "{p}", *features],
              check=True, capture_output=True, text=True).stdout
          for line in set(tree.splitlines()):
              found = re.match(r"(\S+) v(\S+)(?: \((\S+)\))?", line)
              # Skip the local package itself: a path source.
              if found is None or (found.group(3) or "").startswith("/"):
                  continue
              pkg = {"name": found.group(1), "version": found.group(2)}
              path = vendor_dir(pkg)
              if path is None or is_stub(path):
                  bad.append(platform + ": " + pkg["name"] + " " + pkg["version"])
  bad = sorted(set(bad))
  print("Merged", len(names), "crates from", len(platforms), "platform runs.")
  if bad:
      print("Needed but missing or stubbed:", *sorted(bad), sep="\n  ")
      sys.exit(1)
  ' "${work_dir}/vendor" src/rust/Cargo.toml "${work_dir}/per-platform";
  # Capture the source-replacement config cargo emits rather than keeping a
  # hand-written one: with extendr pinned to a git rev there is now a
  # `[source."git+https://github.com/extendr/extendr?rev=..."]` stanza
  # alongside `[source.crates-io]`, and an offline build fails without it.
  # Rewrite the absolute temp path back to the relative `vendor` dir the
  # Makevars recipes extract to.
  \sed "s|directory = .*|directory = \"vendor\"|" "${work_dir}/vendor-config.toml" \
    > src/rust/vendor-config.toml;
  \builtin echo "Compressing...";
  tar cf - -C "${work_dir}" vendor | xz -9e -T0 > src/rust/vendor.tar.xz;
  \builtin echo "Verifying offline build against the regenerated tree...";
  \rm -rf src/vendor src/.cargo;
  \mkdir -p src/.cargo;
  \cp src/rust/vendor-config.toml src/.cargo/config.toml;
  tar xf src/rust/vendor.tar.xz -C src;
  # Debug, not --release: LTO/codegen-units=1 make the real (release) build
  # much slower and don't affect which crates get pulled in, which is all
  # this is checking. `just check`/CRAN builds still go through the real
  # --release path via Makevars separately.
  CARGO_HOME="$(\pwd)/src/.cargo" cargo build --offline --lib \
    --manifest-path=src/rust/Cargo.toml --target-dir "${work_dir}/target-default";
  CARGO_HOME="$(\pwd)/src/.cargo" cargo build --offline --lib \
    --features wheels --manifest-path=src/rust/Cargo.toml \
    --target-dir "${work_dir}/target-wheels";
  \rm -rf src/vendor src/.cargo;
  \builtin echo "vendor.tar.xz regenerated: $(\du -h src/rust/vendor.tar.xz | \cut -f1)";
  \builtin echo "Review and commit the Cargo.lock diff; vendor.tar.xz stays out of git (.gitignore).";
