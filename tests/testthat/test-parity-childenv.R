# Parity of the environment that child processes get (spec 6.2, row
# test-parity-childenv.R; T4 of SPEC.md): run(), run_bin() with and without
# activation, from an R session with stale Conda settings, with
# `method = "micromamba"` and `method = "rattler"`. The two environments are
# compared after each backend's root, the environment name, the per-call
# temporary directory and R's own session directory are replaced by
# placeholders. What still differs is the allowlist of R-5, each entry with
# its reason. condathis activates the environment first and then starts
# the command itself for both backends, with run(), run_bin() and
# run_pipeline() (R-4 is closed: micromamba's run() no longer goes through
# `micromamba run`). Also: an activation without bash (P-A8), the exit
# status of a command killed by a signal (P-A2), and activate.d scripts,
# which both backends run (R-1), with what they print, unset or fail.

# The stale settings of the session: none of them may reach a child.
pr_dirty_session <- c(
  CONDA_PREFIX = if (isTRUE(is_windows())) {
    "C:\\rt-bogus\\prefix"
  } else {
    "/rt-bogus/prefix"
  },
  CONDA_SHLVL = "1",
  CONDA_DEFAULT_ENV = "rt-bogus",
  CONDA_PROMPT_MODIFIER = "(rt-bogus) ",
  RT_PR_SESSION = "kept"
)

# The environment of a child started by `fn` ("run", "run_bin",
# "run_bin_noact", that is run_bin() with `activate = FALSE`, or
# "run_pipeline", whose first step prints and second copies) in
# `env_name`: a named character vector, names in upper case on Windows,
# without processx's per-process marker variables (`PROCESSX_*`).
pr_child_env <- function(fn, method, env_name) {
  args <- rscript_print_env_args()
  res <- switch(
    fn,
    run = condathis::run(
      rscript_path(),
      args,
      env_name = env_name,
      method = method,
      verbose = "silent"
    ),
    run_bin = condathis::run_bin(
      rscript_path(),
      args,
      env_name = env_name,
      method = method,
      verbose = "silent"
    ),
    run_bin_noact = condathis::run_bin(
      rscript_path(),
      args,
      env_name = env_name,
      method = method,
      verbose = "silent",
      activate = FALSE
    ),
    run_pipeline = condathis::run_pipeline(
      condathis::run_step(rscript_path(), args),
      condathis::run_step(rscript_path(), rscript_cat_args()),
      env_name = env_name,
      method = method,
      verbose = "silent"
    )
  )
  env <- parse_env_output(condathis::parse_output(res))
  if (isTRUE(is_windows())) {
    names(env) <- toupper(names(env))
  }
  return(env[!grepl("^PROCESSX_", names(env))])
}

# Replaces every spelling of the directory `path` in `x` by `token`: with
# `/` for `\`, and without case on Windows.
pr_sub_path <- function(x, path, token) {
  real <- tryCatch(as.character(fs::path_real(path)), error = function(e) path)
  for (spelling in unique(c(path, real))) {
    spelling <- gsub("\\", "/", spelling, fixed = TRUE)
    pattern <- gsub("([][{}()+*^$|\\\\?.])", "\\\\\\1", spelling)
    x <- gsub(pattern, token, x, ignore.case = isTRUE(is_windows()))
  }
  return(x)
}

# A child environment with the paths that differ by construction replaced:
# the child's own TMPDIR (a new directory per call) by `<CALLTMP>`, the
# backend's root by `<ROOT>`, the environment name by `<ENV>`, and the
# name of R's session directory by `Rtmp<X>`.
pr_normalize_env <- function(env, root, env_name) {
  values <- gsub("\\", "/", env, fixed = TRUE)
  call_tmp <- values[["TMPDIR"]]
  values <- pr_sub_path(values, call_tmp, "<CALLTMP>")
  values <- pr_sub_path(values, root, "<ROOT>")
  values <- gsub(env_name, "<ENV>", values, fixed = TRUE)
  values <- gsub("Rtmp[A-Za-z0-9]+", "Rtmp<X>", values)
  names(values) <- names(env)
  return(values)
}

# The entries of a PATH value, in order, empty ones included (a separator
# at the end gives an empty last entry), compared without case on Windows.
pr_path_entries <- function(value) {
  entries <- strsplit(value, .Platform$path.sep, fixed = TRUE)[[1L]]
  if (isTRUE(endsWith(value, .Platform$path.sep))) {
    entries <- c(entries, "")
  }
  if (isTRUE(is_windows())) {
    entries <- tolower(entries)
  }
  return(entries)
}

# The entries of a PATH value as a set in order of first appearance, without
# empty ones. The children here are Rscript processes, and on Windows R
# puts Rtools in front of the PATH it starts with (again, spelled with `/`
# and `\`), and micromamba's activation adds the session's directories
# again, spelled with `\`: so on Windows only the sets compare.
pr_path_set <- function(entries) {
  return(unique(entries[nzchar(entries)]))
}

