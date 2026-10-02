# Microphone

## Choosing an input

Pick an input in **Settings → Dictation → Microphone**. **System default** follows the input selected in macOS and is the default. If a chosen microphone is disconnected, AeriVoice falls back to the system default.

Using AirPods or another Bluetooth headset as the microphone switches it to a lower-quality call profile, which also degrades playback. Choosing the built-in microphone avoids this.

## During a dictation

- **Start:** with sound cues on, the microphone starts while the start sound plays; audio from the first 200 ms is discarded so the cue is not transcribed. With cues off and microphone access already granted, the microphone starts the moment you press the shortcut, while AeriVoice checks your provider keys, Accessibility access and the local model. If a check fails, the microphone stops, its audio is discarded without being sent, and the problem is shown. A Bluetooth headset's microphone starts only after the checks pass, so a dictation that can't run never switches the headset to its call profile.
- **Between dictations:** after a dictation ends or is cancelled, the next one's microphone engine is prepared in advance without opening the microphone. Sleep, screen lock and quitting release it; waking or unlocking prepares it again.
- **Stop:** the microphone keeps recording until its current audio block ends (at most about 0.1 s after you release), keeps only what you said before releasing, then closes. The stop sound plays after it closes, so it is never transcribed.
- **Switching inputs:** if the input changes mid-dictation (plugging in a headset, or changing input in System Settings), capture restarts on the new input and the recording continues. If it cannot restart, AeriVoice finishes with the audio already captured and shows "Microphone disconnected".

## Audio processing

Audio is mixed to mono, resampled to 16 kHz, and passed through an 80 Hz high-pass filter that removes rumble such as fans and desk bumps. No noise suppression or automatic gain is applied; speech providers recommend against both.
