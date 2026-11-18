#!/usr/bin/env python3
"""What the TV plays, measured: makes a 12 s clip per codec, plays them through the app's player and tee,
and records what LG's pipeline says, with a capture of the screen 5 s into each. The pipeline reports no
error for a track it can't decode (it plays the picture in silence, or a black screen), so the verdict is
the capture for the picture and a listener for the sound: each clip speaks its own name.
After a clip that fails, a control clip (H.264 + AAC) plays; if that fails too the TV's media service is
stuck and the run stops (App.qml's playList). Results: .lab/playback/<group>.json and shots/, and
docs/playback.md is written from them by hand.

usage: python3 -I tools/playback-matrix.py <group> [name ...] [--remake]    (the lab server must be up; --remake
makes the clips again, after a change to their recipes). A group is one of TESTS below, or a JSON file of
[{ "title", "url" }] for files that can't be made here (real releases: Dolby Vision layers, Atmos, DTS-HD)."""
import json, os, subprocess, sys, time, urllib.parse

repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
media, reports, out = (os.path.join(repo, ".lab", p) for p in ("www/media", "reports", "playback"))
server = "http://192.168.1.47:8091/media/"
SECONDS = 9
REMAKE = "--remake" in sys.argv
V = "-c:v libx264 -preset veryfast -pix_fmt yuv420p -profile:v high"       # the video every audio test has
A = "-c:a aac -ac 2"                                                        # the audio every video test has
HD, UHD = "1920x1080:rate=24000/1001", "3840x2160:rate=24000/1001"

