# metacheck Docker reproducibility images

Pre-built Docker images for [metacheck](https://github.com/scienceverse/metacheck)'s
`reproducibility_check(execute = TRUE, sandbox = "docker")` execution backend.
Running a paper's downloaded code with `sandbox = "docker"` sandboxes it (no
network, read-only filesystem, non-root user) instead of running it directly
on your machine — see `R/reproducibility_check_docker.R` in the main
metacheck repo for the backend itself. These images exist so that sandbox
run doesn't have to compile ~400-750 R packages (or install ~50-120 Python
packages) from scratch every time.

**Naming/publish status as of 2026-10 (confirmed by direct `docker pull`,
not assumed from this README alone — see the next session's own notes
before trusting any image name here without checking):** `ghcr.io/
scienceverse/metacheck_r:latest` (the single, un-split image) is the ONLY R
image actually live on the registry right now. `metacheck_r_large`/
`metacheck_r_small` below describe Dockerfiles that exist in this repo and
have been built and smoke-tested LOCALLY, but have NOT yet been pushed to
`ghcr.io` — `metacheck-new`'s own R code (`.repro_docker_default_image` in
`R/reproducibility_check_docker.R`) was briefly pointed at
`metacheck_r_large` and had to be reverted once a real `docker pull`
confirmed it did not exist. **Before changing that constant again, run
`docker pull ghcr.io/scienceverse/<name>:latest` yourself and confirm it
succeeds — do not trust this file's own naming claims without checking.**
The Python images (`metacheck_py_small`/`metacheck_py_large`) are in the
same state: built and tested locally, not yet pushed.

## Images

| Image | Tag | Contents | Size (uncompressed) | Use when |
|---|---|---|---|---|
| `metacheck_r_large` | `latest` | ~750 R packages (every package seen anywhere in the corpus scan) + JAGS + a JDK + the GDAL/GEOS/PROJ geospatial stack (sf/terra/stars/rgl/tmap/...) | ~4.9GB | You want maximum R coverage, including geospatial/ecology and JAGS-based Bayesian papers, and don't mind a bigger pull |
| `metacheck_r_small` | `latest` | ~390 R packages (seen in ≥3 corpus files) + JAGS + a JDK | ~4.4GB | Smaller, more conservative default; a paper needing an uncommon or geospatial package falls back to installing it at run time |
| `metacheck_py_small` | `latest` | ~45 Python packages seen in ≥2 of 486 scanned files (numpy/pandas/scipy/matplotlib/seaborn/scikit-learn/statsmodels/django/pytest/...) | ~2.7GB | Default for Python reproducibility checks; a paper needing an uncommon package installs it at run time |
| `metacheck_py_large` | `latest` | everything `metacheck_py_small` has, plus ~70 more less-common packages and CPU-only torch + tensorflow-cpu | ~8.3GB | A paper uses a deep-learning framework and you don't want the slow run-time install |

The R images include R (`rocker/r-ver` base) and Quarto. Neither includes
LaTeX/TinyTeX or CmdStan — see "Planned variants" below. The Python images
are built on `python:3.11-slim`; see "Python images" below for their own
build notes. `psychopy` was deliberately excluded from both Python images
despite being common in the scan (18 of 486 files) — it is a live-
experiment stimulus-presentation library (GUI/audio/video/serial-port I/O)
with no legitimate use in an analysis-only execute phase, and its own
install pulls in PyQt6 + ffmpeg/moviepy/pyglet (measured: ~700MB) for
nothing this image's own use case needs.

## Quick start

```r
reproducibility_check(paper, execute = TRUE, sandbox = "docker",
                      docker_image = "ghcr.io/scienceverse/metacheck_r_large:latest")
```

(Check the `docker_image`/image-selection argument name against the current
`reproducibility_check()` signature in the main repo — this may have
changed since this README was written.)

## Building from source

### R images

Both Dockerfiles are self-contained in this repo (Dockerfile + its package
CSV sit side by side, no external build context needed):

```bash
# Large image (~750 packages)
docker build -t metacheck_r_large:latest -f Dockerfile .

# Small image (~390 packages)
docker build -t metacheck_r_small:latest -f Dockerfile.minimal .
```

