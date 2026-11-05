# Parity of the pip steps of environment files (R-8, R-28):
# `create_env(env_file = )` with `method = "micromamba"` and
# `method = "rattler"`, with a real python from conda-forge and the local
# wheel of fixtures/pip (`rtwheel`, built by tools/make-test-wheel.py), so
# pip never asks PyPI (`PIP_NO_INDEX=1`). After the Conda packages are
# linked, micromamba 2.10.0 runs pip in the activated environment for every
# `pip:` section of a YAML file (`<python> -m pip install -r <file>
# --no-input`) and for the pip packages of a lock file (`--no-deps`), and
# so does the rattler backend (`rattler_run_pip_steps()`): the same
# packages, the same output per verbose level, the same failures.
#
# Environments are in the process sandbox (setup.R), named
# `rt-ppip-<case>-mm` and `rt-ppip-<case>-rt`.

# pip only installs the local wheel: no index, no version check.
ppip_local_pip <- function(env = parent.frame()) {
  withr::local_envvar(
    c(PIP_NO_INDEX = "1", PIP_DISABLE_PIP_VERSION_CHECK = "1"),
    .local_envir = env
  )
  return(invisible(NULL))
}

# The python version of these tests: one that conda-forge builds for the
# platform of this R, so no create falls back to emulation and the solve
# probe, which pins that platform, finds it. conda-forge builds python for
# win-arm64 only from 3.14 on.
ppip_python_version <- function() {
  if (isTRUE(is_windows_arm64())) {
    return("3.14")
  }
  return("3.12")
}

# The test wheel, copied into a new directory of the test.
ppip_wheel <- function(env = parent.frame()) {
  dir <- withr::local_tempdir(pattern = "rt-ppip-wheel-", .local_envir = env)
  name <- "rtwheel-1.0-py3-none-any.whl"
  file.copy(fixtures_path("pip", name), file.path(dir, name))
  return(normalizePath(file.path(dir, name), winslash = "/"))
}

# Writes an environment file into a new directory of its own and returns
# its path.
ppip_env_file <- function(lines, name = "pip.yml", env = parent.frame()) {
  dir <- withr::local_tempdir(pattern = "rt-ppip-file-", .local_envir = env)
  path <- file.path(dir, name)
  writeLines(lines, path, useBytes = TRUE)
  return(normalizePath(path, winslash = "/"))
}

# A YAML file with python from conda-forge and the given `pip:` sections
# (each a character vector of requirements; `character(0)` is `pip: []`).
ppip_yaml <- function(..., env = parent.frame()) {
  sections <- list(...)
  pip_lines <- unlist(lapply(sections, function(reqs) {
    if (identical(length(reqs), 0L)) {
      return("  - pip: []")
    }
    return(c("  - pip:", paste0("    - ", reqs)))
  }))
  return(ppip_env_file(
    c(
      "channels:",
      "  - conda-forge",
      "dependencies:",
      paste0("  - python=", ppip_python_version()),
      pip_lines
    ),
    env = env
  ))
}

# Creates an environment from `env_file` with `method` at `verbose`, and
# records what a user sees (see `psolve_capture()`), with the carriage
# returns of the printed lines dropped (pip and micromamba end lines with
# CRLF on Windows).
ppip_create <- function(env_name, env_file, method, verbose = "silent") {
  captured <- psolve_capture(condathis::create_env(
    env_file = env_file,
    env_name = env_name,
    method = method,
    verbose = verbose
  ))
  captured$output <- sub("\r$", "", captured$output)
  return(captured)
}

# What `import rtwheel` gives in the environment: its version, or the
# status of a failed import.
ppip_rtwheel_version <- function(env_name, method) {
  res <- condathis::run_bin(
    "python",
    c("-c", "import rtwheel; print(rtwheel.__version__)"),
    env_name = env_name,
    method = method,
    verbose = "silent",
    error = "continue"
  )
  if (isFALSE(identical(res$status, 0L))) {
    return(paste("status", res$status))
  }
  return(trimws(res$stdout))
}

# The `site-packages` directory of the python of `ppip_python_version()`
# in an environment.
ppip_site_packages <- function(env_name, method) {
  prefix <- condathis::get_env_dir(env_name, method = method)
  if (isTRUE(is_windows())) {
    return(file.path(prefix, "Lib", "site-packages"))
  }
  return(file.path(
    prefix,
    "lib",
    paste0("python", ppip_python_version()),
    "site-packages"
  ))
}

