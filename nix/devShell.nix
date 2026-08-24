{
  mkShell,
  lib,
  stdenv,
  alejandra,
  nushell,
  shellcheck,
  swiftlint,
  typos,
  zig,
}:
mkShell {
  name = "costbar";

  packages =
    [
      # Build
      zig

      # Scripting
      nushell

      # Formatting and linting
      alejandra
      shellcheck
      typos
    ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      swiftlint
    ];

  shellHook = lib.optionalString stdenv.hostPlatform.isDarwin ''
    # On macOS, unset the SDK and compiler variables injected by Nix. Costbar
    # relies on the system Xcode installation.
    unset SDKROOT
    unset DEVELOPER_DIR
    unset NIX_CC
    unset NIX_CFLAGS_COMPILE
    unset NIX_LDFLAGS
    unset LD
    unset CC
    unset CXX
    unset CFLAGS
    unset CPPFLAGS
    unset LDFLAGS

    # Some dependencies inject xcrun wrappers. Keep the system Apple
    # toolchain first so Zig, libtool, lipo, and xcodebuild agree on the SDK.
    export PATH=$(echo "$PATH" | awk -v RS=: -v ORS=: '$0 !~ /xcrun/ || $0 == "/usr/bin" {print}' | sed 's/:$//')
    export PATH="/opt/homebrew/opt/llvm/bin:/opt/homebrew/bin:/usr/local/opt/llvm/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
  '';
}
