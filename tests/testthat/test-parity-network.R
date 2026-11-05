# Proxies, certificates and credentials (R-10): rattler honors what
# micromamba honors when condathis runs it (`--rc-file`, `--no-env`), and
# nothing else. Measured with micromamba 2.10.0 (see src/rust/src/netenv.rs):
#
# * libcurl's proxy variables: `http_proxy` (lower case only, but Windows
#   has no case in names), `https_proxy`/`HTTPS_PROXY`,
#   `all_proxy`/`ALL_PROXY`, `no_proxy`/`NO_PROXY`;
# * no CA variable (`SSL_CERT_FILE`, `SSL_CERT_DIR`, `REQUESTS_CA_BUNDLE`,
#   `CURL_CA_BUNDLE`): the system bundle, or `ssl/cert.pem` of the root;
# * `~/.mamba/auth/authentication.json`, `.netrc`, and credentials or
#   tokens in channel URLs.
#
# Every test has a sandbox of its own (a fresh home for the credential
# files) and a local server (helper-concurrency.R, helper-network.R).

test_that("both backends download through http_proxy (R-10)", {
  local_condathis_sandbox()
  local_parity_micromamba()
  server <- local_http_channel("chA")
  http_channel_release(server)
  local_proxy_env(http_proxy = http_channel_base(server))
  for (method in psolve_methods) {
    http_channel_clear_log(server)
    # A host that does not exist: only the proxy can reach it.
    got <- network_create(
      "rt-pnet-proxy",
      "http://channel.invalid/chA",
      method
    )
    expect_null(got$error, label = method)
    expect_identical(got$packages, "foo", label = method)
    log <- http_channel_log(server)
    expect_true(
      any(grepl(
        "^GET http://channel[.]invalid/chA/noarch/repodata[.]json",
        log
      )),
      label = paste(method, paste(log, collapse = "; "))
    )
    expect_true(
      "GET http://channel.invalid/chA/noarch/foo-1.0-0.tar.bz2 200" %in% log,
      label = paste(method, paste(log, collapse = "; "))
    )
  }
})

test_that("HTTP_PROXY is not used for http, and no_proxy is (R-10)", {
  local_condathis_sandbox()
  local_parity_micromamba()
  server <- local_http_channel("chA")
  http_channel_release(server)
  base <- http_channel_base(server)
  # Only the upper-case name: libcurl ignores it on Linux and macOS; on
  # Windows names have no case, so it is http_proxy.
  local_proxy_env(HTTP_PROXY = base)
  for (method in psolve_methods) {
    http_channel_clear_log(server)
    got <- network_create("rt-pnet-upper", server$url("chA"), method)
    expect_null(got$error, label = method)
    log <- http_channel_log(server)
    proxied <- any(grepl("^GET http://127[.]0[.]0[.]1", log))
    expect_identical(proxied, is_windows(), label = method)
  }
  # no_proxy wins over a proxy that is not there.
  local_proxy_env(
    http_proxy = "http://127.0.0.1:9",
    all_proxy = "http://127.0.0.1:9",
    no_proxy = "127.0.0.1"
  )
  for (method in psolve_methods) {
    got <- network_create("rt-pnet-noproxy", server$url("chA"), method)
    expect_null(got$error, label = method)
    expect_identical(got$packages, "foo", label = method)
  }
})

