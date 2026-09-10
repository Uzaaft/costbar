# iPhone companion

Build the usage policy XCFramework from the repository root first:

```sh
zig build usage-kit -Doptimize=ReleaseSafe
```

Then open `mobile/CostbarMobile.xcodeproj` and run `CostbarMobile` on iOS 17 or newer.
Rebuild the kit after changing `src/usage_policy.zig`, `src/usage_api.zig`, or its
header. The generated `mobile/CostbarUsageKit.xcframework` is ignored by Git.
The app embeds small/medium Home Screen widgets and circular/rectangular/inline
Lock Screen widgets. A watchOS app is not included.

The Mac remains the usage collector. Private CloudKit sync transfers provider
names, costs and quota windows. Sessions, prompts and responses stay on the Mac.
Provider credentials never enter the snapshot; on a signed build they sync only
between Macs through iCloud Keychain (see below). Every saved Codex account refreshes independently and syncs as a
separate source, including accounts whose usage is temporarily unavailable. The
active Codex selection controls ordering; it does not hide other accounts.
Use one publishing Mac and the same Apple Account on both devices.

## Shared usage policy

`src/usage_policy.zig` owns freshness, quota activity, alert eligibility and alert
identities. `src/usage_api.zig` exposes those rules, highest-quota selection and
next semantic transition times through a small C ABI. Inputs use fractional Unix
seconds; Swift owns all buffers and Zig borrows them only during each call.
Existing alert identities are preserved so this migration does not resend alerts.

The policy kit contains macOS arm64/x86_64, iOS arm64, and Simulator arm64/x86_64
static libraries. Both the app and widget link it; the Mac also links it because
it shares the snapshot model. It excludes provider collection and networking.
Normal `zig build` and `zig build test` generate the required kit for the Mac.

Swift retains Codable transport, CloudKit, file protection, notification delivery,
WidgetKit scheduling, UI state, localized text and currency formatting. Zig
returns decisions and timestamps; it does not call Apple APIs or persist data.

## Signing and setup

All targets need the same developer team and `iCloud.com.costbar.app` container.
The phone and widget share `group.com.costbar.mobile`. Entitlements are committed
beside their Info.plist files. The phone also enables Push Notifications and
background remote notifications/fetch.

The normal Mac build works without iCloud provisioning and disables the sync
toggle. Build the iCloud-enabled variant with:

```sh
xcodebuild -project macos/Costbar.xcodeproj -scheme Costbar \
  -configuration Debug CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_ENTITLEMENTS=Resources/MobileSync.entitlements \
  COSTBAR_MOBILE_SYNC_ENABLED=YES -allowProvisioningUpdates build
```

The same entitlements file carries the `keychain-access-groups` entry that lets
Costbar store provider credentials in the data protection keychain as
synchronizable items, so iCloud Keychain carries them end-to-end encrypted to
your other Macs. On first launch the signed build moves existing login-keychain
items across (merging account lists another Mac already synced) and then removes
the local copies. Unsigned and ad-hoc builds cannot reach that keychain and keep
credentials in the login keychain on this Mac; **Settings → General → Credentials**
shows which applies.

This requires a registered development Mac and matching profile. Do not set
`COSTBAR_MOBILE_SYNC_ENABLED` without signing with the CloudKit entitlement.
Distribution also requires provisioning the release bundle ID and deploying the
CloudKit development schema to production in CloudKit Console.

On the signed Mac build, enable **Settings → General → iPhone companion**.
Open the iPhone app and pull to refresh. Enable quota alerts in its Settings;
permission is requested only then. Available thresholds: 50, 75, 80, 90, 95, 100%.
Add widgets through the Home Screen or Lock Screen widget gallery. Widgets show
the first currency total and highest active quota; the app shows every currency.

## Updates and privacy

The Mac uploads after publishing a refreshed dashboard. Saving provider settings
requests a refresh immediately; if one is already running, a follow-up refresh
reloads the saved credentials after it finishes. Multiple saves during the same
request coalesce into one follow-up. One private CloudKit
`UsageSnapshot` record named `current-usage` stores versioned JSON in a Bytes
field named `payload`. The first development upload creates the schema.
A silent query subscription handles creation, update and deletion. Phone refresh
updates the shared cache, reloads widgets and evaluates alerts. Foreground and
background refresh provide further opportunities; widgets also fetch directly
when WidgetKit requests a timeline.