Expect the large build to take **2+ hours** as of the 2026-10 JAGS/
geospatial additions (measured directly: ~2.3 hours for the full ~750-
package list including `brms`/Stan-family source compiles) — longer than
this file's earlier "30-60+ minutes" estimate, which predates those
additions. The small build is faster but still expect 25-30+ minutes. Most
of the time is R packages either downloading as binaries (fast) or
compiling from source (slow; no binary exists for every platform/package
combination on Posit Package Manager).

**Build these ONE AT A TIME, not concurrently** — confirmed directly as a
real failure mode, not a theoretical one: running the large and small
builds at the same time exhausted the host's disk (Docker Desktop's own
WSL2 virtual disk on Windows does not shrink back down after a build
completes or is pruned — it stays at its own high-water mark until the
`.vhdx` is manually compacted), which crashed Docker Desktop itself
mid-build with `dpkg: unrecoverable fatal error ... Input/output error` on
BOTH builds. `docker builder prune -af` reclaims build-cache SPACE Docker
itself tracks, but does not shrink the underlying WSL2 disk file back down
on Windows — if `df`/disk usage stays high after pruning, that is the next
thing to check, not a sign the prune failed.

### Python images

```bash
# Small image (~45 packages: numpy/pandas/scipy/matplotlib/seaborn/
# scikit-learn/statsmodels/django/pytest/...)
docker build -t metacheck_py_small:latest -f Dockerfile.py.small .

# Large image (built FROM metacheck_py_small -- build that first):
# ~70 more packages + CPU-only torch + tensorflow-cpu
docker build -t metacheck_py_large:latest -f Dockerfile.py.large .
```

Much faster than the R builds (~7 minutes for the small image, since pip
installs pre-compiled wheels for nearly everything in the list rather than
compiling from source) — except the large image's torch/tensorflow-cpu
downloads, which dominate its own build time.

### Updating the package lists

`all_packages.csv` and `common_packages.csv` (R) are `package,n_files`
tables generated by scanning a local corpus cache of downloaded papers for
`library()`/`require()`/`p_load()` calls (via metacheck's own
`code_library_names()`). `all_packages_py.csv` and `common_packages_py.csv`
(Python) are the same idea via `code_library_names(lang = "Python")`
against a Python corpus cache's `import`/`from ... import` statements
(2026-10, 486 files scanned), with a `pypi_package` column instead of
`package` since the importable module name and the installable PyPI
distribution name sometimes differ (`sklearn` → `scikit-learn`, `cv2` →
`opencv-python`, `PIL` → `Pillow`, `yaml` → `PyYAML`). To regenerate either
side against a newer/larger corpus, scan every file with
`code_library_names()` and tally package frequency into a `package,n_files`
table (see the metacheck project session notes, 2026-08 for R / 2026-10 for
Python, for the exact scan scripts used to build the current lists).

