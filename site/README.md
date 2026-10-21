# Multilingual website

`languages.json` is the URL, hreflang and Apple metadata locale registry.
`locales/en.json` is the source key set; all 25 locale files must provide every key
and preserve message placeholders. Native application UI remains English.

Run `sh scripts/prepare-pages.sh` to generate a validated temporary Pages directory.
Run `python3 -m unittest discover -s tests -p site_test.py` to check discovery,
translations, utility-page indexing, fixture IDs and metadata limits. Deployment
runs the same checks.

English URLs stay at `/` and `/fixtures/bridge.html`; translated routes use
lowercase locale prefixes. Four substantive pages per locale provide 100 indexable
pages. Navigation and hidden security fixtures are noindex. Privacy is copied
byte-for-byte from the bundled English policy. Shared fixture scripts preserve the
hardware API requests, the 20% initial resizable console, and keyboard behavior.

Each page has a canonical URL, reciprocal language alternates, an English
x-default, an ordinary-link language chooser, and a linked Markdown mirror.
`sitemap.xml` contains the 100 pages and privacy. `llms.txt` files link to the same
content and are a convenience for readers/tools, not a promise of search rankings
or inclusion in AI answers. Search discovery uses normal crawlable HTML, links,
metadata and the sitemap. There are no automatic language redirects.

The native screenshot capture test targets iPhone 17 Pro. Run it separately with
`WAND_FIXTURE_URL` pointing to an HTTPS generated fixture directory; export its
three xcresult attachments to `assets/screenshots/`. Existing screenshots are real
simulator captures, in English, with translated website captions. The local server
address in the fixture screenshot is intentional; no successful radio operations
are simulated. Real hardware is required for Bluetooth and NFC verification.
