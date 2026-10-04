# iDexed

A native SwiftUI port of [Dexed](https://github.com/asb2m10/dexed), the open-source DX7 FM synthesizer, for macOS, iOS and iPadOS.

- `DexedKit/` – Swift package: Dexed's msfa C++ engine (`CDexedEngine`, JUCE-free voice manager with a C API, output filter, Scala tuning) plus Swift patch/SysEx/audio/MIDI code and the AUv3 `DexedAudioUnit`.
- `iDexed/` – the app entry point and assets.
- `Shared/` – the SwiftUI editor, compiled into both the app and the plug-in.
- `iDexedAU/` – the AUv3 extension (instrument `aumu iDxd Kenr`), embedded in the app.
- Run engine/plug-in tests: `cd DexedKit && swift test`. Validate the plug-in: build the app, then `pluginkit -a <…/iDexedAU.appex>` and `auval -v aumu iDxd Kenr`.

## Features
6-operator editor with live operator/EG/output meters, algorithm diagram, 32-voice banks, SysEx import/export, factory banks,
on-screen keyboard with pitch/mod wheels, typing-keyboard and MIDI input, MIDI out (virtual source "iDexed") with
optional local-sound mute, output filter, master tune, Scala `.scl`/`.kbm` microtuning, AUv3 plug-in (macOS, iOS, iPadOS).

Not ported: MTS-ESP, MPE, Dexed's cartridge manager and parameter-mapping dialogs.

## License
GPL v3 (derived from Dexed). msfa engine files are Apache-2.0 (Google / Pascal Gauthier). See `LICENSE`.
