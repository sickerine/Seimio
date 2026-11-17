# The player: plan and references

The goal (from the user, 2026-11-17): a complete player. Audio and subtitle selectors whose active choice
becomes the default for the genre (anime, everything else), turning either off (saved too), subtitle
delay in 0.1 s steps saved per file, a stream switcher sheet, an episode row that peeks below the
player, intro and outro skip, usable seeking, micro-animations, and no wasted bytes, memory or frames.
Track logic comes from established players, not invented.

## What the TV gives us

LG's media server (uMediaClient) reports, per stream (sourceInfo):
- audio: language ("en", "ja") and codec per track, in container order. No titles, no default or forced
  flags.
- subtitles: only text tracks (ASS/SRT), language only. PGS isn't listed. Five English tracks of
  different kinds (Signs & Songs, Dialogue, No Honorifics) look identical.
It has setSubtitleEnable/Sync/Source and its own (plain) text rendering, setAudioMute, selectTrack.

So track names, flags, fonts, chapters and the subtitle events come from the file itself.

## Design

1. Track engine (C++, Seimio.Data `tracks.h`)
   - Language matching: mpv `misc/language.c` (`mp_match_lang`, the ISO 639-1/639-2 B/T table,
     BCP 47 subtags). A track whose tag is missing or `und` takes its language from its title: codes
     as mpv reads them from file names, and language names from Qt's CLDR data
     (`QLocale::languageToString`, `nativeLanguageName`).
   - Choosing tracks: mpv `player/loadfile.c` `select_default_track` + `compare_track`, with mpv's
     defaults (`subs-fallback=default`, `subs-fallback-forced=yes`, `subs-with-matching-audio=yes`).
     Jellyfin's `MediaStreamSelector` agrees on ordering (default > untagged > forced).
   - Preferences: per genre { audio: lang | "off", subs: lang | "off" }, written only when the user
     picks in the menus. A fallback pick is never saved. Subtitle delay per file (infohash + file).
2. Subtitle tee (C++, port of stremio-webos `service/ass-tee.js`, `mkv-subs.js`, `mkv-cut.js`)
   - A local HTTP server the LG player loads from; each Range is fetched once upstream, written to the
     player, and fed to a streaming Matroska parser that copies only subtitle blocks (tracks, flags,
     attachments/fonts, chapters, ASS/SRT events; zlib-inflated).
   - The player's view hides the Attachments element (LG reads fonts at ~5 MB/s before the first frame),
     rewriting Segment size, SeekHead and Cues.
   - Read-ahead capped (16 MB) so memory stays bounded.
   - libass (`SubtitleLayer`) draws the chosen track over the video, with the delay.
3. Player UI: transport, seeking that queues one seek, Audio and Subtitles menus (+ Off, delay),
   stream sheet (switch keeps the position), episode row (Down), skip intro/outro (stremio-webos
   `service/skip-timestamps.js`: AniSkip, IntroDB, TheIntroDB, chapter names).
4. Measure every route on the TV, iterate.

## Status

- [x] 1 track engine (tracks.h, tools/tests/tst_tracks.qml)
- [x] 2 tee (tee.h: server and Matroska parser; subtitle_layer.h: libass fed by the tee). Verified on
  the TV with [Salieri] Demon Slayer S3E9: 7 subtitle tracks, 35 fonts, chapters, ASS drawn.
- [x] PGS (pgs.h, ffmpeg's pgssubdec): checked against a UHD remux's English track on the Mac and on
  the TV (YTS 2160p BluRay, 18 tracks). Only a window around the reading position is kept: about
  130 MB for the whole app with 18 tracks, steady over minutes and seeks.
- [x] MP4 text subtitles (tx3g, `Mp4Subs` in tee.h): moov anywhere (an Apple WEB-DL keeps it at the
  end, behind a 3.8 MB free box). Verified on the TV with Dexter S2E3 MP4-BTM.
- Not yet: VobSub, hiding Attachments from the player (mkv-cut).
- [x] External subtitles: Stremio's OpenSubtitles addon (`opensubtitles-v3.strem.io`), up to three per
  language, listed after the file's own and downloaded only when chosen. No default flag, so one plays
  only when its language is the chosen one, and the file's own wins a tie. OpenSubtitles' four codes
  outside ISO 639 (its `export_languages.php`) map to BCP 47. The addon knows only IMDb ids: Kitsu ids
  (anime) get nothing, even with the file name.
- [x] 3 UI (overlay, menus, sheet, episode row, skip from chapters and from AniSkip, IntroDB,
  TheIntroDB). Verified on the TV: a stream switch resumes where it was, an episode from the row plays,
  an addon subtitle downloads and draws, delay steps 0.1 s and comes back with the file, audio Off sticks.
- [x] 4 performance: every tour within budget, and GUI stalls measured apart (a heartbeat). Entering
  the player and the streams page stalled 50-65 ms building stream rows; rows are now made
  asynchronously, and neither stalls.
