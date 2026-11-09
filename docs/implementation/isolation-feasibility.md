# Isolation feasibility — 2026-11-09

Status: release gate not satisfied. No production isolation implementation or
attestation claim is enabled by this probe.

## Physical-device observation

Ran `WebViewTests/isolationNativeBoundaryProbe()` on zaephone, iPhone 15 Pro,
iOS 27.2 (device OS reported by Xcode), using the separate Debug app and a
nonpersistent WKWebsiteDataStore. The fixture loads over HTTPS before native
delegates are installed that cancel child navigation and deny capture permission.
The test then inserts a blank iframe and calls enumerateDevices from that child.

Observed:

```json
{"childAccessible":true,"secure":true,"devices":[{"kind":"audioinput","label":""},{"kind":"videoinput","label":""}],"error":null}
```

Native child navigations denied: 1. Capture permission callbacks: 0.
One Swift Testing test executed successfully; its passing assertion means the
probe completed, not that the isolation policy passed.

The child retained an accessible secure initial document and received a device
list despite navigation cancellation and a deny-all capture delegate. Labels
were empty. Capture was not requested or demonstrated. This is enough to reject
navigation cancellation plus capture permission denial as enforcement of the
roadmap's strict no-embedded-context/no-device-list policy.

## Evidence and limits

- Test source: `ios/WandBrowserTests/WebViewTests.swift`.
- Local log: `/private/tmp/wand-isolation-probe.log`.
- Results: `/private/tmp/wand-isolation-probe/Logs/Test/`.
- Initial run without parentheses in the selector executed zero tests and is
  not evidence; the corrected selector executed one test.
- This does not prove every public WebKit enforcement approach impossible.
- Persistent storage separation, capture revocation, other iOS versions, and
  App Attest were not tested by this probe.

## Release consequence

Do not ship the complete strict-isolation claim based on navigation delegates
and capture permission checks. A stronger native enforcement approach must pass
this probe and the full roadmap matrix before enabling isolation or signing
policy proofs. JavaScript wrappers and disabling capture alone are not substitutes.
Version remains 0.3.2; no archive or upload was prepared.
