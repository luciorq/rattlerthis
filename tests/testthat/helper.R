skip_if_offline <- function() {
  testthat::skip_if_not_installed("curl")
  if (isFALSE(curl::has_internet())) {
    testthat::skip("No internet connection available.")
  }
}

local_rattlerthis_root <- function(env = parent.frame()) {
  root <- withr::local_tempdir(pattern = "rattlerthis-test", .local_envir = env)
  withr::local_envvar(
    c(RATTLERTHIS_ROOT_DIR = root),
    .local_envir = env
  )
  root
}
