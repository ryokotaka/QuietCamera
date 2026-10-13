<p align="center">
  <img src="QuietCamera/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="96" height="96" alt="Quiet Camera app icon">
</p>

<h1 align="center">Quiet Camera</h1>

<p align="center">
  An iPhone camera app that tries to keep the shutter quiet<br>
  while requesting the largest photo dimensions the camera offers.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-18.0%2B-1d2b31?style=flat-square" alt="iOS 18.0+">
  <img src="https://img.shields.io/badge/dependencies-none-1d2b31?style=flat-square" alt="No external dependencies">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3f6f60?style=flat-square" alt="MIT License"></a>
</p>

<p align="center">
  <strong>English</strong> · <a href="README.ja.md">日本語</a>
</p>

Quiet Camera is a personal project that started in a classroom. It shows a large 4:3 preview, tries to suppress the shutter sound automatically on every shot, and requests the largest photo dimensions the selected camera offers before saving still photos to the Photos app. It's shared as source code. To use it, you build it in Xcode and install it on your own iPhone.

> [!IMPORTANT]
> **Quiet Camera does not guarantee silence.** Saving at 48 MP also doesn't mean you get the same image quality as Apple's Camera app. So far it has only been checked on one specific device. Please read [How it works](#how-it-works) before relying on it.

## Why this app exists

### Silent mode doesn't always silence the camera

Apple's iPhone User Guide says you can mute the shutter by putting iPhone in Silent mode. The same page adds that in some countries and regions, the shutter sound can't be muted ([Apple Support](https://support.apple.com/guide/iphone/adjust-the-shutter-volume-iph6cfaf98b6/ios)). Japan is one place where people run into this. SoftBank's iPhone support FAQ lists the camera shutter sound among the sounds that silent mode (called *manner mode* in Japan) does not mute ([SoftBank FAQ](https://www.softbank.jp/support/faq/view/12722), in Japanese).

How this works can vary by device and region. But on an iPhone where it applies, turning on Silent mode isn't enough to take a quiet photo.

### What I wanted

During a class, a professor asked me to do something about my shutter sound. I wasn't happy with the image quality of the silent camera apps I tried. So I built a camera that does both: it tries to keep the shutter quiet, and it aims to save high-resolution photos.

That comparison came from my own use. I haven't run any formal image-quality tests against other apps.

The goal is to avoid disturbing a quiet room. Please use Quiet Camera only where photography is allowed, and respect the privacy of the people around you and the rules of your class or venue.

## Features

- **Large preview.** A 4:3 camera preview for framing, with front/rear camera switching.
- **Resolution first.** Requests the largest photo dimensions the selected camera offers. Captures HEIC (falling back to JPEG) and saves it to your photo library. The app itself doesn't downscale or re-compress photos before saving.
- **Automatic shutter-sound suppression.** Runs on every shot, with no toggle to remember. It uses Apple's official API where the system supports it and an experimental fallback where it doesn't ([details](#shutter-sound)).
- **Digital zoom.** Zoom buttons, a slider, and pinch.
- **Save status and retry.** Shows whether each photo was saved and lets you retry a failed save. Unsaved photos are lost if you quit the app.
- **Limited access.** Normal shooting uses the camera and add-only Photos access. There is no networking of its own, no ads, and no analytics.

## Tested so far

| Date | Setup | Result |
| --- | --- | --- |
| Oct 6, 2026 | iPhone 15 / iOS 27.0.1<br>Rear main camera at 1× | Shots were taken without a shutter sound, confirmed in hands-on use. The photo's Info panel in Photos showed **8064 × 6048 (about 48.8 MP; reversed depending on orientation)**. On this device the official suppression flag was `false`, so the experimental fallback was used. |
| Oct 9, 2026<br>(after a UI update) | Rear camera at 1× | Hands-on use confirmed the large preview, plus quiet shooting and saving with no switches to operate. |

These results come from one specific device. They aren't tests across multiple models or regions, and they aren't a quality comparison with Apple's Camera app.

## How it works

### Shutter sound

Quiet Camera picks one of two paths on every shot. There's no on/off switch.

| When | What the app does | Type |
| --- | --- | --- |
| `isShutterSoundSuppressionSupported` is true | Turns on `isShutterSoundSuppressionEnabled` | Apple's official API |
| Otherwise | Calls `AudioServicesDisposeSystemSoundID(1108)` in the capture callbacks just before and after the shot | Experimental |

`AudioServicesDisposeSystemSoundID` itself is a public API. **But using it with ID `1108` to suppress the shutter sound is not something Apple documents as a way to silence the camera.** This fallback is kept separate in [ExperimentalShutterSilencer.swift](QuietCamera/ExperimentalShutterSilencer.swift).

- Trying to suppress the sound isn't the same as succeeding. A return value of `0` isn't treated as proof that the shutter was silent.
- The sound may still play depending on the device, iOS version, region, and shooting conditions. An iOS update could change this behavior.
- The same process runs for the front camera, but whether it works there hasn't been confirmed on a real device.
- There is no confirmation that Apple approves of this implementation. Nor has it been confirmed to meet App Store Review requirements or Apple's agreements and terms.

Reference: [Apple's shutter sound suppression API](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isshuttersoundsuppressionsupported)

### Image quality and resolution

| Setting | Value |
| --- | --- |
| Capture | `AVCapturePhotoOutput` with the `.photo` preset |
| Requested size | The largest photo dimensions the selected camera offers |
| Quality prioritization | `.quality` |
| Compression quality | `1.0` |
| Format | HEIC, or JPEG when HEIC isn't available |
| App-side resizing or recompression | None before saving. |

Limitations:

- **HEIC and JPEG are lossy formats.** A compression quality of `1.0` does not mean lossless.
- The maximum resolution shown in the app is the size it *requests*. What you actually get depends on the model, lens, lighting, system processing, and other factors.
- The app doesn't guarantee the same image processing or quality as Apple's Camera app, or 24 MP / 48 MP output on every model. RAW and ProRAW aren't supported.
- On the rear side, the app uses the main wide camera. Zoom is digital, so higher zoom can reduce detail and saved resolution. Even at the same pixel count, a zoomed photo won't keep the detail of a 1× shot.
- The extended zoom option (「さらに拡大」) goes up to the maximum the camera allows. Quality and behavior at high zoom haven't been widely tested.

<details>
<summary><strong>48 MP check and deferred photo processing</strong></summary>

<br>

When a rear camera that supports 48 MP is used at 1×, the app checks each photo against the requested maximum dimensions. If a photo comes up short, the app shows an error instead of saving it. For a finished image it checks the actual dimensions. For a deferred-processing proxy it checks the expected final dimensions the system reports. While zoomed, lower resolution is accepted. The front camera isn't subject to this 48 MP check.

Where deferred photo processing is available, the app hands a proxy to the photo library as `.photoProxy`, and the system finishes the image. **A proxy's dimensions are not the final image's dimensions, and checking the expected final dimensions doesn't guarantee the quality of the finished photo.** If the app shows 「写真アプリで仕上げ待ち」 (waiting for Photos to finish processing), check the dimensions in the photo's Info panel in Photos once processing is done.

Reference: [Apple's deferred photo proxy](https://developer.apple.com/documentation/avfoundation/avcapturedeferredphotoproxy)

</details>

## Privacy and permissions

| Access | In normal shooting |
| --- | --- |
| Camera | Used to take photos |
| Photos | **Add-only** (`addOnly`). Permission to read existing photos isn't requested. |
| Location | Not requested |
| Microphone | Not used (see below) |
| Network, ads, analytics | None in the app |

Once a photo is in your library, things like iCloud sync follow your device settings.

The project still contains code from an earlier microphone / Live Photo experiment, along with the microphone usage description. That feature's flag is fixed to `false`. It can't be started from the camera screen, and normal shooting never uses the microphone or Live Photos.

## Getting started

### Requirements

- An iPhone running iOS 18.0 or later (see [Tested so far](#tested-so-far) for what has actually been verified)
- A Mac with a version of Xcode that includes the iOS 18 SDK or later and supports your iPhone's iOS version
- An Apple Account for installing on a real device

No external libraries, packages, or servers are needed. The Simulator alone can't show real capture, shutter-sound suppression, or saved image quality.

### Install on your iPhone

This repository is source code only. It doesn't include a signed app, developer certificates, private keys, or provisioning profiles.

1. Open [QuietCamera.xcodeproj](QuietCamera.xcodeproj) in Xcode.
2. Sign in with your Apple Account under **Xcode > Settings > Apple Accounts**.
3. In **TARGETS > QuietCamera > Signing & Capabilities**, turn on **Automatically manage signing** and choose your **Team**.
4. The **Bundle Identifier** `com.example.QuietCamera` is a placeholder for publishing. Change it to one that's unique to you, for example `com.example.myuniqueid.QuietCamera`.
5. Connect your iPhone to your Mac, unlock it, and trust the computer if asked. If prompted, turn on **Settings > Privacy & Security > Developer Mode** on the iPhone.
6. In Xcode, select the **QuietCamera** scheme and your iPhone, then press **Run (⌘R)**.
7. If the iPhone says the developer isn't trusted, go to **Settings > General > VPN & Device Management** and trust and verify your developer app.
8. Allow camera access and adding photos, take a shot, and check the result in Photos. Try it first somewhere a shutter sound won't bother anyone.

> [!NOTE]
> With a free Personal Team, the provisioning profile expires **7 days** after it's issued. After that, rebuild and reinstall using the same Apple Account and Bundle Identifier. See [Apple's explanation](https://developer.apple.com/help/account/basics/about-your-developer-account).

If you publish your own copy after adding your signing settings, make sure it doesn't include your Team ID, device information, certificates, or personal settings and logs.

## License

Quiet Camera is released under the [MIT License](LICENSE). You can reuse, modify, and redistribute it, including for commercial use, as long as you keep the copyright notice and license text. The software is provided without warranty. This license doesn't change the terms of Apple's SDKs or services.

Public examples referenced during development, and their license notices, are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
