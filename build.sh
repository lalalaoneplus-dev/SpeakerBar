#!/bin/zsh
# Build SpeakerBar.app into ~/Applications
set -e
cd "$(dirname "$0")"

APP="$HOME/Applications/SpeakerBar.app"

swiftc -O main.swift -o SpeakerBar \
  -framework AppKit -framework IOBluetooth -framework AVFoundation \
  -framework CoreAudio -framework Carbon -framework ServiceManagement

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp SpeakerBar "$APP/Contents/MacOS/SpeakerBar"
cp Info.plist "$APP/Contents/Info.plist"
# Stable identity: keeps TCC grants (Accessibility/Automation/Bluetooth) valid across rebuilds.
codesign --force -s "SpeakerBar Dev" "$APP" 2>/dev/null || codesign --force -s - "$APP"
echo "Built: $APP"
