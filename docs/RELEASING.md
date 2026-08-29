# Releasing

Costbar ships one rolling `tip` release rather than tagged versions. The
`tip` git tag and its GitHub release are both moved to whatever commit was
last published, so the download URL never changes and the Homebrew cask
(`Casks/costbar.rb`) is `version :latest` with `sha256 :no_check` — it needs no
edit when a build ships.

The trade-off is that Homebrew has no version to compare, so users upgrade with
`brew upgrade --cask --greedy costbar` rather than a plain `brew upgrade`.

## One-time setup

Publishing requires a **Developer ID Application** certificate for team
`FCWK5WR45W` in the login Keychain. The `Debug` and `ReleaseLocal` Xcode
configurations sign with `Apple Development`, which is fine for this machine
and refused by Gatekeeper on every other one; only `Release` signs for
distribution.

Store notarization credentials once. The password is an app-specific password
from appleid.apple.com, not the Apple ID password:

```sh
xcrun notarytool store-credentials costbar \
    --apple-id you@example.com \
    --team-id FCWK5WR45W \
    --password APP-SPECIFIC-PASSWORD
```

`gh` must also be authenticated with push access to the repository.

## Publishing

From a clean checkout of the commit to publish:

```sh
dist/release.nu --publish
```

The script refuses to run against a dirty working tree, because `tip` has to be
reproducible from a commit. It then:

1. Builds a universal (`arm64` + `x86_64`) XCFramework and the `Release`
   configuration, stamping `CURRENT_PROJECT_VERSION` with the commit count so
   builds are ordered.
2. Verifies the bundle's leading signing authority really is a Developer ID
   Application certificate and aborts if it is not. A Development-signed build
   succeeds locally and then fails to launch everywhere else, so this is
   checked before anything ships rather than discovered by whoever installs it.
3. Zips with `ditto --sequesterRsrc --keepParent`, submits to notarization,
   waits, staples the ticket, rebuilds the archive around the stapled bundle,
   and asserts `spctl --assess` passes.
4. Force-moves the `tip` tag, then creates or replaces the `tip` release and
   its `Costbar.zip` asset.

Without `--publish` every step but the last runs and the archive is left at
`dist/out/Costbar.zip` for inspection. `--skip-notarize` is for rehearsing the
build only; the script refuses to publish an un-notarized archive, which
Gatekeeper would block anyway.

## Verifying a build before publishing

```sh
dist/release.nu                       # build, sign, notarize, do not publish
codesign -dvv dist/out/Costbar.zip    # or against macos/build/Release/Costbar.app
spctl --assess --type execute --verbose macos/build/Release/Costbar.app
lipo -archs macos/build/Release/Costbar.app/Contents/MacOS/Costbar
```

The last command must print `x86_64 arm64`; a native-only XCFramework silently
produces a single-architecture app that Intel Macs cannot run.

## Changing the cask

The cask only needs editing when the artifact's shape changes — its name, the
minimum macOS version, the bundle identifier used by `uninstall quit:`, or the
paths under `zap`. Lint it against a local tap, since Homebrew will not inspect
a cask outside one:

```sh
brew tap uzaaft/costbar "$PWD"
brew style --cask uzaaft/costbar/costbar
brew untap uzaaft/costbar
```

Note that `brew tap` clones the committed tree, so commit the cask before
linting it.
