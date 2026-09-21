# GoblinCam

An iPhone as a 4K camera for OBS on a Mac. `goblincam.py` is the whole
interface; `ios/` is the app it installs and talks to.

- Operating it: `.claude/skills/goblincam/SKILL.md`. Read it before running
  any command for someone.
- What each prompt on the phone and Mac means: `docs/SETUP.md`.
- The two ports, if you need to drive the phone from something other than the
  script: `docs/PROTOCOL.md`.
- Why the video is late and how to fix a clip: `docs/SYNC.md`.

Rules for changing the code:

- `config.json` and `ios/GoblinCam.xcodeproj` are generated (by `setup`) and
  gitignored. Team and bundle id are filled into `ios/project.yml` from the
  environment by XcodeGen; never hard-code either.
- `ios/GoblinCam/TSMuxer.swift` is hand-rolled format code. After touching it,
  run `ios/tools/tsmux_check.sh`; it must print `PASS`.
- `install` builds into `ios/build` and pushes with `devicectl`. It replaces
  the running app, so never run it while someone is recording.
- Every command prints labelled lines. Read them; nothing here returns silently.