# The rows of `psolve_packages()` from conda-forge, and those micromamba
# lists for the packages pip installed (channel `pypi`).
ppip_conda_rows <- function(pkgs) {
  out <- pkgs[pkgs$channel != "pypi", , drop = FALSE]
  rownames(out) <- NULL
  return(out)
}

# Asserts that both environments have the same Conda packages, the wheel
# installed by pip, and the same listing of it.
ppip_expect_same_packages <- function(env_names) {
  pkgs <- lapply(psolve_methods, function(method) {
    psolve_packages(env_names[[method]], method)
  })
  names(pkgs) <- psolve_methods
  expect_identical(
    ppip_conda_rows(pkgs$rattler),
    ppip_conda_rows(pkgs$micromamba)
  )
  expect_true("python" %in% pkgs$rattler$name)
  expect_true("pip" %in% pkgs$rattler$name)
  # micromamba lists what pip installed (`pip inspect`) as channel `pypi`.
  mm_pypi <- pkgs$micromamba[pkgs$micromamba$channel == "pypi", , drop = FALSE]
  expect_identical(mm_pypi$name, "rtwheel")
  expect_identical(mm_pypi$version, "1.0")
  # condathis's default reader, which lists rattler environments, reads the
  # PyPI packages from the `site-packages` metadata of the environment's
  # python, as micromamba's `pip inspect` lists them (R-9): the frames are
  # the same.
  expect_identical(pkgs$rattler, pkgs$micromamba)
  for (method in psolve_methods) {
    env_name <- env_names[[method]]
    expect_identical(ppip_rtwheel_version(env_name, method), "1.0")
    dist_info <- file.path(
      ppip_site_packages(env_name, method),
      "rtwheel-1.0.dist-info"
    )
    expect_true(dir.exists(dist_info), label = method)
    expect_identical(
      readLines(file.path(dist_info, "INSTALLER")),
      "pip",
      label = method
    )
  }
  return(invisible(pkgs))
}

test_that("pip sections of a YAML file install the same packages with both backends (R-8)", {
  local_parity_micromamba()
  ppip_local_pip()
  wheel <- ppip_wheel()
  # Two steps, in file order: the wheel, then an empty section, which
  # micromamba also runs (pip with an empty requirements file).
  env_file <- ppip_yaml(wheel, character(0L))
  env_names <- list()
  seen <- list()
  for (method in psolve_methods) {
    env_names[[method]] <- psolve_env_name("rt-ppip-yml", method)
    defer_remove_env(env_names[[method]], method = method)
    seen[[method]] <- ppip_create(
      env_names[[method]],
      env_file,
      method,
      verbose = "full"
    )
  }
  for (method in psolve_methods) {
    expect_null(seen[[method]]$error, label = method)
  }
  ppip_expect_same_packages(env_names)
  # The requirements files (`mambaf*`) were written next to the file and
  # deleted.
  expect_identical(
    list.files(dirname(env_file), all.files = TRUE, no.. = TRUE),
    "pip.yml"
  )
  # Both ask for `pip` with the file's specs, as libmamba adds it.
  for (method in psolve_methods) {
    specs <- grep(
      "^# update specs",
      read_history(condathis::get_env_dir(
        env_names[[method]],
        method = method
      ))$lines,
      value = TRUE
    )
    expect_identical(
      specs,
      paste0(
        "# update specs: [\"python=",
        ppip_python_version(),
        "\", \"pip\"]"
      ),
      label = method
    )
  }
  # At "full", both print micromamba's line for each step, then pip's
  # output; the result's stdout holds them too.
  for (method in psolve_methods) {
    output <- seen[[method]]$output
    stdout <- seen[[method]]$value$stdout
    header <- paste0("Installing pip packages: ", wheel)
    expect_identical(sum(output == header), 1L, label = method)
    expect_identical(
      sum(output == "Installing pip packages: "),
      1L,
      label = method
    )
    expect_true(
      match(header, output) < match("Installing pip packages: ", output),
      label = method
    )
    expect_true(
      "Successfully installed rtwheel-1.0" %in% output,
      label = method
    )
    expect_true(grepl(header, stdout, fixed = TRUE), label = method)
    expect_true(
      grepl("Successfully installed rtwheel-1.0", stdout, fixed = TRUE),
      label = method
    )
  }
})

