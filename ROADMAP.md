# Wand Browser: Future Feature Roadmap

## Direction

Add iPhone capabilities that help web apps work well in Wand, using the web
wallet as an initial use case. Implement each feature independently. The order
below is provisional. These are candidates, except where an agreed plan is
explicitly recorded; platform feasibility still needs validation.

## Features

### 1. Push notifications

- Support opt-in notifications for payment requests, incoming payments and other web-app events.
- Before implementation, investigate iOS/WKWebView support and decide between standard Web Push and a Wand-specific native service.
- Define site-specific consent, delivery infrastructure, notification routing and revocation.

### 2. Contact selection

- Let users select one or several contacts through native iPhone UI.
- Return only requested names, phone numbers and emails.
- Prefer the draft Contact Picker API interface where practical.
- Keep recipient verification and contact-to-wallet mapping in the web wallet: a phone number or email alone does not establish a wallet address.
- Defer whole-address-book import, friend discovery and ongoing synchronization.

### 3. QR scanning

- Build on existing camera support for wallet addresses, payment requests and device pairing.
- Evaluate web-based decoding before adding a native scanning API.
- Require confirmation before acting on scanned content.

### 4. Share web-app content

- Support sharing payment requests, receipts, text and files through the native share sheet.
- Evaluate standard Web Share support before extending Wand.

### 5. File import and export

- Support user-selected imports and exports for encrypted backups, transaction records and receipts.
- Validate existing WebKit behavior before adding native functionality.
- Keep backup encryption and restoration logic in the wallet.

### 6. App links and return flows

- Support opening intended web-app destinations in Wand and returning from external apps.
- Design URL validation, user confirmation and cancellation behavior before implementation.

### 7. Authentication compatibility

- Test passkeys and hardware authentication with the wallet's actual flows.
- Add native capabilities only for demonstrated gaps.
- Treat account authentication and transaction signing as separate requirements.

### 8. Website-requested isolated profiles

Agreed plan; strict isolation guarantees are subject to physical-device validation.

#### Summary

Let a website request a dedicated Wand profile, subject to native user approval.
Each profile belongs to one exact HTTPS origin and has separate persistent
website storage. The website and its backend can verify the enforced policy.
The guarantee covers browser isolation, not malicious code running within the
authorized website or hardware use by other iPhone apps.

#### Profile creation and storage

- Add `wand.profile.requestIsolation()`. Show native approval identifying the exact origin and explaining separate storage, blocked embedded pages, and hardware restrictions.
- After approval, create or reopen that origin's profile and load the requesting URL there. Creation starts with empty storage; do not copy existing cookies or login sessions.
- Use a dedicated persistent `WKWebsiteDataStore` per profile, separate from ordinary browsing and every other profile.
- Keep the origin binding immutable. Different schemes, hosts, or ports require different profiles.
- Block navigation and redirects outside the bound origin. Offer a native action to open those destinations in ordinary browsing.
- Prohibit embedded browsing contexts, including same-origin frames and popup windows. Validate enforcement for dynamically created frames, `srcdoc`, `about:blank`, and blob/data URLs.
- Add native profile selection, a persistent isolation indicator, and profile deletion that removes its website data and local attestation credentials.
- Isolation does not prevent the authorized website from deliberately transmitting its own data or loading external scripts that execute with its authority.

#### Hardware enforcement and website interface

- Centralize policy checks in native code: bound origin, current main document, active profile, foreground state, and valid document session.
- Preserve separate BLE selection, NFC approval, and camera consent. Profile isolation never grants hardware permission automatically.
- Stop hardware access and invalidate pending operations on navigation, reload, backgrounding, profile switching, deletion, or revocation.
- Permit only one active profile document to hold hardware access. Route camera permission and capture shutdown through the same lifecycle.
- Include BLE, NFC, and camera; report contacts as unsupported.
- Add `wand.profile.getState()` and a change event reporting isolation status, bound origin, policy version, document session, and capability support. Distinguish eligibility from granted permission and active use.
- Require native enforcement of **no device enumeration outside the authorized main document**. JavaScript wrappers are not an acceptable security boundary.

