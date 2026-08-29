#!/usr/bin/env nu

# Build, sign, notarize, and package Costbar.app as the rolling `tip` release.
#
# Costbar publishes one moving `tip` release rather than tagged versions, so
# the Homebrew cask is `version :latest` with `sha256 :no_check` and never
# needs editing. Publishing is what changes for users, so it is opt-in behind
# --publish; without it the archive is left in dist/out for inspection.
#
# Like macos/build.nu this shells out to Xcode with a scrubbed environment, so
# Nix compiler and SDK variables cannot contaminate the Apple toolchain.
#
# Notarization needs credentials stored once, under the name passed to
# --keychain-profile:
#
#     xcrun notarytool store-credentials costbar \
#         --apple-id you@example.com --team-id FCWK5WR45W --password APP-SPECIFIC

def main [
    --keychain-profile: string = "costbar" # notarytool credential profile
    --skip-notarize                        # Package without notarizing
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

    (^env -i
        $"HOME=($env.HOME)"
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        xcodebuild
        -project ($root | path join "macos/Costbar.xcodeproj")
        -target Costbar
        -configuration Release
        $"SYMROOT=($root | path join 'macos/build')"
        $"CURRENT_PROJECT_VERSION=($build_number)"
        build)

    # A Development-signed bundle builds fine here and then fails to launch on
    # every other Mac, so the certificate is checked before anything ships
    # rather than discovered by whoever installs it.
    let authorities = (
        ^codesign -dvv $app
        | complete
        | get stderr
        | lines
        | where {|line| $line starts-with "Authority="}
        | each {|line| $line | str replace "Authority=" ""}
    )
    let leaf = ($authorities | get --optional 0 | default "unsigned")
    if not ($leaf | str starts-with "Developer ID Application") {
        error make {msg: $"Release build is signed by '($leaf)', not a Developer ID Application certificate. Every other Mac would refuse to launch it."}
    }
    ^codesign --verify --strict --deep $app
    print $"Signed by ($leaf)"

    ^ditto -c -k --keepParent --sequesterRsrc $app $archive

    if $skip_notarize {
        print "WARNING: skipped notarization. Gatekeeper will block this archive."
    } else {
        print "Notarizing (this waits on Apple)…"
        ^xcrun notarytool submit $archive --keychain-profile $keychain_profile --wait
        ^xcrun stapler staple $app
        # The staple lands inside the bundle, so the archive is rebuilt around it.
        rm $archive
        ^ditto -c -k --keepParent --sequesterRsrc $app $archive
        ^spctl --assess --type execute --verbose $app
    }

    print $"\n($archive)"
    if $publish {
        if $skip_notarize {
            error make {msg: "refusing to publish an un-notarized build"}
        }
        publish-tip $commit $archive
    } else {
        print "Not published. Re-run with --publish to move the tip tag."
    }
}

# `tip` is a moving tag, so the release is replaced rather than added to: the
# cask always points at the same URL and must always find the newest build.
def publish-tip [commit: string, archive: string] {
    let notes = $"Rolling build of ($commit). Install with:\n\n```sh\nbrew tap uzaaft/costbar https://github.com/uzaaft/costbar\nbrew install --cask costbar\n```"

    ^git tag --force tip $commit
    ^git push --force origin $"refs/tags/tip"

    let exists = (^gh release view tip | complete | get exit_code) == 0
    if $exists {
        ^gh release edit tip --notes $notes --target $commit
        ^gh release upload tip $archive --clobber
    } else {
        ^gh release create tip $archive --title "Costbar (tip)" --notes $notes --target $commit
    }
    print $"Published tip at ($commit)."
}