test_that("saved credentials, .netrc and URL tokens are sent by both backends (R-10)", {
  sandbox <- local_condathis_sandbox()
  local_parity_micromamba()
  local_proxy_env()
  auth_file <- file.path(sandbox$home, ".mamba", "auth", "authentication.json")
  dir.create(dirname(auth_file), recursive = TRUE)
  # A bearer token for host:port.
  bearer <- local_http_channel("chA", auth = "Bearer rt-secret")
  http_channel_release(bearer)
  host <- sub("^http://", "", http_channel_base(bearer))
  # Without credentials both fail; with them both succeed.
  for (method in psolve_methods) {
    got <- network_create("rt-pnet-noauth", bearer$url("chA"), method)
    expect_s3_class(got$error, "condathis_create_env_failed")
  }
  writeLines(
    sprintf(
      '{"%s": {"type": "BearerToken", "token": "rt-secret"}}',
      host
    ),
    auth_file
  )
  for (method in psolve_methods) {
    got <- network_create("rt-pnet-bearer", bearer$url("chA"), method)
    expect_null(got$error, label = method)
    expect_identical(got$packages, "foo", label = method)
  }
  # A conda token for the channel, inserted as /t/<token>/.
  tokened <- local_http_channel("chA", token = "rt-tok")
  http_channel_release(tokened)
  host <- sub("^http://", "", http_channel_base(tokened))
  writeLines(
    sprintf('{"%s/chA": {"type": "CondaToken", "token": "rt-tok"}}', host),
    auth_file
  )
  for (method in psolve_methods) {
    got <- network_create("rt-pnet-condatoken", tokened$url("chA"), method)
    expect_null(got$error, label = method)
    expect_identical(got$packages, "foo", label = method)
  }
  # A token in the channel URL, without the file.
  unlink(auth_file)
  url_with_token <- paste0(http_channel_base(tokened), "/t/rt-tok/chA")
  for (method in psolve_methods) {
    got <- network_create("rt-pnet-urltoken", url_with_token, method)
    expect_null(got$error, label = method)
    expect_identical(got$packages, "foo", label = method)
  }
  # A .netrc login for the host (Basic).
  basic <- local_http_channel("chA", auth = "Basic cnQtdXNlcjpydC1wdw==")
  http_channel_release(basic)
  writeLines(
    "machine 127.0.0.1 login rt-user password rt-pw",
    file.path(sandbox$home, ".netrc")
  )
  for (method in psolve_methods) {
    got <- network_create("rt-pnet-netrc", basic$url("chA"), method)
    expect_null(got$error, label = method)
    expect_identical(got$packages, "foo", label = method)
  }
  # The same login in the channel URL, without .netrc.
  unlink(file.path(sandbox$home, ".netrc"))
  url_with_login <- sub("^http://", "http://rt-user:rt-pw@", basic$url("chA"))
  for (method in psolve_methods) {
    got <- network_create("rt-pnet-urllogin", url_with_login, method)
    expect_null(got$error, label = method)
    expect_identical(got$packages, "foo", label = method)
  }
})

test_that("neither backend trusts a CA from the environment's variables (R-10)", {
  sandbox <- local_condathis_sandbox()
  local_parity_micromamba()
  local_proxy_env()
  server <- local_https_channel("chA")
  ca <- test_tls_files()$ca
  withr::local_envvar(
    SSL_CERT_FILE = ca,
    SSL_CERT_DIR = dirname(ca),
    REQUESTS_CA_BUNDLE = ca,
    CURL_CA_BUNDLE = ca
  )
  for (method in psolve_methods) {
    got <- network_create("rt-pnet-cavars", server$url("chA"), method)
    expect_s3_class(got$error, "condathis_create_env_failed")
    expect_identical(got$packages, character(0L), label = method)
  }
  # Both trust the bundle of conda-forge's ca-certificates in condathis's
  # root (`ssl/cert.pem`, `Library/ssl/cacert.pem` on Windows): micromamba
  # in its root prefix, which condathis gives its processes (TD5), and
  # rattler in the same directory. On Windows micromamba's curl (schannel)
  # also checks the revocation of the certificate online, which the test
  # CA cannot answer, so micromamba fails there; rattler checks it only
  # against the system's cache (R-10).
  root <- condathis::get_install_dir(method = "micromamba")$path
  expect_identical(
    fs::path_real(root),
    fs::path_real(fs::path_dir(condathis::backend_root_dir("rattler")))
  )
  bundle <- if (isTRUE(is_windows())) {
    file.path(root, "Library", "ssl", "cacert.pem")
  } else {
    file.path(root, "ssl", "cert.pem")
  }
  dir.create(dirname(bundle), recursive = TRUE)
  file.copy(ca, bundle)
  for (method in psolve_methods) {
    got <- network_create("rt-pnet-rootca", server$url("chA"), method)
    if (identical(method, "micromamba") && isTRUE(is_windows())) {
      expect_s3_class(got$error, "condathis_create_env_failed")
      expect_match(
        paste(got$error$stderr, collapse = "\n"),
        "revocation status is unknown",
        fixed = TRUE
      )
      expect_identical(got$packages, character(0L))
      next
    }
    expect_null(got$error, label = method)
    expect_identical(got$packages, "foo", label = method)
  }
  # Each backend that succeeded downloaded the package (separate caches,
  # R-16).
  expect_identical(
    sum(grepl(
      "^GET /chA/noarch/foo-1[.]0-0[.]tar[.]bz2",
      https_channel_log(server)
    )),
    if (isTRUE(is_windows())) 1L else 2L
  )
})

