#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXECUTABLE_NAME="Upkeep"
APP_NAME="Upkeep"
BUNDLE_ID="com.local.Upkeep"
APP_VERSION="${UPKEEP_VERSION:-1.1.2}"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
DEV_CERT_NAME="Upkeep Local Signing"

echo "Building $APP_NAME (Swift 6 release)..."
cd "$ROOT_DIR"
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if command -v cargo >/dev/null 2>&1 && [[ -x "$ROOT_DIR/Scripts/build-rust-cabi.sh" ]]; then
    echo "Building Rust upkeep_core static library..."
    "$ROOT_DIR/Scripts/build-rust-cabi.sh"
fi
if [[ -z "${SDKROOT:-}" && -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" && ! -f "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]; then
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
fi
swift build -c release --disable-sandbox --cache-path /tmp/swiftpm-cache --config-path /tmp/swiftpm-config --security-path /tmp/swiftpm-security

echo "Packaging $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$EXECUTABLE_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Workaround for swiftlang/swift-build#1887: SwiftPM's swiftbuild stamps minos (15.0) into
# LC_BUILD_VERSION.sdk instead of the real macOS SDK version, which disables macOS 26/27
# Liquid Glass controls (capsule buttons, rounded pickers, glass sidebars) at runtime.
if command -v vtool >/dev/null 2>&1; then
    SDK_VER="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo "26.5")"
    if [[ -n "$SDK_VER" ]]; then
        echo "Stamping LC_BUILD_VERSION sdk=$SDK_VER (enables native macOS 26/27 Liquid Glass controls)..."
        vtool -set-build-version macos 15.0 "$SDK_VER" -replace \
            -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
            "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    fi
fi

# Bundle Apple Icon Composer assets
if [[ -f "$ROOT_DIR/Resources/Icons/AppIcon.icns" ]]; then
    cp "$ROOT_DIR/Resources/Icons/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi
if [[ -f "$ROOT_DIR/Resources/Icons/AppIcon.png" ]]; then
    cp "$ROOT_DIR/Resources/Icons/AppIcon.png" "$APP_BUNDLE/Contents/Resources/AppIcon.png"
fi
if [[ -d "$ROOT_DIR/Resources/Icons/Upkeep.icon" ]]; then
    cp -R "$ROOT_DIR/Resources/Icons/Upkeep.icon" "$APP_BUNDLE/Contents/Resources/Upkeep.icon"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Upkeep</string>
    <key>CFBundleExecutable</key>
    <string>Upkeep</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.Upkeep</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Upkeep</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>5</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>Upkeep uses Device Control / Accessibility to temporarily lock keyboard and pointer input during Cleaning Mode.</string>
    <key>UpkeepUpdateRepo</key>
    <string>manavo-o/Upkeep</string>
</dict>
</plist>
PLIST

plutil -lint "$APP_BUNDLE/Contents/Info.plist"

ensure_signing_identity() {
    local existing
    existing="$(security find-identity -v -p codesigning 2>/dev/null | grep -E "Apple Development|$DEV_CERT_NAME" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
    if [[ -n "$existing" ]]; then
        echo "$existing"
        return 0
    fi

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    cat > "$tmp_dir/cert.cfg" << EOF
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = codesign_ext
prompt = no

[ req_distinguished_name ]
CN = $DEV_CERT_NAME

[ codesign_ext ]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -config "$tmp_dir/cert.cfg" \
        -keyout "$tmp_dir/key.pem" -out "$tmp_dir/cert.pem" >/dev/null 2>&1

    openssl pkcs12 -export -legacy -out "$tmp_dir/cert.p12" \
        -inkey "$tmp_dir/key.pem" -in "$tmp_dir/cert.pem" \
        -passout pass:upkeep >/dev/null 2>&1 || \
    openssl pkcs12 -export -out "$tmp_dir/cert.p12" \
        -inkey "$tmp_dir/key.pem" -in "$tmp_dir/cert.pem" \
        -passout pass:upkeep >/dev/null 2>&1

    local keychain="$HOME/Library/Keychains/login.keychain-db"
    security import "$tmp_dir/cert.p12" -k "$keychain" -P upkeep -T /usr/bin/codesign >/dev/null 2>&1 || true
    security add-trusted-cert -d -r trustRoot -p codeSign -k "$keychain" "$tmp_dir/cert.pem" >/dev/null 2>&1 || true
    rm -rf "$tmp_dir"

    security find-identity -v -p codesigning 2>/dev/null | grep "$DEV_CERT_NAME" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true
}

if [[ -n "${CI:-}" || -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "CI environment detected; using non-interactive ad-hoc signing..."
    codesign --force --deep --sign - "$APP_BUNDLE"
    codesign --verify --deep --strict "$APP_BUNDLE"
else
    SIGN_IDENTITY="$(ensure_signing_identity)"
    if [[ -n "$SIGN_IDENTITY" ]]; then
        echo "Signing $APP_BUNDLE with persistent identity '$SIGN_IDENTITY' (preserves TCC permissions)..."
        codesign --force --deep --sign "$SIGN_IDENTITY" \
            "$APP_BUNDLE"
        codesign --verify --deep --strict "$APP_BUNDLE"
    else
        echo "Warning: Could not create persistent signing cert; falling back to ad-hoc signing."
        codesign --force --deep --sign - "$APP_BUNDLE"
    fi
fi

echo "Done: $APP_BUNDLE"