# name: (what the clip says, picture, ffmpeg's codec arguments, extension)
TESTS = {
    "audio": {
        "aac-2.0": ("A A C, stereo", HD, f"{V} -c:a aac -ac 2", "mkv"),
        "aac-5.1": ("A A C, five point one", HD, f"{V} -c:a aac -ac 6", "mkv"),
        "he-aac-2.0": ("H E A A C, stereo", HD, f"{V} -c:a aac_at -profile:a 4 -ac 2", "mkv"),
        "ac3-5.1": ("Dolby Digital, five point one", HD, f"{V} -c:a ac3 -ac 6", "mkv"),
        "eac3-5.1": ("Dolby Digital Plus, five point one", HD, f"{V} -c:a eac3 -ac 6", "mkv"),
        "opus-2.0": ("Opus, stereo", HD, f"{V} -c:a libopus -ac 2", "mkv"),
        "opus-5.1": ("Opus, five point one", HD, f"{V} -c:a libopus -ac 6", "mkv"),
        "flac-2.0-16bit": ("Flac, stereo, sixteen bit", HD, f"{V} -c:a flac -ac 2 -sample_fmt s16", "mkv"),
        "flac-2.0-24bit": ("Flac, stereo, twenty four bit", HD, f"{V} -c:a flac -ac 2 -sample_fmt s32 -bits_per_raw_sample 24", "mkv"),
        "flac-5.1-24bit": ("Flac, five point one, twenty four bit", HD, f"{V} -c:a flac -ac 6 -sample_fmt s32 -bits_per_raw_sample 24", "mkv"),
        "dts-5.1": ("D T S, five point one", HD, f"{V} -c:a dca -strict -2 -ac 6", "mkv"),
        "truehd-5.1": ("Dolby True H D, five point one", HD, f"{V} -c:a truehd -strict -2 -ac 6", "mkv"),
        "mp3-2.0": ("M P three, stereo", HD, f"{V} -c:a libmp3lame -ac 2", "mkv"),
        "vorbis-2.0": ("Vorbis, stereo", HD, f"{V} -c:a vorbis -strict -2 -ac 2", "mkv"),
        "pcm-16bit": ("P C M, sixteen bit", HD, f"{V} -c:a pcm_s16le -ac 2", "mkv"),
        "pcm-24bit": ("P C M, twenty four bit", HD, f"{V} -c:a pcm_s24le -ac 2", "mkv"),
        "alac-2.0": ("Apple lossless, stereo", HD, f"{V} -c:a alac -ac 2", "mkv"),
        "mp2-2.0": ("M P two, stereo", HD, f"{V} -c:a mp2 -ac 2", "mkv"),
    },
    "audio2": {     # what the first run left open: is it the codec or the channels, and does a second track get picked
        "pcm-5.1": ("P C M, five point one", HD, f"{V} -c:a pcm_s16le -ac 6", "mkv"),
        "flac-5.1-16bit": ("Flac, five point one, sixteen bit", HD, f"{V} -c:a flac -ac 6 -sample_fmt s16", "mkv"),
        "aac-7.1": ("A A C, seven point one", HD, f"{V} -c:a aac -ac 8", "mkv"),
        "dts-2.0": ("D T S, stereo", HD, f"{V} -c:a dca -strict -2 -ac 2", "mkv"),
        "two-tracks": ([("eng", "First track, English, A A C"), ("jpn", "Second track, Japanese, Opus")], HD, f"{V} -c:a:0 aac -c:a:1 libopus -ac 2", "mkv"),
    },
    "video": {
        "h264-high-8bit": ("H two six four, eight bit", HD, f"{V} {A}", "mkv"),
        "h264-high10": ("H two six four, ten bit", HD, f"-c:v libx264 -preset veryfast -pix_fmt yuv420p10le -profile:v high10 {A}", "mkv"),
        "h264-1080p60": ("H two six four, sixty frames", "1920x1080:rate=60", f"{V} {A}", "mkv"),
        "h264-4k24": ("H two six four, four K", UHD, f"{V} {A}", "mkv"),
        "h264-4k60": ("H two six four, four K, sixty frames", "3840x2160:rate=60", f"{V} {A}", "mkv"),
        "hevc-main": ("H E V C, eight bit", HD, f"-c:v libx265 -preset ultrafast -pix_fmt yuv420p {A}", "mkv"),
        "hevc-main10": ("H E V C, ten bit", HD, f"-c:v libx265 -preset ultrafast -pix_fmt yuv420p10le {A}", "mkv"),
        "hevc-main10-4k60": ("H E V C, ten bit, four K, sixty frames", "3840x2160:rate=60", f"-c:v libx265 -preset ultrafast -pix_fmt yuv420p10le {A}", "mkv"),
        "hevc-hdr10": ("H E V C, H D R ten", HD, "-c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -x265-params colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1:"
                       f"master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400 {A}", "mkv"),
        "av1-8bit": ("A V one, eight bit", HD, f"-c:v libsvtav1 -preset 12 -pix_fmt yuv420p {A}", "mkv"),
        "av1-10bit": ("A V one, ten bit", HD, f"-c:v libsvtav1 -preset 12 -pix_fmt yuv420p10le {A}", "mkv"),
        "av1-10bit-4k": ("A V one, ten bit, four K", UHD, f"-c:v libsvtav1 -preset 12 -pix_fmt yuv420p10le {A}", "mkv"),
        "vp9-8bit": ("V P nine, eight bit", HD, f"-c:v libvpx-vp9 -deadline realtime -cpu-used 8 -pix_fmt yuv420p {A}", "mkv"),
        "vp9-10bit": ("V P nine, ten bit", HD, f"-c:v libvpx-vp9 -deadline realtime -cpu-used 8 -pix_fmt yuv420p10le -profile:v 2 {A}", "mkv"),
        "vp8": ("V P eight", HD, f"-c:v libvpx -deadline realtime -cpu-used 8 {A}", "mkv"),
        "mpeg2": ("M peg two", HD, f"-c:v mpeg2video {A}", "mkv"),
        "mpeg4-xvid": ("M peg four, X vid", HD, f"-c:v mpeg4 -vtag XVID {A}", "mkv"),
    },
    "tracks": {     # does the right track get picked: each track says which it is
        "second-track-opus": ([("eng", "First track, English, A A C"), ("jpn", "Second track, Japanese, Opus")], HD, f"{V} -c:a:0 aac -c:a:1 libopus -ac 2", "mkv"),
        "third-track": ([("eng", "First track, English"), ("fre", "Second track, French"), ("jpn", "Third track, Japanese")], HD, f"{V} -c:a aac -ac 2", "mkv"),
        "second-after-dts": ([("jpn", "First track, Japanese, D T S"), ("eng", "Second track, English, A A C")], HD, f"{V} -c:a:0 dca -strict -2 -c:a:1 aac -ac 2", "mkv"),
        "second-after-opus-5.1": ([("jpn", "First track, Japanese, Opus five point one"), ("eng", "Second track, English, A A C")], HD,
                                  f"{V} -c:a:0 libopus -ac:a:0 6 -c:a:1 aac -ac:a:1 2", "mkv"),
    },
    "channels": {   # which channels of a 5.1 track are heard: each one says its own name in turn (CHANNELS)
        "channels-aac": (None, HD, f"{V} -c:a aac", "mkv"),
        "channels-opus": (None, HD, f"{V} -c:a libopus", "mkv"),
        "channels-flac": (None, HD, f"{V} -c:a flac -sample_fmt s16", "mkv"),
        "channels-pcm": (None, HD, f"{V} -c:a pcm_s16le", "mkv"),
    },
    "channels7": {  # the same in 7.1
        "channels-aac-7.1": (None, HD, f"{V} -c:a aac", "mkv"),
        "channels-opus-7.1": (None, HD, f"{V} -c:a libopus", "mkv"),
    },
    "audio3": {     # more than 5.1, and high sample rates
        "opus-7.1": ("Opus, seven point one", HD, f"{V} -c:a libopus -ac 8", "mkv"),
        "flac-7.1": ("Flac, seven point one", HD, f"{V} -c:a flac -ac 8 -sample_fmt s16", "mkv"),
        "pcm-7.1": ("P C M, seven point one", HD, f"{V} -c:a pcm_s16le -ac 8", "mkv"),
        "ac3-2.0": ("Dolby Digital, stereo", HD, f"{V} -c:a ac3 -ac 2", "mkv"),
        "eac3-2.0": ("Dolby Digital Plus, stereo", HD, f"{V} -c:a eac3 -ac 2", "mkv"),
        "flac-2.0-96k": ("Flac, stereo, ninety six kilohertz", HD, f"{V} -c:a flac -ac 2 -ar 96000 -sample_fmt s32 -bits_per_raw_sample 24", "mkv"),
        "aac-2.0-mono": ("A A C, mono", HD, f"{V} -c:a aac -ac 1", "mkv"),
    },
    "video2": {     # chroma, depth, frame rate and scan
        "h264-422": ("H two six four, four two two", HD, f"-c:v libx264 -preset veryfast -pix_fmt yuv422p -profile:v high422 {A}", "mkv"),
        "h264-444": ("H two six four, four four four", HD, f"-c:v libx264 -preset veryfast -pix_fmt yuv444p -profile:v high444 {A}", "mkv"),
        "h264-interlaced": ("H two six four, interlaced", "1920x1080:rate=30000/1001", f"{V} -flags +ilme+ildct -top 1 {A}", "mkv"),
        "h264-1080p120": ("H two six four, one hundred twenty frames", "1920x1080:rate=120", f"{V} {A}", "mkv"),
        "hevc-422-10bit": ("H E V C, four two two", HD, f"-c:v libx265 -preset ultrafast -pix_fmt yuv422p10le {A}", "mkv"),
        "hevc-444-10bit": ("H E V C, four four four", HD, f"-c:v libx265 -preset ultrafast -pix_fmt yuv444p10le {A}", "mkv"),
        "hevc-12bit": ("H E V C, twelve bit", HD, f"-c:v libx265 -preset ultrafast -pix_fmt yuv420p12le {A}", "mkv"),
        "hevc-hlg": ("H E V C, H L G", HD, f"-c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -x265-params colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc {A}", "mkv"),
        "hevc-1080p120": ("H E V C, one hundred twenty frames", "1920x1080:rate=120", f"-c:v libx265 -preset ultrafast -pix_fmt yuv420p10le {A}", "mkv"),
        "hevc-4k120": ("H E V C, four K, one hundred twenty frames", "3840x2160:rate=120", f"-c:v libx265 -preset ultrafast -pix_fmt yuv420p10le {A}", "mkv"),
        "vp9-4k": ("V P nine, four K", UHD, f"-c:v libvpx-vp9 -deadline realtime -cpu-used 8 -pix_fmt yuv420p10le -profile:v 2 {A}", "mkv"),
    },
    "container": {
        "mp4-h264-aac": ("M P four, with A A C", HD, f"{V} {A}", "mp4"),
        "mp4-hevc-eac3": ("M P four, H E V C, with Dolby Digital Plus", HD, "-c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -tag:v hvc1 -c:a eac3 -ac 6", "mp4"),
        "mp4-av1-opus": ("M P four, A V one, with Opus", HD, "-c:v libsvtav1 -preset 12 -pix_fmt yuv420p10le -c:a libopus -ac 2", "mp4"),
        "mp4-h264-flac": ("M P four, with Flac", HD, f"{V} -c:a flac -ac 2 -strict -2", "mp4"),
        "webm-vp9-opus": ("Web M, V P nine, with Opus", HD, "-c:v libvpx-vp9 -deadline realtime -cpu-used 8 -pix_fmt yuv420p -c:a libopus -ac 2", "webm"),
        "ts-h264-ac3": ("Transport stream, with Dolby Digital", HD, f"{V} -c:a ac3 -ac 6", "ts"),
        "avi-xvid-mp3": ("A V I, X vid, with M P three", HD, "-c:v mpeg4 -vtag XVID -c:a libmp3lame -ac 2", "avi"),
    },
}
JELLYFIN = "https://repo.jellyfin.org/test-videos/"       # Jellyfin's test videos (CC BY-SA): picture only
SAMPLES = {     # downloaded once and served from here (150 Mbps needs the LAN); played longer: the panel switches modes for HDR
    "hdr": {
        "dv-p5-1080p": "HDR/Dolby Vision/Test Jellyfin 1080p DV P5.mp4",
        "dv-p5-4k": "HDR/Dolby Vision/Test Jellyfin 4K DV P5.mp4",
        "dv-p8.1-4k": "HDR/Dolby Vision/Test Jellyfin 4K DV P8.1.mp4",
        "dv-p8.4-4k": "HDR/Dolby Vision/Test Jellyfin 4K DV P8.4.mp4",
        "hdr10-hevc-4k-80M": "HDR/HDR10/HEVC/Test Jellyfin 4K HEVC HDR10 80M.mp4",
        "hdr10-hevc-4k-150M": "HDR/HDR10/HEVC/Test Jellyfin 4K HEVC HDR10 150M.mp4",
        "hdr10-av1-4k-100M": "HDR/HDR10/AV1/Test Jellyfin 4K AV1 HDR10 100M.mp4",
        "hdr10-hevc-8k-150M": "HDR/HDR10/HEVC/Test Jellyfin 8K HEVC HDR10 150M.mp4",
    },
}
CHANNELS = [("FL", "left"), ("FR", "right"), ("FC", "center"), ("LFE", "bass"), ("BL", "back left"), ("BR", "back right")]
CONTROL = "audio/aac-2.0"

