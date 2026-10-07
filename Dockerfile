# The BASE reproducibility_check Docker image: R + Quarto + the full set of
# R packages seen across the metacheck corpus scan (~750 packages, see
# all_packages.csv) + the system libraries those packages need.
# No LaTeX, no CmdStan -- those are separate, larger layers built ON TOP of
# this image's tag (see Dockerfile.tex, Dockerfile.cmdstan), so a paper that
# only needs ordinary R analysis code pulls the smallest, fastest image, and
# a paper needing PDF rendering or cmdstanr pulls a layered variant instead
# of everyone paying for everything. Project decision, 2026-08 session.
#
# Built FROM bare rocker/r-ver, NOT rocker/geospatial: geospatial's own
# GDAL/GEOS/PROJ stack (sf/terra/raster/rgdal/rgeos/sp/gstat/...) covers at
# most 4 of 2330 scanned corpus files -- the same order of magnitude as
# cmdstanr's 3 files, which was judged not worth its own build cost.
#
# MULTI-STAGE build (2026-08 revision): the first pass produced a 6.34GB
# image for what should be ~2-3GB of actual runtime content. Measured
# directly: 2.3GB R packages + 447MB Quarto + the REST was -dev header
# packages (needed only to COMPILE other packages' C/C++/Fortran code, never
# again once that compile is done -- e.g. libpoppler-cpp-dev pulls in
# libpoppler-dev's headers, but pdftools's ALREADY-COMPILED .so only needs
# libpoppler-cpp0t64 at runtime) plus ~924MB of R's own per-package help/
# html/Meta directories (documentation this container never renders --
# nothing here runs ?function or browseVignettes()). A "builder" stage
# installs system -dev headers + compiles all ~750 R packages; the final
# stage copies over ONLY the compiled R library + Quarto + RUNTIME (non-dev)
# system libraries, dropping the dev headers and compiler toolchain entirely.
#
# Build (from metacheck_demo/docker/):
#   docker build -t metacheck-repro:latest -f Dockerfile .

# ══════════════════════════ STAGE 1: builder ═══════════════════════════════
FROM rocker/r-ver:latest AS builder

