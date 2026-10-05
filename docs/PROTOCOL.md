# The two ports

Everything `cam.py` does goes through two TCP ports on the phone. Both
are plain enough to drive from `nc`, ffmpeg, or a few lines in any language.

Over USB, `iproxy` forwards the same port numbers on `127.0.0.1` to the phone
through usbmuxd. Over Wi-Fi, the phone advertises `_formwrkcam._tcp` by Bonjour
under the instance name `FORMWRK Cam`, and you connect to its address directly.

## 9000: the picture

Connect, and MPEG-TS starts flowing. No handshake, no request.

```
ffplay -fflags nobuffer -i tcp://127.0.0.1:9000
ffprobe -v error -show_entries stream=codec_name,width,height,avg_frame_rate tcp://127.0.0.1:9000
```

What is in the stream:

| | |
|---|---|
| container | MPEG-TS, 188-byte packets, one program |
| PIDs | PAT on 0, PMT on 0x1000, video on 0x100, the microphone on 0x101 |
| codec | HEVC (stream type 0x24) or H.264 (0x1B), picked on the phone |
| microphone | AAC-LC in ADTS (stream type 0x0F), 64 kb/s mono, on the video's clock. Present only when the phone granted microphone access -- otherwise the PMT names video alone, so a reader never waits on a stream that will not come. It is a sync reference, not sound to use: see SYNC.md |
| key frames | every second, parameter sets (VPS/SPS/PPS) repeated on each one |
| B-frames | none, so DTS equals PTS and every PES header carries PTS alone |
| PAT/PMT | ahead of every key frame and at least every 30 frames |
| clock | 90 kHz; PTS runs 50 ms ahead of PCR. PCR rides the video stream, and the microphone is stamped against the same base, so the two share one timeline |
| access units | each begins with an access unit delimiter |

A new client receives nothing until the next key frame, and the phone forces
one the moment a client connects, so decoding starts within a frame. If a
client falls more than about 4 MB behind, the phone drops non-key frames for
that client until the next key frame rather than queueing; queueing on a live
feed only turns into latency.

The phone encodes only while at least one client is connected. Any change to
orientation, size, frame rate or codec restarts the encoder and cuts every
client, because the stream's shape has changed and a reader part-way through
the old one cannot renegotiate. Reconnect and you get the new format.

## 9001: control

One line in, one line out, then the phone closes the connection. Replies start
with `ok` or `error`.

```
printf 'state\n' | nc 127.0.0.1 9001
```

| send | reply | does |
|---|---|---|
| `rotate 0` | `ok 0` | landscape |
| `rotate 90` | `ok 90` | portrait |
| `rotate 180` | `ok 180` | landscape, upside down |
| `rotate 270` | `ok 270` | portrait, upside down |
| `lock` | `ok locked` | lock exposure and white balance where they are; focus is left alone |
| `auto` | `ok auto` | exposure and white balance back to continuous auto |
| `set zoom 1.5` | `ok zoom 1.5` | zoom factor |
| `set bias -0.7` | `ok bias -0.7` | exposure compensation in EV (auto exposure) |
| `set iso 200` | `ok iso 200` | manual exposure ISO; turns manual exposure on |
| `set shutter 60` | `ok shutter 60` | manual exposure, 1/60 s; turns manual exposure on |
| `set temp 5200` | `ok temp 5200` | manual white balance, kelvin; turns manual WB on |
| `set tint 0` | `ok tint 0` | manual white balance tint; turns manual WB on |
| `set focus 0.7` | `ok focus 0.7` | lens position 0 (near) to 1 (far); locks focus |
| `set bitrate 40` | `ok bitrate 40` | Mb/s, applied without restarting the stream |
| `set exposure on` | `ok exposure on` | lock (`on`) or auto (`off`) exposure; clears manual |
| `set wb on` | `ok wb on` | lock or auto white balance; clears manual |
| `set focuslock off` | `ok focuslock off` | release or re-lock focus |
| `set iso 200 shutter 60 wb on focus 0.7` | `ok iso 200 shutter 60 wb on focus 0.7` | several pairs, validated together and applied as one look |
| `state` | see below | what was asked for, then what the camera is doing |

Flags accept `on`, `off`, `true`, `false`, `1`, `0`. Numbers are clamped to
what the active format allows.

`state` returns one line:

```
rotation=90 size=2160x3840 fps=30 clients=1 zoom=1.0 exposure=manual iso=200 1/60 wb=locked focus=locked 0.70 | device exposure=custom iso=200 1/60 wb=locked focus=locked 0.70 queue=ok
```

Everything before `| device` is the request. Everything after it is read off the
camera itself, so a setting that did not land shows up as a mismatch between the
two halves. `queue=stuck` means the capture session queue did not answer within
half a second: no setting will apply until the app is relaunched.
`./cam.py preset` checks the second half for you.

`exposure` reads `auto <bias>EV`, `locked`, or `manual iso=<n> 1/<n>`. `wb`
reads `auto`, `locked`, or `manual <k>K tint=<n>`. `focus` reads `auto` or
`locked <position>`.

`size` is derived from the chosen format and rotation, not read back from the
encoder. To know what is actually in the bitstream, ask ffprobe on port 9000.

## Errors

```
error rotate needs 0, 90, 180 or 270
error set needs key value pairs
error unknown key <key>
error <key> needs a number
error <key> needs on or off
error unknown command
```
