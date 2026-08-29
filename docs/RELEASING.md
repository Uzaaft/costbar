# Releasing

Costbar ships one rolling `tip` release rather than tagged versions. The `tip`
git tag and its GitHub release are both moved to whatever commit was last
published, so the download URL never changes and the Homebrew cask
(`Casks/costbar.rb`) is `version :latest` with `sha256 :no_check` — it needs no
edit when a build ships.

The trade-off is that Homebrew has no version to compare, so users upgrade with
`brew upgrade --cask --greedy costbar` rather than a plain `brew upgrade`.

## Signing

Tip is **ad-hoc signed** today. That needs no Apple account, and it costs
users two things:

- Gatekeeper refuses a quarantined copy, so they install with
  `--no-quarantine` or clear the flag by hand. The cask's caveats say so.
- Every build has a different code identity, so the login Keychain treats each
  upgrade as a new application and re-prompts for each provider credential.
  This is the same problem `9951fc4` fixed for local builds; it returns for
  distributed ones until tip is notarized.

Truly unsigned is not an option: macOS will not execute an unsigned arm64
binary at all, so `Release` ad-hoc signs rather than skipping the step.

Notarizing removes both problems. It needs a **Developer ID Application**
certificate for team `FCWK5WR45W` in the login Keychain, and credentials stored
once — the password is an app-specific password from appleid.apple.com, not the
Apple ID password:

```sh
xcrun notarytool store-credentials costbar \
    --apple-id you@example.com \
    --team-id FCWK5WR45W \
    --password APP-SPECIFIC-PASSWORD
```

Then pass `--notarize`. The Xcode project stays ad-hoc; the script overrides
the identity, so the repository never carries a certificate reference that only
the publisher can satisfy.

The `Debug` and `ReleaseLocal` configurations are unrelated to all of this and
keep signing with `Apple Development`.

## Publishing

From a clean checkout of the commit to publish:

```sh
dist/release.nu --publish              # ad-hoc
dist/release.nu --notarize --publish   # Developer ID and notarized
```

The script refuses to run against a dirty working tree, because `tip` has to be
reproducible from a commit. It then:

1. Builds a universal XCFramework and the `Release` configuration, stamping
   `CURRENT_PROJECT_VERSION` with the commit count so builds are ordered.
2. Asserts the app is universal. A native-only XCFramework silently yields a
   single-architecture app that Intel Macs cannot run, and nothing else in the
   pipeline would notice.
3. With `--notarize`, checks the leading signing authority really is a
   Developer ID certificate before submitting. A Development-signed build
   succeeds locally and then fails to launch everywhere else, so this is caught
   before anything ships rather than by whoever installs it.
4. Zips with `ditto --sequesterRsrc --keepParent`; when notarizing, submits and
   waits, staples the ticket, rebuilds the archive around the stapled bundle,
   and asserts `spctl --assess` passes.
5. Force-moves the `tip` tag, then creates or replaces the `tip` release and
   its `Costbar.zip` asset. Release notes mention the Gatekeeper step only for
   an un-notarized build.

Without `--publish` every step but the last runs and the archive is left at
`dist/out/Costbar.zip` for inspection.

## Verifying a build before publishing

```sh
dist/release.nu
codesign -dvv macos/build/Release/Costbar.app
lipo -archs macos/build/Release/Costbar.app/Contents/MacOS/Costbar
```

`codesign` prints `Signature=adhoc` for a default build and an
`Authority=Developer ID Application: …` line for a notarized one. `lipo` must
print `x86_64 arm64`.

## Changing the cask

The cask only needs editing when the artifact's shape changes — its name, the
minimum macOS version, the bundle identifier used by `uninstall quit:`, the
paths under `zap`, or the caveats once notarization lands. Lint it against a
local tap, since Homebrew will not inspect a cask outside one:

```sh
brew tap uzaaft/costbar "$PWD"
brew style --cask uzaaft/costbar/costbar
brew untap uzaaft/costbar
```

Note that `brew tap` clones the committed tree, so commit the cask before
linting it.