# ── Quarto ───────────────────────────────────────────────────────────────
# Not an R package -- a separate CLI tool, needed both because some papers'
# analysis code is .qmd and because metacheck's own report() uses Quarto to
# render. Built here, copied whole into the final stage below (Quarto's own
# install has no meaningful dev-vs-runtime split to trim).
#
# Done via R's OWN download.file()/readLines(), not curl/grep -P: bare
# rocker/r-ver has NEITHER curl NOR wget on PATH (confirmed directly --
# `which curl` fails), and this base image's `grep` does not support -P
# PCRE mode either (confirmed: "grep: -P supports only unibyte and UTF-8
# locales" / "missing terminating ] for character class" against the exact
# shell command tried first). R itself is the one thing guaranteed present.
RUN Rscript -e '\
  j <- readLines("https://quarto.org/docs/download/_download.json", warn = FALSE); \
  v <- sub(".*\"version\":\\s*\"([^\"]+)\".*", "\\1", j[grepl("\"version\"", j)][1]); \
  cat("Quarto version:", v, "\n"); \
  url <- paste0("https://github.com/quarto-dev/quarto-cli/releases/download/v", v, "/quarto-", v, "-linux-amd64.deb"); \
  download.file(url, "/tmp/quarto.deb", quiet = FALSE)' \
    && apt-get update && apt-get install -y --no-install-recommends /tmp/quarto.deb \
    && rm -f /tmp/quarto.deb && rm -rf /var/lib/apt/lists/*

# ── System -dev headers, needed only to COMPILE the R packages below ───────
# poppler (pdftools), ImageMagick (magick), librsvg (rsvg/DiagrammeRsvg),
# libcurl/libssl/libxml2 (httr/curl/RCurl/xml2), fonts (extrafont/showtext),
# libuv1t64 (fs's runtime dep -- see below), plus libglpk-dev/libgsl-dev/
# libnetcdf-dev/tcl-dev: found the HARD way (2026-08 build attempt #1) --
# igraph/copula/energy/mvnormalTest/MVN/rtdists/ncdf4/geoR/summarytools ALL
# installed successfully (install.packages() reported no error) but then
# failed to LOAD, with dyn.load() errors naming these exact missing runtime
# .so files -- a class of bug that install-time success completely hides,
# only surfacing at library() time, which is why it took a real test pass
# (not just reading install logs) to find. `apt-cache depends r-cran-<pkg>`
# against Ubuntu's own binary R packages is the authoritative way to check
# this class of dependency; confirmed against r-cran-fs for libuv1t64 first.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpoppler-cpp-dev \
    libmagick++-dev \
    librsvg2-dev \
    libcurl4-openssl-dev \
    libssl-dev \
    libuv1t64 \
    libxml2-dev \
    libfontconfig1-dev \
    libfreetype6-dev \
    fonts-dejavu \
    fonts-liberation \
    ghostscript \
    libglpk-dev \
    libgsl-dev \
    libnetcdf-dev \
    tcl-dev tk-dev \
    libgdal-dev libgeos-dev libproj-dev \
    libudunits2-dev \
    libgl1-mesa-dev libglu1-mesa-dev libx11-dev libfreetype6-dev \
    libpng-dev \
    jags \
    default-jdk \
    && rm -rf /var/lib/apt/lists/*
# libgdal-dev/libgeos-dev/libproj-dev: added so sf/terra/raster/rgdal/rgeos
# (previously failing outright, since rocker/geospatial's stack was dropped
# for being mostly unused -- see header comment) at least get a chance to
# install; still expected to be large/slow for the ~4-file corpus payoff
# they represent, but now a real attempt rather than a guaranteed failure.
#
# libudunits2-dev: `units` (a transitive sf/stars dependency -- confirmed as
# a real "installed but not loadable" failure against a real BES-corpus run,
# not a hypothetical) needs libudunits2 at both compile AND runtime; without
# it install.packages("units") itself fails outright (not even the
# install-succeeds-load-fails pattern -- it never gets that far).
#
# libgl1-mesa-dev/libglu1-mesa-dev/libx11-dev: `rgl` (common alongside sf/
# terra for 3D visualisation -- also a confirmed real "not loadable" BES
# failure) needs OpenGL + X11 headers to compile its interactive device
# backend. rgl can build a software-rendering-only backend without a GPU,
# but still needs these headers present to compile at all.
#
# libpng-dev: found the hard way testing rgl specifically -- it ALSO
# #includes png.h directly (for texture/image support in its 3D device,
# independent of the OpenGL/X11 headers above), and compilation fails
# outright ("fatal error: png.h: No such file or directory") without it.
# Confirmed this is the ONLY thing blocking rgl once OpenGL/X11/JAGS/JDK
# were already in place -- a real, live build+load test against this exact
# Dockerfile, not a guess from rgl's own documentation.
#
# jags (the JAGS MCMC sampler itself, NOT an R package -- it is the external
# program rjags/R2jags dynamically link against) + default-jdk (rJava/
# glmulti need a real JDK, not just a JRE, for R CMD javareconf below) --
# issue #395: confirmed real "installed but not loadable" failures for
# rjags/R2jags/rJava/glmulti against a real BES-corpus run (the R package
# installs fine either way; it is the MISSING EXTERNAL PROGRAM/JDK that
# dyn.load() fails against, not a compile step).
#
# R CMD javareconf here too (builder stage): rJava's own install.packages()
# COMPILE step (below) probes for a JVM via the same javareconf-recorded
# Makeconf entries the runtime stage's own javareconf call (near the bottom
# of this file) sets up again for its copied-in JDK -- without running it
# here first, rJava fails to even COMPILE (not merely the install-succeeds-
# load-fails pattern the rest of this comment block documents).
RUN R CMD javareconf

# rjags module-path symlink: found the hard way testing rjags specifically --
# it installs and even COMPILES cleanly, but then fails to LOAD with
# "File not found: /usr/lib/JAGS/modules-4/basemod.so". Ubuntu's own `jags`
# apt package installs its modules at the Debian MULTIARCH path
# (/usr/lib/x86_64-linux-gnu/JAGS/modules-4/), but rjags's own configure
# script resolves (hardcodes, at COMPILE time) the non-multiarch path
# instead -- a real, confirmed mismatch, not a hypothetical. A symlink from
# the path rjags expects to where the files actually are is the standard
# fix (and the only ONE needed, confirmed directly: this alone took rjags
# from failing to load to loading cleanly). Created in the BUILDER stage
# because rjags is COMPILED here, and that compiled .so's expected search
# path is baked in at this point; the runtime stage needs its own matching
# symlink too (see below) since it has a freshly apt-installed `jags` of
# its own with the same multiarch layout.
RUN mkdir -p /usr/lib/JAGS && \
    ln -s /usr/lib/x86_64-linux-gnu/JAGS/modules-4 /usr/lib/JAGS/modules-4

# ── R packages from the corpus scan ─────────────────────────────────────────
# See install_packages.R's own header for the CRAN -> CRAN Archive retry
# logic and why Bioconductor/GitHub-only packages are deliberately excluded
# here (they still install correctly at PAPER RUN TIME if that paper's own
# code names a GitHub source -- this only pre-bakes the CRAN-installable
# majority for speed).
RUN mkdir -p /build
COPY all_packages.csv /build/all_packages.csv
COPY install_packages.R /build/install_packages.R
RUN Rscript /build/install_packages.R

# ── Strip per-package documentation NOT needed at runtime ──────────────────
# help/ (the ?function Rd database) and html/ (rendered HTML help) measured
# 924MB TOGETHER WITH Meta/, and vignette doc/ directories a further 568MB,
# across the installed library (2026-08 build) -- nothing in an automated
# docker-run script calls ?function/browseVignettes()/vignette().
# install_packages.R's own --no-docs/--no-html/--no-help install flags
# should mean most of help/html/doc is never generated in the first place;
# this find/rm is defense-in-depth for any package whose build ignores those
# flags (some do, e.g. packages with their own custom Makevars doc step).
#
# Meta/ is DELIBERATELY NOT stripped, despite looking like the same kind of
# dead weight: confirmed the hard way that it is NOT safe to remove.
# installed.packages() reads Meta/package.rds as its package index rather
# than re-scanning DESCRIPTION files live -- stripping Meta/ across the
# library made installed.packages() report only 31 base packages instead of
# the real ~1170 installed (individual packages still LOADED fine via
# library()/requireNamespace(), which is what made this easy to miss --
# only enumeration was broken, not loading). Whatever else in metacheck's
# pipeline calls installed.packages() (dependency-availability checks, etc.)
# would have silently seen an almost-empty library. Meta/ stays.
RUN find /usr/local/lib/R/site-library -maxdepth 2 -type d \
      \( -name help -o -name html -o -name doc \) -exec rm -rf {} + 2>/dev/null || true

# ── Strip debug symbols from compiled package .so files ────────────────────
# Compiled shared objects (rstan's, igraph's, ...) carry debug symbols by
# default, which can be a large fraction of a .so's size and serve no
# purpose once the package is built -- `strip` removes them without
# affecting the compiled code's behaviour. -s (--strip-all) is safe here:
# this is the FINAL compiled output, nothing downstream re-links against it.
RUN find /usr/local/lib/R/site-library -name "*.so" -exec strip --strip-unneeded {} + 2>/dev/null || true

# ══════════════════════════ STAGE 2: runtime ═══════════════════════════════
# Only the compiled R library + Quarto + RUNTIME (non-dev) system libraries
# are copied in -- no compiler toolchain, no -dev headers, no apt package
# cache. A paper's script that itself calls install.packages() at RUN TIME
# would need a compiler and is a separate, already-known limitation (static
# analysis + repro_install_deps_docker() handle declared dependencies before
# the run phase; this image is not meant to compile NEW packages on the fly).
FROM rocker/r-ver:latest

COPY --from=builder /opt/quarto /opt/quarto
RUN ln -sf /opt/quarto/bin/quarto /usr/local/bin/quarto
COPY --from=builder /usr/local/lib/R/site-library /usr/local/lib/R/site-library

# Runtime-only counterparts of the builder stage's -dev packages (no *-dev,
# no compiler toolchain) -- what the ALREADY-COMPILED .so files in
# site-library actually dyn.load() against.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpoppler-cpp0t64 \
    libmagick++-6.q16-9t64 \
    librsvg2-2 librsvg2-common \
    libcurl4 \
    libssl3 \
    libuv1t64 \
    libxml2 \
    libfontconfig1 \
    libfreetype6 \
    fonts-dejavu \
    fonts-liberation \
    ghostscript \
    libglpk40 \
    libgsl27 libgslcblas0 \
    libnetcdf19t64 \
    libtcl8.6 libtk8.6 \
    libgdal34t64 libgeos-c1t64 libproj25 \
    libudunits2-0 \
    libgl1 libglu1-mesa libx11-6 \
    libpng16-16 \
    jags \
    default-jdk \
    && rm -rf /var/lib/apt/lists/*
# jags and default-jdk are RUNTIME, not builder-only, unlike this image's
# other -dev/non-dev pairs: JAGS itself is an external PROGRAM rjags/R2jags
# shell out to / dynamically link against at call time (not something an R
# package's own compiled .so statically links at build time), and rJava
# needs a live JVM (libjvm.so, reached via JAVA_HOME) present wherever R
# actually runs, not just wherever rJava was compiled -- a JRE alone is
# usually enough for libjvm.so, but default-jdk (not default-jre) is used
# here because a handful of Java-dependent R packages invoke `javac`
# dynamically at RUNTIME (not merely at package-build time), which a
# JRE-only install does not provide.
#
# R CMD javareconf: rJava's install step probes for a JVM and records its
# path/flags into R's own Makeconf: run here (AFTER the JDK is installed,
# in the RUNTIME stage specifically) so the recorded path matches where
# the JDK actually lives in the final image, not wherever (or whether) one
# was present during the builder stage's own install_packages.R run.
RUN R CMD javareconf

# Same rjags module-path symlink as the builder stage (see that stage's own
# comment for the full explanation) -- this stage has its OWN freshly
# apt-installed `jags`, at the same Debian multiarch path, so it needs the
# same symlink independently (the builder stage's own symlink lives only in
# that stage's filesystem layer, which this FROM rocker/r-ver:latest stage
# does not inherit).
RUN mkdir -p /usr/lib/JAGS && \
    ln -s /usr/lib/x86_64-linux-gnu/JAGS/modules-4 /usr/lib/JAGS/modules-4

# ── Non-root user the run phase actually uses ───────────────────────────────
# repro_run_scripts_docker() always runs as uid:gid 1000:1000 (see
# .repro_docker_uid, R/reproducibility_check_docker.R). Bare rocker/r-ver
# has NO uid-1000 user (confirmed -- unlike rocker/geospatial's inherited
# `rstudio` user), so one is created explicitly here with a real home
# directory so R's user-level paths (e.g. a user library, if ever needed)
# have somewhere to write.
RUN useradd -m -u 1000 -s /bin/bash rcheck

CMD ["R"]
