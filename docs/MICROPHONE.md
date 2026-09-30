# Microphone

## Choosing an input

Pick an input in **Settings → Dictation → Microphone**. **System default** follows the input selected in macOS and is the default. If a chosen microphone is disconnected, AeriVoice falls back to the system default.

Using AirPods or another Bluetooth headset as the microphone switches it to a lower-quality call profile, which also degrades playback. Choosing the built-in microphone avoids this.

## During a dictation

- **Start:** with sound cues on, the microphone starts while the start sound plays; audio from the first 200 ms is discarded so the cue is not transcribed. With cues off, capture starts immediately.
- **Stop:** capture continues 50 ms after you stop, and the stop sound plays after the microphone closes.
- **Switching inputs:** if the input changes mid-dictation (plugging in a headset, or changing input in System Settings), capture restarts on the new input and the recording continues. If it cannot restart, AeriVoice finishes with the audio already captured and shows "Microphone disconnected".

## Audio processing

Audio is mixed to mono, resampled to 16 kHz, and passed through an 80 Hz high-pass filter that removes rumble such as fans and desk bumps. No noise suppression or automatic gain is applied; speech providers recommend against both.
