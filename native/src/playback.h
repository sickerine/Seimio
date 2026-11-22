#pragma once
// What LG's player on the C5 (webOS TV 26) decodes, as measured on the TV by ear and by screen capture:
// docs/playback.md has the table and tools/playback-matrix.py makes it again. LG's own format list
// (webostv.developer.lge.com, "AV Format on webOS TV 26") is close but not the same. The pipeline reports no
// error for sound it can't play: it leaves the track out of its list (DTS, TrueHD, ALAC) or lists it and
// plays only the front pair, so the dialogue in the centre is gone (FLAC beyond stereo, Opus in 7.1). So
// these rules decide, from the file's own tracks, never the pipeline's answer.
#include <QString>
#include <QByteArray>

namespace playback {
#ifdef Q_OS_ANDROID
// On Android mpv plays the file (android/mpv.h): it decodes in software what the TV's own decoders don't
// (DTS, TrueHD, ALAC, 10-bit H.264) and mixes every channel down, so every track is listed and heard and no
// video track is refused.
inline QString videoTrouble(const QString &, const QByteArray &) { return QString(); }
inline bool audioListed(const QString &) { return true; }
inline bool audioPlays(const QString &, int) { return true; }
#else
// `codec` as Matroska names it (A_OPUS), as LG's pipeline does (opus, raw) or as a release name does

// What a video track's own header says the TV won't show, or "": `codec` and `priv` are Matroska's CodecID
// and CodecPrivate. H.264 in 10 bits or beyond 4:2:0 fails to start; HEVC's range extensions (4:2:2, 4:4:4,
// 12 bits) decode to a broken picture or never start.
inline QString videoTrouble(const QString &codec, const QByteArray &priv) {
    if (codec == "V_MPEG4/ISO/AVC" && priv.size() > 1 && priv[0] == 1) {            // avcC: version, profile_idc
        const int profile = uchar(priv[1]);
        return profile == 110 ? "10-bit H.264" : profile == 122 ? "4:2:2 H.264" : profile == 244 ? "4:4:4 H.264" : QString();
    }
    if (codec == "V_MPEGH/ISO/HEVC" && priv.size() > 1 && priv[0] == 1)             // hvcC: version, then the profile in the low five bits
        return (uchar(priv[1]) & 0x1f) >= 4 ? "HEVC beyond 10-bit 4:2:0" : QString();
    return QString();
}

// whether LG's player lists the track at all: its audio track indexes count only these
inline bool audioListed(const QString &codec) {
    const QString c = codec.toLower();
    return !c.contains("dts") && !c.contains("truehd") && !c.contains("mlp") && !c.contains("alac");
}
// whether every channel that matters is heard; `channels` 0 when unknown
inline bool audioPlays(const QString &codec, int channels) {
    const QString c = codec.toLower();
    if (!audioListed(c)) return false;
    if (c.contains("flac")) return channels <= 2;                          // 5.1: left and right only
    if (c.contains("opus")) return channels <= 6;                          // 7.1: left and right only
    if (c.contains("pcm") || c == "raw") return channels <= 6;             // 7.1: the centre was faint; not measured per channel
    return true;                                                            // AAC, Dolby Digital (Plus, Atmos), MP3, MP2, Vorbis
}
#endif
}
