# 0.3.2 site-profile candidate

Candidate: **0.3.2 (9)**. The owner confirmed the latest existing build is
**0.3.1 (8)**. Apple processing and distribution eligibility remain unverified.
Production bundle ID: ai.hito.wand.

## What to test

- Open an HTTPS site and use the profile menu to create a site profile. Confirm
  that it starts signed out and that the exact origin is visible.
- Save a marker at https://wand.hito.ai/fixtures/profiles.html in ordinary browsing,
  then create a profile and verify that its marker is initially empty. This URL
  requires deployment of the candidate website before use.
- Reopen the profile and verify its own marker persists. Clear its website data
  and verify ordinary browsing data remains intact.
- Follow an external link: it must offer ordinary browsing, with cancellation
  keeping the profile open. Test deletion and recreation with empty storage.
- Verify camera capture, BLE connections, and NFC operations end when switching
  profiles. Use disposable tags and harmless BLE commands.
- Test website-requested approval, rejection, navigation during approval, and
  backgrounding while approval is open.

## Reviewer notes

Site profiles provide separate persistent WebKit storage and restrict top-level
navigation to one exact HTTPS origin. Ordinary browsing remains available.
Embedded content follows WebKit rules; no strict frame-blocking, device-enumeration
isolation, or App Attest guarantee is made. Profiles do not grant hardware access.

## Release gates

Cookie/local-storage, IndexedDB, and CacheStorage separation, reopening, and
deletion/recreation passed on zaephone. Service workers, full UI flows, production
hardware lifecycle, and upgrade checks still require recorded results. No TestFlight upload has been performed.
Use a clean checkout and the tracked archive/export verifier tools. Keep public
release manual and defer App Store review submission until TestFlight validation.
