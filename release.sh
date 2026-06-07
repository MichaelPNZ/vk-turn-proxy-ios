#!/usr/bin/env bash
# release.sh — TestFlight + GitHub release pipeline for an already-tagged build.
#
# Usage:
#   ./release.sh <tag> [all|ios|macos]
#
# Default target is `all`, which archives/uploads Apple targets and attaches
# cross-platform release artifacts:
#   - iOS scheme:   VKTurnProxy
#   - macOS scheme: VKTurnProxyMac
#   - Android APK/AAB
#   - Windows runtime zip
#   - Optional Windows setup EXE if prebuilt under build/windows-installer/
#   - Linux server package

set -euo pipefail

TAG="${1:-}"
TARGET_SET="${2:-all}"
if [[ -z "$TAG" || ! "$TARGET_SET" =~ ^(all|ios|macos)$ ]]; then
    cat >&2 <<EOF
Usage: $0 <tag> [all|ios|macos]

Example:
  git tag -a v1.0-build155 -m "..."
  git push origin v1.0-build155
  ./release.sh v1.0-build155 all
EOF
    exit 64
fi

BUILD_NUM="${TAG##*build}"
if [[ ! "$BUILD_NUM" =~ ^[0-9]+$ ]]; then
    echo "ERROR: tag must end with build<N>, got: $TAG" >&2
    exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source "$SCRIPT_DIR/scripts/release-manifest-lib.sh"
source "$SCRIPT_DIR/scripts/release-tag-lib.sh"

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; CYAN=$'\033[36m'; GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
    BOLD=""; CYAN=""; GREEN=""; RED=""; RESET=""
fi
banner() { printf '\n%s==> %s%s\n' "$BOLD$CYAN" "$*" "$RESET"; }
ok()     { printf '%s%s%s\n' "$GREEN" "$*" "$RESET"; }
fail()   { printf '%s%s%s\n' "$RED" "$*" "$RESET" >&2; }

ARTIFACTS=()

add_artifact() {
    local artifact="$1"
    if [[ -z "$artifact" || ! -f "$artifact" ]]; then
        fail "Expected artifact does not exist: ${artifact:-unset}"
        exit 1
    fi
    ARTIFACTS+=("$artifact")
    local size
    size="$(stat -f%z "$artifact")"
    ok "Artifact ready: $artifact ($size bytes)"
}

TARGETS=()
case "$TARGET_SET" in
    all) TARGETS=(ios macos) ;;
    ios) TARGETS=(ios) ;;
    macos) TARGETS=(macos) ;;
esac

