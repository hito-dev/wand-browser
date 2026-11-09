# Site profiles — 0.3.2 candidate

Each approved HTTPS origin has a persistent WebKit data store separate from
ordinary browsing and other profiles. New profiles start with empty storage.
Subdomains and nondefault ports are separate origins. Ordinary browsing data is
not migrated. History and fullscreen preferences are scoped to each profile.

Top-level navigation outside the bound origin is canceled and offers opening in
ordinary browsing. Embedded content and external resources follow normal WebKit
rules within the profile. Cross-origin sign-in that requires top-level navigation
cannot finish inside the locked profile.

## Website interface

- `await wand.profile.getState()` returns `policy`, `active`, `origin`,
  `strictEmbeddedIsolation`, and `attestation`.
- Policy is `storage-origin-v1`; the last two fields are always false.
- `await wand.profile.requestIsolation()` requests native approval. Denial rejects
  with `NotAllowedError`. Approval replaces the page, invalidating its pending
  request; the newly loaded page must query state again. Calling from an already
  active profile returns its state without another prompt.
- `wand.profile.addEventListener('change', callback)` signals state refresh.
  Read state again in the callback. Only the active HTTPS main document may use
  these APIs; ordinary hardware consent remains separate.

Profile deletion first makes the profile unavailable, then removes its website
data and preferences. Failed deletions retry at launch or through the profile
menu. Hardware grants do not transfer when switching profiles.

This is storage isolation and an origin lock, not a guarantee that embedded
documents cannot execute or enumerate media devices. It does not prevent a
website from transmitting its data. There is no App Attest proof.

## Validation status

On zaephone, 23 native tests passed, including the registry, cookie/local-storage,
IndexedDB and CacheStorage separation, reopening, and deletion/recreation.
Service workers, full UI flows, upgrade, and physical hardware lifecycle acceptance
remain pending; these results do not establish those checks. The new fixture is
`tests/fixtures/profiles.html`; it must be published before reviewer use.
