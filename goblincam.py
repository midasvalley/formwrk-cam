#!/usr/bin/env -S uv run --quiet --with websocket-client python
"""GoblinCam: run the phone camera from the Mac and point OBS at it.

    ./goblincam.py setup            # find your Apple team, write config.json, generate the Xcode project
    ./goblincam.py install          # build the app and install it on the phone over USB
    ./goblincam.py status           # phone, tunnel, camera state, what the stream is
    ./goblincam.py up               # open the USB tunnel (or find the phone on Wi-Fi), launch the app, probe
    ./goblincam.py down             # close the USB tunnel
    ./goblincam.py obs on           # show the `GoblinCam` media source in the current OBS scene
    ./goblincam.py obs off          # hide it (the phone stops encoding)
    ./goblincam.py obs continuity   # swap to Apple's Continuity Camera in the same spot
    ./goblincam.py rotate portrait  # portrait | landscape | portrait-flipped | landscape-flipped
    ./goblincam.py lock             # freeze exposure and white balance where they are
    ./goblincam.py auto             # hand them back to the camera
    ./goblincam.py set focus 0.7    # zoom bias iso shutter temp tint focus bitrate
    ./goblincam.py set exposure on  # exposure wb focuslock: on | off
    ./goblincam.py set iso 200 shutter 60 wb on focus 0.7   # several at once, applied as one look
    ./goblincam.py preset shorts    # orientation + the whole look, then checked against the camera
    ./goblincam.py state            # one line from the phone: what was asked for | what the camera is doing

    setup takes --team ID, --bundle-id ID and --phone MODEL (e.g. iPhone18,2) when
    the defaults are not right. See docs/SETUP.md.

The phone is the server and the Mac dials in, which lets one app serve both
transports:

  USB   plugged in, usbmuxd carries it and `iproxy` bridges a local port. No
        network involved and the phone charges while it shoots.
  Wi-Fi unplugged, the app advertises `_goblincam._tcp` and we dial it directly.

`up` picks whichever is available, preferring USB, and `obs on` writes the
matching URL into the source. So unplugging the phone costs one command.
"""
import base64, hashlib, json, os, plistlib, re, shutil, socket, subprocess, sys, threading, time
import websocket

PORT = 9000
CONTROL_PORT = 9001
SOURCE = "GoblinCam"        # the OBS media source this script creates and drives
CONTINUITY = "Continuity"   # the OBS camera source it creates for Apple's Continuity Camera
SERVICE = "_goblincam._tcp"
HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(HERE, "config.json")
IOS = os.path.join(HERE, "ios")
PROJECT = os.path.join(IOS, "GoblinCam.xcodeproj")
BUILD = os.path.join(IOS, "build")
OBS_CFG = os.path.expanduser(
    "~/Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json")
PROFILE_DIRS = ["~/Library/Developer/Xcode/UserData/Provisioning Profiles",
                "~/Library/MobileDevice/Provisioning Profiles"]
UUID_RE = r"\b[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\b"
ANGLES = {"portrait": 90, "landscape": 0, "portrait-flipped": 270, "landscape-flipped": 180}

# A whole shot in one command: orientation plus a manual look. Manual rather than
# auto because auto exposure chases whatever is brightest in a dim room and lifts
# the background with it; a fixed ISO and shutter leave the key light in charge of
# the face and the room dark. Tune per room in config.json under "presets".
PRESETS = {
    "shorts":   {"rotate": "portrait",  "look": {"iso": 200, "shutter": 60, "wb": "on", "focus": 0.7}},
    "longform": {"rotate": "landscape", "look": {"iso": 200, "shutter": 60, "wb": "on", "focus": 0.7}},
}


