#/usr/bin/env bash

set -x


which dub && dub build -b release --compiler=ldc || test -e laspad || {
	echo >&2 "Can not build executable and no executable presupplied!"
	return 1
}

INSTALL_DIR="$(realpath -s ${INSTALL_DIR:=/usr/local})"
mkdir -p "$INSTALL_DIR/lib/laspad"
cp laspad          "$INSTALL_DIR/lib/laspad/"
cp steam_appid.txt "$INSTALL_DIR/lib/laspad/"
ln -sf "$INSTALL_DIR/lib/laspad/laspad" "$INSTALL_DIR/bin/laspad"
