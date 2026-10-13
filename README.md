<p align="center">
  <img src="QuietCamera/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="96" height="96" alt="Quiet Camera app icon">
</p>

<h1 align="center">Quiet Camera</h1>

<p align="center">An experimental iPhone camera for taking photos quietly.</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-18.0%2B-1d2b31?style=flat-square" alt="iOS 18.0+">
  <img src="https://img.shields.io/badge/dependencies-none-1d2b31?style=flat-square" alt="No external dependencies">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3f6f60?style=flat-square" alt="MIT License"></a>
</p>

<p align="center">
  <strong>English</strong> · <a href="README.ja.md">日本語</a>
</p>

During a class, a professor asked me to turn off my shutter sound. On an iPhone that isn't as simple as it sounds. On some iPhones used in Japan, even Silent mode won't mute the shutter. I tried silent camera apps instead, but I wasn't happy with the image quality.

So I made my own. Quiet Camera tries to suppress the shutter sound on every shot, and it asks the camera for the largest photo it can take. The point is to avoid disturbing a quiet room. Please use it only where photography is allowed, and with respect for the people around you.

> [!IMPORTANT]
> This is an experimental personal project. It doesn't guarantee silence, full resolution, or the same image quality as Apple's Camera app. Results can vary with your iPhone model, iOS version, and region, and so far it has only been tested on one iPhone.

## What it does

- **Shutter suppression on every shot.** There's nothing to switch on. It uses Apple's official API where your iPhone supports it, and an experimental fallback where it doesn't.
- **Asks for full resolution.** It requests the largest photo size the selected camera offers and saves HEIC (or JPEG) to Photos. The app doesn't resize or recompress photos before saving.
- **A big 4:3 preview.** Front and rear cameras, with digital zoom by buttons, a slider, or pinch.
- **No extras.** It uses the camera and add-only Photos access. The app has no networking of its own, no ads, and no analytics.

## Tested so far