test_that("children of both backends get the same environment, but for R-5", {
  local_parity_micromamba()
  env_names <- pr_env_names("rt-pce")
  pr_defer_remove_envs(env_names)
  roots <- list()
  for (method in pr_methods) {
    condathis::create_env(
      "foo",
      env_name = env_names[[method]],
      channels = channel_url("chA"),
      method = method,
      verbose = "silent"
    )
    roots[[method]] <- condathis::get_install_dir(method = method)$path
  }
  # R sets TZDIR on macOS the first time it formats a time; set it now, so
  # the session is the same for every child of this test.
  invisible(format(Sys.time(), "%Z"))
  withr::local_envvar(pr_dirty_session)
  # A session PATH with an empty last entry and a repeated one: activated
  # PATHs have neither, with both backends (R-5).
  session_path <- Sys.getenv("PATH")
  first_entry <- strsplit(session_path, .Platform$path.sep, fixed = TRUE)[[
    1L
  ]][[1L]]
  withr::local_envvar(
    PATH = paste0(
      session_path,
      .Platform$path.sep,
      first_entry,
      .Platform$path.sep
    )
  )
  session <- Sys.getenv()
  unix <- isFALSE(is_windows())

  for (fn in c("run", "run_bin", "run_bin_noact", "run_pipeline")) {
    raw <- list()
    env <- list()
    for (method in pr_methods) {
      raw[[method]] <- pr_child_env(fn, method, env_names[[method]])
      env[[method]] <- pr_normalize_env(
        raw[[method]],
        root = roots[[method]],
        env_name = env_names[[method]]
      )
    }
    mm <- env$micromamba
    rt <- env$rattler
    activated <- isFALSE(identical(fn, "run_bin_noact"))

    # The activation and condathis's own settings, equal on both: the stale
    # session values are gone.
    for (method in pr_methods) {
      child <- env[[method]]
      info <- paste(fn, method)
      expect_identical(
        child[["CONDA_SHLVL"]],
        if (isTRUE(activated)) "1" else "0",
        info = info
      )
      expect_identical(
        child[["CONDA_PREFIX"]],
        if (isTRUE(activated)) "<ROOT>/envs/<ENV>" else "",
        info = info
      )
      expect_identical(
        child[["CONDA_DEFAULT_ENV"]],
        if (isTRUE(activated)) "<ENV>" else "",
        info = info
      )
      expect_identical(child[["CONDA_ENVS_PATH"]], "<ROOT>/envs", info = info)
      expect_identical(child[["MAMBA_SHLVL"]], "0", info = info)
      expect_identical(child[["RT_PR_SESSION"]], "kept", info = info)
      # Each backend's own package cache (R-5, decision Q9): micromamba's
      # `<root>/pkgs`, and for rattler `<rattler root>/conda-pkgs`, which
      # condathis owns and clean_cache() empties.
      pkgs_dir <- if (identical(method, "micromamba")) {
        "<ROOT>/pkgs"
      } else {
        "<ROOT>/conda-pkgs"
      }
      expect_identical(child[["CONDA_PKGS_DIRS"]], pkgs_dir, info = info)
      expect_identical(child[["MAMBA_PKGS_DIRS"]], pkgs_dir, info = info)
      # condathis's new temporary directory per call, below R's.
      expect_true(
        startsWith(basename(raw[[method]][["TMPDIR"]]), "condathis-tmp"),
        info = paste(info, raw[[method]][["TMPDIR"]])
      )
      expect_true(
        path_is_within(raw[[method]][["TMPDIR"]], tempdir()),
        info = paste(info, raw[[method]][["TMPDIR"]])
      )
    }

    # The allowlist of R-5: what each backend's activation sets that the
    # other's does not.
    only_mm <- character(0L)
    only_rt <- character(0L)
    differ <- c("CONDA_PKGS_DIRS", "MAMBA_PKGS_DIRS")
    if (isTRUE(activated)) {
      # micromamba's activation names its own binary.
      only_mm <- c(only_mm, "MAMBA_EXE")
      # micromamba puts a `condabin` directory of its own on PATH.
      differ <- c(differ, "PATH")
      if (isTRUE(unix)) {
        # micromamba's activation sets a UTF-8 locale; rattler's keeps the
        # session's LC_ALL.
        if (isTRUE("LC_ALL" %in% names(session))) {
          differ <- c(differ, "LC_ALL")
        } else {
          only_mm <- c(only_mm, "LC_ALL")
        }
      } else {
        # micromamba's cmd.exe activation sets the console code page and
        # UTF-8 for Python, and the environment in PROMPT.
        only_mm <- c(
          only_mm,
          "_CONDA_OLD_CHCP",
          "PYTHONIOENCODING",
          "PYTHONUTF8"
        )
        if (isTRUE("PROMPT" %in% toupper(names(session)))) {
          differ <- c(differ, "PROMPT")
        } else {
          only_mm <- c(only_mm, "PROMPT")
        }
      }
    }
    expect_setequal(setdiff(names(mm), names(rt)), only_mm)
    expect_setequal(setdiff(names(rt), names(mm)), only_rt)
    common <- setdiff(intersect(names(mm), names(rt)), differ)
    expect_identical(rt[common], mm[common], info = fn)

    if (isTRUE(activated)) {
      expect_identical(
        normalizePath(raw$micromamba[["MAMBA_EXE"]], winslash = "/"),
        rt_test_state$micromamba,
        info = fn
      )
      mm_path <- pr_path_entries(mm[["PATH"]])
      rt_path <- pr_path_entries(rt[["PATH"]])
      condabin <- basename(mm_path) == "condabin"
      expect_identical(sum(condabin), 1L, info = fn)
      # micromamba's own `<root>/condabin` (on every OS: condathis runs
      # micromamba with its root, TD5), which nothing creates.
      expect_identical(
        mm_path[condabin],
        if (isTRUE(unix)) "<ROOT>/condabin" else "<root>/condabin",
        info = fn
      )
      expect_false(any(basename(rt_path) == "condabin"), info = fn)
      # No empty entry on either PATH (condathis composes micromamba's,
      # rattlerthis tidies rattler's); on Linux and macOS no repeated one
      # either, and the same entries in the same order but for condabin.
      expect_true(all(nzchar(rt_path)), info = fn)
      expect_true(all(nzchar(mm_path)), info = fn)
      if (isTRUE(unix)) {
        expect_identical(anyDuplicated(rt_path), 0L, info = fn)
        expect_identical(rt_path, mm_path[!condabin], info = fn)
      } else {
        expect_identical(
          pr_path_set(rt_path),
          pr_path_set(mm_path[!condabin]),
          info = fn
        )
      }
      if (isTRUE(unix)) {
        expect_identical(mm[["LC_ALL"]], "C.UTF-8", info = fn)
        if (isTRUE("LC_ALL" %in% names(session))) {
          expect_identical(rt[["LC_ALL"]], session[["LC_ALL"]], info = fn)
        }
        # The environment's bin directory comes first on both.
        expect_identical(rt_path[[1L]], "<ROOT>/envs/<ENV>/bin", info = fn)
        expect_identical(mm_path[[1L]], "<ROOT>/envs/<ENV>/bin", info = fn)
      } else {
        expect_identical(mm[["PYTHONUTF8"]], "1", info = fn)
        # micromamba prefixes the session's prompt with the environment.
        expect_true(startsWith(mm[["PROMPT"]], "(<ENV>) "), info = fn)
        if (isTRUE("PROMPT" %in% names(rt))) {
          expect_identical(
            mm[["PROMPT"]],
            paste0("(<ENV>) ", rt[["PROMPT"]]),
            info = fn
          )
        }
        # The environment's directories, in the same place on both (entries
        # are compared without case on Windows).
        expect_true("<root>/envs/<env>/library/bin" %in% rt_path, info = fn)
        expect_identical(
          match("<root>/envs/<env>", rt_path),
          match("<root>/envs/<env>", mm_path),
          info = fn
        )
      }
    }
    # Commands never get a root prefix of either backend (TD5: condathis
    # sets one only for micromamba's own processes).
    expect_identical(mm[["MAMBA_ROOT_PREFIX"]], "", info = fn)
    expect_identical(rt[["MAMBA_ROOT_PREFIX"]], "", info = fn)
    if (isTRUE("_" %in% names(session))) {
      expect_identical(rt[["_"]], mm[["_"]], info = fn)
    }
  }
})

