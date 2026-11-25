# Use Outputly

## Record a microphone and system playback

Both modes record the selected physical microphone together with system playback from all other apps that macOS makes available to Outputly.

1. Open Outputly in the menu bar and select **System Default** or a physical device under **Microphone**.
   Connect a pinned device before you start recording.
2. Choose **Send after Stop** or **Route Live** under **Mode**, then select **Start Recording**.
   The menu-bar icon changes during recording.
3. Choose **Stop Recording** to save a stereo MP3 in `~/Music/Outputly`.
   Choose **Reveal Last Recording** to locate it in Finder.
   If export fails, reveal the retained CAF source and check FFmpeg and available disk space.

Allow microphone and system audio access when macOS prompts for them.
If you previously denied access, check **Microphone** and **Screen & System Audio Recording** under **System Settings > Privacy & Security**. [Apple's system audio permissions guide](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac)

## Send a transcript after recording

1. Install and sign in to the Codex or Claude Code CLI before selecting it in Outputly.
2. Choose **Send after Stop** and select a destination.
3. Start and stop the recording, then review the on-device Apple Speech transcript when it finishes.
   If recognition fails, choose **Prepare Transcript…** to retry.
   Choose **Preview Transcript…** to reopen the transcript.
4. Choose **Send Transcript to Codex** or **Send Transcript to Claude Code** to start that CLI with the transcript.

Apple Speech can download local recognition assets for your language on first use.
The selected CLI uses its own sign-in and managed policy when you send.

## Route audio to a voice client

1. Install VB-Cable.
   Check that it appears as an audio device in macOS.
2. Select **Route Live** and pin your physical microphone under **Microphone** in Outputly.
3. Select VB-Cable in the voice client's input picker or under **System Settings > Sound > Input** if the client follows the system input.
4. Choose **Start Recording** in Outputly, then start dictation in the client.
5. Stop dictation in the client and choose **Stop Recording** in Outputly to save the MP3.

Use **Live Routing Instructions…** to see the steps for the selected destination.
From **Start Recording** to **Stop Recording**, Outputly sends the same microphone and system playback mix to any app reading VB-Cable.
You control the macOS Sound settings and start dictation in the receiving app.

> [!note]
> Use dictation and turn off spoken replies if the client offers that setting.
> The system audio tap can feed the client's spoken replies back into its input even when you wear headphones.

## Tool locations

Outputly looks for `ffmpeg`, `codex`, and `claude` in the process path and standard local install locations.
For a custom installation, set `OUTPUTLY_FFMPEG`, `OUTPUTLY_CODEX`, or `OUTPUTLY_CLAUDE` to the absolute path of the executable.
Set the variable in the environment that starts Outputly.
Use an FFmpeg build that includes the [libmp3lame encoder](https://ffmpeg.org/ffmpeg-codecs.html#libmp3lame).

## Local data

Outputly writes audio on your Mac and keeps the latest transcript in memory.
Keep saved recordings, recovered source audio, and any copied transcripts outside the repository.
