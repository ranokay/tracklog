# Tracklog

A clean-room scrobbler for macOS that lives in [Droppy](https://getdroppy.app). It reads the
system's now-playing feed, applies your edits and blocks, and sends what you listen to
Last.fm, ListenBrainz, Libre.fm and Pleroma. A local queue keeps scrobbles safe offline; a
local history keeps your listening in one place.

Tracklog is inspired by [Pano Scrobbler](https://github.com/kawaiiDango/pano-scrobbler) and
is not affiliated with it. No Pano code, strings or assets are used.

## Developing

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