# The value of a variable, or `NA` when the environment does not have it.
pr_value <- function(env, name) {
  if (isTRUE(name %in% names(env))) {
    return(unname(env[[name]]))
  }
  return(NA_character_)
}

test_that("an environment given by env_path() runs the same with both backends (R-14)", {
  # Each backend runs commands in an environment it did not create, given
  # by its directory: the environment of the other backend, its own, and a
  # copy outside any `envs` directory. The activation is the directory's
  # (an activate.d script sets one variable and unsets another), the
  # environment is named as libmamba names a directory (its name when its
  # parent is an `envs` directory, else its path), and the commands get
  # the running backend's own envs and package directories, never the
  # directory the environment is in. What differs is the allowlist of R-5.
  # Nothing is written into the environment.
  local_parity_micromamba()
  env_names <- pr_env_names("rt-pce-ep")
  pr_defer_remove_envs(env_names)
  targets <- list()
  roots <- list()
  for (method in pr_methods) {
    condathis::create_env(
      "foo",
      env_name = env_names[[method]],
      channels = channel_url("chA"),
      method = method,
      verbose = "silent"
    )
    roots[[method]] <- condathis::get_install_dir(method = method)$path
    targets[[method]] <- normalizePath(
      condathis::get_env_dir(env_names[[method]], method = method),
      winslash = "/"
    )
    activate_dir <- file.path(targets[[method]], "etc", "conda", "activate.d")
    dir.create(activate_dir, recursive = TRUE, showWarnings = FALSE)
    if (isTRUE(is_windows())) {
      writeLines(
        c("@set \"RT_PCE_EP=on\"", "@set \"RT_PCE_EP_GONE=\""),
        file.path(activate_dir, "rt-pce-ep.bat")
      )
    } else {
      writeLines(
        c("export RT_PCE_EP=on", "unset RT_PCE_EP_GONE"),
        file.path(activate_dir, "rt-pce-ep.sh")
      )
    }
  }
  foreign <- file.path(withr::local_tempdir(pattern = "rt-pce-ep-"), "pfx")
  fs::dir_copy(targets$micromamba, foreign)
  targets$foreign <- normalizePath(foreign, winslash = "/")
  invisible(format(Sys.time(), "%Z"))
  withr::local_envvar(c(pr_dirty_session, RT_PCE_EP_GONE = "session"))
  session <- Sys.getenv()
  unix <- isFALSE(is_windows())
  normalize <- function(raw, target, root) {
    values <- gsub("\\", "/", raw, fixed = TRUE)
    values <- pr_sub_path(values, values[["TMPDIR"]], "<CALLTMP>")
    values <- pr_sub_path(values, target, "<TARGET>")
    values <- pr_sub_path(values, root, "<ROOT>")
    values <- gsub("Rtmp[A-Za-z0-9]+", "Rtmp<X>", values)
    names(values) <- names(raw)
    return(values)
  }
  for (target in names(targets)) {
    target_dir <- targets[[target]]
    files_before <- list.files(target_dir, recursive = TRUE, all.files = TRUE)
    ep <- condathis::env_path(target_dir)
    env_label <- if (identical(basename(dirname(target_dir)), "envs")) {
      basename(target_dir)
    } else {
      "<TARGET>"
    }
    for (fn in c("run", "run_bin", "run_bin_noact", "run_pipeline")) {
      env <- list()
      for (method in pr_methods) {
        env[[method]] <- normalize(
          pr_child_env(fn, method, ep),
          target = target_dir,
          root = roots[[method]]
        )
      }
      activated <- isFALSE(identical(fn, "run_bin_noact"))
      for (method in pr_methods) {
        child <- env[[method]]
        info <- paste("env of", target, fn, method)
        expect_identical(
          pr_value(child, "CONDA_PREFIX"),
          if (isTRUE(activated)) "<TARGET>" else "",
          info = info
        )
        expect_identical(
          pr_value(child, "CONDA_DEFAULT_ENV"),
          if (isTRUE(activated)) env_label else "",
          info = info
        )
        expect_identical(
          pr_value(child, "CONDA_SHLVL"),
          if (isTRUE(activated)) "1" else "0",
          info = info
        )
        expect_identical(
          pr_value(child, "RT_PCE_EP"),
          if (isTRUE(activated)) "on" else NA_character_,
          info = info
        )
        expect_identical(
          pr_value(child, "RT_PCE_EP_GONE"),
          if (isTRUE(activated)) NA_character_ else "session",
          info = info
        )
        # The running backend's own directories.
        expect_identical(
          pr_value(child, "CONDA_ENVS_PATH"),
          "<ROOT>/envs",
          info = info
        )
        pkgs_dir <- if (identical(method, "micromamba")) {
          "<ROOT>/pkgs"
        } else {
          "<ROOT>/conda-pkgs"
        }
        expect_identical(
          pr_value(child, "CONDA_PKGS_DIRS"),
          pkgs_dir,
          info = info
        )
        expect_identical(
          pr_value(child, "MAMBA_PKGS_DIRS"),
          pkgs_dir,
          info = info
        )
        expect_identical(pr_value(child, "MAMBA_ROOT_PREFIX"), "", info = info)
      }
      if (isTRUE(activated)) {
        for (method in pr_methods) {
          expect_identical(
            pr_value(env[[method]], "CONDA_PROMPT_MODIFIER"),
            paste0("(", env_label, ") "),
            info = paste("env of", target, fn, method)
          )
        }
      }
      # The allowlist of R-5, as for environments given by name.
      mm <- env$micromamba
      rt <- env$rattler
      only_mm <- character(0L)
      differ <- c("CONDA_PKGS_DIRS", "MAMBA_PKGS_DIRS")
      if (isTRUE(activated)) {
        only_mm <- "MAMBA_EXE"
        differ <- c(differ, "PATH")
        if (isTRUE(unix)) {
          if (isTRUE("LC_ALL" %in% names(session))) {
            differ <- c(differ, "LC_ALL")
          } else {
            only_mm <- c(only_mm, "LC_ALL")
          }
        } else {
          only_mm <- c(
            only_mm,
            "_CONDA_OLD_CHCP",
            "PYTHONIOENCODING",
            "PYTHONUTF8"
          )
          if (isTRUE("PROMPT" %in% toupper(names(session)))) {
            differ <- c(differ, "PROMPT")
          } else {
            only_mm <- c(only_mm, "PROMPT")
          }
        }
      }
      info <- paste("env of", target, fn)
      expect_setequal(setdiff(names(mm), names(rt)), only_mm)
      expect_setequal(setdiff(names(rt), names(mm)), character(0L))
      common <- setdiff(intersect(names(mm), names(rt)), differ)
      expect_identical(rt[common], mm[common], info = info)
      if (isTRUE(activated)) {
        mm_path <- pr_path_entries(mm[["PATH"]])
        rt_path <- pr_path_entries(rt[["PATH"]])
        condabin <- basename(mm_path) == "condabin"
        expect_identical(sum(condabin), 1L, info = info)
        if (isTRUE(unix)) {
          expect_identical(rt_path, mm_path[!condabin], info = info)
          expect_identical(rt_path[[1L]], "<TARGET>/bin", info = info)
        } else {
          expect_identical(
            pr_path_set(rt_path),
            pr_path_set(mm_path[!condabin]),
            info = info
          )
          # The environment's directories, in the same place on both (the
          # Rscript children put Rtools in front).
          expect_true("<target>/library/bin" %in% rt_path, info = info)
          expect_identical(
            match("<target>", rt_path),
            match("<target>", mm_path),
            info = info
          )
        }
      }
    }
    expect_identical(
      list.files(target_dir, recursive = TRUE, all.files = TRUE),
      files_before,
      info = target
    )
  }
})

