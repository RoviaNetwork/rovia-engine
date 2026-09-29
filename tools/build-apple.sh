#!/usr/bin/env bash
# Build the pinned LibXray xcframework for Apple platforms.
#
# Ownership: this recipe lives in rovia-engine. The app repo keeps only a
# refusing guard (tools/build-engine/xray/build-apple.sh) and the release
# ship manifest (engines.lock.json); the lock stays because fifteen release
# consumers read it, and moving it would trade one file location for a
# network fetch in every gate.
#
# Source parameters (inputs, must exist before the build):
#   LIBXRAY_REPO, LIBXRAY_TAG, LIBXRAY_COMMIT, LIBXRAY_GOMOBILE_VERSION below.
# Measured outputs (written only after a successful build, never invented):
#   build/LibXray.xcframework, build/artifact-manifest.json
#
# Usage:
#   tools/build-apple.sh [--work-dir PATH] [--output-dir PATH]
#
# Exit status: 0 only when the artifact was actually built from the pinned
# source. Every refusal names the missing or mismatched input.
set -euo pipefail

# --- Pinned inputs: change these deliberately, with a commit. ---
LIBXRAY_REPO="https://github.com/XTLS/libXray"
LIBXRAY_TAG="v26.9.9"
LIBXRAY_COMMIT="50b95979f5db551bd273165cf469e5daaf791341"
LIBXRAY_GOMOBILE_VERSION="v0.0.0-20260908204917-8b95e45f8d3e"

script_root="$(cd "$(dirname "$0")/.." && pwd)"
work_dir=""
output_dir="$script_root/build"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir)
      [[ $# -lt 2 ]] && { printf '%s\n' "build-apple: --work-dir requires a value" >&2; exit 2; }
      work_dir="$2"; shift 2
      ;;
    --work-dir=*)
      work_dir="${1#*=}"; shift
      ;;
    --output-dir)
      [[ $# -lt 2 ]] && { printf '%s\n' "build-apple: --output-dir requires a value" >&2; exit 2; }
      output_dir="$2"; shift 2
      ;;
    --output-dir=*)
      output_dir="${1#*=}"; shift
      ;;
    -h|--help)
      printf '%s\n' "usage: build-apple.sh [--work-dir PATH] [--output-dir PATH]" >&2
      exit 0
      ;;
    *)
      printf '%s\n' "build-apple: unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if ! command -v go >/dev/null 2>&1; then
  printf '%s\n' "build-apple: no Go toolchain in PATH; refusing to claim an artifact" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' "build-apple: no python3 for libXray build/main.py" >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  printf '%s\n' "build-apple: no xcodebuild; Apple slices cannot be produced here" >&2
  exit 1
fi

if [[ -z "$work_dir" ]]; then
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' EXIT
fi
mkdir -p "$output_dir"

if ! git ls-remote "$LIBXRAY_REPO" "$LIBXRAY_COMMIT" >/dev/null 2>&1; then
  printf '%s\n' "build-apple: cannot resolve pinned commit $LIBXRAY_COMMIT at $LIBXRAY_REPO" >&2
  exit 1
fi
have_go="$(go version | awk '{print $3}')"
printf '%s\n' "build-apple: have $have_go, pinned libXray $LIBXRAY_TAG ($LIBXRAY_COMMIT)"

if [[ ! -d "$work_dir/libXray/.git" ]]; then
  git clone "$LIBXRAY_REPO" "$work_dir/libXray"
fi
git -C "$work_dir/libXray" fetch origin "$LIBXRAY_COMMIT" 2>/dev/null || true
git -C "$work_dir/libXray" checkout -q "$LIBXRAY_COMMIT"
actual_commit="$(git -C "$work_dir/libXray" rev-parse HEAD)"
if [[ "$actual_commit" != "$LIBXRAY_COMMIT" ]]; then
  printf '%s\n' "build-apple: checkout is $actual_commit, want $LIBXRAY_COMMIT" >&2
  exit 1
fi
# The Go directive in libXray's go.mod is the required toolchain floor. A
# newer major.minor is refused: gomobile + cgo + a newer stdlib is exactly
# how irreproducible engine binaries happen.
go_directive="$(grep -m1 '^go ' "$work_dir/libXray/go.mod" | awk '{print $2}')"
have_mm="$(printf '%s' "$have_go" | sed -E 's/^go([0-9]+\.[0-9]+).*/\1/')"
want_mm="$(printf '%s' "$go_directive" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"
if [[ "$have_mm" != "$want_mm" ]]; then
  printf '%s\n' "build-apple: go.mod wants go $go_directive, have $have_go" >&2
  exit 1
fi

export LIBXRAY_GOMOBILE_VERSION
(
  cd "$work_dir/libXray"
  python3 build/main.py apple gomobile
)

framework="$work_dir/libXray/LibXray.xcframework"
if [[ ! -d "$framework" ]]; then
  printf '%s\n' "build-apple: build finished without LibXray.xcframework" >&2
  exit 1
fi
rm -rf "$output_dir/LibXray.xcframework"
cp -R "$framework" "$output_dir/LibXray.xcframework"

python3 - "$output_dir" "$LIBXRAY_TAG" "$LIBXRAY_COMMIT" "$LIBXRAY_REPO" "$have_go" "$go_directive" <<'PY'
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

output_dir, tag, commit, repo, have_go, go_directive = sys.argv[1:7]
framework = Path(output_dir) / "LibXray.xcframework"
entries = []
seen = set()
for binary in sorted(framework.rglob("LibXray")):
    if not binary.is_file():
        continue
    # Versioned frameworks (macOS, Catalyst) expose the binary through a
    # Versions/Current symlink: resolve it and dedupe by real path.
    real = binary.resolve()
    if not real.is_file() or str(real) in seen:
        continue
    seen.add(str(real))
    digest = hashlib.sha256(real.read_bytes()).hexdigest()
    try:
        arches = subprocess.run(
            ["lipo", "-archs", str(real)], capture_output=True, text=True, check=True
        ).stdout.split()
    except (subprocess.CalledProcessError, FileNotFoundError):
        arches = []
    entries.append(
        {
            "slice": str(binary.parent.parent.relative_to(framework)),
            "sha256": digest,
            "size": real.stat().st_size,
            "architectures": arches,
        }
    )
if not entries:
    print("build-apple: no framework binaries found in the artifact", file=sys.stderr)
    raise SystemExit(1)
if shutil.which("xcodebuild"):
    xcode = subprocess.run(
        ["xcodebuild", "-version"], capture_output=True, text=True
    ).stdout.strip().splitlines()[0]
else:
    xcode = "unknown"
manifest = {
    "engine": "xray",
    "source": repo,
    "version": tag,
    "commit": commit,
    "goVersion": have_go,
    "goDirective": go_directive,
    "gomobileVersion": os.environ.get("LIBXRAY_GOMOBILE_VERSION", ""),
    "xcodeVersion": xcode,
    "slices": entries,
}
(Path(output_dir) / "artifact-manifest.json").write_text(
    json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
)
print(f"build-apple: manifest for {len(entries)} slices written")
PY
