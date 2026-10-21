# TestFlight metadata handoff

The website supports 25 locales. `site/languages.json` maps 20 of them to Apple
metadata locales. Afrikaans, Swahili, Hausa, Yoruba and Amharic are website-only.
The app interface remains English; every description says so. Spanish uses neutral
website copy and Apple's `es-ES` metadata locale. Chinese is Simplified Chinese.

Regenerate these files from the same translations used by the website:

```sh
python3 scripts/build-site.py --output /tmp/wand-site-new --metadata-output release/testflight/metadata
```

Use an empty website output directory. This command performs no upload.

In App Store Connect → Wand Browser → TestFlight:

1. Under Test Information, add each language listed in `metadata/`.
2. Paste that directory's `betaAppDescription.txt` into **Beta App Description**.
3. Set **Feedback Email** to `support-wand@hito.ai` and use the marketing/privacy
   URLs from `metadata.json` in the corresponding fields.
4. Select the uploaded build and paste `whatToTest.txt` into **What to Test** for
   the matching language. These instructions describe Bluetooth selection/GATT,
   NDEF reading/writing, permissions, cancellation and foreground restrictions.
5. Keep the reviewer contact information private and enter it separately. This
   repository does not publish the reviewer's personal contact details. No app
   account is needed. Review notes can link to https://wand.hito.ai/fixtures/bridge.html
   and explain that Bluetooth requires a compatible Hito test wallet and NFC
   requires a physical iPhone and an NDEF test tag.
6. Choose tester groups and submit the build for beta review yourself. Add a public
   invitation link to the website only after one exists.

English screenshots are in `site/assets/screenshots/`: Home, the hardware fixture
with console, and Site controls. Captured from the actual app on the iPhone 17 Pro
simulator using `testCaptureReleaseScreenshots`; they do not demonstrate successful
physical Bluetooth/NFC operations. Captions and alt text are localized on the
website. The fixture screenshot uses the temporary local HTTPS test server.
Screenshots are website/release assets; TestFlight descriptions are separate from
an App Store product-page listing, whose screenshots you can upload when preparing
that listing. No App Store or TestFlight submission is made by these scripts.

Apple references: [test information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/),
[available metadata languages](https://developer.apple.com/help/app-store-connect/reference/app-information/app-store-localizations/).