iOS controls silent pushes, background execution and widget refresh timing.
This is latest-synced usage, not a continuous stream. Notifications can be delayed
or absent if iOS does not grant background execution. Data at least 30 minutes old
is stale and cannot trigger alerts; expired quotas cannot trigger alerts either.
An alert is deduplicated by provider/account, quota, reset and threshold. Without
a reset time, alerts are limited to once per UTC day.

Disabling sync deletes the remote snapshot. Offline phones retain cached usage
with its original age until their next successful fetch. An iCloud account change
clears the phone cache and alert history.

## Validation

```sh
zig build usage-kit test-usage -Doptimize=ReleaseSafe
swift test --scratch-path /tmp/costbar-usage-tests
xcodebuild -project mobile/CostbarMobile.xcodeproj -scheme CostbarMobile \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/costbar-mobile CODE_SIGN_IDENTITY=- build
```

Use simulator signing when launching. `CODE_SIGNING_ALLOWED=NO` omits the
entitlement section CloudKit requires at runtime.

The shared `CostbarMobile` scheme also includes UI tests. On an English-language
iPhone simulator, run `xcodebuild test` with that scheme and the simulator's
explicit destination ID. The notification check enables permission if needed,
sends a test notification, checks the system banner, and restores the app's quota
alert toggle. If permission was previously denied, enable it in iPhone Settings
before running. The Home Screen check requires an installed Costbar widget and
a live synced snapshot; it finds the widget without changing the Home Screen.
Screenshots are saved in the test result bundle. These checks verify foreground
local notification delivery and rendered widget data, not background APNs delivery.

Zig tests cover policy boundaries and the C ABI. Swift-to-Zig tests cover
snapshot versions, multiple currencies, alert deduplication,
reset windows, and stale/unavailable/expired/below-threshold suppression.
Widget tests also verify scheduled quota resets and freshness expiry without
another network fetch.

Before release, verify on signed devices using the same Apple Account:

1. Mac refresh reaches iPhone with matching costs and quotas.
2. Background phone receives updates and reloads its widgets.
3. Crossing a threshold triggers one notification, repeated refresh does not,
   and a new reset window can alert again.
4. Home Screen and Lock Screen layouts, Dynamic Type and VoiceOver work.
5. Offline/stale usage is labeled correctly without invented quota resets.
6. Disabling sync clears the phone after its next successful fetch.

CloudKit schema deployment, APNs delivery and visual device checks remain
required release validation; compilation alone does not prove these flows.

## Simulator preview

A Debug build accepts a JSON `UsageSnapshot` in the `COSTBAR_PREVIEW_JSON`
environment variable (use `SIMCTL_CHILD_COSTBAR_PREVIEW_JSON` with `simctl launch`).
It labels the dashboard “SAMPLE” and skips cloud fetches and
cache writes. Relaunch without that variable to return to live sync. Release
builds ignore this variable.

Live simulator sync requires signing in to an Apple Account in simulator Settings;
it does not inherit the Mac's account. Background App Refresh may be unavailable
in the simulator, so use a real device for final background-delivery validation.

## Verified development behavior

On 2026-09-08, the signed iOS 26.2 iPhone simulator received live usage from the
publishing Mac. Xcode UI checks verified a local notification banner and an
installed Home Screen widget with synced spending, quota usage and snapshot age.
The widget was also visually checked after correcting its light-appearance
contrast and shortening the visible account label.

The simulator's SpringBoard log showed a real CloudKit notification arriving on
`com.apple.icloud-container.com.costbar.mobile`, then rejected its background
delivery: “Content-available push notifications are only supported on-device for
iOS, watchOS, and tvOS.” A simulated content-available push did not produce the
app's remote-update callback either. This verifies subscription routing to the
simulator, but not background app refresh or threshold notification delivery.
Complete that final check on a physical iPhone; repeating simulator pushes cannot
establish it on this runtime.
