# Cresca iOS — Sideload .ipa from MacBook

## 0. Prebuilt .ipa (no Mac needed, recommended)

1. On GitHub → Releases → latest → download `Cresca-iOS-unsigned.ipa`.
2. Self-sign it with **Sideloadly** (or AltStore) using your Apple ID
   (free ID = 7-day cert, refresh over Wi-Fi; $99/yr dev account = 1 yr).
3. iPhone → Settings → General → VPN & Device Management → Trust your
   Apple ID → open Cresca Music.
4. TrollStore (where your iOS version supports it) installs the same
   file permanently with no refresh.

Apple forbids installing unsigned apps, so the published file must be
signed by YOU on install — there is no tap-to-install .ipa. Steps 1–4
below are only for building from source instead.

MVP port (search + stream + lyrics + likes). No pods. Builds on Mac only —
Windows cannot emit an .ipa.

## 1. Create project (on MacBook, 2 min)
1. Xcode → File → New → Project → iOS → App → Name `Cresca`, Bundle ID `com.cresca.app`, Interface SwiftUI, Language Swift.
2. Replace generated `CrescaApp.swift` / `ContentView.swift` with `ios-sideload/CrescaIOSApp.swift` (single file).
3. Target → Signing & Capabilities → Team = your Apple ID, uncheck "Automatically manage" if you want manual.
4. + Capability → Background Modes → tick **Audio, AirPlay, PiP**.
5. `Info` → add `UIBackgroundModes = audio`, `NSAppTransportSecurity` stays default (all https).

## 2. Run on iPhone (no .ipa needed, free account)
1. iPhone → Settings → Privacy → Developer Mode → ON (iOS 16+).
2. Xcode → select your iPhone as run destination → ▶ Run. Unlock phone → Trust.
3. Free Apple ID = 7-day cert (re-run weekly). Paid $99/yr = 1-year cert.

## 3. Build the .ipa (to keep / share)
```bash
# on Mac, in project dir:
xcodebuild -scheme Cresca -sdk iphoneos -configuration Release archive \
  -archivePath build/Cresca.xcarchive
xcodebuild -exportArchive -archivePath build/Cresca.xcarchive \
  -exportPath build/ipa -exportOptionsPlist ExportOptions.plist
```
Minimal `ExportOptions.plist` (development sideload):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>method</key><string>development</string>
  <key>teamID</key><string>YOUR_TEAM_ID</string>
  <key>compileBitcode</key><false/>
</dict></plist>
```
Output: `build/ipa/Cresca.ipa`.

Or Xcode GUI: Product → Archive → Distribute App → Custom → Development → Export → `.ipa`.

## 4. Install the .ipa
- **AltStore / Sideloadly** (free ID, 7-day refresh, works over Wi-Fi).
- Or Xcode → Window → Devices and Simulators → select iPhone → + → pick `.ipa`.
- iPhone → Settings → General → VPN & Device Management → Trust your Apple ID.

## What was cut (intentionally)
NewPipeExtractor (JVM-only, no iOS equivalent), YouTube login, downloads,
offline cache, Live Updates, call-guard (iOS AVAudioSession handles it).
Audio comes from Invidious `adaptiveFormats` — if `inv.tux.pizza` dies or
403s, change `instance` in `CrescaStore` to another from `api.invidious.io/instances.json`.

## When to expand
Add playlists/downloads only after MVP plays reliably on device for a week.