On an iPhone 15 with iOS 27.0.1, using the rear main camera at 1×, photos were taken with no shutter sound. Photos showed them at 8064 × 6048, about 48.8 MP. Apple's official API reported no support on that phone, so the experimental fallback was used. Other models and regions haven't been tested yet. The full log is under [Details](#details).

## Try it on your iPhone

There's no prebuilt app. You build it in Xcode and install it on your own iPhone. You'll need:

- an iPhone on iOS 18.0 or later
- a Mac with Xcode that includes the iOS 18 SDK or later and supports your iPhone's iOS version
- an Apple Account

Then:

1. Open [QuietCamera.xcodeproj](QuietCamera.xcodeproj) and sign in under **Xcode > Settings > Apple Accounts**.
2. In **TARGETS > QuietCamera > Signing & Capabilities**, turn on **Automatically manage signing** and choose your **Team**.
3. Change the **Bundle Identifier** from the placeholder `com.example.QuietCamera` to something unique, such as `com.example.myuniqueid.QuietCamera`.
4. Connect and unlock your iPhone, and trust the Mac if asked. If prompted, turn on **Settings > Privacy & Security > Developer Mode**.
5. Select the **QuietCamera** scheme and your iPhone, then press **Run (⌘R)**.
6. If the iPhone says the developer isn't trusted, trust and verify your app in **Settings > General > VPN & Device Management**.
7. Allow camera access and adding photos, then check your first shots in Photos. Try it first somewhere a shutter sound won't bother anyone.

With a free Personal Team, the provisioning profile expires 7 days after it's issued. When it does, rebuild and reinstall with the same Apple Account and Bundle Identifier ([Apple's explanation](https://developer.apple.com/help/account/basics/about-your-developer-account)).

## Details

The sections below cover the technical background, limitations, and sources.

<details>
<summary><strong>The shutter sound: background and how it's handled</strong></summary>

<br>

Apple's iPhone User Guide says Silent mode mutes the shutter, but it also notes that the shutter can't be muted in some countries and regions ([Apple Support](https://support.apple.com/guide/iphone/adjust-the-shutter-volume-iph6cfaf98b6/ios)). In Japan, SoftBank's iPhone FAQ lists the camera shutter among the sounds that silent mode (*manner mode*) doesn't mute ([SoftBank FAQ](https://www.softbank.jp/support/faq/view/12722), in Japanese). Exact behavior can vary by device and region.

On every shot, Quiet Camera takes one of two paths. There's no on/off switch.

| When | What the app does | Type |
| --- | --- | --- |
| `isShutterSoundSuppressionSupported` is true | Turns on `isShutterSoundSuppressionEnabled` | Apple's official API ([docs](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isshuttersoundsuppressionsupported)) |
| Otherwise | Calls `AudioServicesDisposeSystemSoundID(1108)` in the capture callbacks just before and after the shot | Experimental |

`AudioServicesDisposeSystemSoundID` is a public API. Using it with ID `1108` to suppress the shutter, though, is not a camera-silencing method that Apple documents. The fallback is kept separate in [ExperimentalShutterSilencer.swift](QuietCamera/ExperimentalShutterSilencer.swift).

- Running the fallback isn't the same as succeeding. A return value of `0` isn't treated as proof of silence.
- The sound may still play depending on the device, iOS version, region, and shooting conditions. iOS updates may change this behavior.
- The front camera gets the same treatment, but its effect there hasn't been confirmed on a real device.
- There's no confirmation that Apple approves of this implementation, or that it meets App Store Review requirements or Apple's agreements and terms.

</details>

<details>
<summary><strong>Image quality and resolution</strong></summary>

<br>

| Setting | Value |
| --- | --- |
| Capture | `AVCapturePhotoOutput` with the `.photo` preset |
| Requested size | The largest photo dimensions the selected camera offers |
| Quality prioritization | `.quality` |
| Compression quality | `1.0` |
| Format | HEIC, or JPEG when HEIC isn't available |
| App-side resizing or recompression | None before saving |

- **HEIC and JPEG are lossy.** A compression quality of `1.0` doesn't mean lossless.
- The maximum resolution shown in the app is what it *requests*. What you actually get depends on the model, lens, lighting, system processing, and other factors.
- The app doesn't guarantee the same image processing or quality as Apple's Camera app, or 24 MP / 48 MP output on every model. RAW and ProRAW aren't supported.
- On the rear side, the app uses the main wide camera. Zoom is digital, so zooming in can reduce detail and saved resolution. Even at the same pixel count, a zoomed shot won't keep the detail of a 1× shot.
- The 「さらに拡大」 (zoom further) option goes up to the maximum the camera allows. Quality and behavior at high zoom haven't been widely tested.

**48 MP check.** When a rear camera that supports 48 MP is used at 1×, each photo is checked against the requested maximum dimensions. A photo that falls short isn't saved, and an error is shown instead. Finished images are checked by their actual dimensions. Deferred-processing proxies are checked by the expected final dimensions the system reports. Lower resolution is accepted while zoomed, and the front camera isn't subject to this check.

**Deferred processing.** Where it's available, the app hands a proxy to the photo library as `.photoProxy`, and the system finishes the image. A proxy's dimensions are not the final image's dimensions. Checking the expected final dimensions doesn't guarantee the quality of the finished photo, either. If the app shows 「写真アプリで仕上げ待ち」 (waiting for Photos to finish), check the dimensions in the photo's Info panel in Photos once processing is done ([Apple's deferred photo proxy](https://developer.apple.com/documentation/avfoundation/avcapturedeferredphotoproxy)).

</details>

<details>
<summary><strong>Test log</strong></summary>

<br>

| Date | Setup | Result |
| --- | --- | --- |
| Oct 6, 2026 | iPhone 15 / iOS 27.0.1<br>Rear main camera at 1× | Shots were taken without a shutter sound, confirmed in hands-on use. The photo's Info panel in Photos showed 8064 × 6048 (about 48.8 MP; reversed depending on orientation). The official suppression flag was `false`, so the experimental fallback was used. |
| Oct 9, 2026<br>(after a UI update) | Rear camera at 1× | Hands-on use confirmed the large preview, plus quiet shooting and saving with no switches to operate. |

These results come from one specific device. They aren't tests across multiple models or regions. No image-quality comparison has been made with other apps or with Apple's Camera app.

</details>

<details>
<summary><strong>Permissions, saving, and data</strong></summary>

<br>

| Access | In normal shooting |
| --- | --- |
| Camera | Used to take photos |
| Photos | Add-only (`addOnly`). Permission to read existing photos isn't requested. |
| Location | Not requested |
| Microphone | Not used |
| Network, ads, analytics, tracking | None in the app |

- The app shows the save status of each photo, and you can retry a failed save. Anything not yet saved is lost if you quit the app.
- Once a photo is in your library, things like iCloud sync follow your device settings.
- The project still contains code from an earlier microphone / Live Photo experiment, along with the microphone usage description. That feature's flag is fixed to `false`. It can't be started from the camera screen, and normal shooting doesn't use the microphone or Live Photos.

</details>

<details>
<summary><strong>Building and sharing your own copy</strong></summary>

<br>

- This repository is source code only. It doesn't include a signed app, developer certificates, private keys, or provisioning profiles.
- No external libraries, packages, or servers are needed.
- The Simulator can't show real capture, shutter-sound suppression, or saved image quality.
- If you publish your own copy after adding your signing settings, make sure it doesn't include your Team ID, device information, certificates, or personal settings and logs.

</details>

## License

Released under the [MIT License](LICENSE). You can reuse, modify, and redistribute it, including commercially, as long as you keep the copyright notice and license text. It comes with no warranty, and it doesn't change the terms of Apple's SDKs or services. Public examples referenced during development are credited in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
