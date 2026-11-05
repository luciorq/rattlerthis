# Parity of platforms (spec sections 3.6, 3.7 and 6.2, row
# test-parity-platform.R), with `method = "micromamba"` and
# `method = "rattler"`:
# * `backend_can_solve()`, the probe of condathis's emulation fallback,
#   answers alike for packages of one platform (osxonly, winonly) and for
#   explicit and lock files (e6, e7), for linux-64, osx-64, osx-arm64,
#   win-64 and win-arm64;
# * `create_env(platform = "osx-64")` solves for osx-64 with its virtual
#   packages (`CONDA_OVERRIDE_OSX` honored), condathis records the
#   platform, and later installs solve for it; an environment without a
#   recorded platform gets it from its package records where condathis
#   has a fallback (Apple Silicon, Windows);
# * the emulation fallback, unmocked: Rosetta 2 on Apple Silicon, x64
#   emulation on Windows on ARM, none elsewhere;
# * every platform condathis knows makes an empty environment, and a
#   platform in the wrong case is refused alike (P-A4, Q25).
#
# Environments are in the process sandbox (setup.R), named
# `rt-pplat-<test>-mm` and `rt-pplat-<test>-rt`.

# The platforms the probe is compared for.
platform_targets <- c("linux-64", "osx-64", "osx-arm64", "win-64", "win-arm64")

# The platform condathis recorded for an environment (its marker), or
# `NULL`.
platform_marker <- function(env_name, method) {
  read_marker_platform <- psolve_condathis("read_backend_marker_platform")
  return(read_marker_platform(psolve_env_dir(env_name, method)))
}

# The platform (subdir) of every package record of an environment, by
# package name.
platform_subdirs <- function(env_name, method) {
  pkgs <- psolve_packages(env_name, method)
  return(stats::setNames(pkgs$platform, pkgs$name))
}

# The native platform of a backend, as condathis asks it.
platform_native <- function(method) {
  generic <- psolve_condathis("backend_native_platform")
  return(generic(psolve_backend(method)))
}

test_that("backend_can_solve() gives the same answers for platform-only packages and environment files", {
  local_parity_micromamba()
  probes <- list(
    osxonly = list(
      args = list(packages = "osxonly", channels = channel_url("osxonly")),
      expected = c(FALSE, TRUE, FALSE, FALSE, FALSE)
    ),
    winonly = list(
      args = list(packages = "winonly", channels = channel_url("winonly")),
      expected = c(FALSE, FALSE, FALSE, TRUE, FALSE)
    ),
    # An explicit file needs no solve: micromamba's dry run succeeds for
    # every platform, and rattler answers TRUE without a solve.
    e6 = list(
      args = list(
        env_file = envfile_fixture("e6.txt"),
        channels = channel_url("chA")
      ),
      expected = rep(TRUE, 5L)
    ),
    # A lock file installs the packages it has for the platform, and
    # nothing for a platform it lacks: no solve either.
    e7 = list(
      args = list(
        env_file = envfile_fixture("e7-lock.yml"),
        channels = channel_url("chA")
      ),
      expected = rep(TRUE, 5L)
    )
  )
  for (probe in names(probes)) {
    for (i in seq_along(platform_targets)) {
      platform <- platform_targets[[i]]
      answers <- vapply(
        psolve_methods,
        function(method) {
          args <- c(
            list(method, channel_priority = "strict", platform = platform),
            probes[[probe]]$args
          )
          return(do.call(psolve_can_solve, args))
        },
        logical(1L)
      )
      expect_identical(
        unname(answers),
        rep(probes[[probe]]$expected[[i]], 2L),
        label = paste(probe, platform)
      )
    }
  }
})

test_that("the probe of an environment file with a pip section is the same on both backends (R-28)", {
  # Both solve the Conda part with the `pip` a `pip:` section adds (pip
  # itself does not run in a probe): on a channel without pip, FALSE, so
  # condathis's emulation fallback is tried for both alike.
  local_parity_micromamba()
  e8 <- envfile_fixture("e8-pip.yml")
  args <- list(
    env_file = e8,
    channels = channel_url("chA"),
    channel_priority = "strict",
    platform = r_build_platform()
  )
  expect_false(do.call(psolve_can_solve, c(list("micromamba"), args)))
  expect_false(do.call(psolve_can_solve, c(list("rattler"), args)))
  checked <- psolve_condathis("backend_can_solve_checked")
  answers <- vapply(
    psolve_methods,
    function(method) {
      return(do.call(checked, c(list(psolve_backend(method)), args)))
    },
    logical(1L)
  )
  expect_identical(answers, c(micromamba = FALSE, rattler = FALSE))
})

