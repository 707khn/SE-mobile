# SE-Mobile

A mobile app for attendance tracking and report management for employees of **Semey Engineering (SE-BTRZ)**.

---

## Overview

**SE-Mobile** is the Semey Engineering (SE-BTRZ) employee app, built with Flutter:
phone (Android), computer (Windows) and browser (for iPhone —
https://api.se-btrz.com/web/). The server is Flask + PostgreSQL in
`se-mobile-backend/`; deployment and maintenance are described in `deploy/README.md`.

---

## Key features

- **Login** with personnel number and password; new accounts and password resets
  get a one-time code. After entering the code, everywhere (phone, browser,
  computer) the user creates their own password of at least 8 characters
  (letters, digits, symbols), and the issued code expires; on the phone and in
  the browser, subsequent logins use a four-digit PIN. The password can be
  changed (or set, for those who don't have one) in "Settings" («Настройки»)
- **QR-code login on the computer** — like WhatsApp: the program shows a
  QR code, the user scans it on their phone ("Settings" → "Desktop login",
  «Настройки» → «Вход на компьютере») and confirms; no password is needed on
  the computer. The code lives for two minutes and can be used once
  (`se-mobile-backend/qr_login.py`)
- **Home screen** — today's entries/exits, canteen menu, news, announcements
- **Turnstile passes and timesheet** — your own; a manager sees their department
- **Payslips** — your own; the payroll group uploads payslips from 1C
- **Vacations, business trips, assignments, medical checkups**
- **Directory** of internal phone numbers
- **Confidential chat** (SE-chat), if its address is configured
- **Notifications** to the phone via Firebase, in the web version via a
  Telegram bot; in both cases without message content
- **Admin panel** — employees, accounts, permissions, the "Update" screen
- Kazakh and Russian languages, light and dark theme

---

## Roles

| Role | Who | Access |
|------|-----|--------|
| Employee | everyone | their own data |
| Manager | by job title (head, chief, director, chief …, deputy; but not "chief manager" or "chief specialist") or manually in the admin panel | passes and timesheet of their department |
| Payroll group | by job title or manually in the admin panel | uploading and viewing payslips |
| System administrator | the `admin` account | everything |

---

## Tech stack

- **App**: Flutter (Dart), GetX, http, shared_preferences,
  flutter_secure_storage, Firebase Messaging, excel/csv
- **Server**: Python 3.12, Flask, SQLAlchemy, PostgreSQL 16, gunicorn (gthread)
- **Build and release**: GitHub Actions, once a week (`.github/workflows/release.yml`)

---

## Repository layout

```
lib/                     the app
├── main.dart            entry point, login and profile refresh
├── screens/             screens
├── requests/            server requests
├── services/            notifications (FCM) and other background work
├── chat/                confidential chat tab
├── utils/               roles, translations, version, theme, storage
└── widgets/             shared widgets
se-mobile-backend/       server (app.py is the core; features are separate modules)
deploy/                  install, rollout, watchdog, backups, nginx — see deploy/README.md
tools/                   menu and directory uploaders, load testing
.github/workflows/       PR checks, release, external availability check
```

---

## API

Server: `https://api.se-btrz.com`. The list of endpoints is available at `GET /`
and in the `register_routes` function in `se-mobile-backend/app.py`; features
register their own endpoints in their modules (`it_requests.py`,
`business_trips.py`, etc.).

---

## Color scheme

| Element | Color |
|---------|------|
| Primary | `#018041` (green) |
| Button gradient | `#308f60` → `#49cc8b` |
| Error | `#b00B20` (red) |
| Background | `#fffafa` (snow white) |

---

## Company website

[https://se-btrz.com](https://se-btrz.com)

---

## Building the app

Releases happen once a week, on Mondays at 08:00 plant time: **Actions →
Выпуск** (Release) builds the APK and AAB, the web version and Windows under a
single number and publishes them to **Releases** — one release per version,
`v<version>-<number>`. If the app hasn't changed since the previous release,
the release is skipped. For an urgent release, use the "Run workflow" button
in the same place; the "emulator" checkbox adds a test on a virtual phone and
about twelve more minutes.

The version number is never edited by hand: the major digits (`1.32`) come from
`pubspec.yaml`, and the build number is the number of commits on `main`
(`.github/scripts/version.sh`), which is also the third digit: `1.32.267+267`.
The server picks up the APK from Releases on its own within ten minutes, and
phones offer to update — see `deploy/README.md`, "The build arrives on the
server by itself" («Сборка приезжает на сервер сама»).

### Signing key — do this once

Until there is a key, Android signs the build with a **debug** key, and that
key is regenerated on every clean machine. So every build has its own
signature, and a new version **will not install over the installed one**: the
phone will say "App not installed". For five hundred people this means
"uninstall and install again" on every update, losing the PIN and having to
re-enter the login.

Your own key makes the signature permanent. It is created by `keytool`, which
comes with Java. Java may not be installed on the work Windows machine (the APK
is built in Actions, Android Studio isn't needed), so it's easier to create the
key on the server and then download the file.

**On the server** (`ssh -l ubuntu 87.199.130.179`):

```bash
sudo apt install -y openjdk-17-jre-headless

keytool -genkeypair -v -keystore ~/se-mobile.jks -storetype PKCS12 \
    -keyalg RSA -keysize 2048 -validity 10000 -alias se-mobile \
    -dname "CN=AO Semey Engineering, OU=OITiS, O=AO Semey Engineering, L=Semey, C=KZ"
```

It will ask for a password twice, and that's the only thing you need to enter.
A PKCS12 keystore uses one password for everything, so the key password is the
same.

Next, convert the file to text — this whole line goes into the secret:

```bash
base64 -w0 ~/se-mobile.jks; echo
```

**Download the file and remove it from the server.** In PowerShell on your machine:

```powershell
scp ubuntu@87.199.130.179:~/se-mobile.jks .
```

and back on the server:

```bash
shred -u ~/se-mobile.jks
```

**Keep the `se-mobile.jks` file and the password outside the repository and
don't lose them**: without them the next version won't install over this one,
and everything goes back to "uninstall and install again" — this time for good.

Then add them under **Settings → Secrets and variables → Actions → New repository
secret**, four in total:

| Name | Value |
|---|---|
| `KEYSTORE_BASE64` | what you just copied |
| `KEYSTORE_PASSWORD` | the keystore password |
| `KEY_ALIAS` | `se-mobile` |
| `KEY_PASSWORD` | the same password (PKCS12 has only one) |

After that, the build log's «Чем подписано» ("What it's signed with") step will
show the owner name from your key instead of `CN=Android Debug`.

**Switching to your own key requires one uninstall.** A build signed with the
new key won't install over the old one, since the signature differs. You'll
have to uninstall the app and install it again once — after that, updates will
always install over it. It's best to do this now, before rolling out to all five
hundred phones.

---

## Desktop version (Windows)

This is the same app and the same server (`api.se-btrz.com`), built for
Windows: login with username and password, then with the PIN, and all the same
sections. Things the computer doesn't have are done differently:

| On the phone | On the computer |
|---|---|
| "Share" a report or payslip | The file is saved to `Downloads\SE-mobile`, and the message has an "Open folder" button |
| "Share" text (vacation, "About") | The text is copied to the clipboard |
| The PIN is entered with a finger | The PIN can also be typed on the keyboard: digits, numpad, Backspace |
| The "Back" button | Esc; inside an input field, the first Esc only leaves the field |
| Phone number in the directory — call it | The number is copied to the clipboard |
| Fingerprint | None: PIN only |
| Firebase notifications | None |
| Update: download the APK from the server and install over the old one | Download the archive from the server, close the app and extract it into the same folder, replacing files |

The window opens at 900 × 900 pixels: tabs on the left (Home, Turnstile,
Salary, Vacation, Menu), the screen on the right. When maximized, the content
stays in a centered column; when narrowed to phone width, the tabs move to the
bottom, like on the phone. Launching `SE-mobile.exe` a second time doesn't open
a second window but brings the already open one to the front. Login, PIN and
settings are stored per Windows user (`%APPDATA%\AO Semey Engineering\SemEng`):
on a shared computer, everyone has their own login.

The app used to be called SemEng. The folder with login and settings kept the
old name (`ProductName` in `windows/runner/Runner.rc`) so that updated users
aren't logged out; the archive name also stayed the same, because the server
looks for it. When updating, the installer removes old `SemEng.exe` files and
shortcuts by itself. Those who installed from the archive should, after
extracting the new version, run `SE-mobile.exe` instead and delete the old
`SemEng.exe` and its shortcut.

**Where to get it.** The **Build Windows** workflow (Actions → Build Windows →
Run workflow) puts two files into this version's release next to the APK:

- `SE-mobile-setup-<version>.exe` — the installer: installs without admin
  rights, with a Start menu shortcut; new versions install over it the same
  way. The most convenient option for distribution.
- `SemEng-windows-<version>.zip` — the same without installation: extract to
  any folder and run `SE-mobile.exe`. This is also what the server offers the
  app as an update.

The Visual C++ libraries sit next to `SE-mobile.exe`, so there's no need to
install the "Visual C++ Redistributable" separately. The build itself only runs
after changes to `windows/`: a Windows minute in Actions costs twice as much.

Like the APK, the archive arrives on the server from the release by itself
(`deploy/fetch-apk.sh`, every ten minutes), and the desktop version, like the
phone, says "Version … is out" on the home screen. The archive isn't built
with every version: if a release doesn't include it, the server keeps the
previous one. To make the browser call it an archive rather than an APK, update
the nginx config (`deploy/README.md`, "Update the nginx config", «Обновить
конфиг nginx») — it downloads fine without this, too.

**Building it yourself** (if Actions is unavailable). You need 64-bit Windows
10/11, Flutter 3.47.6 and Visual Studio 2022 or 2026 (or Build Tools) with the
"Desktop development with C++" workload. Developer Mode must be enabled in
Windows (`start ms-settings:developers`): without it Flutter can't build
plugins. Then, in the project folder, in a regular PowerShell:

```bat
flutter pub get --enforce-lockfile
flutter build windows --release
```

The result is in `build\windows\x64\runner\Release`: distribute this whole
folder (a lone `SE-mobile.exe` without the files next to it won't start).

The installer uses Inno Setup 6:
`"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" /DMyAppVersion=<version from pubspec> windows\installer\SE-mobile.iss`,
and the output file is in `build\installer`. For the server to distribute the
build as an update, an archive of the Release folder named
`SemEng-windows-<version>.zip` goes into the GitHub release
`v<version with "-" instead of "+">`.

**Testing against your own server** without touching the real one: the server
address is overridden at build time —
`--dart-define=API_BASE_URL=http://127.0.0.1:5000`.
