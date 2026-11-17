# BoomHype Tech - Tempo Reverb MK I

VST3 reverb with 8 reverb types (Hall, Plate, Room, Space, Spring, Shimmer, Cathedral, Lo-Fi),
a tempo helper (host-synced pre-delay and reverb time), 5-band spectral EQ with live analyser,
ducking (input or sidechain) and needle GR / output VU meters. The window is resizable.

## Get the plugin
* **Windows / macOS / Linux:** push this repo to GitHub, open the **Actions** tab, open the newest
  "Build VST3" run and download the artifact for your system.
* **Linux only, inside Codespaces:** run `bash boomhype_tempo_reverb_mk1.sh build`, then right-click the
  generated `.zip` in the file explorer and choose **Download**.

## Install
* Windows: copy `Tempo Reverb MK I.vst3` to `C:\Program Files\Common Files\VST3\`
* macOS: copy to `~/Library/Audio/Plug-Ins/VST3/` (if blocked: `xattr -cr "Tempo Reverb MK I.vst3"`)
* Linux: copy to `~/.vst3/`

JUCE is used under its AGPLv3/commercial licence. Selling or closed-source distribution needs a JUCE commercial licence.
