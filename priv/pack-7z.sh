#!/bin/sh

if [ "win32" != "$1"] && [ "win64" != "$1" ]; then
	echo "usage: $0 <win32|win64>"
	exit 1
fi

CACHEDIR=./_cache

mkdir -p "$CACHEDIR"

url=${s7ZIP_SFX:-"http://7zsfx.info/files/7zsd_150_2712.7z"}
cache="$CACHEDIR/$(echo "$url" | shasum | awk '{print $1}')"
echo " :: downloading $file"
curl -z "$cache" -o "$cache" "$url"

echo "e5a2a05997553cde6318149951da1e449b0fd277a6e671ac06bfde8572754739 $cache" | sha256sum -c - || {
	echo "ERROR: Checksum mismatch!!!!!" >&2; exit 2; }

cat > "target/$1/setup.bat" <<EOF
set APPDIR=%USERPROFILE%\\Tiny-Mesh\\Tiny-connect
mkdir "%APPDIR%"

mkdir "%APPDIR%\\"
mkdir "%APPDIR%\\erts-7.2.1"
mkdir "%APPDIR%\\lib"
mkdir "%APPDIR%\\releases"

xcopy "erts-7.2.1" "%APPDIR%\\erts-7.2.1" /E /C /Y
xcopy "lib" "%APPDIR%\\lib" /E /C /Y
xcopy "releases" "%APPDIR%\\releases" /E /C /Y
copy "tinyconnect.bat" "%APPDIR%\\tinyconnect.bat"

set SCRIPT="%TEMP%\\tinyconnect-$vsn-%RANDOM%-%RANDOM%-%RANDOM%-%RANDOM%-%RANDOM%.vbs"

echo Set oWS = WScript.CreateObject("WScript.Shell") >> %SCRIPT%
echo link = "%USERPROFILE%\\DESKTOP\\Tinymesh Connect.lnk" >> %SCRIPT%
echo Set oLink = oWS.CreateShortcut(link)  >> %SCRIPT%
echo oLink.TargetPath = "%APPDIR%\\tinyconnect.bat" >> %SCRIPT%
echo oLink.WorkingDirectory = "%APPDIR%" >> %SCRIPT%
echo oLink.Description = "Tiny-connect" >> %SCRIPT%

echo oLink.Save >> %SCRIPT%
echo oWS.Run Chr(34) ^& link ^& Chr(34) >> %SCRIPT%
cscript /nologo %SCRIPT%

del %SCRIPT%

EOF

cat > "target/$1/setup.config" <<EOF
;!@Install@!UTF-8!
Title="Tinymesh Connect"
BeginPrompt="Do you want to install Tiny Connect $vsn from Tiny Mesh AS?"
RunProgram="setup.bat"
;!@InstallEnd@!

EOF


rm -rf "target/$1/setup.7z"
(cd "target/$1"; 7za a "setup.7z" . -m0=BCJ2 -m1=LZMA:d25:fb255 -m2=LZMA:d19 -m3=LZMA:d19 -mb0:1 -mb0s1:2 -mb0s2:3 -mx)

7z e -y "$cache"
cat 7zsd.sfx "target/$1/setup.config" "target/$1/setup.7z" > out/tinyconnect-$1.exe
rm 7zsd.sfx
