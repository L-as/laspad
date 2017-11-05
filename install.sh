#/usr/bin/env bash

set -x

dub build

INSTALL_DIR="$(realpath -s ${INSTALL_DIR:=/usr/local})"
mkdir -p "$INSTALL_DIR/lib/laspad"
cp laspad          "$INSTALL_DIR/lib/laspad/"
cp steam_appid.txt "$INSTALL_DIR/lib/laspad/"
ln -s "$INSTALL_DIR/lib/laspad/laspad" "$INSTALL_DIR/bin/laspad"
