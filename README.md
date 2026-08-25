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

To benchmark the local Codex and Claude session scanners against real data:

```sh
zig run -O ReleaseFast src/bench_local_usage.zig -lc -- \
  codex PERIOD_START_UNIX PERIOD_END_EXCLUSIVE_UNIX
zig run -O ReleaseFast src/bench_local_usage.zig -lc -- \
  claude PERIOD_START_UNIX PERIOD_END_EXCLUSIVE_UNIX
zig run -O ReleaseFast src/bench_local_usage.zig -lc -- \
  cache PERIOD_START_UNIX PERIOD_END_EXCLUSIVE_UNIX
```

To profile a full provider refresh and find out what the wall clock is spent on:

```sh
zig run -O ReleaseFast src/profile_refresh.zig -lc -framework Security -- \
  [--passes N] [--local | --codex --claude --opencode] \
  [--period START_UNIX END_EXCLUSIVE_UNIX]
```

It reports credential lookup, every HTTP request with status and size, each
provider's transport time against its parse time, the slowest requests, the
concurrent refresh the app actually performs against the critical path that
bounds it, and the CPU cost of aggregation and snapshot encoding. Tokens come
from the environment first (`DIGITALOCEAN_TOKEN`, `OVH_ENDPOINT`,
`OVH_APPLICATION_KEY`, `OVH_APPLICATION_SECRET`, `OVH_CONSUMER_KEY`,
`OVH_CLOUD_PROJECT_SERVICE`, `HCLOUD_TOKEN`, `CLOUDFLARE_TOKEN`,
`CLOUDFLARE_ACCOUNT_ID`, `RUNPOD_API_KEY`, `VERCEL_TOKEN`, `VERCEL_TEAM`,
`OPENROUTER_API_KEY`, `OPENROUTER_MANAGEMENT_KEY`, `OPENAI_ADMIN_KEY`,
`ANTHROPIC_ADMIN_KEY`, `XAI_MANAGEMENT_API_KEY`, `XAI_TEAM_ID`, `GITHUB_TOKEN`,
`GITHUB_ORGANIZATION`, `CURSOR_ADMIN_KEY`) and otherwise from the app's
Keychain items, which macOS prompts for because the profiler is not the signed
app. Token values are never printed. `--passes 2` (the default) shows a cold
pass and a warm one, so connection setup separates from server time.

Each invocation reports a fresh collector refresh and a second in-memory hit.
After the first run, the fresh collector can also reuse the persistent cache;
the `cache` mode measures dashboard restore without performing a refresh.

## Architecture

```text
build.zig                         Root graph and public build options
src/build/                        Zig library/XCFramework/Xcode steps
include/costbar.h                 Stable C ABI
include/module.modulemap          CostbarKit Clang module
src/model.zig                     Provider-neutral domain model
src/provider.zig                  Type-erased provider interface
src/registry.zig                  Aggregation and failure isolation
src/http.zig                      Zig HTTP transport and authentication
src/live_refresh.zig              Concurrent provider requests and pagination
src/local_usage.zig               Cached JSONL session scanner
src/simd/index_of.zig             Ghostty-inspired pure-Zig SIMD byte search
src/providers/                    Provider-specific normalization
src/c_api.zig                     Typed Zig-to-Swift C ABI
macos/Costbar.xcodeproj/          Native application and test targets
macos/build.nu                    Clean-environment Xcode entry point
macos/Sources/Costbar/            SwiftUI and thin platform/ABI adapters
nix/devShell.nix                  Pinned development toolchain
```

The current core includes metered infrastructure billing, API organization
billing, local AI subscription quotas, fixed-point
micros, per-currency totals, projections, credit, token classes, and provider
failure isolation. Provider credentials are stored as independent Keychain
items and are copied into Zig-owned memory for requests.

Without credentials, providers report unavailable and no total is invented.
Open the gear menu to save provider credentials and refresh live data:

- DigitalOcean: a token with `billing:read` and `droplet:read`.
- OVHcloud Public Cloud: an API endpoint (`ovh-eu`, `ovh-ca`, or `ovh-us`),
  application key and secret, consumer key, and Public Cloud project ID. The
  credential needs GET access to `/cloud/project/{project}/usage/current` and
  `/cloud/project/{project}/usage/forecast`.
