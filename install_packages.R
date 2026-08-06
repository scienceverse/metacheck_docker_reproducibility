# Installs every package the corpus scan found (metacheck_demo/
# all_packages.csv), for the pre-built reproducibility_check
# Docker image. Two-stage per package: live CRAN (via Posit Package
# Manager's Ubuntu 24.04 binary repo, so this is a binary download for the
# vast majority, not a source compile), then a CRAN Archive retry for
# anything no longer served live. This mirrors metacheck's own
# .repro_cran_archive_install() (R/reproducibility_check.R) exactly, since
# that is the retry logic already trusted for the same purpose at paper-run
# time -- duplicated here (not called directly) because this script runs
# before metacheck itself is installed in the image.
#
# Bioconductor and GitHub-only packages are deliberately NOT attempted here
# (see project decision, 2026-08 session): Bioconductor packages are large
# and used by a narrow subset of papers; GitHub-only packages have no
# reliable owner/repo mapping from a bare package name found via static
# library()/require() scanning. Both remain installable at PAPER RUN TIME
# exactly as they work today (a paper's own install_github() call is
# extracted and honoured by repro_install_deps_docker()) -- this script only
# pre-bakes the CRAN-installable majority for speed.
#
# Anything that fails BOTH live CRAN and the Archive is logged and skipped,
# not treated as a build failure -- the corpus list includes real
# extraction false positives (bare names like "i", "n", "pattern", "process"
# from a script's own local variables or tutorial text misread by the
# library()/require() regex scan), which are expected to fail here and
# should not abort ~750 other legitimate installs.

repos <- c(CRAN = "https://packagemanager.posit.co/cran/__linux__/noble/latest")
options(repos = repos)

# PKG_CSV env var lets a different Dockerfile point this same script at a
# different package list without duplicating the CRAN/Archive-retry logic --
# e.g. Dockerfile.minimal uses common_packages.csv (the >=3-corpus-files
# cutoff, 393 packages) instead of the full all_packages.csv
# (753 packages) this file defaults to.
csv_path <- Sys.getenv("PKG_CSV", "/build/all_packages.csv")
pkgs_df <- read.csv(csv_path, stringsAsFactors = FALSE)
base_pkgs <- c("base", "utils", "stats", "methods", "grid", "parallel",
              "graphics", "grDevices", "datasets", "tools", "compiler",
              "splines", "stats4", "tcltk", "parallelly")
pkgs <- setdiff(pkgs_df$package, base_pkgs)
cat("Attempting", length(pkgs), "packages.\n")

# Same Archive-retry logic as .repro_cran_archive_install() (R/reproducibility_check.R):
# find the package's most recent Archive tarball by directory-listing date,
# install via remotes::install_url() (resolves the tarball's own CRAN
# dependencies -- a plain install.packages(repos = NULL, type = "source")
# does NOT, since repos = NULL disables all dependency resolution).
archive_install <- function(pkg) {
  archive_url <- paste0("https://cran.r-project.org/src/contrib/Archive/", pkg, "/")
  listing <- tryCatch(readLines(archive_url, warn = FALSE), error = function(e) NULL)
  if (is.null(listing)) return(FALSE)

  tarball_pat <- paste0(pkg, "_[0-9][^\"']*\\.tar\\.gz")
  hit_lines <- grep(tarball_pat, listing, value = TRUE)
  if (length(hit_lines) == 0) return(FALSE)

  date_pat <- "(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2})"
  dates <- suppressWarnings(as.POSIXct(
    sub(paste0(".*", date_pat, ".*"), "\\1", hit_lines), tz = "UTC"))
  files <- regmatches(hit_lines, regexpr(tarball_pat, hit_lines))
  ord <- if (all(!is.na(dates))) order(dates, decreasing = TRUE) else order(files, decreasing = TRUE)
  latest_file <- files[ord][1]
  tarball_url <- paste0(archive_url, latest_file)

  ok <- tryCatch({
    remotes::install_url(tarball_url, dependencies = NA, upgrade = "never", quiet = TRUE)
    requireNamespace(pkg, quietly = TRUE)
  }, error = function(e) FALSE)
  isTRUE(ok)
}

failed <- character(0)
via_archive <- character(0)

for (pkg in pkgs) {
  if (requireNamespace(pkg, quietly = TRUE)) next   # already present (base R)
  ok <- tryCatch({
    # --no-docs/--no-html/--no-help: skip generating the Rd/HTML help
    # database and rendering vignettes at install time -- this container
    # never calls ?function/browseVignettes(), and generating that content
    # just to delete it afterward (the Dockerfile's own doc-strip step,
    # which still runs as defense-in-depth for any package these flags
    # don't fully cover) wastes real build time for zero runtime benefit.
    # Confirmed as a real, large cost: help/html/Meta measured 924MB and
    # vignette doc/ directories a further 568MB across the full corpus
    # install (2026-08 build).
    install.packages(pkg, quiet = TRUE,
                     INSTALL_opts = c("--no-docs", "--no-html", "--no-help"))
    requireNamespace(pkg, quietly = TRUE)
  }, error = function(e) FALSE)
  if (isTRUE(ok)) next

  cat("[live CRAN failed] ", pkg, " -- trying CRAN Archive ...\n", sep = "")
  if (archive_install(pkg)) {
    via_archive <- c(via_archive, pkg)
    cat("[archive OK] ", pkg, "\n", sep = "")
  } else {
    failed <- c(failed, pkg)
    cat("[FAILED] ", pkg, " -- not on live CRAN or the Archive (likely GitHub-only, ",
        "Bioconductor, or a non-package name picked up by static analysis)\n", sep = "")
  }
}

cat("\n=== install summary ===\n")
cat("total attempted:", length(pkgs), "\n")
cat("installed (incl. already-present):", length(pkgs) - length(failed), "\n")
cat("  of which via CRAN Archive:", length(via_archive), "\n")
cat("unresolved:", length(failed), "\n")
if (length(failed) > 0) {
  cat("\nUnresolved packages (not installed -- see script header for why this",
      "is expected, not a build failure):\n")
  cat(paste(" -", failed), sep = "\n")
}

writeLines(failed, "/build/unresolved_packages.txt")
writeLines(via_archive, "/build/archive_installed_packages.txt")
