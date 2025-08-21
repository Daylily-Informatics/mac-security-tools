# Laptop Recent Changes Review

If you'd like to know about recent changes to your mac laptop, here are some quick tools.

# Manual Checks.

## Quick GUI (no Terminal)

- System Information → Installations
-  → About This Mac → System Report…
- In the sidebar: Software → Installations.
- Click the Install Date column to sort, then look at the last 3 days.
(This view is backed by /Library/Receipts/InstallHistory.plist and includes macOS updates, App Store app updates, and any .pkg installs.)

## App Store updates only

- Open App Store → click your profile → Updates.
  You’ll see Updated Recently with per‑app dates.
  That alone may be enough. If you want a concise, exportable log that also includes Homebrew and other changes, run the script below.

# SW To Help

Run the following:

```bash
bash bin/mac_software_changes_last3d.sh --help
```

And for 3d back:
```bash
bash bin/mac_software_changes_last3d.sh \
  --start-date "$(date -v-3d +%s)" \
  --end-datetime "$(date +%s)" \
  | tee ~/Desktop/changes-$(hostname)-$(date +%Y%m%d%H%M).txt

```

# For iPhones

---

## On the iPhone (iOS)
Apple doesn’t expose a retroactive, system‑wide “software changes” log on personal devices (that exists only via MDM). Here’s what you *can* get without MDM:

1. **App updates in the last 3 days**
 - Open **App Store** → tap your **profile** (top right) → **Updates**.
 - Scroll under **Updated Recently**. Each app shows the date it was updated. You can scan for items marked “Today”, “Yesterday”, or “2–3 days ago”.

2. **System updates**
 - **Settings → General → Software Update** → tap **More Info** (when available) to see the most recent iOS update details and install date/window.
 - **Settings → General → About → iOS Version** (tap the version row). On recent iOS, this reveals the **build** and sometimes install information.

3. **Configuration profiles (if any)**
 - **Settings → General → VPN & Device Management** shows profiles or device management enrollments added/removed (not timestamped, but useful to confirm changes).

> **If you need an audit trail going forward on iOS:**  
> - The only reliable methods are (a) enrolling the phone in an **MDM** (e.g., a personal Jamf/Mosyle tenant) which logs installs/updates, or (b) connecting to a Mac and using **Apple Configurator 2**/**Console** to *stream and save* device logs from the `installd` process while changes happen. iOS does not keep a user‑accessible historical install log you can fetch after the fact.

---

## Notes & caveats
- The **Install History** on macOS is authoritative for Apple updates, App Store updates, and any `.pkg` installs. It does **not** record pure drag‑and‑drop app copies unless the app bundle’s modification time changed in the last 3 days (the script captures that under “Application bundles touched”).
- **Unified logs** are best‑effort; they rotate and aren’t a full audit trail.
- **Homebrew** sections cover both **formulae** (CLI) and **casks** (GUI apps).
- Run the script as your user; it will prompt for **sudo** to inspect system LaunchDaemons.

If you want, I can fold the script into a minimal `launchd` job so each Mac drops a daily diff on your Desktop; you’ll have a continuous history to refer to.
