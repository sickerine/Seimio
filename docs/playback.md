# What the TV plays

Measured on the LG C5 (webOS TV 26) on 2026-11-17, through the app's own player and tee, with
`tools/playback-matrix.py`. `native/src/playback.h` holds these results as code, and the stream picker and
the player both read it.

## How it was measured

LG's pipeline can't be trusted to say what plays. It reports "playing" with no error for audio it can't
decode, and for some video it shows a broken picture. So each result below comes from the screen and from
someone listening:

- **Clips made with FFmpeg**, one per codec, with a test pattern and a voice saying the clip's name. A
  capture of the TV's screen is taken 5 s in. For surround, a second set gives each channel its own word,
  1.5 s apart, to show which channels are heard.
- **Jellyfin's test videos** (repo.jellyfin.org/test-videos) for Dolby Vision and high bitrates.
- **Real releases** for what can't be made: a Dolby Vision profile 7 remux, Atmos, Dolby Digital Plus 7.1,
  DTS-HD MA, Dolby Vision in AV1. Each was probed with `ffprobe` first, so its name is not taken on trust.
- After a clip that fails, a control clip (H.264 + AAC) plays. If that fails too, the TV's media service is
  stuck and the run stops, so a stuck service can't spoil later results.

LG's own list ("AV Format on webOS TV 26", webostv.developer.lge.com) is close but not the same: it names
Opus in MKV and says nothing of channel counts.

## Video

| Plays | Doesn't |
|---|---|
| H.264 High, 8-bit 4:2:0: 1080p at 24, 60 and 120 fps, interlaced, 4K at 24 and 60 fps | H.264 10-bit, 4:2:2, 4:4:4: "Playing error" |
| HEVC Main and Main 10: 1080p, 1080p120, 4K60, 4K120, at 80 and 150 Mbps | HEVC 4:2:2 and 4:4:4: plays a broken picture, no error |
| HDR10 (HEVC and AV1), HLG | HEVC 12-bit: loads for ever, no error |
| AV1 8 and 10-bit: 1080p, 4K, 100 Mbps | 8K: "Resource Allocation Error" |
| VP9 8 and 10-bit, 4K. VP8. MPEG-2. MPEG-4 (Xvid) | Dolby Vision in AV1 (profile 10): broken picture, no error |
| Dolby Vision profiles 5, 8.1 and 8.4 (the pipeline reports `hdrType: DolbyVision`) | |
| Dolby Vision profile 7 (UHD remux): plays, but the pipeline reports no Dolby Vision, so as HDR10 | |

## Audio

| Codec | Stereo | 5.1 | 7.1 |
|---|---|---|---|
| AAC (LC, HE, mono too) | plays | plays | plays (side channels not heard) |
| Dolby Digital | plays | plays | |
| Dolby Digital Plus, Atmos too | plays | plays | plays |
| MP3, MP2, Vorbis | plays | | |
| Opus | plays | plays | **left and right only** |
| FLAC (16 and 24-bit, 96 kHz) | plays | **left and right only** | **left and right only** |
| PCM | plays | plays | centre faint (not measured per channel) |
| DTS, DTS-HD MA | **dropped** | **dropped** | **dropped** |
| TrueHD, Atmos too | | **dropped** | **dropped** |
| ALAC | **dropped** | | |

- **Dropped**: the pipeline leaves the track out of its list and plays the picture in silence. Its audio
  track indexes count only the tracks it lists, which is how the player addresses a track
  (`playback::audioListed`).
- **Left and right only**: the centre and surround channels are gone, and with them a film's dialogue. The
  pipeline lists the track as if it were fine (FLAC 5.1 is listed as two channels).
- Opus 5.1 is silent when its left and right channels are digital silence. Real content never is.
- Picking a track works: the second or third track plays when chosen, and a dropped first track doesn't
  shift the index of the ones after it.

## Containers

MKV, MP4 (H.264 + AAC, HEVC + Dolby Digital Plus, AV1 + Opus, H.264 + FLAC), WebM and AVI play. A
transport stream with Dolby Digital played its picture in silence.

## Not measured

- HDR10+ (LG sets don't advertise it; a file with both plays as Dolby Vision).
- Other sound outputs. This was the TV's sound output as set on the day; a receiver that takes DTS or
  TrueHD bitstreams may change those rows.
- Dolby Vision profile 7's enhancement layer, beyond what the pipeline reports.

## What the app does with this

- The picker leaves out releases whose names say they won't play (`streams.h`: 10-bit H.264, Dolby Vision
  in AV1, FLAC 5.1, Opus 7.1, DTS or TrueHD with nothing else).
- Names lie or say nothing, so the player judges the file itself once its tracks are read
  (`PlayerScreen.chooseTracks`): no sound the TV plays in the wanted language, or anime with no subtitle
  track, and the picker's own choice is replaced by the next candidate (`Streams.leaveOut`). The same
  happens when the pipeline fails before the first frame, or says nothing for 15 s. The release is
  remembered, so no other episode from it is tried.

## Running it again

```
python3 -I tools/lab-server.py 8091 &
python3 -I tools/playback-matrix.py audio      # or video, video2, audio2, audio3, tracks, channels, channels7, container, hdr
python3 -I tools/playback-matrix.py list.json  # real files: [{ "title", "url", "at": 0.4 }]
```

Results land in `.lab/playback/`, captures in `.lab/playback/shots/`. Someone has to listen: each clip
says what it is.