test_that("an activation needs no bash on either backend", {
  local_parity_micromamba()
  env_names <- pr_env_names("rt-pce-sh")
  pr_defer_remove_envs(env_names)
  prefixes <- list()
  for (method in pr_methods) {
    condathis::create_env(
      "foo",
      env_name = env_names[[method]],
      channels = channel_url("chA"),
      method = method,
      verbose = "silent"
    )
    prefixes[[method]] <- normalizePath(
      condathis::get_env_dir(env_names[[method]], method = method),
      winslash = "/"
    )
  }
  if (isTRUE(is_windows())) {
    # Both activate with cmd.exe: a PATH with only the system directory
    # (no bash anywhere) activates on both.
    system_dir <- normalizePath(
      file.path(Sys.getenv("SystemRoot"), "System32"),
      winslash = "\\"
    )
    withr::local_envvar(c(PATH = system_dir))
    args <- c(
      "-e",
      "cat(Sys.getenv(c('CONDA_SHLVL', 'CONDA_PREFIX')), sep = '|')"
    )
    for (method in pr_methods) {
      for (fn in c("run", "run_bin")) {
        res <- getExportedValue("condathis", fn)(
          rscript_path(),
          args,
          env_name = env_names[[method]],
          method = method,
          verbose = "silent"
        )
        parts <- strsplit(res$stdout, "|", fixed = TRUE)[[1L]]
        expect_identical(parts[[1L]], "1", info = paste(fn, method))
        expect_identical(
          normalizePath(parts[[2L]], winslash = "/"),
          prefixes[[method]],
          info = paste(fn, method)
        )
      }
    }
  } else {
    # A PATH with `sh` and the `basename` that micromamba's activation
    # script calls, but no `bash`: both backends activate (rattler falls
    # back to `sh`, P-A8).
    no_bash_dir <- withr::local_tempdir(pattern = "rt-no-bash-")
    for (tool in c("sh", "basename")) {
      tool_path <- Sys.which(tool)
      expect_true(nzchar(tool_path), info = tool)
      file.symlink(
        normalizePath(tool_path),
        file.path(no_bash_dir, tool)
      )
    }
    expect_false(file.exists(file.path(no_bash_dir, "bash")))
    # `sh` is found on the child's PATH, after the environment's bin.
    script <- "echo \"$CONDA_SHLVL|$CONDA_PREFIX|$PATH\""
    child_values <- function(fn, method, path_value) {
      res <- withr::with_envvar(
        c(PATH = path_value),
        getExportedValue("condathis", fn)(
          "sh",
          "-c",
          script,
          env_name = env_names[[method]],
          method = method,
          verbose = "silent"
        )
      )
      parts <- strsplit(sub("\n$", "", res$stdout), "|", fixed = TRUE)[[1L]]
      return(list(
        shlvl = parts[[1L]],
        prefix = parts[[2L]],
        path = strsplit(parts[[3L]], ":", fixed = TRUE)[[1L]]
      ))
    }
    for (method in pr_methods) {
      for (fn in c("run", "run_bin")) {
        info <- paste(fn, method)
        values <- child_values(fn, method, no_bash_dir)
        expect_identical(values$shlvl, "1", info = info)
        expect_identical(
          normalizePath(values$prefix),
          normalizePath(prefixes[[method]]),
          info = info
        )
        expect_identical(
          pr_real_path(values$path[[1L]]),
          pr_real_path(file.path(prefixes[[method]], "bin")),
          info = info
        )
        expect_identical(
          normalizePath(values$path[[length(values$path)]]),
          normalizePath(no_bash_dir),
          info = info
        )
      }
    }
    # Only `sh` on PATH, without the `basename` that micromamba's
    # activation script calls: both still activate (condathis gives
    # micromamba's activation a system directory, and keeps it out of the
    # command's PATH), with run() and run_bin() (R-4).
    sh_only_dir <- withr::local_tempdir(pattern = "rt-sh-only-")
    file.symlink(normalizePath(Sys.which("sh")), file.path(sh_only_dir, "sh"))
    for (method in pr_methods) {
      for (fn in c("run", "run_bin")) {
        info <- paste(fn, method, "sh only")
        values <- child_values(fn, method, sh_only_dir)
        expect_identical(values$shlvl, "1", info = info)
        expect_identical(
          normalizePath(values$prefix),
          normalizePath(prefixes[[method]]),
          info = info
        )
        expect_identical(
          normalizePath(values$path[[length(values$path)]]),
          normalizePath(sh_only_dir),
          info = info
        )
      }
    }
  }
})