test_that("a create for osx-64 solves with its virtual packages, records the platform, and installs follow it", {
  local_parity_micromamba()
  vpk <- psolve_channel("vpk")
  # osxvp needs `__osx >=11`. With CONDA_OVERRIDE_OSX both backends use the
  # given version; without it, an osx-64 target on another OS has
  # `__osx` 0, and on macOS the version of the machine (Rosetta 2 runs
  # osx-64 on the same macOS, 11 or newer on Apple Silicon).
  cases <- list(
    override_new = list(override = "12.0", solves = TRUE),
    override_old = list(override = "10.9", solves = FALSE),
    no_override = list(override = NA_character_, solves = is_macos())
  )
  for (case in names(cases)) {
    withr::local_envvar(CONDA_OVERRIDE_OSX = cases[[case]]$override)
    seen <- list()
    for (method in psolve_methods) {
      env_name <- psolve_env_name(paste0("rt-pplat-vp-", case), method)
      defer_remove_env(env_name, method = method)
      solves <- psolve_can_solve(
        method,
        packages = "osxvp",
        channels = vpk,
        channel_priority = "strict",
        platform = "osx-64"
      )
      created <- psolve_capture(condathis::create_env(
        "osxvp",
        env_name = env_name,
        channels = vpk,
        platform = "osx-64",
        method = method,
        verbose = "silent"
      ))
      seen[[method]] <- list(
        solves = solves,
        error = created$error,
        exists = condathis::env_exists(env_name, method = method)
      )
      if (isTRUE(seen[[method]]$exists)) {
        env_dir <- psolve_env_dir(env_name, method)
        env_platform <- psolve_condathis("env_platform")
        # A later install solves for the environment's platform: osxonly
        # exists for osx-64 only.
        installed <- psolve_capture(condathis::install_packages(
          "osxonly",
          env_name = env_name,
          channels = c(channel_url("osxonly"), vpk),
          method = method,
          verbose = "silent"
        ))
        seen[[method]]$marker <- platform_marker(env_name, method)
        seen[[method]]$env_platform <- env_platform(env_dir)
        seen[[method]]$install_error <- installed$error
        seen[[method]]$subdirs <- platform_subdirs(env_name, method)
      }
    }
    expected <- cases[[case]]$solves
    for (method in psolve_methods) {
      label <- paste(method, case)
      expect_identical(seen[[method]]$solves, expected, label = label)
      expect_identical(seen[[method]]$exists, expected, label = label)
      if (isTRUE(expected)) {
        expect_null(seen[[method]]$error, label = label)
        expect_identical(seen[[method]]$marker, "osx-64", label = label)
        expect_identical(seen[[method]]$env_platform, "osx-64", label = label)
        expect_null(seen[[method]]$install_error, label = label)
        expect_identical(
          seen[[method]]$subdirs,
          c(osxonly = "osx-64", osxvp = "osx-64"),
          label = label
        )
      }
    }
    if (isFALSE(expected)) {
      psolve_expect_same_failure(
        seen$micromamba$error,
        seen$rattler$error,
        rattler_kind = "solve"
      )
    }
  }
})

