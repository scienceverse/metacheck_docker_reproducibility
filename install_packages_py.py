#!/usr/bin/env python3
"""Installs every package the corpus scan found, for the pre-built
reproducibility_check Python Docker images.

PKG_CSV env var picks which package list (same two-tier split as the R
images' install_packages.R/PKG_CSV): common_packages_py.csv for the small
image (n_files >= 2 in the corpus scan), all_packages_py.csv for the large
image. HEAVY_DL env var ("1"/"0") additionally installs the CPU-only
deep-learning libraries (torch/tensorflow) the CSVs deliberately exclude --
see this repo's README for why those are a separate opt-in rather than baked
into either CSV-driven list.

Unlike R's install_packages.R, there is no CRAN-vs-Archive two-stage retry:
PyPI does not remove old releases the way CRAN's rolling live index does, so
a single `pip install` attempt per package is the whole story. A package
`pip` cannot find (almost always a corpus false positive -- a paper's own
local module name picked up by the same static import scan that misreads a
script's own "i"/"n"/"pattern"-style bare names on the R side, e.g. a
single-paper helper module like "fitCMR") is logged and skipped, not treated
as a build failure -- the full package list was already filtered to drop the
most obvious of these (see build_py_package_lists.R's own filtering, run
once against the corpus scan to produce the checked-in CSVs), but a residual
one slipping through here must not abort every other legitimate install.
"""
import csv
import os
import subprocess
import sys

csv_path = os.environ.get("PKG_CSV", "/build/all_packages_py.csv")
with open(csv_path, newline="", encoding="utf-8") as f:
    pkgs = [row["pypi_package"] for row in csv.DictReader(f)]

heavy_dl = os.environ.get("HEAVY_DL", "0") == "1"
if heavy_dl:
    # CPU-only wheels specifically: the default PyPI `torch`/`tensorflow`
    # wheels pull in CUDA runtime libraries several GB in size that are
    # useless in a sandboxed, GPU-less container -- the CPU-only wheel
    # index (--index-url for torch; the plain `tensorflow-cpu` package for
    # TF) avoids that entirely. Verified: torch's own CPU-only wheel index
    # is published at download.pytorch.org/whl/cpu.
    pkgs = pkgs + ["tensorflow-cpu"]

print(f"Attempting {len(pkgs)} package(s)" +
      (" + CPU-only torch" if heavy_dl else "") + ".", flush=True)

failed = []
for pkg in pkgs:
    print(f"[installing] {pkg} ...", flush=True)
    res = subprocess.run([sys.executable, "-m", "pip", "install", "--quiet", pkg],
                        capture_output=True, text=True)
    if res.returncode != 0:
        print(f"[FAILED] {pkg} -- {res.stderr.strip().splitlines()[-1] if res.stderr.strip() else 'unknown error'}",
              flush=True)
        failed.append(pkg)

if heavy_dl:
    print("[installing] torch (CPU-only wheel) ...", flush=True)
    res = subprocess.run([sys.executable, "-m", "pip", "install", "--quiet",
                         "torch", "--index-url", "https://download.pytorch.org/whl/cpu"],
                        capture_output=True, text=True)
    if res.returncode != 0:
        print(f"[FAILED] torch -- {res.stderr.strip().splitlines()[-1] if res.stderr.strip() else 'unknown error'}",
              flush=True)
        failed.append("torch")

print("\n=== install summary ===", flush=True)
print(f"total attempted: {len(pkgs) + (1 if heavy_dl else 0)}", flush=True)
print(f"installed: {len(pkgs) + (1 if heavy_dl else 0) - len(failed)}", flush=True)
print(f"unresolved: {len(failed)}", flush=True)
if failed:
    print("\nUnresolved packages (not installed -- see this script's own "
          "header for why this is expected, not a build failure):", flush=True)
    for f in failed:
        print(f" - {f}", flush=True)

with open("/build/unresolved_packages_py.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(failed))