- Hetzner Cloud: a read-capable project API token. Hetzner tokens are scoped to
  one project, so configure the project whose resources should be estimated.
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
- xAI (Grok) API: a team ID and Management API key. This reads historical API
  spend by model and the team's prepaid credit balance. SuperGrok consumer
  subscription quota is separate and has no public API.
- GitHub: an organization name and either a saved token or an explicitly
  selected signed-in GitHub CLI session. The selected identity needs
  organization Administration read permission and the organization must use
  GitHub's enhanced billing platform. In CLI mode Zig invokes `gh api`; the
  token is never exported to Costbar.
- Cursor: a Team Admin API key for invoice-reconcilable usage events and model
  token totals.

## Local coding-agent usage

Codex and Claude subscriptions are tracked separately from OpenAI and
Anthropic API billing. Enable either integration explicitly under **AI
subscriptions and agents** in Settings. Their token and quota reports do not
contribute a made-up dollar amount to the financial total.

For Codex, Costbar scans current local session logs for model, token, and
rate-limit counters. No API key is required, and prompt or response text is
never retained by Costbar.

For Claude, Costbar scans local Claude Code session logs for token counters.
Claude exposes subscriber rate limits to status-line commands after a response,
so click **Install Claude quota bridge** to copy that official feed into
Costbar's Application Support directory. Installation preserves and chains any
existing status-line command. **Restore previous Claude status line** removes
the bridge and restores the backed-up setting.

OpenCode is opt-in under the same section. Zig invokes the official
`opencode db --format json` interface with a period-bounded aggregate query
that selects only provider, model, cost, and token fields. Prompt, response,
tool, and file content are not queried. OpenCode's recorded model cost is
informational and excluded from the combined financial total because it can
overlap an API provider's bill or represent usage included in OpenCode Go.

The CLI costs roughly 400 ms of process start-up before it opens anything, so
its answer is cached under `~/Library/Caches/Costbar/local-usage/opencode-v1/`
and replayed while the database is unchanged, which takes a refresh from about
440 ms to under 1 ms. Freshness is decided by SQLite's own write markers — the
header change counter and page count, plus the write-ahead log's size,
checkpoint sequence, and salts — because the CLI bumps the database mtime just
by opening it, so an mtime-keyed cache would invalidate itself on every query.
A cache recorded for a different period is never reused, and when the CLI is
missing or fails, the last cached answer is reported with its original
timestamp instead of dropping the row.

The local collectors persist versioned, normalized per-file scan results under
`~/Library/Caches/Costbar/local-usage/`, so unchanged logs do not need to be
reparsed after Costbar restarts. Entries are invalidated by source size and
modification time. They contain only timestamps, token classes, model names,
quota data, and hashed source/deduplication identities—never source paths,
prompts, or responses. The Zig core also stores the last normalized dashboard
at `~/Library/Caches/Costbar/dashboard-v1.json`. On launch, the UI renders that
snapshot immediately, refreshes it asynchronously, and polls every five
minutes. Codex session data stays under `~/.codex`; Claude session data stays
under `~/.claude`; the Claude quota snapshot is stored at
`~/Library/Application Support/Costbar/claude-status.json`.

## Provider accounting notes

DigitalOcean's balance endpoint reports one account-level figure, so Costbar
also reads the current month's preview invoice to attribute that spend to the
products behind it — Droplets, Apps, Spaces. The balance stays authoritative
for the total, and anything the invoice has not caught up with is shown as its
own item rather than being hidden. Without the billing scope the breakdown
falls back to a single honest “Account usage” item.

OVHcloud uses the Public Cloud project's authoritative current-usage total and
forecast. The breakdown is grouped from OVHcloud's hourly, monthly, and typed
resource usage views while the root total remains authoritative.

Hetzner Cloud does not expose an invoice or historical billing endpoint through
the project API. Costbar therefore labels its figures as estimates, using the
project's current inventory and gross, VAT-inclusive pricing. Existing servers,
server backups, volumes, load balancers, Primary and Floating IPs, and snapshots
are included; resources deleted earlier in the period cannot be reconstructed.

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

xAI uses the official Management API's USD usage series grouped by billed
description and its separately reported prepaid-credit ledger. The management
key is distinct from an inference API key and cannot be replaced by a
SuperGrok login.

GitHub groups enhanced-billing net amounts by product and SKU. Cursor uses each
usage event's charged amount and usage kind, separating subscription-included,
usage-based, and API-key activity while keeping the total reconcilable to the
team invoice.
