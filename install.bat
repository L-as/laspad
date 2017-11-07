@echo off

copy "C:\Program Files (x86)\Steam\steamapps\common\Natural Selection 2\x64\steam_api64.dll" || echo Please copy your steam_api64.dll file from your steam installation hitherto manually!
setx path "%PATH%;%cd%"
echo laspad has been successfully installed into the current folder!
echo Please remove this folder from your PATH environment variable to properly uninstall.

pause