#### Backend verification

- Add `wand.profile.attestChallenge(...)`, available only to the active isolated main document.
- Use Apple App Attest to authenticate native-generated policy statements, following Apple's verification protocol linked below.
- Bind each assertion to the server challenge, expected origin, document session, policy version, and server-defined operation context. Construct policy fields natively; never sign website-supplied policy claims.
- Provide a Node.js/TypeScript verifier and example backend. Each website verifies directly; no central Hito service.
- Require single-use challenges with a 60-second expiry, bound to the backend's authenticated session. Validate attestation identity, environment, signature, assertion counter, and expected policy.
- Keep development and production trust separate. Reject unsupported attestation or invalid proofs without downgrading to a verified result.
- Explain that verification establishes a policy snapshot at assertion time, not continuous access or immediate remote revocation.

#### Validation and release criteria

- **First milestone:** test native storage isolation, embedded-context blocking, camera enumeration, and capture revocation on supported physical iPhones. Inability to enforce the strict policy is a release blocker; disabling camera capture alone does not satisfy enumeration isolation.
- Verify cookies, IndexedDB, local storage, caches, and service workers remain separate across ordinary browsing and isolated profiles, including restart and deletion.
- Exercise redirects, popup attempts, dynamic frames, stale document tokens, forged bridge calls, profile switches, backgrounding, and late hardware callbacks.
- Confirm unauthorized contexts receive neither hardware access nor device lists; confirm approved main-document BLE/NFC/camera flows still work.
- Test proof tampering, replay, expiry, wrong origin/session, counter rollback, unsupported devices, and production/development mismatches.
- Add coverage to existing Swift and JavaScript suites, plus backend verifier tests. Validate real radios, camera behavior, and production App Attest on physical devices before publishing the guarantee.

Defaults: native approval, fresh persistent storage, exact-origin binding, no
embedded documents, no cross-origin sign-in inside the profile, and no contacts
implementation in this release.

### 9. Hito hardware authorization

Build on website-requested isolated profiles and backend verification of Wand's
App Attest assertions. The intended capability is an **isolated, attested
browser with Hito hardware authorization**.

- Bind the website origin, document session, isolation policy, fresh server challenge, and exact operation digest into the authorization flow.
- Have Hito independently verify authenticated authorization, display meaningful operation details, obtain user confirmation, and sign the bound operation.
- Keep private keys and protected operations on Hito hardware.
- Verify browser and hardware proofs together on the website backend; reject replay, mismatched operations, expired challenges, and invalid proofs.
- Investigate Hito firmware support, trusted display capabilities, verifier trust provisioning, and protocol requirements before implementation.
- Validate the complete flow on physical Hito hardware, including denial, tampering, replay, and operation substitution.

Webpage execution remains outside a trusted execution environment (TEE).
Hardware participation alone does not prove browser integrity: Hito signing
arbitrary data supplied by Wand would not validate Wand's isolation policy.
Any TEE claim must be limited to the specific computation and secrets actually
protected by suitable trusted hardware.

## Shared acceptance criteria

- Prefer standard web interfaces; document any Wand-specific extensions.
- Show which site requests access and share only user-approved data.
- Handle cancellation, denial, navigation and backgrounding without leaking data between sites.
- Provide a working fixture, relevant automated checks and physical-iPhone verification for each feature.

## Delivery defaults

Before implementing each feature, confirm its user flow, platform feasibility,
interface and acceptance tests. Push notifications are the next feature to
investigate.

## References

- [Apple Contacts UI](https://developer.apple.com/documentation/ContactsUI)
- [Limited contact access on iOS](https://developer.apple.com/videos/play/wwdc2024/10121/)
- [Contact Picker API draft](https://w3c.github.io/contact-picker/)
- [Apple App Attest server verification](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server)
