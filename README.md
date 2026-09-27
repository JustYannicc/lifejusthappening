# lifejusthappening

A macOS menu bar app that takes a webcam photo every now and then and drops it straight into a Google Photos album. Over a year you get a pile of honest, unposed moments at your desk.

## How it works

- **Random gaps, counted only while you're there.** You pick a range (default 1.5–3 hours). The clock runs only while a display is on, the screen is unlocked and a human touched the keyboard or mouse in the last 5 minutes. Sleep, a locked screen or an AI agent driving the Mac while you're away don't count.
- **Agents don't count as you.** Computer-use agents post synthetic input, which resets every macOS idle timer. The app reads each event's source instead: hardware input comes from the kernel (PID 0), agent input carries the agent's PID. That needs Input Monitoring; only timestamps are kept, never keys.
- **Someone has to be in the shot.** If there hasn't been real input in the last minute, the frame goes through on-device face/upper-body detection first. Empty room means no photo, and it looks again after 5, 10, 20, then 40 minutes of active time.
- **Camera priority list.** Cameras are tried top to bottom. Every camera ever connected stays in the list; new ones show up at the bottom and you move them where you want. Continuity Camera starts switched off.
- **Clamshell aware.** With the lid closed the built-in camera is skipped, even though macOS still reports it as available. No webcam either (the usual office setup) means that photo is skipped and a new interval starts.
- **Metadata Google Photos understands.** Capture time (with UTC offset), GPS location and the camera's name go into EXIF, so photos land on the right day and on the map, even if they sat in the outbox while you were offline.
- **One album.** Everything goes into a single `lifejusthappening` album. After a reinstall the app finds that album again instead of making a second one. Nothing is kept locally after upload.
- **Old photos too.** The Google Photos section can upload an old folder (like the `Moment dd-MM-yyyy at HH-mm.jpg` archive from the imagesnap days) into the same album. The date from the filename is written into EXIF without re-encoding, it's resumable, and the originals aren't touched.
- **Pause** for 30 min, 1 h, 2 h, until tomorrow morning, or until you resume.

## Install

Requires macOS 14+.

```bash
git clone https://github.com/JustYannicc/lifejusthappening.git
cd lifejusthappening/LifeJustHappening
./build-app.sh
mv lifejusthappening.app /Applications/
open /Applications/lifejusthappening.app
```

The first launch opens Settings on whatever's missing (camera access, Google Photos). Input Monitoring and location live under Settings → Permissions. macOS remembers those grants as long as the app keeps the same code signature, so `build-app.sh` signs with the first code-signing identity in your keychain (a self-signed one is fine), or `$CODESIGN_IDENTITY` if you set it. With no identity it falls back to ad-hoc signing, and then every rebuild looks like a new app to macOS.

Then follow [docs/google-photos-setup.md](docs/google-photos-setup.md) to connect Google Photos (one-time, about 5 minutes).

## Checking the camera logic

```bash
LJH_SUPPORT_DIR=/tmp/ljh ./lifejusthappening.app/Contents/MacOS/LifeJustHappening --capture-once
```

This prints the lid state, your camera order and which camera took the shot (or why it skipped), then writes the photo to `/tmp/ljh/Outbox` instead of your real outbox. The camera permission prompt belongs to whatever launched it, usually your terminal.

## Development

```bash
cd LifeJustHappening
swift build
swift test
```

The layout, roughly:

| Folder | What's in it |
|---|---|
| `Scheduling/` | Active-time schedule, pause state, and system activity sampling (lid, displays, lock) |
| `Cameras/` | Priority rules, device discovery, one-shot capture, JPEG/EXIF encoding |
| `Upload/` | Google OAuth (loopback + PKCE), Photos Library client, the outbox queue |
| `App/` | The coordinator loop and menu bar plumbing |
| `Views/` | The popover |

## Privacy

- Photos go to your Google Photos and nowhere else. No analytics.
- The app can only add photos, create its own album, and see what it created itself. It can't read the rest of your library.
- Location is only read at capture time and only ends up in the photo's EXIF.
- Input Monitoring is used to record *when* real input last happened, never what it was.
- The Google OAuth client and refresh token live in `~/Library/Application Support/lifejusthappening/google-credentials.json`, readable only by you (0600). Not the Keychain: self-signed builds have no Team ID, so the Keychain would ask for your password after every rebuild.

## License

[MIT](LICENSE.md)
