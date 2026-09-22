# Audio sync

You record sound on a mic in OBS, and the phone's picture reaches OBS later
than that mic's sound does.

The feed carries the phone's own microphone beside the picture, for one
purpose: measuring that lag. It travels with the video -- same capture, same
encode, same socket, same buffering -- so it arrives exactly as late as the
picture does. Put it on its own recording track in OBS and you can read the
delay straight off the tape: cross-correlate it against the real mic's track
and the offset between them *is* the video lag, to within a frame or two of
audio (the AAC encoder's own small fixed delay, on the safe side). No clapping, no
reading lips, and it tracks drift through a long take instead of giving one
number for the whole thing.

It is a 64 kb/s mono reference, not content. Never mix it into the recording.

**In OBS:** put `GoblinCam` on a recording track of its own (track 3, say),
the real mic on tracks 1 and 2, and set the recording to write tracks 1 and 3.
Check the level meter moves before you record -- a silent track means the app
has no microphone permission, and the fallback below is what you have.

## What the lag does

Measured across real recording sessions:

- 0.5 to 0.9 s, video behind audio.
- Different on each connection. Reconnect the source and the number moves.
- Grows over a session: about 0.2 s on the first clip, about 0.9 s eighty
  minutes later, roughly monotonic.
- Steady within one clip, so one constant shift per clip is enough.

So a sync offset typed into OBS (Advanced Audio Properties) is wrong by the
next connection and drifts further through the session. Fix each clip in post
instead.

## The procedure

**1. Measure, off the two audio tracks.** Cross-correlate the phone's track
against the real mic's track. The peak is that clip's delay, with none of the
guesswork below.

```
ffmpeg -i clip.mp4 -map 0:a:0 -ac 1 -ar 16000 -f s16le mic.raw -y
ffmpeg -i clip.mp4 -map 0:a:1 -ac 1 -ar 16000 -f s16le phone.raw -y
```

Correlate the two in whatever you like; the lag is where they line up. Because
both are real audio of the same room, the correlation is strong and you can do
it in windows across the take to follow drift, instead of assuming one number
holds.

**2. Without the phone's track** -- permission refused, or a take recorded before
this existed -- fall back to a mark. Clap once, both hands in frame, at the
start of every take and again after twenty minutes on a long one, then find
the frame where the hands meet against the transient in the waveform. Add
about 40 ms: a mouth opens slightly before the voice arrives, and audio a hair
late reads as natural where audio early reads as dubbed.

**3. Shift the audio, and bake it into the samples.** The obvious remux

```
ffmpeg -i clip.mp4 -itsoffset 0.68 -i clip.mp4 -map 0:v -map 1:a -c copy out.mp4
```

writes the delay as a container start offset on the audio track. QuickTime,
IINA and ffmpeg all honour it, so the file looks right on your Mac. A
server-side pipeline that decodes both tracks from zero throws it away and the
audio snaps back to where it was. Upload sites do exactly that. Resample
instead, so the delay becomes real leading silence, with the video stream
copied so there is no quality cost:

```
ffmpeg -i clip.mp4 -itsoffset 0.68 -i clip.mp4 -map 0:v -map 1:a \
  -c:v copy -af "aresample=async=1:first_pts=0" -c:a aac -b:a 320k -ar 48000 out.mp4
```

**4. Verify.**

```
ffprobe -v error -show_entries stream=codec_type,start_pts -of compact out.mp4
```

Both streams must read `start_pts=0`. Then check the clap again, decoding the
way a server does:

```
ffplay -ignore_editlist 1 out.mp4
```

## Measuring without a clap

If a clip has no clap, cross-correlate the picture against the sound: crop the
mouth region, take frame-to-frame difference energy, resample it and the audio
envelope to a common rate, and find the peak of their cross-correlation
(positive means video lags). Check the sign convention on a synthetic pulse
pair before trusting a number. Correlations on real speech run around 0.5, so
measure several windows and take the median; a single window can be off by a
few hundred milliseconds. Clips with under ten seconds of speech give nothing
usable; borrow the delay from their neighbours in the session.