test_that("an environment of osx-64 packages without a recorded platform", {
  local_parity_micromamba()
  write_marker <- psolve_condathis("write_backend_marker")
  env_platform <- psolve_condathis("env_platform")
  seen <- list()
  for (method in psolve_methods) {
    env_name <- psolve_env_name("rt-pplat-records", method)
    defer_remove_env(env_name, method = method)
    condathis::create_env(
      "osxonly",
      env_name = env_name,
      channels = channel_url("osxonly"),
      platform = "osx-64",
      method = method,
      verbose = "silent"
    )
    # Forget the platform, as for an environment of another tool or an
    # older condathis: a marker without it, and no `.mambarc`
    # (micromamba's own record of `--platform`).
    env_dir <- psolve_env_dir(env_name, method)
    write_marker(env_dir, method, platform = NULL)
    unlink(file.path(env_dir, ".mambarc"))
    recorded <- env_platform(env_dir)
    # intelonly has builds for linux-64, osx-64 and win-64.
    installed <- psolve_capture(condathis::install_packages(
      "intelonly",
      env_name = env_name,
      channels = channel_url("intelonly"),
      method = method,
      verbose = "silent"
    ))
    seen[[method]] <- list(
      marker = platform_marker(env_name, method),
      recorded = recorded,
      error = installed$error,
      subdirs = platform_subdirs(env_name, method)
    )
  }
  # Where condathis has an emulation fallback (Apple Silicon, Windows), an
  # environment without a recorded platform gets the platform of its
  # package records; elsewhere the backend solves for its own platform.
  has_fallback <- isTRUE(psolve_condathis("has_platform_fallback")())
  native <- r_build_platform()
  expected_subdir <- if (isTRUE(has_fallback)) "osx-64" else native
  for (method in psolve_methods) {
    got <- seen[[method]]
    expect_null(got$marker, label = method)
    expect_identical(got$recorded, "osx-64", label = method)
    if (isTRUE(expected_subdir %in% c("linux-64", "osx-64", "win-64"))) {
      expect_null(got$error, label = method)
      expect_identical(
        got$subdirs,
        c(intelonly = expected_subdir, osxonly = "osx-64"),
        label = method
      )
    } else {
      # linux-aarch64: intelonly has no build for it.
      expect_s3_class(got$error, "condathis_install_packages_failed")
      expect_identical(got$subdirs, c(osxonly = "osx-64"), label = method)
    }
  }
  if (isTRUE(is.null(seen$micromamba$error))) {
    expect_null(seen$rattler$error)
  } else {
    psolve_expect_same_failure(
      seen$micromamba$error,
      seen$rattler$error,
      rattler_kind = "solve"
    )
  }
})

test_that("the emulation fallback chooses the same platform on both backends", {
  local_parity_micromamba()
  natives <- vapply(psolve_methods, platform_native, character(1L))
  # rattler solves for the platform of this R (of its own build). So does
  # micromamba here; on an ARM64 PC an x64 R runs micromamba's own binary,
  # which may be an ARM64 one (R-6), so each backend is checked against
  # its own platform.
  expect_identical(natives[["rattler"]], r_build_platform())
  same_native <- identical(natives[["micromamba"]], natives[["rattler"]])
  if (isFALSE(is_windows())) {
    expect_true(same_native)
  }
  requests <- c("osxonly", "winonly", "intelonly")
  seen <- list()
  for (request in requests) {
    for (method in psolve_methods) {
      env_name <- psolve_env_name(paste0("rt-pplat-fb-", request), method)
      defer_remove_env(env_name, method = method)
      created <- psolve_capture(condathis::create_env(
        request,
        env_name = env_name,
        channels = channel_url(request),
        method = method,
        verbose = "output"
      ))
      exists <- isTRUE(condathis::env_exists(env_name, method = method))
      seen[[request]][[method]] <- list(
        error = created$error,
        messages = created$messages[
          !grepl("successfully created", created$messages, fixed = TRUE)
        ],
        exists = exists,
        marker = if (isTRUE(exists)) platform_marker(env_name, method),
        subdirs = if (isTRUE(exists)) platform_subdirs(env_name, method)
      )
    }
  }
  # What a request gives on this machine for a backend that solves for
  # `native`: the platform its package is installed for (`NA` when the
  # create fails), the platform condathis records (`NULL` for the native
  # one), and the emulation message. condathis's Apple Silicon fallback
  # follows the machine; its Windows fallback follows the backend.
  apple_silicon <- identical(
    psolve_condathis("get_sys_arch")(),
    "Darwin-arm64"
  )
  rosetta <- rosetta_running()
  expectation <- function(request, native) {
    builds <- switch(
      request,
      osxonly = "osx-64",
      winonly = "win-64",
      intelonly = c("linux-64", "osx-64", "win-64")
    )
    if (isTRUE(native %in% builds)) {
      return(list(subdir = native, marker = NULL, message = NULL))
    }
    if (isTRUE(apple_silicon)) {
      if (isFALSE(rosetta)) {
        return(list(
          subdir = NA_character_,
          marker = NULL,
          message = "Rosetta 2 is not enabled"
        ))
      }
      if (isTRUE("osx-64" %in% builds)) {
        return(list(
          subdir = "osx-64",
          marker = "osx-64",
          message = "Using Rosetta 2 emulation."
        ))
      }
      return(list(subdir = NA_character_, marker = NULL, message = NULL))
    }
    if (
      isTRUE(is_windows()) &&
        identical(native, "win-arm64") &&
        isTRUE("win-64" %in% builds)
    ) {
      return(list(
        subdir = "win-64",
        marker = "win-64",
        message = "Using x64 emulation for win-64 packages."
      ))
    }
    return(list(subdir = NA_character_, marker = NULL, message = NULL))
  }
  for (request in requests) {
    for (method in psolve_methods) {
      expected <- expectation(request, natives[[method]])
      got <- seen[[request]][[method]]
      label <- paste(method, request)
      if (is.na(expected$subdir)) {
        expect_s3_class(got$error, "condathis_create_env_failed")
        expect_true(
          rlang::cnd_inherits(
            got$error,
            if (identical(method, "rattler")) {
              "rattlerthis_rattler_solve"
            } else {
              "condathis_micromamba_status_error"
            }
          ),
          label = label
        )
        expect_false(got$exists, label = label)
      } else {
        expect_null(got$error, label = label)
        expect_identical(unname(got$subdirs), expected$subdir, label = label)
        expect_identical(got$marker, expected$marker, label = label)
      }
      if (is.null(expected$message)) {
        expect_identical(got$messages, character(0L), label = label)
      } else {
        expect_length(got$messages, 1L)
        expect_match(got$messages, expected$message, fixed = TRUE)
      }
    }
    if (isTRUE(same_native)) {
      expect_identical(
        seen[[request]]$rattler$messages,
        seen[[request]]$micromamba$messages,
        label = request
      )
      expect_identical(
        seen[[request]]$rattler$subdirs,
        seen[[request]]$micromamba$subdirs,
        label = request
      )
      expect_identical(
        seen[[request]]$rattler$marker,
        seen[[request]]$micromamba$marker,
        label = request
      )
    }
  }
})