test_that("pip's output is printed only at verbose = \"full\", with both backends", {
  local_parity_micromamba()
  ppip_local_pip()
  env_file <- ppip_yaml(ppip_wheel())
  for (verbose in c("silent", "cmd", "output")) {
    for (method in psolve_methods) {
      env_name <- psolve_env_name(paste0("rt-ppip-", verbose), method)
      defer_remove_env(env_name, method = method)
      seen <- ppip_create(env_name, env_file, method, verbose = verbose)
      info <- paste(verbose, method)
      expect_null(seen$error, label = info)
      expect_false(
        any(grepl(
          "Installing pip packages|Successfully installed",
          seen$output
        )),
        info = info
      )
      # At "cmd" each backend prints its own request line (R-2), nothing
      # of pip.
      running <- grepl("^Running ", seen$output)
      expect_identical(
        any(running),
        identical(verbose, "cmd"),
        info = info
      )
      expect_true(
        grepl(
          "Successfully installed rtwheel-1.0",
          seen$value$stdout,
          fixed = TRUE
        ),
        info = info
      )
      expect_identical(
        ppip_rtwheel_version(env_name, method),
        "1.0",
        info = info
      )
    }
  }
})

test_that("a failing pip step fails the create alike, and leaves no environment", {
  local_parity_micromamba()
  ppip_local_pip()
  env_file <- ppip_yaml("rtmissing==9.9")
  seen <- list()
  for (method in psolve_methods) {
    env_name <- psolve_env_name("rt-ppip-fail", method)
    defer_remove_env(env_name, method = method)
    seen[[method]] <- ppip_create(env_name, env_file, method)
    expect_false(condathis::env_exists(env_name, method = method))
    expect_false(fs::dir_exists(condathis::get_env_dir(
      env_name,
      method = method
    )))
  }
  psolve_expect_same_failure(
    seen$micromamba$error,
    seen$rattler$error,
    rattler_kind = "pip"
  )
  expect_s3_class(seen$rattler$error, "condathis_create_env_failed")
  expect_false(inherits(seen$rattler$error, "condathis_backend_unsupported"))
  # Both report pip's status and its error.
  mm_parent <- seen$micromamba$error$parent
  rt_parent <- seen$rattler$error$parent
  expect_identical(mm_parent$status, 1L)
  expect_identical(rt_parent$status, 1L)
  expect_identical(rt_parent$kind, "pip")
  for (parent in list(mm_parent, rt_parent)) {
    expect_true(grepl(
      "No matching distribution found for rtmissing==9.9",
      parent$stderr,
      fixed = TRUE
    ))
  }
  expect_true(grepl(
    "pip failed to install packages",
    conditionMessage(rt_parent),
    fixed = TRUE
  ))
  expect_true(grepl(
    "pip failed to install packages",
    mm_parent$stderr,
    fixed = TRUE
  ))
  expect_identical(
    list.files(dirname(env_file), all.files = TRUE, no.. = TRUE),
    "pip.yml"
  )
})

# --- Lock files ---------------------------------------------------------------------

# The package records (`conda-meta/*.json`) of a python environment from
# conda-forge, made once per run with rattler: what the lock files below
# list.
ppip_state <- new.env(parent = emptyenv())

ppip_python_records <- function() {
  if (isFALSE(is.null(ppip_state$records))) {
    return(ppip_state$records)
  }
  env_name <- "rt-ppip-records"
  condathis::create_env(
    c(paste0("python=", ppip_python_version()), "pip"),
    env_name = env_name,
    channels = "conda-forge",
    method = "rattler",
    verbose = "silent"
  )
  prefix <- condathis::get_env_dir(env_name, method = "rattler")
  files <- list.files(
    file.path(prefix, "conda-meta"),
    pattern = "[.]json$",
    full.names = TRUE
  )
  records <- lapply(files, jsonlite::fromJSON, simplifyVector = FALSE)
  condathis::remove_env(env_name, method = "rattler", verbose = "silent")
  ppip_state$records <- records
  return(records)
}

# The sha256 of the committed wheel, as tools/make-test-wheel.py prints it
# (the build is deterministic). The lock files give it to pip, which checks
# it.
ppip_wheel_sha256 <- "0f82c902f10c658f91addf0c04e6859fc727c5d1d059d469c93a4c9267d6893f"

