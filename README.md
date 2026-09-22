# GoblinCam

An iPhone as a 4K camera for OBS on a Mac, over the USB cable, with focus,
exposure, white balance and orientation set from the terminal.

Every step is a command, so an agent can run the camera for you. The repo ships
a [Claude Code skill](.claude/skills/goblincam/SKILL.md): open Claude Code in
this directory and say "bring the phone camera into OBS".

## Why not Continuity Camera

Continuity Camera hands macOS one thing: 1920x1080, landscape, no controls.
A vertical shot is the middle 9:16 column of that, about 608 pixels wide,
scaled up. Center Stage picks its own zoom and drifts while you talk. Auto HDR
re-grades the picture mid-take.

GoblinCam sends 3840x2160 straight off the sensor, HEVC or H.264 in hardware,
at whatever bitrate you set. Turn it to portrait and it is 2160x3840 with nothing
thrown away. Center Stage and HDR are off. Exposure, white balance and focus
lock where you put them.

| | frame | controls |
|---|---|---|
| Continuity Camera | 1920x1080, landscape only | none |
| GoblinCam | 3840x2160 or 2160x3840 | lens, fps, codec, bitrate, zoom, focus, exposure, white balance, orientation |

The cost is latency: the picture reaches OBS half a second to a second late.
Right for recording, where you fix that afterwards. Wrong for a live call.
See [Audio sync](docs/SYNC.md).

## What you need

- A Mac with Xcode 15 or later and an Apple ID signed in to it. A free Apple
  ID works; its apps expire after seven days, so you reinstall weekly. A paid
  developer account signs for a year.
- An iPhone on iOS 17 or later and a cable that carries data.
- OBS 28 or later (it has the WebSocket server built in).
- Four Homebrew packages: `libimobiledevice` (the USB tunnel), `xcodegen` (makes
  the Xcode project), `ffmpeg` (reads the stream back), `uv` (runs the script).

No App Store, no TestFlight, no paid build service. The app installs straight
from your Mac on a development certificate.

## Quick start

```
brew install libimobiledevice xcodegen ffmpeg uv
git clone https://github.com/midasvalley/goblincam.git && cd goblincam
./goblincam.py setup        # finds your Apple team, writes config.json, makes the Xcode project
./goblincam.py install      # builds the app and puts it on the plugged-in phone
./goblincam.py up           # opens the USB tunnel, launches the app, reports the stream
./goblincam.py obs on       # adds a GoblinCam media source to the current OBS scene
```

The phone and the Mac each show a few prompts along the way (Trust This
Computer, Developer Mode, camera access). [docs/SETUP.md](docs/SETUP.md) walks
through every one.

## Commands

```
./goblincam.py setup [--team ID] [--bundle-id ID] [--phone MODEL]
./goblincam.py install
./goblincam.py status           # phone, tunnel, camera state, what the stream is
./goblincam.py up               # USB if plugged in, else Wi-Fi; launches the app if it is not running
./goblincam.py down             # close the USB tunnel
./goblincam.py obs on           # show the GoblinCam source in the current scene
./goblincam.py obs off          # hide it; the phone stops encoding
./goblincam.py obs continuity   # swap to Apple's Continuity Camera in the same spot
./goblincam.py rotate portrait  # portrait | landscape | portrait-flipped | landscape-flipped
./goblincam.py lock             # freeze exposure and white balance where they are
./goblincam.py auto             # hand them back to the camera
./goblincam.py set focus 0.7    # zoom bias iso shutter temp tint focus bitrate
./goblincam.py set exposure on  # exposure wb focuslock: on | off
./goblincam.py state            # one line: rotation, size, fps, clients, exposure, wb, focus
```

`obs on` creates the media source if the scene does not have one and points it
at whichever transport is live. Hiding the source drops the socket, which
stops the phone encoding and keeps it cool.

## Setting the look

Start on the defaults: everything auto, HDR and Center Stage off. Frame the
shot, let the camera settle, then:

```
./goblincam.py lock             # exposure and white balance stay where they landed
./goblincam.py set focus 0.7    # a lens position from 0 (close) to 1 (far)
```

`lock` leaves focus alone on purpose. Autofocus does not reliably land on a
person sitting still in front of a busier background, and a locked lens that
lands soft cannot be nudged back without walking over to the phone. Set the
position as a number and check the picture. Setting any number turns manual
control on for that thing: `set iso 200` switches exposure to manual, `set temp
5200` switches white balance to manual. `auto` hands both back.