def make(group, name):
    says, picture, codecs, ext = TESTS[group][name]
    path = os.path.join(media, f"{name}.{ext}")
    if os.path.exists(path) and not REMAKE: return path
    os.makedirs(media, exist_ok=True)
    if says is None:        # one 5.1 (or 7.1) track, a word per channel, 1.5 s apart
        channels = CHANNELS + [("SL", "side left"), ("SR", "side right")] if "7.1" in name else CHANNELS
        cmd, voices, graph = ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"testsrc2=size={picture}"], [], ""
        for i, (channel, word) in enumerate(channels):
            voices.append(os.path.join(media, f"{name}-{i}.aiff"))
            subprocess.run(["say", "-o", voices[-1], word + "."], check=True)
            cmd += ["-i", voices[-1]]
            graph += f"[{i + 1}:a]aresample=48000,adelay={i * 1500}:all=1,apad[a{i}];"
        graph += "".join(f"[a{i}]" for i in range(len(channels))) + f"join=inputs={len(channels)}:channel_layout={'7.1' if len(channels) == 8 else '5.1'}:map=" \
                 + "|".join(f"{i}.0-{c}" for i, (c, w) in enumerate(channels)) + "[a]"
        cmd += ["-filter_complex", graph, "-map", "0:v", "-map", "[a]", "-metadata:s:a:0", "language=jpn", "-t", "17" if len(channels) == 8 else "14", "-b:v", "8M", *codecs.split(), path]
        done = subprocess.run(cmd, capture_output=True, text=True)
        for v in voices: os.remove(v)
        if done.returncode: print(f"  can't make {name}: {done.stderr.strip().splitlines()[-1]}"); return None
        return path
    tracks = says if isinstance(says, list) else [("jpn", says)]      # the app prefers Japanese audio
    cmd, voices = ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"testsrc2=size={picture}"], []
    for i, (lang, text) in enumerate(tracks):
        voices.append(os.path.join(media, f"{name}-{i}.aiff"))
        subprocess.run(["say", "-o", voices[-1], text + "."], check=True)
        cmd += ["-stream_loop", "-1", "-i", voices[-1]]
    cmd += ["-map", "0:v"]
    for i, (lang, text) in enumerate(tracks): cmd += ["-map", f"{i + 1}:a", f"-metadata:s:a:{i}", f"language={lang}"]
    cmd += ["-af", "apad=pad_dur=1.5,aresample=48000", "-t", "12", "-b:v", "25M" if "3840" in picture else "8M",   # within LG's limits (50 Mbps at 4K)
            *codecs.split(), path]
    done = subprocess.run(cmd, capture_output=True, text=True)
    for v in voices: os.remove(v)
    if done.returncode: 
        if os.path.exists(path): os.remove(path)
        print(f"  can't make {name}: {done.stderr.strip().splitlines()[-1] if done.stderr.strip() else done.returncode}"); return None
    return path

