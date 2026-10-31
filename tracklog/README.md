# Tracklog

A scrobbler for macOS that lives in [Droppy](https://getdroppy.app). It reads the
system's now-playing feed, applies your edits and blocks, and sends what you listen to
Last.fm, ListenBrainz, and Libre.fm or another GNU FM server. A local queue keeps scrobbles
safe offline; a local history keeps your listening in one place.

Scrobbling stays off until you turn it on in Tracklog's settings, and it runs while Droppy
is open. Your listens go only to the services you connect.

## SDK setup

Install the [DroppyKit SDK](https://getdroppy.app/docs/droppykit), then add its
`Scripts` directory to your shell's PATH. For example, if the checkout is in
`~/Developer/droppykit`:

```bash
export DROPPYKIT_ROOT="$HOME/Developer/droppykit"
export PATH="$DROPPYKIT_ROOT/Scripts:$PATH"
```

Run the mise commands below from the repository root. The package declares
DroppyKit 1.20.1 or a compatible later 1.x version; the SDK keeps its own license.
To use the checked-in MCP configurations, open `tracklog/` as the client workspace
and launch the client with `droppykit` on PATH. Their package path is relative to
that workspace.

## Last.fm credentials

Source builds do not include a Last.fm application key or shared secret. Register
your own application at <https://www.last.fm/api/account/create>, then open
Tracklog settings, Services, Last.fm app credentials. Save both values there
before signing in through your browser. Tracklog validates the pair and keeps it
in the Keychain; no local JSON provisioning file is read at runtime.

Changing or removing the pair signs existing Last.fm connections out. Pending
scrobbles remain queued until those connections sign in again. ListenBrainz and
Libre.fm setup does not require a Last.fm app pair. Keep credentials out of Git,
logs and screenshots.

## Developing

```bash
mise install         # hk, jactionlint, SwiftLint, SwiftFormat, shellcheck
mise run hooks       # install the hk Git hooks
mise run gate        # lint, test, build, validate, shots
mise run lint        # SwiftFormat, SwiftLint and jactionlint
mise run format      # apply SwiftFormat fixes
```

```bash
cd tracklog          # from the repository root
droppykit run        # open the droplet in Droppy's harness
droppykit build      # produce Tracklog.droplet
droppykit validate   # the checks the Store repository runs
droppykit run -- --shots ./shots --report ./shots/report.json
```

The package lives in `tracklog/`. The map for the project is
[issue #1](https://github.com/ranokay/tracklog/issues/1); research notes live on
`research/*` branches.

## Licence

Tracklog-owned code and documentation use [Apache-2.0](../LICENSE).
[Third-party terms](../THIRD_PARTY_NOTICES.txt) apply to DroppyKit, its scaffold
material and generated placeholder artwork. Project names and logos are reserved
for official branding. The SDK build copies the license files in
`Assets/Licenses/` into the droplet resources.
