# Tracklog

A scrobbler droplet for [Droppy](https://getdroppy.app) that brings your listening
history to the notch: Last.fm, ListenBrainz, Libre.fm and Pleroma, with a local queue, a
local history, metadata edits and blocks.

- **Droplet package:** [`tracklog/`](tracklog/) — SwiftPM, DroppyKit, SwiftUI.
- **Map:** [issue #1](https://github.com/ranokay/tracklog/issues/1).
- **Research:** `research/*` branches, one per question; no pull requests.
- **Licence:** MIT.

## Development

```bash
mise install
mise run hooks
mise run gate
```

`mise run lint` runs SwiftFormat, SwiftLint and jactionlint through `hk`; `mise run format` applies SwiftFormat. The same `hk check --all` runs in CI.