| key | value | what it does |
|---|---|---|
| `zoom` | 1 to the lens's max | digital zoom factor |
| `bias` | -3 to 3 | exposure compensation in EV, while exposure is auto |
| `iso` | the format's range | manual exposure: ISO |
| `shutter` | 24 to 2000 | manual exposure: 1/n second |
| `temp` | 2500 to 8000 | manual white balance: kelvin |
| `tint` | -50 to 50 | manual white balance: green to magenta |
| `focus` | 0 to 1 | lens position, and locks focus |
| `bitrate` | 5 to 120 | Mb/s, changed live without a restart |
| `exposure` | on / off | lock exposure at its current value |
| `wb` | on / off | lock white balance at its current value |
| `focuslock` | on / off | lock focus at its current position |

Lens, size (4K or 1080p), frame rate and codec are on the phone's own screen.

## Orientation

```
./goblincam.py rotate portrait
```

Turns the sensor's output, then turns the phone in its mount yourself. The
command hides the OBS source, turns the camera, and shows the source again,
because a rotation changes the stream's dimensions and OBS keeps the size it
read when it connected. Rotating with a reader attached can leave the picture
squashed into the old shape. If that ever happens, `obs off`, `rotate`, `obs on`.

The app starts in landscape. `obs on` relaunches the app when it has to take
the camera back from Continuity, which resets rotation and focus, so set those
after `obs on`, not before.

## How the picture gets to the Mac

The phone captures, encodes in hardware, muxes MPEG-TS and listens on TCP 9000.
The Mac dials in.

```
iPhone  --USB--> usbmuxd --> iproxy --> 127.0.0.1:9000 --> OBS media source
```

Over USB nothing touches the network and the phone charges while it shoots.
Unplugged, the app advertises `_goblincam._tcp` and `up` finds it on Wi-Fi.
Nothing is encoded until a client connects.

MPEG-TS rather than a raw stream because TS carries real timestamps. A raw
elementary stream makes ffmpeg invent them at a nominal rate, which drifts
against the sensor's true rate over a long take and slides the picture out of
sync with the mic.

A second port, 9001, takes one line of text and answers with one. That is what
`rotate`, `lock`, `set` and `state` speak. [docs/PROTOCOL.md](docs/PROTOCOL.md)
has both ports in full, if you want to drive it from something other than this
script.

## Audio

Record your sound on a real mic in OBS. The feed carries the phone's own
microphone too, but only as a measuring stick -- 64 kb/s mono, never to be
mixed in.

The video arrives 0.5 to 0.9 s behind the mic, the delay differs from one
connection to the next, and it grows over a long session, so a fixed sync
offset in OBS will not hold. The phone's track is late by exactly as much as
the picture is, because it travels with it. Record it on its own track in OBS
and the delay is whatever offset lines the two audio tracks up -- measurable
across the take, drift and all, instead of guessed from one clap.
[docs/SYNC.md](docs/SYNC.md) has the procedure, the fallback for a take without
it, and the one ffmpeg flag that makes the fix survive a server-side re-encode.

## The app

`ios/` is a plain Swift app. `setup` generates the Xcode project from
`project.yml` with your team and bundle id, and `install` builds it and pushes
it to the phone with `devicectl`.

| file | does |
|---|---|
| `CaptureController.swift` | the capture session, manual controls, the control-port commands |
| `VideoEncoder.swift` | VideoToolbox, Annex-B out, no B-frames so DTS equals PTS |
| `TSMuxer.swift` | MPEG-TS, one program, one video stream |
| `StreamServer.swift` | TCP listener; drops frames rather than queueing when a reader stalls |
| `ControlServer.swift` | the line-based control port |
| `ContentView.swift` | the on-screen controls and the connection status |

`TSMuxer` is the only hand-rolled format code, so it has a check:

```
ios/tools/tsmux_check.sh
```

It muxes real H.264 and 4K-vertical HEVC, then asserts against ffmpeg (the
demuxer OBS uses) that every frame survives, the stream decodes without one
error, and the timestamps land on the designed cadence. It finishes by
corrupting a stream to prove those checks can fail. Run it after touching the
muxer.

## Limits

- iPhone and Mac only. The USB path is usbmuxd, the install path is Xcode.
- No macOS virtual camera. To use the feed in Zoom or QuickTime, run it through
  OBS and start OBS's Virtual Camera.
- One phone at a time on the default ports.

## Licence

MIT. See [LICENSE](LICENSE).
