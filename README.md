# Wand Browser

An open-source iOS browser for developers. Test JavaScript web apps on iPhone
with WebBluetooth (BLE/GATT) and WebNFC (NDEF tags).

## Test your web app

Open your HTTPS site in Wand to test its Web Bluetooth or Web NFC code against
nearby hardware.

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
[bridge implementation](ios/WandBrowser/Resources/HardwareBridge.js).
Hardware access requires a top-level HTTPS page with Wand in the foreground.
NFC support is limited to NDEF tags.

Use a physical iPhone and compatible hardware for BLE and NFC tests. The simulator
can test browser flows and bridge logic but cannot validate either radio.

## Run

Requires iOS 18 or later. We tested builds with Xcode 26.6.

1. Open [ios/WandBrowser.xcodeproj](ios/WandBrowser.xcodeproj).
2. Select the **WandBrowser** scheme and an iPhone simulator or physical iPhone.
3. For your own device build, choose your signing team and a unique bundle ID in
   Signing & Capabilities. Enable **NFC Tag Reading** for that App ID.
4. Run the app.

Build the checked-in Xcode project directly. You do not need to generate it or
install packages.

## Test

In Xcode, choose **Product → Test**. The native and UI tests load
[hosted HTTPS fixtures](https://hito-dev.github.io/wand-browser/fixtures/bridge.html).
They need internet access. No local server or certificate setup is required.

Set the `WAND_FIXTURE_URL` build setting to use another HTTPS fixture host.

Node.js is optional. To run the standalone bridge and SDK tests from the
repository root:

```sh
node --experimental-vm-modules --test tests/bridge.test.mjs
```

## License

[MIT](LICENSE).

## Prepare a TestFlight build

Commit the release source and choose a build number higher than any already
uploaded for version 0.2.3. With the Hito signing account configured in Xcode:

```sh
BUILD_NUMBER=5 sh scripts/archive-testflight.sh
```

The script archives Release, exports an App Store distribution IPA, and verifies
the packaged signing, NFC entitlement, privacy manifest, policy, and build number.
It saves the source commit, archive, symbols, export, and reports under
`artifacts/testflight/0.2.3-5/`. Existing candidates are preserved. Add
`--archive-only` to stop before distribution export. This command does not upload
or submit the build; TestFlight upload and external beta review are separate steps.