def sh(*args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def cfg():
    """config.json beside this script: team, bundle_id and (optionally) phone model."""
    try:
        with open(CONFIG) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def obs_settings(host):
    """A live network feed: never seek it, never cache it, reconnect on its own."""
    return {
        "is_local_file": False,
        "input": f"tcp://{host}:{PORT}",
        "input_format": "mpegts",
        "hw_decode": True,
        "reconnect_delay_sec": 1,
        # Zero, not the default. At ~20 Mb/s each megabyte of buffer is roughly
        # 400 ms of delay, and this is a live camera, not a file.
        "buffering_mb": 0,
        "clear_on_media_end": False,
        # Release the socket when the item is hidden, so the phone stops encoding
        # (and stops getting hot) the moment you switch away.
        "close_when_inactive": True,
        "restart_on_activate": True,
        "seekable": False,
    }


# --- setup and install -------------------------------------------------------

def detect_teams():
    """Every Apple team this Mac has signed an iOS app for: the provisioning
    profiles Xcode keeps, plus whatever team was picked in Xcode's Signing &
    Capabilities for a project generated earlier."""
    teams = set()
    try:
        with open(os.path.join(PROJECT, "project.pbxproj")) as f:
            teams.update(re.findall(r"DEVELOPMENT_TEAM = ([A-Z0-9]{10});", f.read()))
    except FileNotFoundError:
        pass
    for d in PROFILE_DIRS:
        d = os.path.expanduser(d)
        if not os.path.isdir(d):
            continue
        for name in os.listdir(d):
            if not name.endswith(".mobileprovision"):
                continue
            raw = sh("security", "cms", "-D", "-i", os.path.join(d, name)).stdout
            try:
                teams.update(plistlib.loads(raw.encode()).get("TeamIdentifier", []))
            except Exception:
                pass
    return teams


def generate_project(c):
    """XcodeGen turns ios/project.yml into the .xcodeproj, with the team and
    bundle id filled in from config. The project itself is never committed."""
    if not shutil.which("xcodegen"):
        sys.exit("xcodegen is missing:  brew install xcodegen")
    env = dict(os.environ, DEVELOPMENT_TEAM=c["team"], BUNDLE_ID=c["bundle_id"])
    r = subprocess.run(["xcodegen", "generate", "--quiet"], cwd=IOS, env=env,
                       capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stdout + r.stderr)
    print(f"project   {PROJECT}")


def setup(args):
    given = {}
    it = iter(args)
    for flag in it:
        key = flag.lstrip("-").replace("-", "_")
        if key not in ("team", "bundle_id", "phone"):
            sys.exit(f"setup does not know {flag}. It takes --team, --bundle-id and --phone.")
        value = next(it, None)
        if not value:
            sys.exit(f"{flag} needs a value")
        given[key] = value

    c = cfg()
    c.update(given)
    if not c.get("team"):
        teams = detect_teams()
        if len(teams) == 1:
            c["team"] = teams.pop()
            print(f"team      {c['team']}  (from the provisioning profiles on this Mac)")
        elif teams:
            sys.exit("this Mac has signed for more than one team (" + ", ".join(sorted(teams))
                     + "): run  ./goblincam.py setup --team ID")
        else:
            # Nothing on this Mac names a team yet. Xcode can: generate the
            # project without one, let Xcode write the team into it, and the
            # next run reads it back.
            generate_project({"team": "", "bundle_id": c.get("bundle_id", "com.goblincam.app")})
            sys.exit("no Apple team found on this Mac yet. Open ios/GoblinCam.xcodeproj in Xcode,\n"
                     "select the GoblinCam target > Signing & Capabilities, pick your Team, then run\n"
                     "  ./goblincam.py setup  again. Or pass it:  ./goblincam.py setup --team ID")
    else:
        print(f"team      {c['team']}")
    # Bundle ids are unique across Apple's developer portal, so the default
    # carries your team id rather than a name everyone would collide on.
    c.setdefault("bundle_id", f"com.goblincam.{c['team'].lower()}")
    print(f"bundle    {c['bundle_id']}")
    if c.get("phone"):
        print(f"phone     {c['phone']}")

    with open(CONFIG, "w") as f:
        json.dump(c, f, indent=2)
        f.write("\n")
    print(f"config    {CONFIG}")
    generate_project(c)
    print("next      ./goblincam.py install")


def install():
    c = cfg()
    if not c.get("team"):
        sys.exit("no config.json yet:  ./goblincam.py setup")
    generate_project(c)

    found = devices()
    print(f"building  for {found[0][1] if found else 'the phone paired over the network'}")
    r = subprocess.run(["xcodebuild", "-project", PROJECT, "-scheme", "GoblinCam",
                        "-sdk", "iphoneos", "-destination", "generic/platform=iOS",
                        "-configuration", "Debug", "-derivedDataPath", BUILD,
                        "-allowProvisioningUpdates", "build"],
                       capture_output=True, text=True)
    if r.returncode:
        print("\n".join(l for l in r.stdout.splitlines() if "error:" in l)[-4000:] or r.stderr[-2000:])
        sys.exit("build failed")
    app_path = os.path.join(BUILD, "Build", "Products", "Debug-iphoneos", "GoblinCam.app")

    device = found[0][0] if found else device_id()
    if not device:
        sys.exit("no iPhone paired with this Mac. Plug it in, tap Trust on the phone, and retry.")
    r = sh("xcrun", "devicectl", "device", "install", "app", "--device", device, app_path)
    if r.returncode:
        sys.exit(r.stdout + r.stderr)
    print("installed. Unlock the phone, open GoblinCam once (it asks for the camera), then:")
    print("          ./goblincam.py up")


# --- finding the phone -------------------------------------------------------

def devices():
    """(udid, name) for every iPhone attached by USB."""
    return [(u, sh("ideviceinfo", "-u", u, "-k", "DeviceName").stdout.strip() or "iPhone")
            for u in sh("idevice_id", "-l").stdout.split()]


def bonjour_host(timeout=6):
    """Ask Bonjour where the app is. dns-sd never exits, so it gets killed."""
    p = subprocess.Popen(["dns-sd", "-L", SOURCE, SERVICE, "local"],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    killer = threading.Timer(timeout, p.kill)
    killer.start()
    try:
        for line in p.stdout:
            m = re.search(r"can be reached at ([\w.\-]+?)\.?:(\d+)", line)
            if m:
                return m.group(1)
    except Exception:
        pass
    finally:
        killer.cancel()
        p.kill()
    return None


def tunnel_pid():
    """PID holding our local port, but only if it is actually iproxy."""
    for pid in sh("lsof", "-ti", f"tcp:{PORT}", "-sTCP:LISTEN").stdout.split():
        if "iproxy" in sh("ps", "-p", pid, "-o", "comm=").stdout:
            return int(pid)
    return None


def open_tunnel(udid):
    if tunnel_pid():
        return True
    # Detached, so it outlives this process and the shell that spawned it.
    subprocess.Popen(["iproxy", "-u", udid, f"{PORT}:{PORT}", f"{CONTROL_PORT}:{CONTROL_PORT}"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     stdin=subprocess.DEVNULL, start_new_session=True)
    for _ in range(40):
        time.sleep(0.1)
        if tunnel_pid():
            return True
    return False


def endpoint(quiet=False):
    """Where to reach the phone right now. USB wins when it is available."""
    for tool in ("idevice_id", "iproxy"):
        if not shutil.which(tool):
            sys.exit(f"{tool} is missing:  brew install libimobiledevice")
    found = devices()
    if found:
        udid, name = found[0]
        if open_tunnel(udid):
            if not quiet:
                print(f"transport USB   {name} -> 127.0.0.1:{PORT}")
            return "127.0.0.1", "usb"
        sys.exit("iproxy would not start")
    host = bonjour_host()
    if not host:
        sys.exit("no iPhone on USB and nothing advertising GoblinCam on the network.\n"
                 "Plug the phone in (and tap Trust on it), or open GoblinCam on the phone.")
    if not quiet:
        print(f"transport Wi-Fi {host}:{PORT}")
    return host, "wifi"


def device_id():
    """devicectl's identifier for the phone: the configured model if there is
    one, else the connected iPhone, else a paired one. The id is pulled out by
    shape, because the model column has spaces and splitting on them lies."""
    model = cfg().get("phone")
    rows = [l for l in sh("xcrun", "devicectl", "list", "devices").stdout.splitlines() if "iPhone" in l]
    if model:
        rows = [l for l in rows if model in l]
    rows.sort(key=lambda l: 0 if " connected" in l else 1 if " available" in l else 2)
    for line in rows:
        m = re.search(UUID_RE, line)
        if m:
            return m.group(0)
    return None


def app(action):
    """Launch or kill GoblinCam on the phone. Continuity cannot have the camera
    while our app holds it, so the A/B has to hand it over."""
    bundle = cfg().get("bundle_id")
    device = device_id()
    if not (bundle and device):
        return False
    if action == "launch":
        r = sh("xcrun", "devicectl", "device", "process", "launch",
               "--device", device, "--terminate-existing", bundle)
        return r.returncode == 0
    pids = [l.split()[0] for l in sh("xcrun", "devicectl", "device", "info", "processes",
                                     "--device", device).stdout.splitlines()
            if "/GoblinCam.app/" in l]
    for pid in pids:
        sh("xcrun", "devicectl", "device", "process", "terminate", "--device", device, "--pid", pid)
    return True


# --- talking to it -----------------------------------------------------------

def control(line, host="127.0.0.1"):
    """One request/response exchange on the phone's control port."""
    try:
        with socket.create_connection((host, CONTROL_PORT), timeout=3) as s:
            s.sendall((line + "\n").encode())
            return s.recv(256).decode().strip()
    except OSError as e:
        return f"error {e.strerror or e}"


def look(line):
    """Anything that changes the picture rather than the transport."""
    host, _ = endpoint(quiet=True)
    reply = control(line, host)
    if reply.startswith("error"):
        sys.exit(f"phone said: {reply}\nIs GoblinCam open?")
    print(f"camera    {reply}")
    print(f"          {control('state', host)}")


def rotate(which):
    if which not in ANGLES:
        sys.exit(f"rotate needs one of: {', '.join(ANGLES)}")
    host, _ = endpoint(quiet=True)
    # Turn with nobody reading. A reader attached during the turn can keep the
    # old frame size, and the picture then arrives squashed into the wrong
    # shape. Hiding the OBS item drops its socket, so the phone stops encoding,
    # turns, and starts again at the new size when the item comes back.
    ws = obs_connect(optional=True)
    was_shown = hide_source(ws) if ws else False
    reply = control(f"rotate {ANGLES[which]}", host)
    if reply.startswith("error"):
        sys.exit(f"phone said: {reply}\nIs GoblinCam open?")
    print(f"camera    {which} ({ANGLES[which]} deg)")
    print("          turn the phone in its mount to match -- a sensor cannot be rotated in software")
    if was_shown:
        # Let the phone settle at the new size before OBS reads the header.
        time.sleep(1.5)
        show_source(ws)
        print(f"obs       {SOURCE} reconnected at the new size")


def preset(name):
    """Orientation and the whole look in one go, then read back off the device.

    `state` has two halves: what was asked for, and after `| device` what the
    camera is actually doing. This checks the second half, so a look that did not
    land is reported as a failure instead of an `ok`."""
    presets = {**PRESETS, **cfg().get("presets", {})}
    if name not in presets:
        sys.exit(f"preset needs one of: {', '.join(presets)}")
    p = presets[name]
    rotate(p["rotate"])
    host, _ = endpoint(quiet=True)
    pairs = " ".join(f"{k} {v}" for k, v in p["look"].items())
    reply = control(f"set {pairs}", host)
    if reply.startswith("error"):
        sys.exit(f"phone said: {reply}")
    time.sleep(1.5)  # exposure and focus settle over a few frames
    state = control("state", host)
    print(f"camera    {state}")
    device = state.split("| device", 1)[1] if "| device" in state else ""
    if not device:
        sys.exit("check     this app build does not report the device -- run ./goblincam.py install")
    problems = []
    if "queue=stuck" in device:
        problems.append("the camera queue is stuck, so nothing applies -- relaunch the app (./goblincam.py up after closing it)")
    look_ = p["look"]
    if "iso" in look_:
        m = re.search(r"iso=(\d+)", device)
        if not m or abs(int(m.group(1)) - float(look_["iso"])) > 0.15 * float(look_["iso"]):
            problems.append(f"iso is {m.group(1) if m else '?'}, wanted {look_['iso']}")
    if "shutter" in look_ and f"1/{int(look_['shutter'])}" not in device:
        problems.append(f"shutter is not 1/{int(look_['shutter'])}")
    if look_.get("wb") == "on" and "wb=locked" not in device:
        problems.append("white balance is not locked")
    if "focus" in look_ and "focus=locked" not in device:
        problems.append("focus is not locked")
    if problems:
        sys.exit("check     " + "; ".join(problems))
    print(f"check     {name}: the camera matches")

def probe(host):
    """Read a little of the stream, then let ffprobe say what it is."""
    try:
        with socket.create_connection((host, PORT), timeout=5) as s:
            s.settimeout(5)
            head = s.recv(376)
    except OSError as e:
        print(f"stream    nothing on {host}:{PORT} ({e.strerror or e}) -- is GoblinCam open?")
        return False
    if not head or head[0] != 0x47:
        print("stream    connected but that is not MPEG-TS")
        return False
    if not shutil.which("ffprobe"):
        print("stream    MPEG-TS is flowing (install ffmpeg to see the codec and size)")
        return True
    r = sh("ffprobe", "-v", "error", "-show_entries",
           "stream=codec_type,codec_name,width,height,avg_frame_rate", "-of", "json",
           "-analyzeduration", "4000000", "-probesize", "6000000",
           f"tcp://{host}:{PORT}?timeout=12000000")
    try:
        streams = json.loads(r.stdout)["streams"]
        st = next(s for s in streams if s.get("codec_type") == "video")
        num, den = (st.get("avg_frame_rate") or "0/1").split("/")
        fps = int(num) / int(den) if int(den) else 0
        # The microphone rides along as a second stream purely so the video delay
        # can be measured afterwards (docs/SYNC.md). Say whether it is there: a
        # take recorded without it has to fall back to reading lips.
        mic = any(s.get("codec_type") == "audio" for s in streams)
        print(f"stream    {st['codec_name']} {st['width']}x{st['height']} @ {fps:g}fps"
              + (" + mic (sync reference)" if mic else " -- no mic, sync must be read off the lips"))
    except Exception:
        print("stream    MPEG-TS is flowing, ffprobe could not read a full header yet")
    return True


def up():
    host, transport = endpoint()
    state = control("state", host)
    if state.startswith("error") and transport == "usb":
        if app("launch"):
            print("camera    launching GoblinCam on the phone")
            for _ in range(20):
                time.sleep(0.5)
                state = control("state", host)
                if not state.startswith("error"):
                    break
    print(f"camera    {state}")
    if state.startswith("error"):
        print("          unlock the phone and open GoblinCam, then run this again")
        return
    probe(host)


def down():
    pid = tunnel_pid()
    if not pid:
        print("tunnel    already closed")
        return
    os.kill(pid, 15)
    time.sleep(0.3)
    print(f"tunnel    closed (pid {pid})")


def status():
    found = devices()
    print(f"phone     {found[0][1]} on USB" if found else "phone     not on USB")
    pid = tunnel_pid()
    print(f"tunnel    {'open on :%d (pid %d)' % (PORT, pid) if pid else 'closed'}")
    host, _ = endpoint(quiet=True)
    print(f"camera    {control('state', host)}")
    probe(host)


# --- OBS ---------------------------------------------------------------------

def obs_connect(optional=False):
    """A live obs-websocket 5 session. Port and password come from OBS's own
    config, so there is nothing to set up beyond enabling the server."""
    try:
        with open(OBS_CFG) as f:
            c = json.load(f)
    except FileNotFoundError:
        if optional:
            return None
        sys.exit("no obs-websocket config found. In OBS: Tools > WebSocket Server Settings,\n"
                 "tick Enable WebSocket server, Apply, then retry.")
    if not c.get("server_enabled", True):
        if optional:
            return None
        sys.exit("obs-websocket is switched off. In OBS: Tools > WebSocket Server Settings,\n"
                 "tick Enable WebSocket server, Apply, then retry.")
    try:
        ws = websocket.create_connection(f"ws://127.0.0.1:{c['server_port']}", timeout=10)
    except OSError:
        if optional:
            return None
        sys.exit("OBS is not running (nothing listening on obs-websocket). Open OBS and retry.")
    hello = json.loads(ws.recv())
    ident = {"op": 1, "d": {"rpcVersion": 1}}
    auth = hello["d"].get("authentication")
    if auth:
        secret = base64.b64encode(
            hashlib.sha256((c["server_password"] + auth["salt"]).encode()).digest())
        ident["d"]["authentication"] = base64.b64encode(
            hashlib.sha256(secret + auth["challenge"].encode()).digest()).decode()
    ws.send(json.dumps(ident))
    ws.recv()
    return ws


def call(ws, typ, data=None):
    ws.send(json.dumps({"op": 6, "d": {"requestType": typ, "requestId": "1",
                                       "requestData": data or {}}}))
    while True:
        msg = json.loads(ws.recv())
        if msg["op"] == 7:
            d = msg["d"]
            if not d["requestStatus"]["result"]:
                raise SystemExit(f"{typ} failed: {d['requestStatus']}")
            return d.get("responseData") or {}


def scene_item(ws, scene, name):
    for item in call(ws, "GetSceneItemList", {"sceneName": scene})["sceneItems"]:
        if item["sourceName"] == name:
            return item["sceneItemId"]
    return None


def set_shown(ws, scene, item, shown):
    call(ws, "SetSceneItemEnabled",
         {"sceneName": scene, "sceneItemId": item, "sceneItemEnabled": shown})


def hide_source(ws):
    """Hide the GoblinCam item in the current scene. True if it was showing."""
    scene = call(ws, "GetCurrentProgramScene")["sceneName"]
    item = scene_item(ws, scene, SOURCE)
    if item is None:
        return False
    shown = any(i["sceneItemId"] == item and i["sceneItemEnabled"]
                for i in call(ws, "GetSceneItemList", {"sceneName": scene})["sceneItems"])
    if shown:
        set_shown(ws, scene, item, False)
    return shown


def show_source(ws):
    scene = call(ws, "GetCurrentProgramScene")["sceneName"]
    item = scene_item(ws, scene, SOURCE)
    if item is not None:
        set_shown(ws, scene, item, True)


def continuity_camera():
    """(unique id, name) of the phone's Continuity Camera as macOS lists it.
    Matched on the configured model when there is one, so two iPhones with the
    same name do not get mixed up."""
    model = cfg().get("phone") or "iPhone"
    name = uid = mid = None
    for line in sh("system_profiler", "SPCameraDataType").stdout.splitlines():
        s = line.strip()
        if s.endswith(":") and not line.startswith(" " * 6):
            name, uid, mid = s[:-1], None, None
        elif s.startswith("Model ID:"):
            mid = s.split(":", 1)[1].strip()
        elif s.startswith("Unique ID:"):
            uid = s.split(":", 1)[1].strip()
            # ...0001 is the camera, ...0002 is Desk View.
            if mid and mid.startswith(model) and uid.endswith("1"):
                return uid, name
    return None, None


def obs(mode):
    ws = obs_connect()
    scene = call(ws, "GetCurrentProgramScene")["sceneName"]
    item = scene_item(ws, scene, SOURCE)

    if mode == "continuity":
        uid, name = continuity_camera()
        if not uid:
            sys.exit("macOS lists no Continuity Camera for the phone -- is it awake, unlocked and nearby?")
        # Our app must let go of the camera first.
        app("terminate")
        settings = {"device": uid, "device_name": name,
                    "use_preset": True, "preset": "AVCaptureSessionPresetHigh"}
        cont = scene_item(ws, scene, CONTINUITY)
        if cont is None:
            existing = [i["inputName"] for i in call(ws, "GetInputList")["inputs"]]
            if CONTINUITY in existing:
                cont = call(ws, "CreateSceneItem",
                            {"sceneName": scene, "sourceName": CONTINUITY})["sceneItemId"]
                call(ws, "SetInputSettings", {"inputName": CONTINUITY, "inputSettings": settings})
            else:
                cont = call(ws, "CreateInput", {"sceneName": scene, "inputName": CONTINUITY,
                                                "inputKind": "macos-avcapture",
                                                "inputSettings": settings})["sceneItemId"]
            if item:  # sit exactly where GoblinCam sits, so only the camera changes
                t = call(ws, "GetSceneItemTransform",
                         {"sceneName": scene, "sceneItemId": item})["sceneItemTransform"]
                for k in ("sourceWidth", "sourceHeight", "width", "height"):
                    t.pop(k, None)
                if t.get("boundsType") == "OBS_BOUNDS_NONE":
                    for k in ("boundsWidth", "boundsHeight", "boundsAlignment", "boundsType"):
                        t.pop(k, None)
                call(ws, "SetSceneItemTransform",
                     {"sceneName": scene, "sceneItemId": cont, "sceneItemTransform": t})
        if item:
            set_shown(ws, scene, item, False)
        set_shown(ws, scene, cont, True)
        print(f"obs       {scene}: showing {CONTINUITY} (1080p landscape, cropped by the scene)")
        print("          ./goblincam.py obs on  to go back")
        return

    # Going back to GoblinCam: Continuity must release the camera, so the app
    # is relaunched. That resets the phone to landscape and auto focus.
    cont = scene_item(ws, scene, CONTINUITY)
    if cont and mode == "on":
        set_shown(ws, scene, cont, False)
        app("launch")
        time.sleep(5)

    if mode == "off":
        if item:
            set_shown(ws, scene, item, False)
        print(f"obs       {scene}: {SOURCE} hidden")
        return

    host, transport = endpoint(quiet=True)
    settings = obs_settings(host)
    if item is None:
        existing = [i["inputName"] for i in call(ws, "GetInputList")["inputs"]]
        if SOURCE in existing:
            item = call(ws, "CreateSceneItem", {"sceneName": scene, "sourceName": SOURCE})["sceneItemId"]
            call(ws, "SetInputSettings", {"inputName": SOURCE, "inputSettings": settings})
        else:
            item = call(ws, "CreateInput", {"sceneName": scene, "inputName": SOURCE,
                                            "inputKind": "ffmpeg_source",
                                            "inputSettings": settings})["sceneItemId"]
    else:
        call(ws, "SetInputSettings", {"inputName": SOURCE, "inputSettings": settings})

    set_shown(ws, scene, item, True)
    print(f"obs       {scene}: showing {SOURCE} over {transport} ({settings['input']})")


def main():
    cmd, *a = sys.argv[1:] or ["status"]
    if cmd == "setup":
        setup(a)
    elif cmd == "install":
        install()
    elif cmd == "status":
        status()
    elif cmd == "up":
        up()
    elif cmd == "down":
        down()
    elif cmd == "rotate" and a:
        rotate(a[0])
    elif cmd in ("lock", "auto"):
        look(cmd)
    elif cmd == "set" and a and len(a) % 2 == 0:
        look("set " + " ".join(a))
    elif cmd == "preset" and a:
        preset(a[0])
    elif cmd == "state":
        host, _ = endpoint(quiet=True)
        print(control("state", host))
    elif cmd == "obs" and a and a[0] in ("on", "off", "continuity"):
        obs(a[0])
    else:
        raise SystemExit(__doc__)


main()