require_build_numbers_match_tag() {
    local mismatches
    mismatches="$(awk -v expected="$BUILD_NUM" '
        /^[[:space:]]+CURRENT_PROJECT_VERSION:/ {
            value=$NF
            gsub(/"/, "", value)
            if (value != expected) print NR ":" value
        }
    ' VKTurnProxy/project.yml)"
    if [[ -n "$mismatches" ]]; then
        fail "project.yml contains CURRENT_PROJECT_VERSION values that do not match tag build $BUILD_NUM:"
        echo "$mismatches" >&2
        exit 1
    fi
}

make_export_plist() {
    local destination="$1"
    local path="$2"
    cat > "$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>teamID</key>
	<string>CDMQ33VFQC</string>
	<key>uploadBitcode</key>
	<false/>
	<key>uploadSymbols</key>
	<true/>
	<key>destination</key>
	<string>$destination</string>
</dict>
</plist>
EOF
}

archive_target() {
    local platform="$1"
    local scheme="$2"
    local archive_path="$3"

    banner "Archiving $platform Release configuration"
    rm -rf "$archive_path"
    xcodebuild \
        -project VKTurnProxy/VKTurnProxy.xcodeproj \
        -scheme "$scheme" \
        -destination "generic/platform=$platform" \
        -configuration Release \
        -archivePath "$archive_path" \
        archive \
        -allowProvisioningUpdates \
        2>&1 | tail -12
    ok "$platform archive created at $archive_path"
}

upload_testflight() {
    local label="$1"
    local archive_path="$2"
    local export_dir="$3"

    banner "Uploading $label to TestFlight"
    local export_plist
    export_plist="$(mktemp -t ExportOptions-upload.XXXXXX.plist)"
    make_export_plist "upload" "$export_plist"
    rm -rf "$export_dir"
    xcodebuild -exportArchive \
        -archivePath "$archive_path" \
        -exportPath "$export_dir" \
        -exportOptionsPlist "$export_plist" \
        -authenticationKeyPath "$APPSTORE_KEY_PATH" \
        -authenticationKeyID "$APPSTORE_KEY_ID" \
        -authenticationKeyIssuerID "$APPSTORE_ISSUER_ID" \
        -allowProvisioningUpdates \
        2>&1 | tail -12
    rm -f "$export_plist"
    ok "$label TestFlight upload submitted."
}

export_local_artifact() {
    local label="$1"
    local archive_path="$2"
    local export_dir="$3"
    local fallback_zip_name="$4"

    banner "Exporting local $label artifact"
    local export_plist
    export_plist="$(mktemp -t ExportOptions-export.XXXXXX.plist)"
    make_export_plist "export" "$export_plist"
    rm -rf "$export_dir"
    xcodebuild -exportArchive \
        -archivePath "$archive_path" \
        -exportPath "$export_dir" \
        -exportOptionsPlist "$export_plist" \
        -allowProvisioningUpdates \
        2>&1 | tail -8
    rm -f "$export_plist"

    local artifact
    artifact="$(find "$export_dir" -maxdepth 2 -type f \( -name '*.ipa' -o -name '*.pkg' -o -name '*.zip' \) | head -1 || true)"
    if [[ -z "$artifact" ]]; then
        local app_dir
        app_dir="$(find "$export_dir" -maxdepth 2 -type d -name '*.app' | head -1 || true)"
        if [[ -n "$app_dir" ]]; then
            artifact="$export_dir/$fallback_zip_name"
            ( cd "$(dirname "$app_dir")" && /usr/bin/ditto -c -k --keepParent "$(basename "$app_dir")" "$artifact" )
        fi
    fi
    if [[ -z "$artifact" || ! -f "$artifact" ]]; then
        fail "Expected local $label artifact under $export_dir but none was found."
        exit 1
    fi
    add_artifact "$artifact"
}

build_cross_platform_artifacts() {
    banner "Building cross-platform release artifacts"
    local package_output
    package_output="$(ANDROID_HOME="${ANDROID_HOME:-"$HOME/Library/Android/sdk"}" scripts/package-release-artifacts.sh "$TAG")"
    printf '%s\n' "$package_output"
    while IFS= read -r artifact; do
        add_artifact "$artifact"
    done < <(awk -F= '/^artifact=/{print $2}' <<<"$package_output")
}

write_checksum_manifest() {
    banner "Writing release checksum manifest"
    local dir="build/release"
    local manifest="$dir/$TAG-sha256.txt"
    mkdir -p "$dir"
    : > "$manifest"
    for artifact in "${ARTIFACTS[@]}"; do
        release_manifest_write_entry "$SCRIPT_DIR" "$artifact" >> "$manifest"
    done
    add_artifact "$manifest"
}

banner "Verifying environment for $TAG (build $BUILD_NUM, target=$TARGET_SET)"

if [[ -n "$(git status --porcelain)" ]]; then
    fail "Working tree is dirty. Commit or stash before releasing."
    git status --short
    exit 1
fi

tag_detail=""
if ! tag_detail="$(release_tag_alignment_detail "$SCRIPT_DIR" "$TAG")"; then
    fail "$tag_detail"
    if [[ "$tag_detail" == tag_missing=* ]]; then
        fail "Create it first: git tag -a $TAG -m '...' && git push origin $TAG"
    else
        fail "Create a new build tag on the current commit instead of uploading an older tag."
    fi
    exit 1
fi
ok "$tag_detail"

require_build_numbers_match_tag

ENV_FILE="VKTurnProxy/AppStoreConnect.env"
if [[ ! -f "$ENV_FILE" ]]; then
    fail "$ENV_FILE not found — App Store Connect API credentials missing."
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
for var in APPSTORE_KEY_ID APPSTORE_ISSUER_ID APPSTORE_KEY_PATH; do
    if [[ -z "${!var:-}" ]]; then
        fail "$ENV_FILE missing required variable: $var"
        exit 1
    fi
done
if [[ ! -f "$APPSTORE_KEY_PATH" ]]; then
    fail "APPSTORE_KEY_PATH=$APPSTORE_KEY_PATH does not exist on disk."
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    fail "gh CLI not installed — needed for GitHub Release upload."
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    fail "gh CLI not authenticated. Run: gh auth login"
    exit 1
fi

ok "All checks passed."

if [[ "$TARGET_SET" == "all" ]]; then
    build_cross_platform_artifacts
fi

banner "Building Go xcframework"
( cd WireGuardBridge && make xcframework )
ok "xcframework built."

IOS_ARCHIVE="VKTurnProxy/build_output/VKTurnProxy-iOS.xcarchive"
MAC_ARCHIVE="VKTurnProxy/build_output/VKTurnProxy-macOS.xcarchive"

for target in "${TARGETS[@]}"; do
    case "$target" in
        ios)
            archive_target "iOS" "VKTurnProxy" "$IOS_ARCHIVE"
            upload_testflight "iOS" "$IOS_ARCHIVE" "VKTurnProxy/build_output/Export-iOS-tf$BUILD_NUM"
            export_local_artifact "iOS" "$IOS_ARCHIVE" "VKTurnProxy/build_output/Export-iOS-build$BUILD_NUM" "VKTurnProxy-iOS.app.zip"
            ;;
        macos)
            archive_target "macOS" "VKTurnProxyMac" "$MAC_ARCHIVE"
            upload_testflight "macOS" "$MAC_ARCHIVE" "VKTurnProxy/build_output/Export-macOS-tf$BUILD_NUM"
            export_local_artifact "macOS" "$MAC_ARCHIVE" "VKTurnProxy/build_output/Export-macOS-build$BUILD_NUM" "VKTurnProxyMac.app.zip"
            ;;
    esac
done

write_checksum_manifest

banner "Attaching artifacts to GitHub Release $TAG"
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release $TAG already exists; uploading artifacts with --clobber"
    gh release upload "$TAG" "${ARTIFACTS[@]}" --clobber
else
    TAG_SUBJECT="$(git tag -l --format='%(contents:subject)' "$TAG")"
    TAG_BODY="$(git tag -l --format='%(contents:body)' "$TAG")"
    [[ -n "$TAG_SUBJECT" ]] || TAG_SUBJECT="$TAG"
    [[ -n "$TAG_BODY" ]] || TAG_BODY="Build $BUILD_NUM artifacts."
    gh release create "$TAG" "${ARTIFACTS[@]}" \
        --title "$TAG_SUBJECT" \
        --notes "$TAG_BODY"
fi
ok "GitHub Release ready."

RELEASE_URL="$(gh release view "$TAG" --json url -q .url 2>/dev/null || echo "")"
banner "Release pipeline complete"
cat <<EOF
  Tag:        $TAG (build $BUILD_NUM)
  Targets:    ${TARGETS[*]}
  Artifacts:
$(printf '    - %s\n' "${ARTIFACTS[@]}")
  TestFlight: uploaded — check App Store Connect for processing status
  GitHub:     $RELEASE_URL
EOF