test_that("every platform condathis knows makes an empty environment on both backends", {
  local_parity_micromamba()
  platforms <- condathis_known_platforms()
  expect_length(platforms, 32L)
  seen <- list()
  for (method in psolve_methods) {
    env_name <- psolve_env_name("rt-pplat-known", method)
    defer_remove_env(env_name, method = method)
    seen[[method]] <- vapply(
      platforms,
      function(platform) {
        created <- psolve_capture(condathis::create_env(
          env_name = env_name,
          platform = platform,
          channels = channel_url("chA"),
          overwrite = TRUE,
          method = method,
          verbose = "silent"
        ))
        if (isFALSE(is.null(created$error))) {
          return(paste("error:", class(created$error)[[1L]]))
        }
        return(platform_marker(env_name, method) %||% "no platform recorded")
      },
      character(1L)
    )
  }
  expect_identical(seen$micromamba, stats::setNames(platforms, platforms))
  expect_identical(seen$rattler, seen$micromamba)
})

test_that("a platform in another spelling is refused alike, before any backend call (P-A4, Q25)", {
  local_parity_micromamba()
  cases <- c(
    `Linux-64` = "linux-64",
    `OSX-ARM64` = "osx-arm64",
    `linux-arm64` = "linux-aarch64",
    `win64` = "win-64"
  )
  for (platform in names(cases)) {
    seen <- list()
    for (method in psolve_methods) {
      env_name <- psolve_env_name("rt-pplat-case", method)
      seen[[method]] <- list(
        create = psolve_capture(condathis::create_env(
          "foo",
          env_name = env_name,
          channels = channel_url("chA"),
          platform = platform,
          method = method,
          verbose = "silent"
        )),
        exists = condathis::env_exists(env_name, method = method),
        dir = fs::dir_exists(condathis::get_env_dir(env_name, method = method))
      )
    }
    rt_error <- seen$rattler$create$error
    mm_error <- seen$micromamba$create$error
    expect_s3_class(rt_error, "condathis_create_env_invalid_platform")
    expect_s3_class(rt_error, "condathis_invalid_arg")
    expect_identical(class(rt_error), class(mm_error), label = platform)
    expect_identical(
      conditionMessage(rt_error),
      conditionMessage(mm_error),
      label = platform
    )
    # condathis suggests the known name, lower case.
    expect_match(
      conditionMessage(rt_error),
      paste0("Did you mean \"", cases[[platform]], "\"?"),
      fixed = TRUE
    )
    for (method in psolve_methods) {
      expect_false(seen[[method]]$exists, label = paste(method, platform))
      expect_false(seen[[method]]$dir, label = paste(method, platform))
    }
  }
})
