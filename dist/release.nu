#!/usr/bin/env nu

# Build and package Costbar.app as the rolling `tip` release.
#
# Costbar publishes one moving `tip` release rather than tagged versions, so
# the Homebrew cask is `version :latest` with `sha256 :no_check` and never
# needs editing. Publishing is what changes for users, so it is opt-in behind
# --publish; without it the archive is left in dist/out for inspection.
#
# By default the app is ad-hoc signed, which needs no Apple account and which
# Gatekeeper does not trust: whoever installs it has to allow it once, and
# every build has a different code identity, so the Keychain re-prompts for
# each provider credential after an upgrade. --notarize produces a build with
# neither problem and requires a Developer ID Application certificate for the
# team plus credentials stored once:
#
#     xcrun notarytool store-credentials costbar \
#         --apple-id you@example.com --team-id FCWK5WR45W --password APP-SPECIFIC
#
# Like macos/build.nu this shells out to Xcode with a scrubbed environment, so
# Nix compiler and SDK variables cannot contaminate the Apple toolchain.

const developer_id = "Developer ID Application"
const team = "FCWK5WR45W"

def main [
    --notarize                             # Sign with Developer ID and notarize
    --keychain-profile: string = "costbar" # notarytool credential profile
    --publish                              # Move the tip tag and upload
] {
    let root = ($env.FILE_PWD | path dirname)
    let out = ($root | path join "dist/out")
    let app = ($root | path join "macos/build/Release/Costbar.app")
    let archive = ($out | path join "Costbar.zip")

    cd $root
    let commit = (^git rev-parse --short HEAD | str trim)
    let build_number = (^git rev-list --count HEAD | str trim)
    if (^git status --porcelain | str trim | is-not-empty) {
        error make {msg: "working tree is dirty; tip must be reproducible from a commit"}
    }

    print $"Building tip ($commit) as build ($build_number)…"
    rm -rf $out
    mkdir $out
    ^zig build -Doptimize=ReleaseFast -Dxcframework-target=universal -Demit-macos-app=false

    # The Release configuration ad-hoc signs, so a build needs no Apple
    # account. Notarizing overrides the identity rather than the project
    # carrying a certificate nobody but the publisher has.
    let signing = if $notarize {
        [$"CODE_SIGN_IDENTITY=($developer_id)" $"DEVELOPMENT_TEAM=($team)"]
    } else {
        []
    }

    (^env -i
        $"HOME=($env.HOME)"
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        xcodebuild
        -project ($root | path join "macos/Costbar.xcodeproj")
        -target Costbar
        -configuration Release
        $"SYMROOT=($root | path join 'macos/build')"
        $"CURRENT_PROJECT_VERSION=($build_number)"
        ...$signing
        build)

    check-architectures $app
    let leaf = (signing-authority $app)
    ^codesign --verify --strict --deep $app
    print $"Signed by ($leaf)"

    if $notarize {
        # A Development-signed bundle builds fine here and then fails to launch
        # on every other Mac, so the certificate is checked before anything
        # ships rather than discovered by whoever installs it.
        if not ($leaf | str starts-with $developer_id) {
            error make {msg: $"--notarize needs a ($developer_id) certificate, but the build is signed by '($leaf)'."}
        }
        ^ditto -c -k --keepParent --sequesterRsrc $app $archive
        print "Notarizing (this waits on Apple)…"
        ^xcrun notarytool submit $archive --keychain-profile $keychain_profile --wait
        ^xcrun stapler staple $app
        # The staple lands inside the bundle, so the archive is rebuilt around it.
        rm $archive
        ^ditto -c -k --keepParent --sequesterRsrc $app $archive
        ^spctl --assess --type execute --verbose $app
    } else {
        ^ditto -c -k --keepParent --sequesterRsrc $app $archive
        print "Ad-hoc signed: Gatekeeper will warn on first launch, and the"
        print "Keychain will re-prompt for provider credentials after an upgrade."
    }

    print $"\n($archive)"
    if $publish {
        publish-tip $commit $archive $notarize
    } else {
        print "Not published. Re-run with --publish to move the tip tag."
    }
}

def signing-authority [app: string]: nothing -> string {
    let authorities = (
        ^codesign -dvv $app
        | complete
        | get stderr
        | lines
        | where {|line| $line starts-with "Authority="}
        | each {|line| $line | str replace "Authority=" ""}
    )
    $authorities | get --optional 0 | default "ad-hoc"
}

# A native-only XCFramework silently yields a single-architecture app that
# Intel Macs cannot run, and nothing else in the pipeline would notice.
def check-architectures [app: string] {
    let archs = (^lipo -archs $"($app)/Contents/MacOS/Costbar" | str trim | split row " " | sort)
    if $archs != ["arm64" "x86_64"] {
        error make {msg: $"expected a universal build, got ($archs | str join ', ')"}
    }
}

# `tip` is a moving tag, so the release is replaced rather than added to: the
# cask always points at the same URL and must always find the newest build.
def publish-tip [commit: string, archive: string, notarized: bool] {
    let gatekeeper = if $notarized {
        ""
    } else {
        "\n\nThis build is ad-hoc signed, not notarized. Install it with `brew install --cask --no-quarantine costbar`, or allow it once under System Settings > Privacy & Security."
    }
    let notes = $"Rolling build of ($commit). Install with:\n\n```sh\nbrew tap uzaaft/costbar https://github.com/uzaaft/costbar\nbrew install --cask costbar\n```($gatekeeper)"

    ^git tag --force tip $commit
    ^git push --force origin "refs/tags/tip"

    let exists = (^gh release view tip | complete | get exit_code) == 0
    if $exists {
        ^gh release edit tip --notes $notes --target $commit
        ^gh release upload tip $archive --clobber
    } else {
        ^gh release create tip $archive --title "Costbar (tip)" --notes $notes --target $commit
    }
    print $"Published tip at ($commit)."
}
