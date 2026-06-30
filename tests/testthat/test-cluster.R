test_that("union-find groups connected elements", {
  # 1-2 connected, 3 alone, 4-5 connected
  comp <- dd_union_find(5, rbind(c(1, 2), c(4, 5)))
  expect_equal(comp[1], comp[2])
  expect_equal(comp[4], comp[5])
  expect_false(comp[1] == comp[3])
  expect_false(comp[1] == comp[4])
  expect_equal(length(unique(comp)), 3L)
})

test_that("exact clustering keeps only shared pixel hashes", {
  photos <- data.frame(
    photo_id = 1:4,
    pixel_hash = c("aaaa", "aaaa", "bbbb", "cccc"),
    stringsAsFactors = FALSE)
  ex <- dd_cluster_exact(photos)
  expect_equal(sort(ex$photo_id), c(1L, 2L))
  expect_true(all(ex$group_key == "aaaa"))
})

test_that("near clustering links similar fingerprints under threshold", {
  # Two near-identical fingerprints (differ in 1 bit) and one far away.
  photos <- data.frame(
    photo_id = 1:3,
    fingerprint = c("ffff", "fffe", "0000"),
    stringsAsFactors = FALSE)
  near <- dd_cluster_near(photos, threshold = 2L, bands = 4L, nbits = 16L)
  expect_setequal(near$photo_id, c(1L, 2L))
  expect_equal(length(unique(near$group_key)), 1L)
})

test_that("near clustering returns empty when nothing is close", {
  photos <- data.frame(
    photo_id = 1:2,
    fingerprint = c("ffff", "0000"),
    stringsAsFactors = FALSE)
  near <- dd_cluster_near(photos, threshold = 1L, bands = 4L, nbits = 16L)
  expect_equal(nrow(near), 0L)
})
