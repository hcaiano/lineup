#!/usr/bin/env bash
# Build a disposable, document-free app for real Zones launch/drag verification.
# Kept outside SwiftPM so lineup-tests remains usable without AppKit app launches.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROBE_DIR="$(mktemp -d /tmp/lineup-placement-probe.XXXXXX)"
PROBE_APP="${PROBE_DIR}/Placement Probe.app"
mkdir -p "${PROBE_APP}/Contents/MacOS"
swiftc -parse-as-library "${SCRIPT_DIR}/PlacementProbe.swift" -o "${PROBE_APP}/Contents/MacOS/placement-probe"
cat > "${PROBE_APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.caiano.lineup.placement-probe</string>
<key>CFBundleName</key><string>Placement Probe</string>
<key>CFBundleExecutable</key><string>placement-probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "${PROBE_APP}" >/dev/null 2>&1
printf '%s\n' "${PROBE_APP}"

if [[ "${1:-}" == "--check-discovery" ]]; then
    REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
    swiftc -emit-library -emit-module -module-name ZonesCore \
        -emit-module-path "${PROBE_DIR}/ZonesCore.swiftmodule" \
        "${REPO_DIR}"/Sources/ZonesCore/*.swift -o "${PROBE_DIR}/libZonesCore.dylib"
    swiftc -parse-as-library -D DISCOVERY_CHECK -I "${PROBE_DIR}" -L "${PROBE_DIR}" -lZonesCore \
        -Xlinker -rpath -Xlinker "${PROBE_DIR}" \
        "${SCRIPT_DIR}/PlacementProbe.swift" \
        "${REPO_DIR}/Sources/lineup/Tools/Zones/AppLaunchPlacementController.swift" \
        -o "${PROBE_DIR}/discovery-check"
    "${PROBE_DIR}/discovery-check" "${PROBE_APP}"
    "${PROBE_DIR}/discovery-check" "${PROBE_APP}" --cancel
    "${PROBE_DIR}/discovery-check" "${PROBE_APP}" --unknown-window
fi
