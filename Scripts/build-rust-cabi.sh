#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CRATE_DIR="$ROOT_DIR/rust/upkeep_core"
OUT_DIR="$ROOT_DIR/Frameworks"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found. Install Rust via https://rustup.rs/ then re-run this script."
  exit 1
fi

ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
  TARGET="aarch64-apple-darwin"
  # Every Apple Silicon Mac supports apple-m1 (ARMv8.4 LSE atomics, dotprod, NEON, M-series scheduling).
  export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-C target-cpu=apple-m1"
else
  TARGET="x86_64-apple-darwin"
fi

cd "$CRATE_DIR"
cargo build --release --target "$TARGET"
mkdir -p "$OUT_DIR/lib" "$OUT_DIR/include"
cp "target/$TARGET/release/libupkeep_core.a" "$OUT_DIR/lib/"
cp include/upkeep_core.h "$OUT_DIR/include/"
cp include/module.modulemap "$OUT_DIR/include/"
touch "$ROOT_DIR/Package.swift"
echo "Built C-ABI Rust static library: $OUT_DIR/lib/libupkeep_core.a ($TARGET)"
