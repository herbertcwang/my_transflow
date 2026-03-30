# 027 Fix Speech Runtime State - Changelog

## Summary

Fix two runtime state issues: stale Apple Speech model readiness after idle, and realtime diarization appearing unavailable on Home until Settings is opened once.

## Changes

### Speech Model Truth Source

- `SpeechModelManager` now treats `SpeechTranscriber.installedLocales` as the source of truth for installed speech locales
- `AssetInventory.status(forModules:)` still participates in `.downloading` / `.unsupported` handling and stale-cache recovery
- Added divergence logging when AssetInventory says `installed` but the resolved locale is absent from `installedLocales`
- `refreshAllStatuses()` now evaluates all locales against a single installed-locale snapshot for a more consistent refresh pass

### Runtime Recovery

- Added a small recovery helper that refreshes speech model state after runtime transcription errors
- Live transcription and video transcription now trigger that refresh path when `SpeechEngine` emits `.error`

### Realtime Diarization Availability

- `DiarizationModelManager` now checks local model files during singleton initialization
- Added foreground re-check on `NSApplication.didBecomeActiveNotification`
- Home initialization and live-session startup both re-check diarization model status before deciding whether realtime diarization can run
- `ControlBarView` now explicitly observes `DiarizationModelManager.shared`, so button enabled/disabled state updates without visiting Settings first
