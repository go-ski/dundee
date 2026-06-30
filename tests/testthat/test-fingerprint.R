test_that("fingerprint bits expand correctly", {
  # 0xF0 -> 1111 0000
  expect_equal(dd_fingerprint_bits("f0"), c(1L, 1L, 1L, 1L, 0L, 0L, 0L, 0L))
  expect_equal(dd_fingerprint_bits("00"), rep(0L, 8))
  expect_equal(sum(dd_fingerprint_bits("ff")), 8L)
})

test_that("hamming distance is symmetric and correct", {
  expect_equal(dd_hamming("f0", "f0"), 0L)
  # 0xF0 vs 0x00 differ in 4 bits
  expect_equal(dd_hamming("f0", "00"), 4L)
  expect_equal(dd_hamming("f0", "ff"), dd_hamming("ff", "f0"))
})

test_that("empty fingerprints yield NA distance", {
  expect_true(is.na(dd_hamming("", "ff")))
})
