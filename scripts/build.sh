#!/bin/zsh
# Baut Kelter.app (Debug) nach build/Kelter.app.
# Aufruf: scripts/build.sh            → bauen
#         scripts/build.sh --open     → bauen und starten
set -euo pipefail
cd "${0:A:h}/.."

xcodebuild \
  -project Kelter.xcodeproj \
  -scheme Kelter \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  -quiet \
  build

rm -rf build/Kelter.app
cp -R build/DerivedData/Build/Products/Debug/Kelter.app build/Kelter.app
echo "Fertig: $(pwd)/build/Kelter.app"

if [[ "${1:-}" == "--open" ]]; then
  open build/Kelter.app
fi