test_that("a command killed by a signal has the same status on both backends", {
  local_parity_micromamba()
  env_names <- pr_env_names("rt-pce-kill")
  pr_defer_remove_envs(env_names)
  for (method in pr_methods) {
    condathis::create_env(
      env_name = env_names[[method]],
      channels = channel_url("chA"),
      method = method,
      verbose = "silent"
    )
  }
  if (isTRUE(is_windows())) {
    # No signals: a process ended with TerminateProcess() exits with the
    # code it was given (1 for tools::pskill()), with both backends.
    cmd <- rscript_path()
    args <- c("-e", "tools::pskill(Sys.getpid())")
    run_status <- 1L
    run_bin_status <- 1L
  } else {
    # run() reports a command killed by signal 9 as 128 + 9, as
    # `micromamba run` did (P-A2, Q24); run_bin() keeps processx's -9.
    cmd <- "sh"
    args <- c("-c", "kill -9 $$")
    run_status <- 137L
    run_bin_status <- -9L
  }
  for (method in pr_methods) {
    res <- condathis::run(
      cmd,
      args,
      env_name = env_names[[method]],
      method = method,
      verbose = "silent",
      error = "continue"
    )
    expect_identical(res$status, run_status, info = method)
    cnd <- expect_error(
      condathis::run(
        cmd,
        args,
        env_name = env_names[[method]],
        method = method,
        verbose = "silent"
      ),
      class = "condathis_run_status_error"
    )
    expect_identical(cnd$status, run_status, info = method)
    res <- condathis::run_bin(
      cmd,
      args,
      env_name = env_names[[method]],
      method = method,
      verbose = "silent",
      error = "continue"
    )
    expect_identical(res$status, run_bin_status, info = method)
    cnd <- expect_error(
      condathis::run_bin(
        cmd,
        args,
        env_name = env_names[[method]],
        method = method,
        verbose = "silent"
      ),
      class = "condathis_run_bin_status_error"
    )
    expect_identical(cnd$status, run_bin_status, info = method)
  }
})

