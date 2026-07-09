test_that("parse_strategy_verbose accepts the documented vocabulary", {
  for (v in c("output", "silent", "cmd", "spinner", "full")) {
    parsed <- parse_strategy_verbose(v)
    expect_identical(parsed$strategy, v)
  }
})

test_that("parse_strategy_verbose maps logical values for backward compatibility", {
  expect_identical(parse_strategy_verbose(TRUE)$strategy, "output")
  expect_identical(parse_strategy_verbose(FALSE)$strategy, "silent")
})

test_that("parse_strategy_verbose rejects unknown values", {
  expect_error(parse_strategy_verbose("nonsense"))
})
