# Setup, prompt by prompt

Ten minutes the first time. After that the phone just needs to be plugged in.

## 1. The Mac

**Xcode.** Install the full Xcode from the App Store, not just the command line
tools: the phone install goes through `devicectl` and the iOS SDK, which only
Xcode has. Open it once, accept the licence, and let it download the iOS
platform when it asks (Xcode > Settings > Components if it does not).

**An Apple ID in Xcode.** Xcode > Settings > Accounts > `+` > Apple ID. This is
what signs the app.

- A free Apple ID gives you a "Personal Team". Apps it signs stop launching
  after seven days, so you run `./goblincam.py install` again each week. It also
  caps you at three such apps on one phone.
- A paid Apple Developer Program membership signs for a year.

**Four Homebrew packages.**

```
brew install libimobiledevice xcodegen ffmpeg uv
```

| package | for |
|---|---|
| `libimobiledevice` | `idevice_id` sees the phone on USB; `iproxy` bridges a Mac port to it through usbmuxd |
| `xcodegen` | generates the Xcode project from `ios/project.yml` with your team and bundle id |
| `ffmpeg` | `ffprobe` reads the stream back so `status` can say what is flowing |
| `uv` | runs `goblincam.py` with its one Python dependency, nothing to install by hand |

**OBS.** Tools > WebSocket Server Settings > tick Enable WebSocket server >
Apply. Leave authentication on; the script reads the port and password from the
file OBS writes, so there is nothing to copy. OBS 28 or later has this built in.

## 2. The phone

**Plug it in** with a cable that carries data. Some charge-only cables look the
same and give you a phone that charges but never appears. Unlock the phone.

**"Trust This Computer?"** on the phone: Trust, then the passcode. On an Apple
silicon laptop the Mac may ask **"Allow accessory to connect?"**: Allow.

Check:

```
idevice_id -l
```

One line, the phone's UDID. Nothing means the cable or the trust prompt.

**Developer Mode.** iOS refuses to run an app signed for development until this
is on. Settings > Privacy & Security > Developer Mode > on. The phone restarts
and asks once more; confirm. The switch only appears once the phone has been
plugged into a Mac with Xcode on it, so if it is missing, plug in first.

## 3. Setup and install

From the repo:

```
./goblincam.py setup
```

It looks for your Apple team in the provisioning profiles Xcode keeps and
writes `config.json` (gitignored) with the team, a bundle id, and optionally
the phone model. Then it generates `ios/GoblinCam.xcodeproj`.

- Brand-new Mac with no iOS build behind it: `setup` generates the project
  without a team and tells you to open it in Xcode, pick your Team under the
  GoblinCam target > Signing & Capabilities, and run `setup` again. Or pass
  `--team ID` (developer.apple.com/account > Membership details).
- Two iPhones? `./goblincam.py setup --phone iPhone18,2` pins the model, which
  `xcrun devicectl list devices` shows in its last column.
- Want your own bundle id? `--bundle-id com.you.goblincam`. The default is
  `com.goblincam.<your team id>`, which cannot collide with anyone else's.

```
./goblincam.py install
```

Builds with `xcodebuild` and pushes the app with `devicectl`. The first build
registers the phone with your team and makes a provisioning profile; that is
the `-allowProvisioningUpdates` step and it needs the Apple ID from step 1.

**"Untrusted Developer"** the first time you open the app on the phone:
Settings > General > VPN & Device Management > tap the developer entry > Trust.
Paid accounts usually skip this.

**Camera access** on first open: Allow. It asks about the **local network** the
first time too: Allow. That is the Wi-Fi path, and USB does not use it.

**Video effects.** While a camera app is open, Control Center shows Video
Effects. Portrait, Studio Light, Reactions and Background must all be off; no
app can switch them off itself, so GoblinCam shows a red banner while any is
on. Center Stage is handled in the app and is already off.

## 4. Run it

```
./goblincam.py up
```

```
transport USB   Your iPhone -> 127.0.0.1:9000
camera    rotation=0 size=3840x2160 fps=30 clients=0 zoom=1.0 exposure=auto +0.0EV wb=auto focus=auto
stream    hevc 3840x2160 @ 30fps
```

If the app is not running, `up` launches it (the phone must be unlocked for
that). On the phone the dot in the status bar goes yellow while it waits and
green when a client is connected.

```
./goblincam.py obs on
```

Adds a media source called `GoblinCam` to the current OBS scene, or points the
existing one at the live transport, and shows it. Size it in OBS as you would
any source. Then frame, `lock`, `set focus`, and record.

## 5. Wi-Fi instead of the cable

Unplug. The app advertises itself on the local network; `up` finds it by
Bonjour and prints `transport Wi-Fi <host>:9000`; `obs on` re-points the source.
Both devices need to be on the same network, and the phone needs the local
network permission from step 3. Expect a lower safe bitrate than over USB.

## 6. When something is wrong

| you see | it means | do |
|---|---|---|
| `no iPhone on USB and nothing advertising GoblinCam` | the Mac cannot see the phone | data cable, unlock, Trust This Computer, `idevice_id -l` |
| `xcodebuild` fails on signing | no Apple ID in Xcode, or no team in `config.json` | Xcode > Settings > Accounts, then `setup` again |
| "Untrusted Developer" on the phone | first launch of a development-signed app | Settings > General > VPN & Device Management > Trust |
| the app will not open after a week | free Personal Team signature expired | `./goblincam.py install` |
| `phone said: error Connection refused` | the app is not running | unlock the phone, `./goblincam.py up` |
| `stream nothing on 127.0.0.1:9000` | tunnel is up, app is not serving | open GoblinCam on the phone; check the dot in its status bar |
| OBS log says `MP: Failed to find stream info` and the scene goes blank | the app died mid-session | `./goblincam.py up`, then `obs off` and `obs on` |
| the picture is squashed into the wrong shape | rotated while OBS was reading | `obs off`, `rotate <orientation>`, `obs on` |
| the picture is soft | autofocus settled on the background | `./goblincam.py set focus 0.7`, adjust, check the picture |
| red banner on the phone naming Portrait or Studio Light | a system video effect is on | Control Center > Video Effects, turn it off |
| exposure or colour drifts during a take | auto exposure or white balance still on | `./goblincam.py lock` once the shot has settled |
| `obs-websocket is switched off` | OBS's WebSocket server is not enabled | Tools > WebSocket Server Settings > Enable |
| `OBS is not running` | nothing on the websocket port | open OBS |
