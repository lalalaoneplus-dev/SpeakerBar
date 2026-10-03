# SpeakerBar

A macOS menu bar app that keeps a Bluetooth speaker connected, switches audio output with a global hotkey, and adds a system-wide equalizer.

- **Managed speaker:** pick a paired Bluetooth speaker from the menu; a watchdog reconnects it when it drops and after wake.
- **Global hotkey:** ⌥⌘B toggles between the speaker and the Mac's built-in speakers.
- **Keep Speaker Awake:** an inaudible 25 Hz pulse every five minutes prevents the speaker's auto-standby.
- **System-wide equalizer:** a 10-band biquad filter bank (RBJ audio-EQ cookbook) on a Core Audio process tap (macOS 14.2+), with factory presets and an editor window.
- **Start at Login** and **Reconnect Now** in the menu.
- One Swift file on AppKit, IOBluetooth, CoreAudio and AVFoundation, with zero third-party dependencies.

## Build

```sh
./build.sh
```

Builds `SpeakerBar.app` into `~/Applications`. Activity is logged to `~/Library/Logs/SpeakerBar.log`.
