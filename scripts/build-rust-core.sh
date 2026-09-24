#!/bin/bash
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
cargo=${HARD_PAUSE_CARGO:-}
if [[ -z "$cargo" ]]; then
    cargo=$(command -v cargo || true)
fi
if [[ -z "$cargo" && -x "$HOME/.cargo/bin/cargo" ]]; then
    cargo="$HOME/.cargo/bin/cargo"
fi
[[ -n "$cargo" ]] || { echo 'Rust cargo is required to build Hard Pause' >&2; exit 1; }

platform=${PLATFORM_NAME:?Xcode PLATFORM_NAME is required}
read -r -a architectures <<< "${ARCHS:?Xcode ARCHS is required}"
[[ ${#architectures[@]} -gt 0 ]] || { echo 'Xcode ARCHS is empty' >&2; exit 1; }

target_for() {
    case "$platform:$1" in
        macosx:arm64) echo aarch64-apple-darwin ;;
        macosx:x86_64) echo x86_64-apple-darwin ;;
        iphoneos:arm64) echo aarch64-apple-ios ;;
        iphonesimulator:arm64) echo aarch64-apple-ios-sim ;;
        iphonesimulator:x86_64) echo x86_64-apple-ios ;;
        *) echo "Unsupported Rust core target: $platform:$1" >&2; return 1 ;;
    esac
}

export CARGO_TARGET_DIR="${HARD_PAUSE_RUST_TARGET_DIR:-$repo_root/build/rust-target}"
output_dir="$repo_root/build/rust-core/$platform"
mkdir -p "$output_dir"
libraries=()
for arch in "${architectures[@]}"; do
    target=$(target_for "$arch")
    "$cargo" build --manifest-path "$repo_root/core/rust/Cargo.toml" \
        --locked --release --target "$target" --quiet
    libraries+=("$CARGO_TARGET_DIR/$target/release/libhard_pause_core.a")
done

temporary=$(/usr/bin/mktemp "$output_dir/libhard_pause_core.XXXXXXXX")
trap 'rm -f "$temporary"' EXIT
if [[ ${#libraries[@]} -eq 1 ]]; then
    /bin/cp "${libraries[0]}" "$temporary"
else
    /usr/bin/lipo -create "${libraries[@]}" -output "$temporary"
fi
/bin/mv -f "$temporary" "$output_dir/libhard_pause_core.a"
trap - EXIT