The raw scan output needs manual filtering before it is a usable package
list — confirmed necessary both times this has been done: a static import/
library() scan cannot tell a real installable package from (a) a paper's
OWN local module/script picked up by the same regex (the Python scan's
raw output included things like a single paper's own `probCMR_overrides`
module, and — more subtly — a corpus that happens to contain a PACKAGE'S
OWN source repository as one of its "papers" inflates that package's own
internal submodule imports to look like heavy real-world usage: the 2026-10
scan's `innvestigate` entry at 45 files was entirely this artefact, traced
to the corpus containing `innvestigate`'s own GitHub repo), (b) Python
2-era stdlib names a straggling compat script imports (`StringIO`,
`ConfigParser`), and (c) a package that is real but needs manual
intervention to install at all (`psiturk`: needs a C compiler for
`psutil`/`setproctitle`, dropped rather than fought for a niche tool).

`common_packages.csv`/`common_packages_py.csv` should be the `all_`
variant filtered to `n_files >= 3` (R) / `>= 2` (Python, since the smaller
486-file Python corpus makes `>= 3` too strict a cutoff) — or whatever
cutoff feels right; this is a judgement call, not a fixed rule.

### Pushing a new build

```bash
# R
docker tag metacheck_r_large:latest ghcr.io/scienceverse/metacheck_r_large:latest
docker push ghcr.io/scienceverse/metacheck_r_large:latest
docker tag metacheck_r_small:latest ghcr.io/scienceverse/metacheck_r_small:latest
docker push ghcr.io/scienceverse/metacheck_r_small:latest

# Python
docker tag metacheck_py_small:latest ghcr.io/scienceverse/metacheck_py_small:latest
docker push ghcr.io/scienceverse/metacheck_py_small:latest
docker tag metacheck_py_large:latest ghcr.io/scienceverse/metacheck_py_large:latest
docker push ghcr.io/scienceverse/metacheck_py_large:latest
```

Requires `docker login ghcr.io` with a token that has `write:packages` scope
and push access to the `scienceverse` org. **After pushing, update
`metacheck-new`'s `.repro_docker_default_image`/`.repro_docker_default_image_py`
constants (`R/reproducibility_check_docker.R` /
`R/reproducibility_check_python_docker.R`) to point at the newly-pushed
name — AND verify with `docker pull` first** (see the naming-status note at
the top of this file for why that verification step is not optional).

## Reducing image size: what we learned (2026-08)

The first build came out at 6.34GB, which felt far too large for ~750 R
packages + Quarto. Here is exactly what was tried, what worked, what didn't,
and what the real floor turned out to be — so the next person doesn't have
to re-discover this.

### What actually worked

1. **Multi-stage build.** A `builder` stage installs `-dev` system headers
   (needed only to *compile* packages) and compiles everything; the final
   stage copies over only the compiled R library, Quarto, and the
   **runtime** (non-`-dev`) counterparts of those system libraries. This
   drops the entire compiler toolchain and header files from the final
   image. Concretely: `libpoppler-cpp-dev` (builder) → `libpoppler-cpp0t64`
   (runtime); `libmagick++-dev` → `libmagick++-6.q16-9t64`; and so on for
   every system library. Find the runtime package name with
   `apt-cache depends <the-dev-package>` or `apt-cache search <libname>`.

2. **Strip R's own generated documentation.** `install.packages()` with
   `INSTALL_opts = c("--no-docs", "--no-html", "--no-help")` avoids
   generating the `?function` Rd database and rendered HTML help in the
   first place. A defensive `find ... -name help -o -name html -o -name doc
   -exec rm -rf` after install cleans up anything a package's own build
   process generates anyway despite those flags (some do — packages with a
   custom `Makevars`/doc step). Measured: **924MB** in `help/`+`html/`
   directories, **568MB** in vignette `doc/` directories, across the full
   ~750-package library. Nothing in an automated `docker run` script calls
   `?function`, `browseVignettes()`, or `vignette()`, so this is pure dead
   weight for this use case specifically.

3. **`strip --strip-unneeded` on compiled `.so` files.** Cheap, safe,
   essentially zero risk (`|| true`, and it's the final compiled output —
   nothing re-links against it). In practice this saved very little on our
   corpus: most `.so` files here came from Posit Package Manager's
   pre-compiled binaries, which are already stripped. Worth keeping for the
   packages that DO compile from source, but don't expect much from it.

### What we got WRONG the first time (a real correctness bug, not just size)

**`Meta/` looks like the same kind of dead weight as `help/`/`html/`/`doc/`
— it is NOT.** `Meta/` holds `Meta/package.rds`, which `installed.packages()`
reads as its package index instead of re-scanning every `DESCRIPTION` file
live. Stripping `Meta/` across the library made `installed.packages()`
report only ~31 base R packages instead of the real ~1170 installed —
**individual packages still `library()`/`requireNamespace()`d fine**, which
is what made this dangerous to miss: only *enumeration* was broken, not
*loading*. Anything in a pipeline that calls `installed.packages()` (a
dependency-availability check, for instance) would have silently seen an
almost-empty library. **Do not strip `Meta/`.** This cost a full rebuild
cycle (~45 min) to catch and fix — verify with
`length(installed.packages()[,1])` after any change to what gets stripped,
not just "do individual packages load".

### What ISN'T actually a lever (checked and ruled out)

- **Quarto is not the villain.** It measures ~450-470MB (`du -sh /opt/quarto`),
  confirmed directly — not the 1.5GB it might feel like. There's no
  supported way to trim it further (it bundles a full Deno runtime and
  Pandoc) without breaking Quarto itself.
- **R itself, compiled from source, is ~800MB** inside the `rocker/r-ver`
  base image (`rocker_scripts/install_R_source.sh`). This is a fixed,
  already-shared cost if the base image is already pulled for other reasons
  — not something this project's Dockerfiles add on top.
- **`docker images` / `docker system df` size numbers are misleading for
  "how much do I actually need to download."** They report each image's
  *total* size including fully-counted shared base layers. The number that
  actually matters for "how much extra does pulling THIS image cost, if I
  already have the base" is closer to what `docker save <image> | wc -c`
  reports for that image's own unique layers (~1.3GB for the large image on
  top of the shared `rocker/r-ver` base, measured directly) — NOT the
  4.5-6GB figure `docker images` shows. If image size is being reported to
  someone, be precise about which number you mean.

