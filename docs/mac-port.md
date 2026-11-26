# The macOS port

Where the port of G-Lite to macOS stands: what was done, in what order, what has been tried on real devices, and what's left.
The code is in `mac/`; how it's organised, file by file, is in the Mac section of `CLAUDE.md`.

## In short

- Swift (language mode 5), AppKit, IOKit HID, AVFoundation and ScreenCaptureKit. No dependencies.
- Ported from the C# file by file: the same protocol code, golden bytes, settings keys, preset texts, log and backup formats as
  Windows, so a `settings.txt` or a preset written by one reads on the other.
- `mac/build.sh` builds a universal `G-Lite.app` (arm64 and x86_64, macOS 12 and up), runs `GLite --selftest` first and stops if it
  fails, signs the app, then quits the running copy and installs it in `/Applications` (or `~/Applications`).
- Every device family Windows supports has its screen. Nothing on Windows' feature list is left to port.
- Almost everything is tested only on fake devices (`--demo`, the self-test). See [Tested on real devices](#tested-on-real-devices).

## Building and running

```
mac/build.sh
```

- Signing: `GLITE_SIGN` names the identity, else the first Apple Development certificate in the keychain, else ad-hoc. macOS ties
  the Input Monitoring permission to the signature, and an ad-hoc one changes at every build, so the permission was lost at each
  build until the app was signed with a real identity. If the permission still gets stuck: `tccutil reset ListenEvent org.g-lite.GLite`.
- Permissions the app asks for: Input Monitoring (to open a receiver that is also a keyboard, and for Echo's key presses), Screen
  Recording (Screen and Audio effects), Microphone (the headset's Test sidetone only).
- Command line: `GLite --demo` (fake devices, log in the temp folder, settings in `GLite/Demo`; also Demo Mode in the menus), `--demo --snapshot <folder>` (each screen drawn into a PNG, light
  mode), `--scan` (what a scan finds, read only), `--screen` (what the Screen and Audio effects see for two seconds), `--selftest`,
  `--iconset`, `--tray` (start in the menu bar only, used by Run at login).

## The steps, in order

The plan had nine steps; step 9 (Developer ID signing and notarisation) was dropped on purpose. After the first eight, each feature
Windows had was ported one after the other.

1. **Scan and HID++**: `HidThread` (the run loop input reports arrive on), `Port` (one IOHIDDevice), `Reader` (each user of a port gets
   every report, like a handle on Windows), `Hidpp` (HID++ 2.0 calls, HID++ 1.0 registers and uploads, feature reports). The scan finds
   direct, Bluetooth and receiver devices, their names, features, firmware and battery.
2. **App shell**: menu bar item with the slanted GL, window with the sidebar (devices, Settings, Logs), Dock icon when opened from the
   Finder, closing the window leaves it in the menu bar, Run at login as a launch agent.
3. **G515 screen**: effect, colour, speed, direction, brightness, live preview, Save to keyboard after a backup.
4. **Other devices** (non-G): brightness, pointer speed, SmartShift, invert scrolling, thumb wheel, backlight and its fade delays,
   Easy-Switch; sent live and sent again at each scan.
5. **Mice**: HID++ 2.0 mice with profile formats 2 to 8, the first save that sets up a mouse running only its factory profile, the
   Backups menu.
6. **Live keyboards**: G915, G915 TKL and G815 (saved into their onboard profile, format 4), G512 X 75, G915 X and other RGB keyboards.
7. **Zones**: the G560 and the 0x8070 keyboards (G213, G413, G512, G513...).
8. **Device table** (`DeviceTable.swift`, like `app/DeviceTable.cs`), then headsets, Litra lights, G510, the HID++ 1.0 mice (G9x,
   G500, G500s, G700, G5, G9), G600 and G300.
9. **Key picture and live effects**: the live key picture (ISO when the keyboard says so), Starlight, Echo, Rain, Fire, Aurora, Audio and
   Screen drawn key by key through 0x8081.
10. **Screen effect**: ScreenCaptureKit capture of a display and, on macOS 13 and up, the Mac's sound; the Screen box with its areas
    (move, resize, add, remove), monitor, intensity, update rate, smoothing, pauses (locked or asleep, low battery), keys per area.
11. **Presets** on every screen, with the Windows keys and texts.
12. **Mice, more**: the Bindings view (Keystroke... recording, the button spy), the live mouse picture, the mouse's own DPI button and
    profile changes followed.
13. **Zones keyboards, more**: Audio on the zones, the G512 and G513's per-key live effects (0x8080).
14. **G915 family, more**: G keys (Bindings view), onboard profiles M1-M3 (picker, M keys followed), Game mode (all keyboards that have
    it), the G512 X 75's light bar as its own zone, When idle (Dim after, Dim to, Turn off after) and the G515's idle watch while a
    preview isn't saved.
15. **Last pieces**: the Litra's live picture and Try effect, the headset's Test sidetone, the key picture's icons, the drag rectangle,
    the Game view's legends in the Mac's keyboard layout.
16. **Report and demo**: the device report (Report at the right of each device screen's title: what G-Lite reads from the device,
    read only, to copy or send in a GitHub issue when adding a device); the demo with every device Windows' demo lists (33, plus the
    G213), reachable from the menus (Demo Mode), its settings kept apart from the real devices'.

UI fixes along the way: title height, box margins and centring, sidebar icons of fixed width, every screen kept within Windows' window
size (868 x 730).

17. **Fixes after first real use** (2026-11-26):
    - the other devices' screen compares with what the device has when a send runs, as Windows does, so a backlight turned on
      again while the turn-off was still being sent is no longer skipped;
    - Demo Mode relaunches with `Process` (with `NSWorkspace.openApplication` both copies waited on each other and quit);
    - the menu bar item's battery column starts after the longest name;
    - the sidebar's G-Lite section (Settings, Logs) is pinned at the bottom, so it doesn't move as devices are found.
18. **The games' easter egg** (`Games.swift`): a click on the sidebar's G-Lite heading opens the virtual G515 TKL with Blocks, Snake
    and Mines, as Windows' G-Lite title does. Windows' version shows the fake keyboard's effect; the Mac's shows only the factory
    animation's rainbow (what Windows shows there too, its fake keyboard being new each time).

## Tested on real devices

| What | How | Result |
|---|---|---|
| MX Keys S, LIFT (Bluetooth) | `--scan`, then the other devices' screen | Read correctly; the backlight and DPI changed by the user read back as set |
| MX Keys S backlight (0x1982) | the screen, and direct writes | On, off, Automatic and Level taken at once and read back; the fade delays read back as set (the keys actually fading after them not watched). Plugged in, the keys light up only at the next key press, as the screen's note says |
| Demo Mode | the menu bar item's Demo Mode and Leave Demo Mode, clicked | Relaunches into the demo and back |
| Menu bar item, sidebar | used | Battery on the same line as a long name; G-Lite section stays at the bottom |
| Screen capture and sound | `--screen` | Colours of the areas and audio bands correct (sound checked with `afplay`) |
| Microphone list | the same discovery as Test sidetone | Built-in, Continuity and virtual microphones listed |
| Keyboard layout legends | Game view on a French layout | AZERTY legends shown |

Everything else has only run against the fake devices (`mac/Sources/Fake.swift`) and the self-test. In particular, never tried:

- **A receiver (C547 and others)**: the code assumes macOS shows the receiver's HID++ interface as one IOHIDDevice with both FF00
  collections. If that's wrong, nothing behind a receiver is found.
- **Every G device**: G515, G915 family, G512 X 75, zones keyboards, G560, mice, headsets, Litra, G510, G600, G300.
- **Writes to onboard memory** (G515, G915 family, mice, G9x pages, G300): the same bytes as Windows, compared in the self-test, but
  never sent to a real device from the Mac. A backup is always made first.
- **Interactions only simulated or not clicked**: the drag rectangle (simulated with synthetic events), Try effect, Test sidetone,
  the light bar's Per zone switch, the Game view's clicks, the report's Copy and Open GitHub issue.
- **The device report on a real device**: only on the fakes so far. Its first real use is the next step for adding devices.

## What's left

### To try on hardware, first

1. A keyboard or mouse on a receiver, with `GLite --scan`: does the scan find it? This checks the one-device assumption above. Then
   its Report, to compare with the Windows report of the same device.
2. Then each screen with its device, starting with what's read only, then a live change, then a save.
3. The ISO case of the Game view's legends (macOS swaps the key left of 1 and the one beside the left Shift on an ISO keyboard).

### Known differences from Windows

- The MX Keys S's own support is being added on Windows; it comes to the Mac at the next sync.
- The click on Windows' G-Lite title opens the games, not the demo; the demo is `--demo` only on Windows, and Demo Mode in the menus on
  the Mac.
- The slot in use (M1-M3) is checked on load and on the keyboard's events; Windows also checks it when the window comes to the front,
  for a change made while G-Lite was closed.
- Picking an effect for one zone of a G512 or G513 while a per-key effect runs on All: the per-key effect sets every zone to Off again
  every 2 s, which overrides that zone (not checked against Windows).
- The headset screen has no headset picture.
- A device with 0x40A0 and a coarse battery (the K295) gets the other devices' screen instead of Windows' info page with its media keys.
- When idle is hidden while a live effect runs, since a live effect isn't saved.

### Not planned

- Developer ID signing and notarisation (step 9 of the plan), so the app can be shared without Gatekeeper's warning. Without it, a copy
  given to someone else has to be opened with right click, Open, or allowed in System Settings.
- A release workflow for the Mac app (Windows has `.github/workflows/release.yml`).
- The website (`site/`) doesn't mention the Mac version yet.

## Keeping it in step with Windows

- A change to the C# protocol code goes to the same place in the Swift (the file headers say which C# file each one comes from).
- A new golden-bytes check in `app/SelfTest.cs` gets its twin in `mac/Sources/SelfTest.swift`.
- The Mac section of `CLAUDE.md` describes each Swift file; keep it up to date, and this file's lists too.
