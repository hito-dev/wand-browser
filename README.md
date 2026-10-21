# Wand Browser

An open-source iPhone browser for developers. Test web apps that connect to
Bluetooth devices and NFC tags.

## Test your web app

Open your HTTPS site in Wand and use its Web Bluetooth or Web NFC code to talk
to nearby hardware. Test prototypes and device setup pages on an iPhone without
building a separate native app for each project.

- **Bluetooth Low Energy:** select a device, connect to GATT services, read and
  write characteristics, and receive notifications through `navigator.bluetooth`.
- **NFC:** read and write NDEF tags through `NDEFReader`.
- **History:** reopen recent test pages from the home screen. Wand stores history
  on your device.

You choose which Bluetooth device a site can access and approve NFC requests.
Hardware permissions end when you load a new document, reload, background Wand,
or revoke access in Site controls.

## Limits

This early version supports a subset of Web Bluetooth and Web NFC.
Check the API calls your site uses against the
[bridge implementation](ios/HitoWand/Resources/HardwareBridge.js).
Hardware access requires a top-level HTTPS page with Wand in the foreground.
NFC support is limited to NDEF tags.

Use a physical iPhone and compatible hardware for BLE and NFC tests. The simulator
can test browser flows and bridge logic but cannot validate either radio.

## Run

Requires iOS 18 or later. We tested builds with Xcode 26.6.

1. Open [ios/HitoWand.xcodeproj](ios/HitoWand.xcodeproj).
2. Select the **HitoWand** scheme and an iPhone simulator or physical iPhone.
3. For your own device build, choose your signing team and a unique bundle ID in
   Signing & Capabilities. Enable **NFC Tag Reading** for that App ID.
4. Run the app.

Build the checked-in Xcode project directly. You do not need to generate it or
install packages.

## Test

With Node.js installed, run the bridge and SDK tests from the repository root:

```sh
node --experimental-vm-modules --test tests/bridge.test.mjs
```

## License

[MIT](LICENSE).