### The realistic floor

For "R + Quarto + N real CRAN packages, doc-stripped, multi-stage,
Meta/ correctly preserved": expect roughly **3.5-4.5GB reported by `docker
images`** for a ~400-750 package list, of which **~1.3-1.5GB is genuinely
unique to a from-scratch build** on top of the shared `rocker/r-ver` base.
This is comparable to (often smaller than) other all-in-one R data-science
images (`rocker/verse` alone is 6GB+; `jupyter/datascience-notebook` is
~5GB). Going meaningfully below this means fewer packages, not more
aggressive stripping of what's already there — see `metacheck_r_small` for
that tradeoff already made once.

### Missing runtime `.so` libraries: a whole class of silent bugs

A package can `install.packages()` successfully and STILL fail to load,
because a runtime shared library its compiled `.so` needs (`libglpk.so.40`,
`libgsl.so.27`, `libnetcdf.so.19`, `libtcl8.6.so`, `libuv.so.1`, ...) isn't
present in a minimal base image. **Install-time success does not mean
load-time success.** Confirmed the hard way against `osfr` (→ `fs` →
`libuv.so.1`), then a further batch (`rstanarm`/`ggraph`/`qgraph`/`ggm` →
`igraph` → `libglpk.so.40`; `copula`/`energy`/`mvnormalTest`/`MVN`/`rtdists`
→ `libgsl.so.27`; `ncdf4` → `libnetcdf.so.19`; `geoR` → `tcltk` →
`libtcl8.6.so`). The authoritative way to check this class of dependency is
`apt-cache depends r-cran-<pkgname>` (Ubuntu's own binary R packages
declare their real runtime `.so` dependencies) — don't guess from the
package's CRAN page alone. If a new "unresolved" package shows up in a
future build's `unresolved_packages.txt` that you'd expect to work, test it
directly:

```r
install.packages("thepackage")
library(thepackage)   # the REAL test -- install succeeding is not enough
```

and read the `dyn.load()` error for the missing `.so` name.

### 2026-10 additions: JAGS, a JDK, and the geospatial stack

Added to both R Dockerfiles after a real BES (ecology journal) corpus run
surfaced a concrete, ranked list of "installed but not loadable" failures:
`sf` (45 occurrences), `rgdal` (25), `rgeos` (14), `maptools` (10), plus
`stars`/`tmap`/`mapview`/`ggspatial`/`rgl` (4-6 each) on the geospatial
side, and `rjags`/`rJava`/`glmulti`/`R2jags` (matching issue #395) on the
JAGS/Java side. Two NEW instances of the missing-runtime-.so class the
section above already documents, found fixing this:

- **`rgl` needs `libpng-dev`/`libpng16-16`** (compile/runtime), not just the
  OpenGL/X11 headers its own documentation emphasises — it directly
  `#include`s `png.h` for its 3D device's texture/image support,
  independent of the GL/X11 path. Confirmed as the ONLY remaining blocker
  once JAGS/JDK/OpenGL/X11 were already in place for a different reason.