test_that("a missing command fails alike on both backends (R-4)", {
  # condathis looks the command up and starts it itself for both backends:
  # the same status, error classes and text (but for the environment's
  # name), with run() and run_bin().
  local_parity_micromamba()
  env_names <- pr_env_names("rt-pce-nocmd")
  pr_defer_remove_envs(env_names)
  for (method in pr_methods) {
    condathis::create_env(
      env_name = env_names[[method]],
      channels = channel_url("chA"),
      method = method,
      verbose = "silent"
    )
  }
  for (fn in c("run", "run_bin")) {
    run_fn <- getExportedValue("condathis", fn)
    seen <- list()
    for (method in pr_methods) {
      res <- run_fn(
        "rt-pce-no-such-command",
        "--version",
        env_name = env_names[[method]],
        method = method,
        verbose = "silent",
        error = "continue"
      )
      cnd <- tryCatch(
        run_fn(
          "rt-pce-no-such-command",
          env_name = env_names[[method]],
          method = method,
          verbose = "silent"
        ),
        error = function(e) e
      )
      seen[[method]] <- list(
        status = res$status,
        stderr = gsub(env_names[[method]], "<ENV>", res$stderr, fixed = TRUE),
        class = class(cnd),
        message = gsub(
          env_names[[method]],
          "<ENV>",
          conditionMessage(cnd),
          fixed = TRUE
        )
      )
    }
    expect_identical(seen$micromamba$status, 127L, info = fn)
    expect_identical(seen$rattler, seen$micromamba, info = fn)
  }
})

test_that("activate.d scripts run on both backends (R-1)", {
  local_parity_micromamba()
  env_names <- pr_env_names("rt-pce-actd")
  pr_defer_remove_envs(env_names)
  args <- c("-e", "cat(Sys.getenv('RT_PR_ACTD', 'unset'))")
  for (method in pr_methods) {
    condathis::create_env(
      "practd",
      env_name = env_names[[method]],
      channels = pr_prlink_channel(),
      method = method,
      verbose = "silent"
    )
    for (fn in c("run", "run_bin")) {
      res <- getExportedValue("condathis", fn)(
        rscript_path(),
        args,
        env_name = env_names[[method]],
        method = method,
        verbose = "silent"
      )
      expect_identical(res$stdout, "on", info = paste(fn, method))
    }
    res <- condathis::run_bin(
      rscript_path(),
      args,
      env_name = env_names[[method]],
      method = method,
      verbose = "silent",
      activate = FALSE
    )
    expect_identical(res$stdout, "unset", info = method)
  }
})

test_that("run(timeout =) covers the activation and the command on both backends (R-4)", {
  # condathis activates the environment first, then starts the command:
  # `timeout` covers both, with run(), run_bin() and run_pipeline() and
  # both backends, on every OS. An activation that takes the whole time is
  # stopped (with what its activate.d scripts started) and the command does
  # not start: a timeout, as for a command that is killed. Once the
  # activation is fast, the command gets the time.
  local_parity_micromamba()
  env_names <- pr_env_names("rt-pce-timeout")
  pr_defer_remove_envs(env_names)
  sleep_secs <- 30
  sleep_script <- function(env_dir) {
    activate_dir <- file.path(env_dir, "etc", "conda", "activate.d")
    dir.create(activate_dir, recursive = TRUE, showWarnings = FALSE)
    if (isTRUE(is_windows())) {
      path <- file.path(activate_dir, "rt-pce-sleep.bat")
      writeLines(
        paste0(
          "@\"%SystemRoot%\\System32\\ping.exe\" -n ",
          sleep_secs + 1,
          " 127.0.0.1 > nul"
        ),
        path
      )
    } else {
      path <- file.path(activate_dir, "rt-pce-sleep.sh")
      writeLines(paste("sleep", sleep_secs), path)
    }
    return(path)
  }
  scripts <- list()
  for (method in pr_methods) {
    condathis::create_env(
      env_name = env_names[[method]],
      channels = channel_url("chA"),
      method = method,
      verbose = "silent"
    )
    scripts[[method]] <- sleep_script(
      condathis::get_env_dir(env_names[[method]], method = method)
    )
  }
  args <- c("-e", "cat('done')")
  for (method in pr_methods) {
    for (fn in c("run", "run_bin")) {
      info <- paste(fn, method)
      started <- Sys.time()
      res <- getExportedValue("condathis", fn)(
        rscript_path(),
        args,
        env_name = env_names[[method]],
        method = method,
        verbose = "silent",
        timeout = 3,
        error = "continue"
      )
      took <- as.numeric(difftime(Sys.time(), started, units = "secs"))
      expect_true(isTRUE(res$timeout), info = info)
      expect_identical(res$status, -9L, info = info)
      expect_false(identical(res$stdout, "done"), info = info)
      expect_lt(took, sleep_secs - 5)
    }
    expect_error(
      condathis::run(
        rscript_path(),
        args,
        env_name = env_names[[method]],
        method = method,
        verbose = "silent",
        timeout = 3
      ),
      class = "condathis_run_timeout_error"
    )
    pipe <- condathis::run_pipeline(
      condathis::run_step(rscript_path(), args),
      condathis::run_step(rscript_path(), rscript_cat_args()),
      env_name = env_names[[method]],
      method = method,
      verbose = "silent",
      timeout = 3,
      error = "continue"
    )
    expect_true(isTRUE(pipe$timeout), info = method)
  }
  # Without the slow script, the activation is fast and the command runs.
  for (method in pr_methods) {
    unlink(scripts[[method]])
    res <- condathis::run(
      rscript_path(),
      args,
      env_name = env_names[[method]],
      method = method,
      verbose = "silent",
      timeout = 60
    )
    expect_identical(res$stdout, "done", info = method)
    expect_false(isTRUE(res$timeout), info = method)
  }
})