def fetch(name, where):
    path = os.path.join(media, f"{name}.mp4")
    if not os.path.exists(path):
        os.makedirs(media, exist_ok=True)
        subprocess.run(["curl", "-s", "-L", "-m", "600", "-A", "media-test/1.0", "-o", path, JELLYFIN + urllib.parse.quote(where)], check=True)
    return server + f"{name}.mp4"

def play_log():
    files = sorted((f for f in os.listdir(reports) if "design" in f), key=lambda f: os.path.getmtime(os.path.join(reports, f)))
    for f in reversed(files[-3:]):
        try: return json.load(open(os.path.join(reports, f)))["state"].get("playLog", []), os.path.getmtime(os.path.join(reports, f))
        except (ValueError, KeyError): pass
    return [], 0

def main():
    group, only = sys.argv[1], [a for a in sys.argv[2:] if a != "--remake"]
    make(*CONTROL.split("/"))
    control, seconds, shot = server + CONTROL.split("/")[1] + ".mkv", SECONDS, 5000
    if group in TESTS:
        made = [n for n in TESTS[group] if (not only or n in only) and make(group, n)]
        plays = [{"title": n, "url": server + f"{n}.{TESTS[group][n][3]}"} for n in made]
        if group.startswith("channels"): seconds = 15 if group == "channels7" else 12
    else:
        if group in SAMPLES: plays = [{"title": n, "url": fetch(n, p)} for n, p in SAMPLES[group].items() if not only or n in only]
        else: plays = [p for p in json.load(open(group)) if not only or p["title"] in only]; group = os.path.splitext(os.path.basename(group))[0]
        made, seconds, shot = [p["title"] for p in plays], 16, 10000
    variant = {"playList": plays, "playSeconds": seconds, "playShotAt": shot, "playGroup": "anime", "control": control}
    www = os.path.join(repo, ".lab", "www", "variant.json")
    json.dump(variant, open(www, "w"))
    env = dict(os.environ, PATH=os.path.expanduser("~/.nvm/versions/node/v20.20.0/bin") + ":" + os.environ["PATH"])
    subprocess.run(["ares-launch", "-d", "tv", "--close", "com.seimio.tv"], env=env, capture_output=True)
    started = time.time()
    subprocess.run(["ares-launch", "-d", "tv", "com.seimio.tv"], env=env, capture_output=True, check=True)
    time.sleep(6); json.dump({}, open(www, "w"))
    log, seen = [], 0
    while time.time() - started < 30 + len(made) * (seconds + SECONDS + 2):
        time.sleep(3)
        log, at = play_log()
        if at < started: log = []
        if len(log) > seen:
            for e in log[seen:]: print(f"  {'plays ' if e['ok'] else 'FAILS '} {e['title']:22} {e['failure'] or ''}", flush=True)
            seen = len(log)
        tests = [e for e in log if e["title"] != "control"]
        if len(tests) == len(made) and (tests[-1]["ok"] or log[-1]["title"] == "control"): break
        if log and log[-1]["title"] == "control" and not log[-1]["ok"]: print("  the control failed: the TV's media service is stuck, restart the TV"); break
    # each clip's capture, and how much of a picture it is: a black screen has no spread of brightness
    shots = os.path.join(out, "shots"); os.makedirs(shots, exist_ok=True)
    ssh = ["ssh", "-i", os.path.expanduser("~/.ssh/tv_key"), "-p", "9922", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
           "-o", "HostKeyAlgorithms=+ssh-rsa", "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa", "-o", "LogLevel=ERROR", "prisoner@192.168.1.37"]
    for e in log:
        if e["title"] == "control": continue
        png = os.path.join(shots, e["title"] + ".png")
        with open(png, "wb") as f: subprocess.run(ssh + [f"cat /media/developer/temp/play-{e['title']}.png"], stdout=f)
        stats = subprocess.run(["ffprobe", "-v", "error", "-f", "lavfi", "-i", f"movie={png},signalstats", "-show_entries", "frame_tags=lavfi.signalstats.YLOW,lavfi.signalstats.YHIGH",
                                "-of", "csv=p=0"], capture_output=True, text=True).stdout.strip().split(",")
        e["spread"] = int(stats[1]) - int(stats[0]) if len(stats) == 2 and stats[0] else -1
        print(f"  {e['title']:22} picture {'yes' if e['spread'] > 120 else 'NO '} (brightness spread {e['spread']})")
    json.dump(log, open(os.path.join(out, f"{group}.json"), "w"), indent=1)

main()
