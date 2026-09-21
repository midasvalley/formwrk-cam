---
name: goblincam
description: Use when someone wants an iPhone as the camera in OBS on a Mac. Triggers on "bring the phone camera into OBS", "set up GoblinCam", "start the phone camera", "the phone feed is gone", "rotate the camera", "portrait" / "landscape", "lock the exposure", "set the focus", "the picture is soft / stretched / late / blown out", "install the camera app on my phone". Runs goblincam.py in order, checks each step by its printed output, and knows the failure modes.
---

# GoblinCam

Run everything from the repo root, the directory holding `goblincam.py`. Every
command prints a few labelled lines; read them, do not assume.

## First time on this Mac

```
brew install libimobiledevice xcodegen ffmpeg uv    # once
./goblincam.py setup                                  # team, config.json, Xcode project
./goblincam.py install                                # build + push to the plugged-in phone
```

`setup` finds the Apple team on its own when this Mac has built an iOS app
before. If it says no team was found, it has generated `ios/GoblinCam.xcodeproj`
without one: ask the person to open that project in Xcode, pick their Team
under the GoblinCam target > Signing & Capabilities, then run `setup` again.
Do not guess a team id.

`install` needs the phone plugged in, unlocked, trusted, with Developer Mode on.
The phone-side prompts are in `docs/SETUP.md`; walk the person through the one
that is blocking rather than listing them all. Never run `install` while a
recording is in progress: it replaces the running app and kills the feed.

## Every session

```
./goblincam.py up          # tunnel, launch the app if needed, probe the stream
./goblincam.py obs on      # GoblinCam media source into the current OBS scene
```

Good looks like:

```
transport USB   <name> -> 127.0.0.1:9000
camera    rotation=0 size=3840x2160 fps=30 clients=0 ...
stream    hevc 3840x2160 @ 30fps
obs       <scene>: showing GoblinCam over usb (tcp://127.0.0.1:9000)
```

`./goblincam.py status` any time gives the same picture without changing anything.

## Setting the look

Defaults are all auto with HDR and Center Stage off. Once the shot is framed
and has settled:

```
./goblincam.py lock              # exposure + white balance stay put
./goblincam.py set focus 0.7     # lens position 0 (near) to 1 (far)
```

Focus is deliberately not part of `lock`: autofocus does not reliably land on a
seated person, so set it as a number and have the person check the picture.
A seated subject about a metre from the phone lands near 0.7; adjust in steps
of 0.05. Setting any number (`iso`, `shutter`, `temp`, `tint`) switches that
control to manual; `auto` hands exposure and white balance back.

Keys: `zoom bias iso shutter temp tint focus bitrate`, flags: `exposure wb
focuslock on|off`. Full table in the README.

## Orientation

```
./goblincam.py rotate portrait     # or landscape, portrait-flipped, landscape-flipped
```

The command hides the OBS source, turns the camera, and shows the source again.
That order matters: rotating with a reader attached can leave the bitstream at
the old size and the picture squashed. Tell the person to turn the phone in its
mount to match. The app starts in landscape, and `obs on` relaunches the app
whenever it has to take the camera back from Continuity Camera, which resets
rotation and focus. So the order is `obs on`, then `rotate`, then `set focus`.

## Verify with the stream, not with `state`

`state`'s `size` is derived from the settings. The bitstream is what OBS sees:

```
ffprobe -v error -show_entries stream=codec_name,width,height -of csv=p=0 tcp://127.0.0.1:9000
```

## When it goes wrong

| symptom | cause | fix |
|---|---|---|
| `no iPhone on USB and nothing advertising` | Mac cannot see the phone | data cable, unlock, Trust This Computer; `idevice_id -l` should print a UDID |
| `phone said: error Connection refused` | app not running | `up` launches it; the phone must be unlocked |
| `stream nothing on 127.0.0.1:9000` | tunnel open, app not serving | open the app on the phone, check its status dot |
| OBS log `MP: Failed to find stream info`, scene blank | the app died | `up`, then `obs off`, `obs on`, then re-set rotation and focus |
| picture squashed / stretched | rotated with a reader attached | `obs off`, `rotate <o>`, `obs on` |
| picture soft | autofocus on the background | `set focus 0.7` and adjust |
| exposure or colour drifting mid-take | still on auto | `lock` |
| looks blown out or flat after switching cameras | OBS colour filters live on the source, not the camera | check filters on the `GoblinCam` source, not the phone |
| red banner on the phone naming Portrait / Studio Light | system video effect on | Control Center > Video Effects, off |
| `obs-websocket is switched off` / `OBS is not running` | OBS side | Tools > WebSocket Server Settings > Enable; open OBS |
| app will not launch after a week | free Personal Team signature expired | `install` |

## Audio

Video lags the mic by 0.5 to 0.9 s, differently on each connection, and the lag
grows over a session. Do not set an OBS sync offset; it will be wrong by the
next connection. Fix each clip in post.

The feed carries the phone's microphone beside the picture, arriving exactly as
late as the picture does. Put `GoblinCam` on its own OBS recording track (the
real mic on 1 and 2, the phone on 3, the recording writing 1 and 3) and the lag
is whatever offset lines the two audio tracks up -- to within a frame or two,
and measurable in windows so drift through a long take is visible. Never mix that track into the
recording; it is 64 kb/s mono of the room.

Check `status` says `+ mic (sync reference)` before a take that matters. If it
says the mic is missing, the app was refused microphone access -- have the
person clap in frame at the start of every take instead. `docs/SYNC.md` has
both procedures and the ffmpeg command that survives server-side re-encoding.

## Do not

- Run `install` during a recording.
- Rotate while the OBS item is showing by any path other than `rotate`.
- Put a sync offset in OBS's Advanced Audio Properties for this source.
- Trust `state`'s `size`; ask ffprobe.
- Commit `config.json` or `ios/GoblinCam.xcodeproj`; both are generated and gitignored.
