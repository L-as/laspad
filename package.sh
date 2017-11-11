#/usr/bin/env bash

tar -cf laspad.tar laspad steam_appid.txt install.sh
gzip -f9 laspad.tar