test_that("channel metadata without cache headers is reused for an hour by both backends (R-39)", {
  # A server without ETag, Last-Modified or Cache-Control: libmamba keeps
  # the metadata for an hour (`local_repodata_ttl` 1, no max-age), and
  # rattlerthis follows that rule, where rattler would download it on every
  # call.
  local_condathis_sandbox()
  local_parity_micromamba()
  local_proxy_env()
  server <- local_http_channel("chA", validators = FALSE)
  http_channel_release(server)
  metadata_gets <- function() {
    return(sum(grepl(
      "^GET /chA/noarch/repodata[.]json 200",
      http_channel_log(server)
    )))
  }
  for (method in psolve_methods) {
    http_channel_clear_log(server)
    for (i in 1:2) {
      got <- network_create(
        paste0("rt-pnet-ttl", i),
        server$url("chA"),
        method
      )
      expect_null(got$error, label = method)
    }
    expect_identical(metadata_gets(), 1L, label = method)
    age_rattler_repodata_cache()
    got <- network_create("rt-pnet-ttl3", server$url("chA"), method)
    expect_null(got$error, label = method)
    expect_identical(metadata_gets(), 2L, label = method)
  }
})

test_that("channel credentials stay out of what both backends write and say (R-10)", {
  # micromamba writes a record's `url` with the token and the password of
  # its channel hidden (`/t/*****/`, `user:*****@`), and the record's
  # `channel` and the history without them; rattler kept them, in
  # `conda-meta/*.json`, in what list_packages() shows, and in the error of
  # a failed download.
  local_condathis_sandbox()
  local_parity_micromamba()
  local_proxy_env()
  tokened <- local_http_channel("chA", token = "rt-tok")
  http_channel_release(tokened)
  basic <- local_http_channel("chA", auth = "Basic cnQtdXNlcjpydC1wdw==")
  http_channel_release(basic)
  cases <- list(
    token = list(
      url = paste0(http_channel_base(tokened), "/t/rt-tok/chA"),
      secret = "rt-tok",
      server = tokened
    ),
    login = list(
      url = sub("^http://", "http://rt-user:rt-pw@", basic$url("chA")),
      secret = "rt-pw",
      server = basic
    )
  )
  has_secret <- function(x, secret) {
    return(any(grepl(secret, unlist(x), fixed = TRUE)))
  }
  for (case in names(cases)) {
    url <- cases[[case]]$url
    secret <- cases[[case]]$secret
    prefix <- paste0("rt-pnet-secret-", case)
    frames <- list()
    history <- list()
    for (method in psolve_methods) {
      info <- paste(case, method)
      got <- network_create(prefix, url, method)
      expect_null(got$error, label = info)
      env_name <- psolve_env_name(prefix, method)
      frame <- as.data.frame(condathis::list_packages(
        env_name,
        method = method
      ))
      frames[[method]] <- frame[, c("name", "channel", "base_url", "url")]
      expect_false(has_secret(frames[[method]], secret), label = info)
      record <- readLines(
        file.path(
          psolve_env_dir(env_name, method),
          "conda-meta",
          "foo-1.0-0.json"
        ),
        warn = FALSE
      )
      expect_false(has_secret(record, secret), label = info)
      history[[method]] <- psolve_history(env_name, method)
      expect_false(has_secret(history[[method]], secret), label = info)
    }
    expect_identical(frames$rattler, frames$micromamba, label = case)
    expect_identical(history$rattler, history$micromamba, label = case)
  }
  # A failed download (the archive is gone, and nothing is cached) names
  # the URL with the secret hidden, on both backends.
  local_condathis_sandbox()
  for (case in names(cases)) {
    server <- cases[[case]]$server
    unlink(file.path(server$root, "chA", "noarch", "foo-1.0-0.tar.bz2"))
    for (method in psolve_methods) {
      info <- paste(case, method)
      got <- network_create(
        paste0("rt-pnet-secret404-", case),
        cases[[case]]$url,
        method
      )
      expect_s3_class(got$error, "condathis_create_env_failed")
      texts <- character(0L)
      cnd <- got$error
      while (isFALSE(is.null(cnd))) {
        texts <- c(texts, conditionMessage(cnd), cnd$stderr)
        cnd <- cnd$parent
      }
      expect_false(has_secret(texts, cases[[case]]$secret), label = info)
      if (identical(method, "rattler")) {
        expect_true(any(grepl("*****", texts, fixed = TRUE)), label = info)
      }
    }
  }
})

