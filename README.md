# SpyProtect

A macOS menu bar app that watches for activity while your screen is locked, so you know
if anyone tried to get in while you were away.

## What it logs

- **Failed unlock attempts** (with a webcam snapshot of whoever tried)
- **USB devices connecting/disconnecting**, with keyboard/HID-class devices flagged
  separately (the class code keystroke-injection "BadUSB" attacks impersonate)
- **Apps launched** while the screen was locked

Everything is scoped to the actual locked→unlocked window - nothing is logged while
you're using the machine normally. A real-time notification fires per event, plus one
summary notification when you unlock if anything happened.

It also includes a **Security Check** (right-click the menu bar icon) that audits
FileVault, the Guest account, Firewall, Remote Login, and Screen Sharing, and flags a few
other settings (Startup Security, lock-screen notification previews, AirDrop) that are
worth checking manually since they can't be read reliably from the command line.

## Installing a release build

1. Download `SpyProtect.zip` from the [Releases](../../releases) page and unzip it.
2. **This build is not notarized or signed with an Apple Developer ID**, so Gatekeeper
   will block it. On recent macOS, a plain right-click → Open often doesn't even offer
   an override - you may just see:

   > "Apple could not verify 'SpyProtect.app' is free of malware..."

   Two ways past it (only needed once):

   - **Terminal** (fastest): remove the quarantine flag the download attached -
     ```bash
     xattr -cr ~/Downloads/SpyProtect.app
     ```
     (adjust the path if you unzipped it somewhere else), then open it normally.
   - **System Settings**: after the block, open System Settings → Privacy & Security →
     scroll down to *"SpyProtect.app" was blocked to protect your Mac* → **Open Anyway**,
     then confirm once more when it launches.
3. On first launch, macOS will ask for **Notification** and **Camera** permission -
   both are needed for the core features (alerts, and the failed-unlock snapshot).
4. Move it to `/Applications` if you want it to stick around, and consider adding it as
   a Login Item (System Settings → General → Login Items) so it starts automatically.

## Building from source

Requires Xcode (for the macOS SDK) and its command-line tools.

```bash
git clone <this repo>
cd SpyProtect
./build_app.sh release
open SpyProtect.app
```

`./build_app.sh` (no argument) builds a debug binary for local iteration;
`./build_app.sh release` builds an optimized release build - both produce
`SpyProtect.app` in the project root, ad-hoc signed so macOS treats it as a real app
(own entry in Notification settings, stable TCC identity across relaunches, etc.).

## Running tests

```bash
swift test
```

## Privacy notes

- Snapshots and event history are stored locally only, under
  `~/Library/Application Support/SpyProtect/` - nothing leaves the machine.
- The camera only activates for about a second per failed unlock attempt; it is not
  continuously recording.
- "Clear All Logs" in the right-click menu wipes stored history at any time.
