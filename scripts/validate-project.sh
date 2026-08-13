#!/bin/bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"

fail() {
    echo "error: $*" >&2
    exit 1
}

require_file() {
    [ -f "$PROJECT_ROOT/$1" ] || fail "missing required file: $1"
}

require_file "Jarvis.xcodeproj/project.pbxproj"
require_file "Jarvis.xcodeproj/xcshareddata/xcschemes/Jarvis.xcscheme"
require_file "Jarvis/Resources/Info.plist"
require_file "Jarvis/Resources/Jarvis.entitlements"
require_file "scripts/generate-xcode-project.js"
require_file "docs/ARCHITECTURE.md"
require_file "docs/SMART_HOME.md"
require_file "docs/DEVELOPMENT.md"

PBXPROJ="$PROJECT_ROOT/Jarvis.xcodeproj/project.pbxproj"
INFO_PLIST="$PROJECT_ROOT/Jarvis/Resources/Info.plist"
ENTITLEMENTS="$PROJECT_ROOT/Jarvis/Resources/Jarvis.entitlements"
SCHEME="$PROJECT_ROOT/Jarvis.xcodeproj/xcshareddata/xcschemes/Jarvis.xcscheme"
GENERATOR="$PROJECT_ROOT/scripts/generate-xcode-project.js"

deployment_targets="$(sed -n 's/.*MACOSX_DEPLOYMENT_TARGET = \([^;]*\);.*/\1/p' "$PBXPROJ")"
[ -n "$deployment_targets" ] || fail "the Xcode project has no macOS deployment target"

unexpected_targets="$(printf '%s\n' "$deployment_targets" | grep -v '^11\.0$' || true)"
[ -z "$unexpected_targets" ] || fail "all Xcode deployment targets must remain 11.0 (found: $unexpected_targets)"

generator_targets="$(sed -n "s/.*MACOSX_DEPLOYMENT_TARGET: '\([^']*\)'.*/\1/p" "$GENERATOR")"
[ -n "$generator_targets" ] || fail "the Xcode project generator has no macOS deployment target"
unexpected_generator_targets="$(printf '%s\n' "$generator_targets" | grep -v '^11\.0$' || true)"
[ -z "$unexpected_generator_targets" ] || fail "the generator must preserve deployment target 11.0 (found: $unexpected_generator_targets)"

plist_minimum="$(sed -n '/<key>LSMinimumSystemVersion<\/key>/{n;s/.*<string>\([^<]*\)<\/string>.*/\1/p;q;}' "$INFO_PLIST")"
[ "$plist_minimum" = "11.0" ] || fail "LSMinimumSystemVersion must remain 11.0 (found: ${plist_minimum:-missing})"
grep -q 'PRODUCT_BUNDLE_IDENTIFIER = com\.nandan\.jarvis;' "$PBXPROJ" || fail "Jarvis bundle identifier is not com.nandan.jarvis"
grep -q 'BlueprintName="Jarvis"' "$SCHEME" || fail "the shared scheme does not build Jarvis"

for plist_key in CFBundleDisplayName CFBundleExecutable NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription; do
    grep -q "<key>$plist_key</key>" "$INFO_PLIST" || fail "Info.plist is missing $plist_key"
done

for entitlement in com.apple.security.device.audio-input com.apple.security.network.client; do
    grep -q "<key>$entitlement</key>" "$ENTITLEMENTS" || fail "Jarvis.entitlements is missing $entitlement"
done

while IFS= read -r source_file; do
    case "$source_file" in
        "$PROJECT_ROOT/Jarvis/"*) project_path="${source_file#"$PROJECT_ROOT/Jarvis/"}" ;;
        "$PROJECT_ROOT/JarvisTests/"*) project_path="${source_file#"$PROJECT_ROOT/JarvisTests/"}" ;;
        *) fail "unexpected Swift source path: $source_file" ;;
    esac
    grep -Fq "path = \"$project_path\";" "$PBXPROJ" || fail "Xcode project is missing $project_path; run node scripts/generate-xcode-project.js"
done < <(find "$PROJECT_ROOT/Jarvis" "$PROJECT_ROOT/JarvisTests" -type f -name '*.swift' | sort)

if grep -R -n --include='*.swift' --include='*.pbxproj' 'MenuBarExtra' "$PROJECT_ROOT/Jarvis" "$PROJECT_ROOT/Jarvis.xcodeproj" >/dev/null 2>&1; then
    fail "MenuBarExtra is unavailable on macOS 11; use NSStatusItem"
fi

if grep -n 'EXCLUDED_ARCHS' "$PBXPROJ" >/dev/null 2>&1; then
    fail "the project excludes an architecture; Jarvis must compile for x86_64 and arm64"
fi

if command -v node >/dev/null 2>&1; then
    node --check "$GENERATOR"
fi

if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$INFO_PLIST" >/dev/null
    plutil -lint "$ENTITLEMENTS" >/dev/null
fi

if command -v git >/dev/null 2>&1 && git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    tracked_forbidden="$(
        git -C "$PROJECT_ROOT" ls-files | \
        grep -E '(^|/)(DerivedData|build|xcuserdata)(/|$)|\.xcuserstate$|(^|/)\.env($|\.)|\.(m4a|wav|caf)$' | \
        grep -vE '(^|/)\.env\.example$' || true
    )"
    [ -z "$tracked_forbidden" ] || fail "forbidden generated, secret, audio, or user-specific files are tracked: $tracked_forbidden"

    possible_keys="$(
        git -C "$PROJECT_ROOT" grep -n -E "AIza[0-9A-Za-z_-]{30,}|(api[_ -]?key|access[_ -]?token)[[:space:]]*[:=][[:space:]]*['\"][A-Za-z0-9._-]{20,}['\"]" -- Jarvis JarvisTests 2>/dev/null || true
    )"
    [ -z "$possible_keys" ] || fail "a source or test file appears to contain a credential: $possible_keys"
fi

echo "Jarvis project validation passed (macOS 11.0, com.nandan.jarvis, shared Jarvis scheme)."
