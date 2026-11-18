# Anime seasons as one show

Built in `Franchise` (native/src/franchise.h): an anime opens as its whole franchise from wherever it was
picked. Its TVDB show's seasons as below, AniList's sequel links for the seasons TVDB hasn't placed, then
Movies, Specials and Related, each entry with its own name, logo and art; and Cinemeta for a show Kitsu
doesn't have. Checked live on the TV on eight franchises (Sword, Demon Slayer, One Piece, Bleach, Attack
on Titan, Re:Zero, Naruto, Blue Box).

Kitsu (and the Stremio Kitsu addon we play anime through) treats every season as its own anime, so a
show page for "Reincarnated as a Sword" showed one season of 12 episodes when there are two. This is
what we found about joining them, from a survey of 600 anime (`tools/survey-anime-seasons.py`), run
2026-11-17 on AniList's 300 most popular TV/ONA anime and on ranks 1001-1300.

## The source: Fribb's anime-lists (ARM)

ARM (arm.haglund.dev), which already maps AniList to Kitsu for the Anime tab, serves Fribb's
anime-lists. Each entry carries its TVDB show (`thetvdb`), its season there (`thetvdb-season`, 0 for
specials and movies) and, for a season split into parts, where the part starts (`episode_offset`).
ARM also answers the other way: `GET /api/v2/thetvdb?id=` lists every entry of a show in one call.

- Reincarnated as a Sword: both entries are TVDB 410378, seasons 1 and 2 (IMDb tt15483602).
- Demon Slayer: TVDB 348545 holds the five TV arcs as seasons 1-5 and the Mugen Train and Infinity
  Castle movies as season 0.
- Torrentio answers a season's Kitsu id and its IMDb season the same (57 streams for Sword season 2 both
  ways), so each season can keep playing by its Kitsu id.

## What held

| | top 300 | ranks 1001-1300 |
|---|---|---|
| Entries with a mapping | 300 | 300 |
| With a TVDB show | 300 | 295 |
| With a Kitsu id | 300 | 298 |
| TVDB shows with 2+ seasons | 107 | 116 |
| Kitsu listings checked, present | 338 / 338 | 312 / 312 |
| Later seasons with Torrentio streams by Kitsu id | 59 / 60 (the one: unaired) | 60 / 60 |

## What a build has to handle

1. **Split seasons** (36 in the top 300, 13 lower): parts of one TVDB season, each its own Kitsu entry
   (Attack on Titan s4: 3 parts; Jujutsu Kaisen s3: 2). `episode_offset` orders them: join their
   episodes into one season, each still played by its own Kitsu id. One pair has equal offsets (Haruhi
   2006/2009): order by AniList start date.
2. **TVDB's season numbers aren't the show's own.** TVDB folds some "Season 2"s into season 1 as
   episodes 13-26 (Kono Oto Tomare! Season 2, Aldnoah.Zero Season 2, Ascendance of a Bookworm 3). Label
   each part by its own name (AniList's title), use TVDB only for order.
3. **Long runners have no TVDB season** (13 entries): One Piece, Naruto, Shippuden, Bleach, Gintama,
   Dragon Ball, DBZ, DB Super, Fairy Tail (three entries), Hunter x Hunter, Samurai Champloo. Kitsu has
   each as one entry of hundreds of episodes, TVDB splits it. They sit before the numbered seasons
   (Bleach's 366 episodes, then the Thousand-Year Blood War as season 17), ordered among themselves by
   AniList's prequel/sequel links. This is also the "gaps" the survey saw (Bleach [17], Gintama [5-10],
   InuYasha [8], Pokémon XY).
4. **New entries aren't mapped yet**: finished sequels without a TVDB show (Gintama's Silver Soul arcs,
   Arifureta 3, Record of Ragnarok II part 2, Gantz 2) and releasing ones (Steel Ball Run). Follow
   AniList's SEQUEL/PREQUEL links from the mapped seasons and place them after their prequel.
5. **Franchises span several TVDB shows**: Naruto / Shippuden / Boruto, Dragon Ball / Z / Super / Daima,
   Fate, Baki. Those are separate shows, as TVDB and Stremio have them; AniList's links between them can
   fill a "related" row instead.
   **What a page lists as related has to open as a page of its own.** A title no TVDB show has is
   placed by two pieces of code, the page that links to it (`Franchise::extras`) and the title itself
   when it is the one opened (`adopt`), and they must give the same answer. They didn't: Tensura's
   two-episode Ramiris ONA was "related" on Tensura's page and "Season 5" of Tensura when opened, One
   Piece's MONSTERS its "Season 2", and Re:Zero's Break Time shorts related on one side and specials on
   the other (ARM calls them specials, AniList a short series: AniList's format decides on both sides
   now). The rule, the same from both: a series joins a show as its next season (it follows one of its
   entries) or, a side story, among its specials; a film or a special goes with what it is linked to;
   anything else is a show of its own and is listed as related. And a title announced with no day to
   start on is nowhere yet: Tensura's "4th Season Part 3" (some time in 2027) stood as a Season 5 of
   thirty-three episodes. `tools/franchises.sh` puts AniList's forty most popular shows together on the
   Mac with the app's own loader, opens everything they list as related, and fails when one comes back
   as the show it was listed on (2026-11-18: 5 of 40 did; none after).
6. **Kitsu's dates**: unknown air dates are 1970-01-01, and planned episodes have guessed dates (Blue Box
   season 2 lists 25 with the last two on one day). `Episodes.aired` must treat 1970-01-01 as not aired.
7. **No Kitsu id** (2 in 600: Ranma ½ 2024, Steel Ball Run): play by IMDb season and episode, which
   Torrentio answers too.

## Cost of a show page

One ARM call for the show's entries, one Kitsu addon call per season (in parallel), and AniList only for
entries ARM can't place (4, 5). Fetched ahead while the selection rests, as the Anime tab does now.
