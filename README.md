# Outputly

<img src="Packaging/Outputly.svg" alt="Outputly logo" width="96">

Outputly is a macOS menu-bar app that records a selected microphone and system playback to a stereo MP3.
Send a transcript to Codex or Claude Code after recording, or route the audio mix to VB-Cable during recording.

[TOC]

## Features

1. Use the **system default microphone** or select a physical device such as a MOTU M2.
2. Save the microphone and system playback mix as a local **stereo MP3** in either mode.
3. Choose **Send after Stop** to prepare a local transcript for review before you send it to the selected CLI.
4. Choose **Route Live** to deliver the audio mix to apps that read VB-Cable.

## Structure

```sh
.
├── Sources/OutputlyApp/   # Menu bar and recording controls
├── Sources/OutputlyCore/  # Capture, export, speech recognition, and delivery
├── Tests/                 # Core and menu behavior tests
├── Packaging/             # App bundle metadata
├── scripts/               # App bundle build
└── docs/                  # Usage and design
```

## Getting Started

Use macOS 26 or later, Swift 6.2 or later, and FFmpeg with the `libmp3lame` encoder.
See the [Build and install guide](docs/build.md) for prerequisite checks and installation in Applications.

1. Authenticate Git with a GitHub account that has access to the private repository.
   Clone the `feat/outputly` branch. [GitHub HTTPS authentication](https://docs.github.com/en/get-started/git-basics/about-remote-repositories#cloning-with-https-urls)

    ```sh
    git clone --branch feat/outputly https://github.com/ydixken/outputly.git
    cd outputly
    ```

2. Build the signed app bundle.

    ```sh
    make app
    ```

3. Open Outputly from the build directory.

    ```sh
    open .build/Outputly.app
    ```

4. Select the microphone and mode in the menu bar.
   Choose **Start Recording**.
   Grant microphone and system audio access when macOS prompts you.
   Choose **Stop Recording** after a short recording.

## Commands

- `make app` builds and signs `.build/Outputly.app`.
- `make lint` checks the shell script, bundle metadata, and Swift compiler diagnostics.
- `make test` runs the Swift tests.

## Usage

See the [Usage guide](docs/usage.md).

## Build and install

See the [Build and install guide](docs/build.md).

## Design

See the [Design](docs/superpowers/specs/2026-11-25-outputly-design.md).
