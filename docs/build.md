# Build and install Outputly

## Check prerequisites

Use a Mac with macOS 26 or later.
Use Apple developer tools with Swift 6.2 or later and a macOS 26 or newer SDK. [Xcode 26 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)
Install FFmpeg with the `libmp3lame` encoder. [FFmpeg Homebrew formula](https://formulae.brew.sh/formula/ffmpeg)

1. Check the installed macOS, Swift, and SDK versions.

    ```sh
    sw_vers -productVersion
    swift --version
    xcrun --sdk macosx --show-sdk-version
    ```

2. Check that FFmpeg lists the MP3 encoder.

    ```sh
    ffmpeg -hide_banner -encoders | grep -w libmp3lame
    ```

## Build the app

1. Clone the private repository with an authorized GitHub account. [GitHub HTTPS authentication](https://docs.github.com/en/get-started/git-basics/about-remote-repositories#cloning-with-https-urls)

    ```sh
    git clone --branch feat/outputly https://github.com/ydixken/outputly.git
    cd outputly
    ```

2. Build the app from the checkout.

    ```sh
    make app
    ```

3. Check the ad hoc signature on the local bundle.

    ```sh
    codesign --verify --strict .build/Outputly.app
    ```

## Install the app

1. Locate the built bundle in Finder.

    ```sh
    open -R .build/Outputly.app
    ```

2. Open Applications in Finder.

    ```sh
    open /Applications
    ```

3. For a fresh installation, copy `Outputly.app` from the build directory to Applications in Finder.
   For a replacement, quit the existing copy before you copy the new bundle.
   Choose **Replace** when Finder prompts you.
4. Open the installed app.

    ```sh
    open /Applications/Outputly.app
    ```

Outputly appears in the menu bar.
For microphone selection and recording modes, see the [Usage guide](usage.md).
