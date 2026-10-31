# Tracklog

A scrobbler for macOS that lives in [Droppy](https://getdroppy.app). It reads the
system's now-playing feed, applies your edits and blocks, and sends what you listen to
Last.fm, ListenBrainz, Libre.fm and Pleroma. A local queue keeps scrobbles safe offline; a
local history keeps your listening in one place.

Scrobbling stays off until you turn it on in Tracklog's settings, and it runs while Droppy
is open. Your listens go only to the services you connect.

## Developing

```bash
mise install         # hk, jactionlint, SwiftLint, SwiftFormat, shellcheck
mise run hooks       # install the hk Git hooks
mise run gate        # lint, test, build, validate, shots
mise run lint        # SwiftFormat, SwiftLint and jactionlint
mise run format      # apply SwiftFormat fixes
```

```bash
droppykit run        # open the droplet in Droppy's harness
droppykit build      # produce Tracklog.droplet
droppykit validate   # the checks the Store repository runs
droppykit run -- --shots ./shots --report ./shots/report.json
```

The package lives in `tracklog/`. The map for the project is
[issue #1](https://github.com/ranokay/tracklog/issues/1); research notes live on
`research/*` branches.

## Licence

MIT.