test_that("activate.d scripts get the TMPDIR, user cache and working directory of the command on both backends", {
  # micromamba's activation ran with micromamba's own TMPDIR (deleted after
  # the activation was recorded) and `XDG_CACHE_HOME=<root>/cache`, and both
  # backends reused a recorded value that names the working directory from
  # another one. Now a value that names the TMPDIR of the call is not
  # reused, and one that names the working directory only from it.
  local_parity_micromamba()
  env_names <- pr_env_names("rt-pce-capture")
  pr_defer_remove_envs(env_names)
  for (method in pr_methods) {
    condathis::create_env(
      env_name = env_names[[method]],
      channels = channel_url("chA"),
      method = method,
      verbose = "silent"
    )
    activate_dir <- file.path(
      condathis::get_env_dir(env_names[[method]], method = method),
      "etc",
      "conda",
      "activate.d"
    )
    dir.create(activate_dir, recursive = TRUE, showWarnings = FALSE)
    writeLines(
      c(
        "export RT_PCE_X=\"$TMPDIR/x\"",
        "export RT_PCE_C=\"${XDG_CACHE_HOME:-$HOME/.cache}/x\"",
        "export RT_PCE_P=\"$PWD\""
      ),
      file.path(activate_dir, "rt-pce-capture.sh")
    )
    writeLines(
      c(
        "@set \"RT_PCE_X=%TMPDIR%\\x\"",
        "@set \"RT_PCE_C=%XDG_CACHE_HOME%\\x\"",
        "@set \"RT_PCE_P=%CD%\""
      ),
      file.path(activate_dir, "rt-pce-capture.bat")
    )
  }
  user_cache <- normalizePath(withr::local_tempdir(), winslash = "/")
  withr::local_envvar(XDG_CACHE_HOME = user_cache)
  get_vars <- function(method) {
    res <- condathis::run(
      rscript_path(),
      "-e",
      paste0(
        "cat(Sys.getenv('TMPDIR'), ",
        "Sys.getenv(c('RT_PCE_X', 'RT_PCE_C', 'RT_PCE_P')), sep = '\\n')"
      ),
      env_name = env_names[[method]],
      method = method,
      verbose = "silent"
    )
    out <- gsub("\\\\", "/", strsplit(res$stdout, "\\r?\\n")[[1L]])
    return(list(
      tmp = out[[1L]],
      x = out[[2L]],
      cache = out[[3L]],
      wd = out[[4L]]
    ))
  }
  real <- function(path) normalizePath(path, winslash = "/", mustWork = FALSE)
  wd_a <- withr::local_tempdir()
  wd_b <- withr::local_tempdir()
  for (method in pr_methods) {
    withr::with_dir(wd_a, {
      first <- get_vars(method)
      second <- get_vars(method)
    })
    expect_identical(first$x, paste0(first$tmp, "/x"), info = method)
    expect_identical(second$x, paste0(second$tmp, "/x"), info = method)
    expect_false(identical(first$tmp, second$tmp), info = method)
    expect_identical(first$cache, paste0(user_cache, "/x"), info = method)
    expect_identical(real(first$wd), real(wd_a), info = method)
    withr::with_dir(wd_b, {
      expect_identical(real(get_vars(method)$wd), real(wd_b), info = method)
    })
  }
  # Without XDG_CACHE_HOME, both read it as unset.
  withr::local_envvar(XDG_CACHE_HOME = NA)
  unset <- vapply(pr_methods, function(m) get_vars(m)$cache, character(1L))
  expect_identical(unset[["micromamba"]], unset[["rattler"]])
  if (isTRUE(is_windows())) {
    expect_identical(unset[["rattler"]], "/x")
  } else {
    expect_identical(
      unset[["rattler"]],
      paste0(Sys.getenv("HOME"), "/.cache/x")
    )
  }
})

