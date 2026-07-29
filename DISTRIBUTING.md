# Distributing notepad-aaf to other Macs

## Why the warning appears

> Apple は、"notepad-aaf.app" に Mac に損害を与えたり、プライバシーを侵害する
> 可能性のあるマルウェアが含まれていないことを検証できませんでした。

macOS Gatekeeper shows this when an app is **not notarized by Apple**. By default
`build-app.sh` signs the app *ad-hoc* (`codesign --sign -`), which is fine on the
machine that built it but is not a trusted identity anywhere else. Downloading or
AirDropping the app also attaches a `com.apple.quarantine` flag, which is what
triggers the check.

---

## Option A — open it anyway (no Apple account needed)

Do this **on the receiving Mac**. Good for sending to yourself or a colleague.

**Easiest:** strip the quarantine flag in Terminal:

```bash
xattr -dr com.apple.quarantine /path/to/notepad-aaf.app
```

Then it opens normally, forever.

**Or via the UI** (macOS 13/14): Control-click the app → **Open** → **Open**.

**On macOS 15 (Sequoia) and later** that Control-click shortcut was removed. Instead:
1. Double-click the app, let it be blocked.
2. **System Settings → Privacy & Security**, scroll to Security.
3. Click **Open Anyway** next to the notepad-aaf message, then confirm.

> Send the app as a **zip made with `ditto`** (`ditto -c -k --keepParent
> notepad-aaf.app notepad-aaf.zip`). Compressing with other tools, or emailing the
> raw `.app`, can strip permissions and break the signature.

---

## Option B — sign + notarize properly (no warning for anyone)

This is the real fix, and it requires a **paid Apple Developer Program membership**
($99/year). The certificates currently on this machine are *not* sufficient:

| Certificate you have | Works for distributing outside the App Store? |
|---|---|
| Apple Development | ❌ development/registered devices only |
| Apple Distribution | ❌ App Store submission only |
| **Developer ID Application** | ✅ **this is the one you need** |

### 1. Create a Developer ID Application certificate

You must be **Account Holder or Admin** on the team.

- Xcode → **Settings → Accounts →** select the team → **Manage Certificates → + →
  Developer ID Application**, or
- <https://developer.apple.com/account/resources/certificates> → **+** → *Developer
  ID Application*.

Verify it landed in your keychain:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 2. Store notarization credentials once

Create an **app-specific password** at <https://appleid.apple.com> (Sign-In and
Security → App-Specific Passwords), then:

```bash
xcrun notarytool store-credentials aaf \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

`aaf` is just a local profile name you pick.

### 3. Build, sign, notarize, staple — one command

```bash
SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=aaf \
./build-app.sh
```

That builds a universal binary, signs it with the hardened runtime and a secure
timestamp, uploads it to Apple, waits for the result, and staples the ticket so the
app validates even offline. It produces `notepad-aaf.zip` ready to send.

### 4. Confirm

```bash
spctl -a -vvv notepad-aaf.app     # expect: accepted, source=Notarized Developer ID
xcrun stapler validate notepad-aaf.app
```

---

## Architecture note

`build-app.sh` now builds a **universal** binary (arm64 + x86_64) by default, so it
runs on both Apple Silicon and Intel Macs. The previous builds were arm64-only and
would not have launched on an Intel Mac at all.

Use `UNIVERSAL=0 ./build-app.sh` for a faster arm64-only build while developing.
