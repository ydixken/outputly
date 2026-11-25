# Outputly design

Outputly is a native macOS menu-bar app for recording a selected microphone and system playback and using the mix with Codex or Claude Code.
The app displays Start Recording or Stop Recording and changes its menu-bar indicator while recording.

## Capture and export

Choose System Default to follow the system input between sessions, or pin a physical device such as MOTU M2.
Both modes mix that physical microphone with system playback from all other apps that macOS makes available to the audio tap.
Record stereo PCM in a private CAF file and export a local stereo MP3 to `~/Music/Outputly` through FFmpeg after stopping either recording mode.
Show capture and export errors and retain recoverable audio when exporting fails.

## Delivery

Choose Send after Stop or Route Live under Mode, then choose Codex or Claude Code under Destination.
In Send after Stop mode, start local Apple Speech recognition after exporting and preview the transcript when it is ready.
Choose Send Transcript to Codex or Send Transcript to Claude Code to start that CLI with the transcript.
In Route Live mode, send the same microphone and system playback mix to any app reading VB-Cable from Start Recording to Stop Recording.
Pin the physical microphone in Outputly before selecting VB-Cable as the voice client's input, then control dictation manually.
Leave macOS input and output settings under the user's control.

## Architecture

SwiftPM builds `OutputlyCore` and `OutputlyApp` for macOS 26 or later, with a separate test target for each.
The core owns audio devices, capture, export, transcription, and CLI delivery.
The app owns the menu, recording state presentation, and user commands.
An ad hoc signed app bundle supplies macOS privacy usage descriptions and a stable bundle identifier.
Keep credentials, recorded audio, and transcripts out of version control and logs.