test_that("state and env_vars.d values reach commands as written, but for quotes with micromamba on Linux and macOS", {
  # Both backends set the variables of `conda-meta/state` and
  # `etc/conda/env_vars.d`. micromamba writes them into its activation
  # script in single quotes, without escaping a quote in the value, so on
  # Linux and macOS a value with single quotes reaches no command as
  # written (`x 'a' y` becomes `x a y`; an odd number of quotes can lose
  # the other variables of the file too). rattler passes them to the shell
  # in its environment. On Windows, cmd.exe sets them as written with
  # both.
  local_parity_micromamba()
  env_names <- pr_env_names("rt-pce-state")
  pr_defer_remove_envs(env_names)
  plain <- "a plain value"
  quoted <- "x 'a' y"
  read_vars <- c("RT_PCE_PLAIN", "RT_PCE_DPLAIN", "RT_PCE_QUOTED")
  args <- c(
    "-e",
    paste0(
      "cat(Sys.getenv(c('",
      paste(read_vars, collapse = "', '"),
      "'), 'unset'), sep = '|')"
    )
  )
  for (method in pr_methods) {
    env_name <- env_names[[method]]
    condathis::create_env(
      env_name = env_name,
      channels = channel_url("chA"),
      method = method,
      verbose = "silent"
    )
    env_dir <- condathis::get_env_dir(env_name, method = method)
    jsonlite::write_json(
      list(env_vars = list(RT_PCE_PLAIN = plain)),
      file.path(env_dir, "conda-meta", "state"),
      auto_unbox = TRUE
    )
    vars_dir <- file.path(env_dir, "etc", "conda", "env_vars.d")
    dir.create(vars_dir, recursive = TRUE, showWarnings = FALSE)
    jsonlite::write_json(
      list(RT_PCE_DPLAIN = plain),
      file.path(vars_dir, "a-plain.json"),
      auto_unbox = TRUE
    )
    jsonlite::write_json(
      list(RT_PCE_QUOTED = quoted),
      file.path(vars_dir, "b-quoted.json"),
      auto_unbox = TRUE
    )
    for (fn in c("run", "run_bin")) {
      info <- paste(fn, method)
      res <- getExportedValue("condathis", fn)(
        rscript_path(),
        args,
        env_name = env_name,
        method = method,
        verbose = "silent"
      )
      values <- strsplit(res$stdout, "|", fixed = TRUE)[[1L]]
      expect_length(values, 3L)
      expect_identical(values[[1L]], plain, info = info)
      expect_identical(values[[2L]], plain, info = info)
      if (identical(method, "micromamba") && isFALSE(is_windows())) {
        expect_false(identical(values[[3L]], quoted), info = info)
      } else {
        expect_identical(values[[3L]], quoted, info = info)
      }
    }
  }
})

test_that("what activate.d scripts print, unset or fail is the same on both backends (R-4)", {
  # condathis activates first, with both backends and every run function:
  # what the scripts print is not part of the command's output, a variable
  # they unset is unset for the command (the activation reports it as `NA`,
  # which condathis removes), and a script that fails fails the activation
  # (`condathis_<fn>_resolve_failed`, or status 127 with
  # `error = "continue"`). On Windows cmd.exe `call`s the scripts, so
  # `exit /b 3` fails nothing with either backend.
  local_parity_micromamba()
  withr::local_envvar(RT_PCE_SESSION = "session")
  printing <- pr_env_names("rt-pce-actp")
  failing <- pr_env_names("rt-pce-actf")
  pr_defer_remove_envs(printing)
  pr_defer_remove_envs(failing)
  args <- c("-e", "cat(Sys.getenv('RT_PCE_SESSION', 'unset'))")
  activate_dir <- function(env_name, method) {
    dir <- file.path(
      condathis::get_env_dir(env_name, method = method),
      "etc",
      "conda",
      "activate.d"
    )
    dir.create(dir, recursive = TRUE, showWarnings = FALSE)
    return(dir)
  }
  for (method in pr_methods) {
    for (env_name in c(printing[[method]], failing[[method]])) {
      condathis::create_env(
        env_name = env_name,
        channels = channel_url("chA"),
        method = method,
        verbose = "silent"
      )
    }
    if (isTRUE(is_windows())) {
      writeLines(
        c("@echo from-actd", "@set \"RT_PCE_SESSION=\""),
        file.path(activate_dir(printing[[method]], method), "rt-pce.bat")
      )
      writeLines(
        "@exit /b 3",
        file.path(activate_dir(failing[[method]], method), "rt-pce.bat")
      )
    } else {
      writeLines(
        c("echo from-actd", "unset RT_PCE_SESSION"),
        file.path(activate_dir(printing[[method]], method), "rt-pce.sh")
      )
      writeLines(
        "exit 3",
        file.path(activate_dir(failing[[method]], method), "rt-pce.sh")
      )
    }
  }
  for (method in pr_methods) {
    res <- condathis::run_pipeline(
      condathis::run_step(rscript_path(), args),
      condathis::run_step(rscript_path(), rscript_cat_args()),
      env_name = printing[[method]],
      method = method,
      verbose = "silent"
    )
    expect_identical(
      condathis::parse_output(res),
      "unset",
      info = paste("run_pipeline", method)
    )
    for (fn in c("run", "run_bin")) {
      info <- paste(fn, method)
      run_fn <- getExportedValue("condathis", fn)
      res <- run_fn(
        rscript_path(),
        args,
        env_name = printing[[method]],
        method = method,
        verbose = "silent"
      )
      expect_identical(condathis::parse_output(res), "unset", info = info)
      if (isTRUE(is_windows())) {
        res <- run_fn(
          rscript_path(),
          args,
          env_name = failing[[method]],
          method = method,
          verbose = "silent"
        )
        expect_identical(res$status, 0L, info = info)
        expect_identical(res$stdout, "session", info = info)
        next
      }
      failure_class <- paste0("condathis_", fn, "_resolve_failed")
      expect_error(
        run_fn(
          rscript_path(),
          args,
          env_name = failing[[method]],
          method = method,
          verbose = "silent"
        ),
        class = failure_class,
        info = info
      )
      res <- run_fn(
        rscript_path(),
        args,
        env_name = failing[[method]],
        method = method,
        verbose = "silent",
        error = "continue"
      )
      expect_identical(res$status, 127L, info = info)
    }
  }
})