- **`rjags` compiles and installs cleanly, but fails to LOAD** with `File
  not found: /usr/lib/JAGS/modules-4/basemod.so` — Ubuntu's own `jags` apt
  package installs its modules at the Debian MULTIARCH path
  (`/usr/lib/x86_64-linux-gnu/JAGS/modules-4/`), but `rjags`'s own
  `configure` script resolves (hardcodes, at COMPILE time) the
  non-multiarch path instead. Fixed with a symlink
  (`ln -s /usr/lib/x86_64-linux-gnu/JAGS/modules-4 /usr/lib/JAGS/modules-4`),
  confirmed sufficient on its own — created in BOTH stages (builder, since
  that is where `rjags` is compiled and its expected search path gets baked
  in; runtime, since it has its own freshly apt-installed `jags` at the
  same layout).

`rgdal`/`rgeos` remain genuinely broken and are NOT fixable by adding
system libraries — confirmed directly (`install.packages("rgdal")` itself
reports "package is not available for this version of R" even with every
relevant `-dev` header present): both were formally removed from CRAN's
live index in 2023, exactly the "uncertain, needs a real test" risk issue
#395 itself flagged before this was investigated. `sf`/`terra`/`stars` are
their modern, actively-maintained replacements and all load correctly.

**`psychopy` was found and testing-confirmed, then REMOVED from the Python
package lists** after being included once — see the "Python images" table
entry above for why it has no legitimate use in this execute phase, and the
~700MB it cost before being dropped.

**Status as of this write-up:** `metacheck_r_small` was rebuilt with ALL of
the above fixes and verified. `metacheck_r_large` was rebuilt with the
JAGS/JDK/OpenGL/X11/udunits fixes and verified (`sf`/`stars`/`units`/
`rjags`/`rJava`/`jagsUI`/`runjags`/`mapview`/`ggspatial`/`R2jags`/
`glmulti`/`lwgeom`/`tmap` all confirmed loading correctly against it), but
**NOT yet rebuilt with the later `libpng-dev` + `rjags` symlink fixes**
(found testing AFTER that build) due to running out of local disk space
mid-session — rebuild it with the current Dockerfile before relying on
`rgl` loading in the large image specifically, or re-verify first with
`docker run --rm metacheck_r_large:latest Rscript -e
'requireNamespace("rgl", quietly = TRUE)'`.

## Planned variants (not yet built)

- **TinyTeX layer** (`rmarkdown`/`knitr`/`bookdown`/`papaja` PDF rendering) —
  needed because the sandbox run phase has no network access, so a LaTeX
  package can't be fetched on demand mid-run. Should be a separate image
  built `FROM` one of the two above, not baked into the base — keeps the
  default pull smaller for papers that don't render PDFs.
- **CmdStan layer** (for `cmdstanr` specifically) — deliberately NOT
  included in either image above: `cmdstanr` appeared in only 3 of 2330
  scanned corpus files (0.13%), while pre-building CmdStan is a genuine
  from-source C++ compile taking 20-40+ minutes even with parallel `make`.
  `rstan`/`brms`/`rstanarm`/`bayesplot` (231 files, ~10% of the corpus) need
  NO CmdStan at all — they compile their own bundled Stan headers as an
  ordinary part of their R package install, which both images already do.

## Files in this repo

- `Dockerfile` — the large R image (~750 packages + JAGS/JDK/geospatial)
- `Dockerfile.minimal` — the small R image (~390 packages, `n_files >= 3`,
  + JAGS/JDK)
- `install_packages.R` — shared install script both R Dockerfiles use
  (reads `PKG_CSV` env var to pick which package list; defaults to
  `all_packages.csv`)
- `all_packages.csv` — every R package found in the corpus scan, with
  `n_files` (how many scanned files referenced it)
- `common_packages.csv` — the `n_files >= 3` subset used by
  `Dockerfile.minimal`
- `Dockerfile.py.small` — the small Python image (~45 packages,
  `n_files >= 2` of a 486-file scan)
- `Dockerfile.py.large` — the large Python image (built FROM
  `metacheck_py_small`; ~70 more packages + CPU-only torch/tensorflow-cpu)
- `install_packages_py.py` — shared install script both Python Dockerfiles
  use (reads `PKG_CSV`/`HEAVY_DL` env vars)
- `all_packages_py.csv` / `common_packages_py.csv` — the Python
  equivalents of the two R CSVs above, with a `pypi_package` column (see
  "Updating the package lists")
