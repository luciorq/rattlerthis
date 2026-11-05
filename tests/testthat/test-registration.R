# How rattlerthis becomes condathis's "rattler" backend: registration on
# load, its condathis load hook, unregistration on unload, and condathis's
# on-demand loading of the package (for `method = "rattler"`, and when
# rattler environments or caches exist). Load and unload checks run in new
# R sessions (callr), which inherit the sandbox of this test process and
# its library paths.

hook_generics <- c(
  "backend_create_env",
  "backend_install",
  "backend_resolve_run",
  "backend_resolve_run_in_dir",
  "backend_clean_cache",
  "backend_quiesce",
  "backend_native_platform",
  "backend_can_solve"
)

# The optional hooks that condathis's defaults answer for rattler.
default_generics <- c(
  "backend_get_install_dir",
  "backend_get_env_dir",
  "backend_list_envs",
  "backend_env_exists",
  "backend_list_packages",
  "backend_remove_env",
  "backend_available"
)

# Runs `fun` in a new R session and returns its value. The session has the
# library paths and environment variables of this process.
r_fresh <- function(fun, args = list()) {
  return(callr::r(fun, args = args, libpath = .libPaths(), show = FALSE))
}

test_that("the package registers its backend with condathis's generics", {
  condathis_ns <- asNamespace("condathis")
  expect_true("rattler" %in% condathis::list_registered_backend_names())
  backend <- new_backend_rattler()
  expect_identical(names(backend), hook_generics)
  for (generic_name in hook_generics) {
    generic <- get(generic_name, envir = condathis_ns, inherits = FALSE)
    # condathis passes every argument by name: the same names, order and
    # defaults as its generic.
    expect_identical(
      formals(backend[[generic_name]]),
      formals(generic),
      info = generic_name
    )
    # condathis dispatches the generic to exactly this function.
    expect_identical(
      utils::getS3method(
        generic_name,
        "condathis_backend_rattler",
        envir = condathis_ns
      ),
      backend[[generic_name]],
      info = generic_name
    )
  }
  # condathis's defaults answer the other hooks: rattler registers no
  # method for them.
  for (generic_name in default_generics) {
    expect_null(
      utils::getS3method(
        generic_name,
        "condathis_backend_rattler",
        optional = TRUE,
        envir = condathis_ns
      ),
      info = generic_name
    )
    expect_true(
      is.function(utils::getS3method(
        generic_name,
        "default",
        envir = condathis_ns
      )),
      info = generic_name
    )
  }
  # Registering the same object again passes condathis's checks.
  expect_identical(
    condathis::register_backend("rattler", new_backend_rattler()),
    "rattler"
  )
})

test_that("rattlerthis exports nothing and has no options of its own", {
  # Users call condathis's functions with method = "rattler".
  expect_identical(getNamespaceExports("rattlerthis"), character(0L))
  expect_identical(
    grep("^rattlerthis[.]", names(options()), value = TRUE),
    character(0L)
  )
})

test_that("the condathis version floor is read from DESCRIPTION", {
  libname <- dirname(system.file(package = "rattlerthis"))
  floor <- condathis_version_floor(libname, "rattlerthis")
  expect_s3_class(floor, "package_version")
  imports <- utils::packageDescription("rattlerthis")$Imports
  expect_match(
    imports,
    paste0("condathis \\(>= ", gsub(".", "\\.", format(floor), fixed = TRUE)),
    perl = TRUE
  )
  expect_true(utils::packageVersion("condathis") >= floor)
})

test_that("loading installs exactly one condathis load hook", {
  # The hook is the top-level register function itself, so .onUnload()
  # finds it with identical(), and a reload does not add a second one.
  hooks <- getHook(packageEvent("condathis", "onLoad"))
  is_own <- vapply(
    hooks,
    function(hook) identical(hook, register_condathis_backend),
    logical(1L)
  )
  expect_identical(sum(is_own), 1L)
})

test_that("remove_condathis_load_hook() removes only this package's hook", {
  hook_name <- packageEvent("condathis", "onLoad")
  old_hooks <- getHook(hook_name)
  withr::defer(setHook(hook_name, old_hooks, action = "replace"))
  other_hook <- function(...) invisible(NULL)
  setHook(
    hook_name,
    list(other_hook, register_condathis_backend, register_condathis_backend),
    action = "replace"
  )
  expect_true(remove_condathis_load_hook())
  remaining <- getHook(hook_name)
  expect_length(remaining, 1L)
  expect_identical(remaining[[1L]], other_hook)
  expect_false(remove_condathis_load_hook())
})

