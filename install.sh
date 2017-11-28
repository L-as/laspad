#/usr/bin/env bash

set -x


which dub && LD_RUN_PATH='$ORIGIN/ns2:$ORIGIN' dub build -b release --compiler=ldc --force || test -e laspad || {
	echo >&2 "Can not build executable and no executable presupplied!"
	return 1
}

INSTALL_DIR="$(realpath -s ${INSTALL_DIR:=/usr/local})"
mkdir -p "$INSTALL_DIR/lib/laspad"
cp laspad          "$INSTALL_DIR/lib/laspad/"
cp steam_appid.txt "$INSTALL_DIR/lib/laspad/"
ln -sf "$INSTALL_DIR/lib/laspad/laspad" "$INSTALL_DIR/bin/laspad"
ln -sf "$HOME/.local/share/Steam/steamapps/common/Natural Selection 2/x64" "$INSTALL_DIR/lib/laspad/ns2"

sed -En 's:BaseInstallFolder_.*?"\s*"(.*?)":\1:p' < ~/.local/share/Steam/config/config.vdf |
	while read dir
	do
		# I have no idea why the " is included
		dir="${dir:1}/steamapps/common/Natural Selection 2"
		test -e "$dir" && {
			ln -sf "$dir/x64" "$INSTALL_DIR/lib/laspad/ns2"
			exit 0
		}
	done
