#!/bin/bash
# Crea el instalador DMG (app universal: Intel y Apple silicon).
#   Tools/make-dmg.sh   ->   build/PegasusExplorer-<versión>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="PegasusExplorer"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG="build/$APP_NAME-$VERSION.dmg"
STAGE="build/dmg"

./build.sh --universal

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "build/$APP_NAME.app" "$STAGE/"
ln -s /Applications "$STAGE/Aplicaciones"
cat > "$STAGE/Léeme - primera vez.txt" <<'TXT'
PegasusExplorer

1. Arrastra PegasusExplorer a la carpeta Aplicaciones.
2. Ábrelo desde Aplicaciones.

La primera vez, macOS dirá que no puede verificar al desarrollador
(la app es gratuita y no está notarizada por Apple). Para abrirla:

  Configuración del Sistema > Privacidad y seguridad >
  baja hasta el aviso de PegasusExplorer > «Abrir de todos modos».

Solo hay que hacerlo una vez.

Código fuente: https://github.com/Jonywaper/PegasusExplorer
TXT

hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
shasum -a 256 "$DMG"
echo "Listo: $DMG"
