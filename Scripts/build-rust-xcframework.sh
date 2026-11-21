#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CRATE_DIR="$ROOT_DIR/rust/upkeep_core"
OUT_DIR="$ROOT_DIR/Frameworks"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found. Install Rust via https://rustup.rs/ to compile upkeep_core."
  exit 1
fi

cd "$CRATE_DIR"
cargo build --release --target aarch64-apple-darwin

rm -rf "$OUT_DIR/UpkeepCore.xcframework"
mkdir -p "$OUT_DIR"

xcodebuild -create-xcframework \
  -library target/aarch64-apple-darwin/release/libupkeep_core.a \
  -headers "$CRATE_DIR/include" \
  -output "$OUT_DIR/UpkeepCore.xcframework"

echo "Built $OUT_DIR/UpkeepCore.xcframework"
