#!/bin/zsh
# Baut Kelter (Release) und legt es nach /Applications (ohne Schreibrecht dort: ~/Applications),
# dann startet es die App.
#
# Deine Daten – Engines, Bottles, Spiele, Logs – liegen unter ~/Library/Application Support/Kelter
# und bleiben bei jeder Installation oder jedem Update erhalten. Nichts muss neu geladen werden.
# Laufende Windows-Programme (z. B. Steam) laufen weiter, Kelter erkennt sie nach dem Start wieder.
set -euo pipefail
cd "${0:A:h}/.."

echo "Baue Kelter (Release) …"
xcodebuild \
  -project Kelter.xcodeproj \
  -scheme Kelter \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  -quiet \
  build
app=build/DerivedData/Build/Products/Release/Kelter.app

target=/Applications
if [[ ! -w $target ]]; then
  target=~/Applications
  mkdir -p "$target"
fi

if pgrep -x Kelter >/dev/null; then
  osascript -e 'tell application id "local.kelter.Kelter" to quit' 2>/dev/null || true
  for _ in {1..20}; do pgrep -x Kelter >/dev/null || break; sleep 0.25; done
  pkill -x Kelter 2>/dev/null || true
fi

rm -rf "$target/Kelter.app"
ditto "$app" "$target/Kelter.app"
open "$target/Kelter.app"
echo "Installiert: $target/Kelter.app"