test_that("unloading unregisters the backend and removes the hook", {
  res <- r_fresh(function() {
    loadNamespace("rattlerthis")
    hook_name <- packageEvent("condathis", "onLoad")
    before <- list(
      registered = "rattler" %in% condathis::list_registered_backend_names(),
      hooks = length(getHook(hook_name))
    )
    unloadNamespace("rattlerthis")
    after <- list(
      registered = "rattler" %in% condathis::list_registered_backend_names(),
      hooks = length(getHook(hook_name)),
      condathis_loaded = isNamespaceLoaded("condathis")
    )
    return(list(before = before, after = after))
  })
  expect_identical(res$before, list(registered = TRUE, hooks = 1L))
  expect_identical(
    res$after,
    list(registered = FALSE, hooks = 0L, condathis_loaded = TRUE)
  )
})

test_that("a reload of condathis registers the backend again", {
  # condathis's registry lives in its namespace; the load hook registers
  # rattler again when condathis loads anew (pkgload::load_all() during
  # development does the same).
  res <- r_fresh(function() {
    loadNamespace("rattlerthis")
    unloadNamespace("condathis")
    unloaded <- isFALSE(isNamespaceLoaded("condathis"))
    loadNamespace("condathis")
    return(list(
      unloaded = unloaded,
      registered = "rattler" %in% condathis::list_registered_backend_names(),
      hooks = length(getHook(packageEvent("condathis", "onLoad"))),
      envs = names(condathis::list_envs(method = "rattler"))
    ))
  })
  expect_true(res$unloaded)
  expect_true(res$registered)
  expect_identical(res$hooks, 1L)
  expect_identical(res$envs, c("backend", "env_name", "path"))
})

test_that("method = 'rattler' loads rattlerthis", {
  local_condathis_sandbox()
  res <- r_fresh(function() {
    before <- "rattlerthis" %in% loadedNamespaces()
    envs <- condathis::list_envs(method = "rattler")
    return(list(
      before = before,
      after = "rattlerthis" %in% loadedNamespaces(),
      rows = nrow(envs)
    ))
  })
  expect_identical(res, list(before = FALSE, after = TRUE, rows = 0L))
})

test_that("method = 'auto' finds a rattler environment in a new session", {
  local_condathis_sandbox()
  env_name <- "rt-reg-auto"
  condathis::create_env(
    "polyglot",
    env_name = env_name,
    channels = condathis_polyglot_channel(),
    method = "rattler",
    verbose = "silent"
  )
  res <- r_fresh(
    function(env_name) {
      before <- "rattlerthis" %in% loadedNamespaces()
      exists <- condathis::env_exists(env_name)
      envs <- condathis::list_envs()
      run_res <- condathis::run(
        "polyglot",
        env_name = env_name,
        verbose = "silent"
      )
      return(list(
        before = before,
        exists = exists,
        backends = envs$backend,
        first_line = condathis::parse_output(run_res)[[1L]],
        after = "rattlerthis" %in% loadedNamespaces()
      ))
    },
    args = list(env_name = env_name)
  )
  expect_false(res$before)
  expect_true(res$exists)
  expect_identical(res$backends, "rattler")
  expect_identical(res$first_line, polyglot_first_line())
  expect_true(res$after)
})

test_that("an empty or cleaned rattler root loads nothing", {
  # The bare existence of the root is no trigger: get_install_dir()
  # creates the root of every registered backend.
  paths <- local_condathis_sandbox()
  condathis::get_install_dir(method = "rattler")
  expect_true(dir.exists(paths$rattler))
  queries <- function() {
    condathis::list_envs()
    condathis::env_exists("rt-reg-none")
    condathis::get_install_dir()
    return("rattlerthis" %in% loadedNamespaces())
  }
  expect_false(r_fresh(queries))

  # Caches, without environments: clean_cache() loads rattlerthis and
  # cleans them; a cleaned root then triggers nothing.
  env_name <- "rt-reg-cache"
  condathis::create_env(
    "foo",
    env_name = env_name,
    channels = channel_url("chA"),
    method = "rattler",
    verbose = "silent"
  )
  condathis::remove_env(env_name, method = "rattler", verbose = "silent")
  expect_true(length(list.files(file.path(paths$rattler, "pkgs"))) > 0L)
  expect_false(r_fresh(queries))
  clean <- function() {
    warnings <- character(0L)
    withCallingHandlers(
      invisible(condathis::clean_cache(verbose = "silent")),
      warning = function(cnd) {
        warnings <<- c(warnings, class(cnd)[[1L]])
        invokeRestart("muffleWarning")
      }
    )
    return(list(
      loaded = "rattlerthis" %in% loadedNamespaces(),
      warnings = warnings
    ))
  }
  expect_identical(
    r_fresh(clean),
    list(loaded = TRUE, warnings = character(0L))
  )
  expect_identical(
    list.files(file.path(paths$rattler, "pkgs"), all.files = TRUE, no.. = TRUE),
    ".cache.lock"
  )
  expect_identical(
    r_fresh(clean),
    list(loaded = FALSE, warnings = character(0L))
  )
  expect_false(r_fresh(queries))
})
