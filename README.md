# Costbar

Costbar is a macOS menu-bar dashboard for developer infrastructure and digital
subscription costs. Its provider-neutral core is Zig; its native UI is SwiftUI.

The macOS build uses a Zig-first native toolchain:

- Zig is the root build graph and the source of the C ABI.
- Zig produces `macos/CostbarKit.xcframework`, either native-only for fast local
  iteration or universal (`arm64` + `x86_64`) for distribution.
- A committed Xcode project builds, tests, signs, and bundles the Swift app.
- `macos/build.nu` invokes Xcode in a clean environment so Nix compiler and SDK
  variables cannot contaminate the Apple toolchain.
- A pinned Nix flake supplies Zig 0.16, Nushell, SwiftLint, and the repository's
  format/lint tools. Direnv enters that shell automatically.
- The Xcode configurations are `Debug`, `Release`, and `ReleaseLocal`; Zig
  release modes map to `ReleaseLocal`.

## Development environment

Requirements are macOS 14 or newer, Xcode, Nix with flakes enabled, and
optionally direnv.

```sh
nix develop
```

With direnv:

```sh
direnv allow
```

The shell deliberately uses the system Xcode SDK and linker. It strips the
`SDKROOT`, `DEVELOPER_DIR`, `NIX_CC`, `NIX_CFLAGS_COMPILE`, and `NIX_LDFLAGS`
variables that otherwise interfere with `zig`, `libtool`, and `xcodebuild`.

## Build and test

For normal macOS iteration, update the Zig XCFramework and then use the
Nushell/Xcode entry point:

```sh
zig build -Demit-macos-app=false
macos/build.nu
macos/build.nu --action test
```

The debug app is written to `macos/build/Debug/Costbar.app`. Release-local
builds use:

```sh
zig build -Doptimize=ReleaseFast -Demit-macos-app=false
macos/build.nu --configuration ReleaseLocal
```

The root Zig graph can also drive the entire pipeline:

```sh
zig build
zig build test
zig build run
```

`zig build` creates a universal XCFramework, asks Xcode for the app, and copies
the result to `zig-out/Costbar.app`. `zig build run` uses a native-only
XCFramework to keep edit/build/run cycles fast.

Useful build options:

```text
-Demit-xcframework=false
-Demit-macos-app=false
-Dxcframework-target=native
-Dxcframework-target=universal
-Doptimize=ReleaseFast
```

Run `make clean` to remove only generated Zig, Xcode, and XCFramework outputs.

## Architecture

```text
build.zig                         Root graph and public build options
src/build/                        Zig library/XCFramework/Xcode steps
include/costbar.h                 Stable C ABI
include/module.modulemap          CostbarKit Clang module
src/model.zig                     Provider-neutral domain model
src/provider.zig                  Type-erased provider interface
src/registry.zig                  Aggregation and failure isolation
src/providers/                    Provider-specific normalization
src/c_api.zig                     Zig-to-Swift JSON bridge
macos/Costbar.xcodeproj/          Native application and test targets
macos/build.nu                    Clean-environment Xcode entry point
macos/Sources/Costbar/            Swift wrapper, stores, and SwiftUI views
nix/devShell.nix                  Pinned development toolchain
```

The current core includes metered infrastructure billing, API organization
billing, local AI subscription quotas, recurring subscriptions, fixed-point
micros, per-currency totals, projections, credit, token classes, and provider
failure isolation. Provider credentials share one cached Keychain record and
tokens never cross the C ABI.

Without credentials, providers report unavailable and no total is invented.
Open the gear menu to save provider credentials and refresh live data:

- DigitalOcean: a token with `billing:read` and `droplet:read`.
- Cloudflare: the 32-character account ID and a token with Billing Read, plus
  Zone Read to price the per-zone plan tiers.
- Runpod: an API key with read access to account and billing data.
- Vercel: an access token and optional team ID or slug. The billing export is
  available to Pro and Enterprise teams.
- OpenRouter: an API key for spend and limits. An optional management key adds
  account credits and model-level activity.
- OpenAI API: an organization owner Admin API key. This is separate from a
  ChatGPT or Codex subscription and reads the organization Costs and
  Completions Usage APIs.
- Anthropic API: an organization Admin API key. This is separate from a Claude
  subscription and reads the organization Cost and Messages Usage APIs.
- GitHub: an organization name and token with organization Administration read
  permission. The organization must use GitHub's enhanced billing platform.
- Cursor: a Team Admin API key for invoice-reconcilable usage events and model
  token totals.

Costbar also supports fixed recurring costs without provider credentials. Add
monthly, quarterly, or yearly subscriptions in Settings; quarterly and yearly
amounts are normalized to a monthly equivalent while retaining their original
currency. Totals in different currencies remain separate rather than being
combined with an implicit exchange rate.

## Codex and Claude subscriptions

Codex and Claude subscriptions are tracked separately from OpenAI and
Anthropic API billing. Enable either integration explicitly under **AI
subscriptions** in Settings. Their token and quota reports do not contribute a
made-up dollar amount to the financial total; add the plan's fixed price under
**Recurring subscriptions** if you want it represented there.

For Codex, Costbar asks the installed, signed-in `codex` CLI app server for its
primary and secondary rate-limit windows. It also scans current local Codex
session logs for model and token counters. No API key is required, and prompt
or response text is never retained by Costbar.

For Claude, Costbar scans local Claude Code session logs for token counters.
Claude exposes subscriber rate limits to status-line commands after a response,
so click **Install Claude quota bridge** to copy that official feed into
Costbar's Application Support directory. Installation preserves and chains any
existing status-line command. **Restore previous Claude status line** removes
the bridge and restores the backed-up setting.

The local collectors retain only aggregate token classes, model names, quota
percentages, and reset times. Codex session data stays under `~/.codex`; Claude
session data stays under `~/.claude`; the Claude quota snapshot is stored at
`~/Library/Application Support/Costbar/claude-status.json`.

## Provider accounting notes

DigitalOcean's balance endpoint reports one account-level figure, so Costbar
also reads the current month's preview invoice to attribute that spend to the
products behind it — Droplets, Apps, Spaces. The balance stays authoritative
for the total, and anything the invoice has not caught up with is shown as its
own item rather than being hidden. Without the billing scope the breakdown
falls back to a single honest “Account usage” item.

Cloudflare quotes each subscription at its own billing cadence, so yearly and
quarterly plans are spread across the month they are being compared in. Plan
tiers are billed per zone and never appear in the account subscriptions feed,
so zone plans are read separately and de-duplicated against it. Metered usage
above plan allowances is in neither feed; the provider document model remains
open for a future billable-usage source.

Runpod combines month-to-date Pod, Serverless, and network-volume billing with
the account's existing prepaid credit balance and current hourly burn rate.

Vercel streams the current month's FOCUS v1.3 charge export. Costbar sums
invoice-facing billed cost, including negative credit or adjustment rows, and
groups the breakdown by Vercel service.

OpenRouter keeps its API-key limit window separate from account credit and
reconciles any spend that has not yet appeared in model activity.

OpenAI and Anthropic organization reports keep cached-input, cache-creation,
uncached-input, and output tokens distinct where their APIs expose them.

GitHub groups enhanced-billing net amounts by product and SKU. Cursor uses each
usage event's charged amount so its total can be reconciled against the team
invoice.
