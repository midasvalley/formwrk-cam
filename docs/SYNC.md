# Audio sync

The feed is video only. You record sound on a mic in OBS, and the phone's
picture reaches OBS later than the mic's sound does.

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

**1. Mark every take.** Clap once, both hands in frame, at the start of every
take, and again after twenty minutes on a long one. That is one exact mark per
clip: the frame where the hands meet against the transient in the waveform.

**2. Measure.** In any editor, find the frame of the clap and the audio spike;
the difference is that clip's delay. Add about 40 ms: a mouth opens slightly
before the voice arrives, and audio a hair late reads as natural where audio
early reads as dubbed.

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