# A conda-lock file (version 1) with the python environment for this
# machine's platform and the wheel as a pip package.
ppip_conda_lock <- function(wheel, env = parent.frame()) {
  platform <- r_build_platform()
  conda_entries <- unlist(lapply(ppip_python_records(), function(record) {
    c(
      paste0("- name: ", record$name),
      paste0("  version: '", record$version, "'"),
      "  manager: conda",
      paste0("  platform: ", platform),
      "  dependencies: {}",
      paste0("  url: ", record$url),
      paste0("  hash: {md5: ", record$md5, ", sha256: ", record$sha256, "}"),
      "  category: main",
      "  optional: false"
    )
  }))
  pip_entry <- c(
    "- name: rtwheel",
    "  version: '1.0'",
    "  manager: pip",
    paste0("  platform: ", platform),
    "  dependencies: {}",
    paste0("  url: ", file_url(wheel)),
    paste0("  hash: {sha256: ", ppip_wheel_sha256, "}"),
    "  category: main",
    "  optional: false"
  )
  return(ppip_env_file(
    c(
      "version: 1",
      "metadata:",
      paste0("  content_hash: {", platform, ": rt-ppip}"),
      "  channels: [{url: conda-forge, used_env_vars: []}]",
      paste0("  platforms: [", platform, "]"),
      "  sources: [environment.yml]",
      "package:",
      conda_entries,
      pip_entry
    ),
    name = "pip-lock.yml",
    env = env
  ))
}

# A mambajs lock file with the python environment and the wheel.
ppip_mambajs_lock <- function(wheel, env = parent.frame()) {
  packages <- list()
  for (record in ppip_python_records()) {
    packages[[record$fn]] <- list(
      name = record$name,
      version = record$version,
      build = record$build,
      subdir = record$subdir,
      channel = "conda-forge",
      hash = list(sha256 = record$sha256)
    )
  }
  doc <- list(
    lockVersion = "1.0.0",
    platform = r_build_platform(),
    channels = list("conda-forge"),
    channelInfo = list(
      `conda-forge` = list(list(url = "https://conda.anaconda.org/conda-forge"))
    ),
    packages = packages,
    pipPackages = list(
      `rtwheel-1.0-py3-none-any.whl` = list(
        name = "rtwheel",
        version = "1.0",
        url = file_url(wheel),
        registry = "https://pypi.org/simple",
        hash = list(sha256 = ppip_wheel_sha256)
      )
    )
  )
  return(ppip_env_file(
    jsonlite::toJSON(doc, auto_unbox = TRUE, pretty = TRUE),
    name = "pip-lock.json",
    env = env
  ))
}

test_that("the pip packages of lock files install the same packages with both backends (R-8)", {
  local_parity_micromamba()
  ppip_local_pip()
  wheel <- ppip_wheel()
  expect_identical(
    unname(tools::md5sum(wheel)),
    unname(tools::md5sum(fixtures_path("pip", "rtwheel-1.0-py3-none-any.whl")))
  )
  lock_files <- list(
    conda_lock = ppip_conda_lock(wheel),
    mambajs = ppip_mambajs_lock(wheel)
  )
  for (kind in names(lock_files)) {
    env_names <- list()
    for (method in psolve_methods) {
      env_names[[method]] <- psolve_env_name(paste0("rt-ppip-", kind), method)
      defer_remove_env(env_names[[method]], method = method)
      seen <- ppip_create(
        env_names[[method]],
        lock_files[[kind]],
        method,
        verbose = "full"
      )
      info <- paste(kind, method)
      expect_null(seen$error, label = info)
      # One step without dependencies, with the line libmamba writes.
      expect_true(
        paste0(
          "Installing pip --no-deps packages: rtwheel @ ",
          file_url(wheel),
          "#sha256=",
          ppip_wheel_sha256
        ) %in%
          seen$output,
        info = info
      )
    }
    ppip_expect_same_packages(env_names)
  }
})

# --- The solve probe ------------------------------------------------------------------

test_that("the solve probe of a file with a pip section answers alike (R-28)", {
  local_parity_micromamba()
  env_file <- ppip_yaml("rtwheel")
  local_file <- ppip_env_file(
    c(
      "dependencies:",
      paste0("  - python=", ppip_python_version()),
      "  - pip:",
      "    - rtwheel"
    )
  )
  platform <- r_build_platform()
  for (method in psolve_methods) {
    # conda-forge has python and the pip the section adds: solves. pip
    # itself does not run, as in micromamba's dry run.
    expect_identical(
      psolve_can_solve(
        method,
        env_file = env_file,
        channels = "conda-forge",
        channel_priority = "strict",
        platform = platform
      ),
      TRUE,
      label = method
    )
    # The same file without its channel, against chA, which has neither
    # python nor pip: does not solve.
    expect_identical(
      psolve_can_solve(
        method,
        env_file = local_file,
        channels = channel_url("chA"),
        channel_priority = "strict",
        platform = platform
      ),
      FALSE,
      label = method
    )
  }
})