test_that("neither backend prints the credentials of a channel at \"cmd\" and \"full\" (R-10)", {
  # condathis echoed micromamba's command line, and rattler its request
  # line, with the token or the password of the channel; both now show
  # `*****`, as micromamba hides them in its own log. The `cmd` of the
  # results has them hidden too.
  local_condathis_sandbox()
  local_parity_micromamba()
  local_proxy_env()
  tokened <- local_http_channel("chA", token = "rt-tok")
  http_channel_release(tokened)
  basic <- local_http_channel("chA", auth = "Basic cnQtdXNlcjpydC1wdw==")
  http_channel_release(basic)
  cases <- list(
    token = list(
      url = paste0(http_channel_base(tokened), "/t/rt-tok/chA"),
      secret = "rt-tok",
      hidden = "/t/*****/chA"
    ),
    login = list(
      url = sub("^http://", "http://rt-user:rt-pw@", basic$url("chA")),
      secret = "rt-pw",
      hidden = "http://rt-user:*****@"
    )
  )
  for (case in names(cases)) {
    for (verbose in c("cmd", "full")) {
      for (method in psolve_methods) {
        info <- paste(case, verbose, method)
        env_name <- psolve_env_name(
          paste0("rt-pnet-echo-", case, "-", verbose),
          method
        )
        defer_remove_env(env_name, method = method)
        got <- psolve_capture(condathis::create_env(
          "foo",
          env_name = env_name,
          channels = cases[[case]]$url,
          method = method,
          verbose = verbose
        ))
        expect_null(got$error, label = info)
        texts <- c(
          got$output,
          got$messages,
          unlist(got$value[c("cmd", "stdout", "stderr")])
        )
        expect_false(
          any(grepl(cases[[case]]$secret, texts, fixed = TRUE)),
          label = info
        )
        expect_true(
          any(grepl(cases[[case]]$hidden, got$output, fixed = TRUE)),
          label = info
        )
      }
    }
  }
})

test_that("cached channel metadata that rattler cannot use is downloaded again, as micromamba does (R-39)", {
  # Metadata cached while the clock was ahead: libmamba's freshness rule
  # calls it fresh, rattler's own check of its cache does not, and every
  # create of rattler failed ("no usable repodata cache") until the clock
  # caught up or clean_cache() ran. micromamba downloads it again.
  local_condathis_sandbox()
  local_parity_micromamba()
  local_proxy_env()
  server <- local_http_channel("chA")
  http_channel_release(server)
  for (method in psolve_methods) {
    got <- network_create("rt-pnet-future1", server$url("chA"), method)
    expect_null(got$error, label = method)
  }
  root <- fs::path_dir(condathis::backend_root_dir("rattler"))
  cached <- c(
    list.files(
      file.path(root, "rattler", "repodata_cache"),
      pattern = "[.]json$",
      full.names = TRUE
    ),
    list.files(
      file.path(root, "pkgs", "cache"),
      pattern = "[.]json$",
      full.names = TRUE
    )
  )
  expect_true(length(cached) > 0L)
  Sys.setFileTime(cached, Sys.time() + 3 * 60 * 60)
  for (method in psolve_methods) {
    got <- network_create("rt-pnet-future2", server$url("chA"), method)
    expect_null(got$error, label = method)
    expect_identical(got$packages, "foo", label = method)
  }
})
