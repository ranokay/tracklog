# Tracklog

A scrobbler droplet for [Droppy](https://getdroppy.app) that brings your listening
history to the notch: Last.fm, ListenBrainz, and Libre.fm or another GNU FM server, with a
local queue, a local history, metadata edits and blocks.

- **Droplet package:** [`tracklog/`](tracklog/) — SwiftPM, DroppyKit, SwiftUI.
- **Map:** [issue #1](https://github.com/ranokay/tracklog/issues/1).
- **Research:** `research/*` branches, one per question; no pull requests.
- **Licence:** [Apache-2.0](LICENSE) for Tracklog-owned code and documentation.
  [Third-party terms](THIRD_PARTY_NOTICES.txt) apply to DroppyKit and its scaffold material.
  Project names and logos are reserved for official branding.

## Development

```bash
mise install
mise run hooks
mise run gate
```

`mise run lint` runs SwiftFormat, SwiftLint and jactionlint through `hk`; `mise run format` applies SwiftFormat. The same `hk check --all` runs in CI.

See [SDK setup and Last.fm credentials](tracklog/README.md#sdk-setup) before building.

## Publication preparation

Public visibility is a separate owner action. On 2026-10-31 the owner authorized
retiring the Last.fm app pair retained in historical commits. The matching API
application was disabled through Last.fm, and a read-only API request with its
old key returned HTTP 403, error 26 (API Key Suspended). Source builds use the
user-supplied credentials described in the package README. This preparation does
not publish or submit a Droppy Store release.
