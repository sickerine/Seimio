# The Stremio account in the app

The plan for signing in, the library, watch progress, the Library, Movies and Series tabs, search and the
profile. Researched and tried on 2026-11-18; the experiments ran `core/` on the Mac against a real account.

## How others do it

| Client | Account and library | What counts as watched |
|---|---|---|
| Stremio's own apps (web, shell, Android TV) | `stremio-core`, the Rust core, behind a bridge (WASM, protobuf) | the core's Player model |
| Losange (GNOME, by a Stremio developer) | `stremio-core` as a Rust library with its own `Env` | the core's Player model |
| Alder (Android TV) | its own client for `api.strem.io` ("request shapes from stremio-core"), its own merge of unsynced progress | the core's constants copied (0.7, 0.9); the watched bitfield not written |
| stremio-origin/webos (native, C) | 1,100 lines of its own datastore sync | its own cut-off (resume until 96 %), the bitfield ported by hand |
| Morpheus235/stremio-native (webOS, Rust) | its own account module | its own |

Everyone who doesn't embed the core rewrites its sync and its rules and drifts from them. The core is the
package we agreed on, it already ran on the TV as a probe, and Losange shows the shape: a model made of the
core's models, a runtime, and the UI reading state when the core says a model changed.

### Watched, across players

| | Counts as watched | Resume is kept | At the end |
|---|---|---|---|
| Stremio (`stremio-core`) | time actually played > 70 % of the duration (`WATCHED_THRESHOLD_COEF`), once per video | any position > 0 | stopped past 90 % (`CREDITS_THRESHOLD_COEF`): position cleared, a series moves on to the next video |
| Jellyfin | played to 90 % (`MaxResumePct`) | between 5 % and 90 %, items of 5 minutes or more | past 90 %: resume cleared |
| Kodi | 90 % (`playcountminimumpercent`) | after the first 3 minutes, before the last 8 % | |
| Trakt | scrobble stopped at 80 % or more | below 80 % as a pause | |

We use the core's, unchanged: it is what every other Stremio device of the account applies, and progress
only makes sense if all of them agree. The details that matter:

- `time_watched` adds up time played forward, not the position: seeking to the end doesn't mark anything.
- At 70 % the video's bit is set in the show's watched bitfield and `times_watched` goes up, once per video.
- Leaving a video past 90 % clears its position and, for a series, points the item at the next episode
  with `time_offset = 1`, which is what puts "Next E8" on Continue Watching.
- An item watched without being in the library is `temp` (and `removed`): it shows on Continue Watching,
  not in the Library.
- Continue Watching is every item with a position, or with new episodes (`ContinueWatchingPreview`).

## What was tried

`core/` is now a library (`seimio-core`) with a lab binary (`core-lab <dir> <steps>`). Against the account:

- **Signed out**: the core starts with Stremio's default addons and no library.
- **Link code**: `Load Link` answers in ~850 ms with `{ code: "J2QQ", link: "https://link.stremio.com/J2QQ",
  qrcode: "https://link.stremio.com/qr?data=…" }`; the QR is a 396 x 396 PNG. `Link.ReadData` polls; error
  101 means not approved yet (or expired). Approved, it carries the auth key for
  `Ctx.Authenticate(LoginWithToken)`.
- **Signing in** (`LoginWithToken`): three requests (`loginWithToken`, `datastoreGet`, `addonCollectionGet`),
  800 ms to a full library and the account's 11 addons, all written to storage.
- **Library** (`LibraryWithFilters<NotRemovedFilter>`): types All, movie, series; sorts last watched, name,
  name reversed, times watched, watched, not watched; pages of 100. Items carry id, name, type, poster and
  state, nothing else: the grid needs nothing else.
- **Continue Watching**: 61 items, newest first, each with its video and position.
- **Discover** (`CatalogWithFilters`): types, each type's catalogs across the account's addons (Cinemeta's
  Popular, New and Featured, the TMDB and TVDB lists of AIOMetadata), the catalog's genres, and pages of 50
  previews with poster, background, logo, description, year, runtime and rating. 445 ms for a page.
- **Search** (`CatalogsWithExtra`): asks all eight search catalogs of the account, mostly the same titles
  three times, and Kitsu's own ranking is poor ("demon slayer" starts with "Onigiri"). The patched web app
  solved this before: Cinemeta's movies and series rows, and an Anime row from AniList (most popular among
  the matches) mapped to Kitsu ids. `Live` already has AniList and the mapping.
- **Calendar** (the core's): one release this month for this library. It asks `calendar-videos`, which
  the Kitsu addon doesn't serve, so an anime library gets nothing. Ours (Cinemeta episodes and AniList's
  air times) stays; it takes the library's titles from the core.
- The account has no avatar set (`user.avatar` is empty).
- **An episode marked** (`core-lab <dir> 'mark:series,tt33043892,https://v3-cinemeta.strem.io/manifest.json,tt33043892:2:5,true'`): the title's
  `watched` field went from `tt33043892:2:3:33:…` to `tt33043892:2:5:35:…` in 760 ms (Cinemeta's meta
  150 ms of it) and was pushed; marked back, the field was the first one again. Its `lastWatched` moved to
  that episode's air date, a date still ahead, and did not move back.
- **Off Continue Watching**: a film played for a minute through the Player model was first on Continue
  Watching; `RewindLibraryItem` and `DismissNotificationItem` took it off (`timeOffset` 0), pushed in 260 ms.

HTTP goes through the host: the core hands each request to a callback and the app answers with Qt's network
stack. One client, one certificate store, and the previews' record and replay cover the core too. The
library builds without tokio, reqwest or a TLS stack.

## Design

```
QML  ──  Account (Seimio.Data)  ──  core.h (C++)  ──  libseimio_core.a (Rust: stremio-core)
              │                          │
              │                          └─ fetch ─► Http (Qt, with the previews' replay)
              └─ Catalog/Live take Continue Watching and the library from it
```

- **`core/`** (Rust): `TvModel` = `ctx`, `link`, `continue_watching`, `library`, `discover`, `player`,
  `details`. C interface: `start(dir, onEvent, onFetch)`, `dispatch(model, actionJson)`, `state(model)`,
  `view(name)` (JSON shaped for the UI where the core's own is too large), `fetched(id, status, body)`,
  `mark(type, meta, base, what, watched, today, days)`.
- **One episode watched or not** is the core's `MarkVideoAsWatched`, which it does on its details of the
  title (`details`: the meta from the account's addons, the library item, its watched field). The core
  marks against the first meta that is ready, in the order of the account's addons; they answer in any
  order and their episode lists differ (this account has Cinemeta and a second meta addon for the same
  ids). So `mark` names the addon the app shows the title from (`base`: Cinemeta's, or the Kitsu
  addon's for an anime) and marks only when that one is what the core will use: it has answered and every
  addon before it has failed. Otherwise the mark fails with a reason (a warning, and an `unmarked` event
  when it fails later) and nothing is written. Marks wait in a queue, a title at a time, and an action
  at a time: each action writes the title's whole state to the API, which keeps the write that reaches
  it last, so the next one goes when the core says that title's write has arrived
  (`LibraryItemsPushedToAPI` naming it alone). Four seasons sent together arrived in any order and left
  the account with seasons still watched that the TV had unmarked. Marking the
  episode you are on moves Continue Watching to the next; marking one whose air date is after the title's
  last-watched date moves that date to it, which is why nothing that airs later has the entry.
- **A film or a related show watched or not** is the title's own state (`MetaItemMarkAsWatched`,
  `timesWatched`), as on its page: `Franchise` reads a film's and a related show's check from it.
- **Off Continue Watching** is what Stremio's own Dismiss sends: `RewindLibraryItem` (the title back to its
  start; it stays in the library and what was watched stays watched) and `DismissNotificationItem` (its
  new-episode notices). The core's rules decide the rest, and two of them show: a film marked watched
  leaves Continue Watching, and so does a title added to the library and removed again (it is no longer
  `temp`).
- **`native/src/core.h`**: owns the core, hops its callbacks to Qt's thread, answers `fetch` with the same
  HTTP helper `Live` uses (moved out of `Live` so both share it and its replay).
- **`Account`** (QML type): `signedIn`, `email`, `avatar`; `link` (code, address, QR, waiting or failed);
  `signOut()`; `inLibrary(id)`, `addToLibrary(item)`, `removeFromLibrary(id)`, `markWatched(item, bool)`,
  `markEpisode(videoId, bool)`, `stopWatching(id)`;
  the player's reports (`playing`, `timeChanged`, `seeked`, `paused`, `ended`, `stopped`). Its lists
  (the library page, a Discover page) are `QAbstractListModel`s filled off the GUI thread.
- **Data**: `Live` takes Continue Watching and the library's state from the core instead of
  `app/stremio/*.json`, and takes them again when the core says they changed (a title finished, a sync).
  The stand-in, `tools/fetch-library.sh` and the probe go. The previews' core runs on a recorded storage
  folder with HTTP replayed, so renders stay fixed.
- **Any title opens**: a Cinemeta series loads its seasons on demand the way an anime loads its franchise,
  so results from search and the tabs open as show pages.

## Screens

Each is built first as a preview state (rendered on the Mac), then on the TV.

1. **Sign in** (when signed out): the code in large letters, the QR, `link.stremio.com`, and what is
   happening (waiting, expired and a new code). Approved, Home loads.
2. **Profile**: a round picture at the top left, on the tab bar's line, reached with Left from Home's tab.
   The account's avatar, or a person glyph when it has none. OK opens a menu with the account's email and
   Log out.
3. **Library**: filters on top (type, sort), a grid of posters under them, no hero. The grid is the Anime
   tab's, made a component (`CardGrid`): recycled rows, art held ahead.
4. **Movies, Series**: the same screen with a hero (the focused title's backdrop and facts, as on the Anime
   tab): filters for the list (Popular, New, Featured, the account's other catalogs) and the genre.
5. **Search**: the search tab opens into a text field and the TV's keyboard comes up. Beside the field
   are the kinds of title, Anime, Series and Movies (`SearchBar`): one is chosen, kept between runs
   (`Catalog.searchKind`, choices.json), and its results are a grid under the focused title's facts and
   backdrop, as on Movies and Series (`SearchScreen`). One cursor walks the bar: crossing a kind doesn't
   choose it, OK does, and a kind the search found nothing of is dim. Up or Back from the grid goes to
   the kinds, not the field: the field with the remote raises the keyboard, which then takes the arrows.
   Left from the first kind is the field.
   Movies and Series are Cinemeta's (IMDb ids); an anime's films and seasons are under Anime by their
   Kitsu ids, titles of their own in Stremio, so the same film can be under both with its own watched
   state in each. Every title found is in the grid. Cinemeta gives twenty of a kind and nothing when
   asked for more; the anime come fifty at a time from AniList, the next fifty asked for near the end of
   the rows (`Catalog.searchMore`). A Cinemeta result with no picture behind its poster's address (a fan
   upload, a reaction video) is left out: the image host is asked once a result.
   A Cinemeta result is a name, a year and pictures (`thin`), so the info shows it as its page's item,
   which is fetched when the cursor rests on it and shown when it is in (`App.rest`, `commit`): one
   version of a title's info. Measured on the TV, it shows 0.39 to 0.45 s after the cursor lands, and
   0.28 s (the rest every title waits) once it has been fetched.
   Back in the bar clears what is typed (with the keyboard up the TV's keyboard takes that Back and
   closes, which the field sees as the keyboard going away); Back on an empty bar leaves the search. OK
   on the field brings the keyboard back.
6. **Add to library / Remove from library** and **Mark watched / Mark unwatched** on the show and title
   pages, by the core's state, and in Home's menu (a long OK on a Continue Watching card), which also has
   **Remove from Continue Watching**. A long OK on any card of a show's row opens its menu, and what the
   card is says what the menu has (`App.menuEntries`): Play AI Pick and Play from Stream for what plays
   (an episode, a film), the library's two entries for a title (a film, a related show), watched or not for
   an episode. A title's card in a grid (the Anime tab, Movies, Series, the Library, a search) has the
   library's two entries, on the card's left where its right has no room; an Anime tab card is AniList's
   until its franchise says which Kitsu title it is, so its menu waits for that. A release in an open
   calendar day has its episode's entry. A season's tab has all of it (a long OK on the season bar:
   "Mark all watched"): each title its cards are for an anime (a season is one or more of Kitsu's
   entries), the season by its number for a plain series. A series marked watched takes its episodes with
   it, wherever it is marked (the core's `MarkAsWatched`, then its seasons, on its details of the title);
   a film, and a series neither Cinemeta nor the Kitsu addon lists, is watched as a title only.
   Only what is out is marked. A season that is all out is the core's `MarkSeasonAsWatched`; that action
   takes every episode the season lists and moves the title's last-watched date to the last of them,
   which would tick episodes still to come and hide their new-episode notices, so a season still airing
   is marked an episode at a time (a write each, about 0.3 s: a thousand-episode show still airing takes
   minutes). Out is the rule the page shows "still to come" by: the episode's day against today, the
   day being AniList's for an anime of this season (`Core::setAiring`, from `Live`'s `airing`) and the
   addon's otherwise. Kitsu's days are a guess of one a week: it had Gensou Suikoden's eighth episode a
   week after it aired. A season's tab leaves out a film whose day hasn't come.
   A page's round check button is the white disc a watched card wears while its title is
   watched. Home's menu has both ways to play, as every menu of something that plays.
   A watched title's poster wears the check in every grid, at once
   and without its row being rebuilt (`Account.watchedTitles`, `CardGrid.marks`); a mark that can't be
   made says "Couldn't mark it" at the bottom of the screen. A menu lists what it opened with until it has closed
   (`QuickMenu`'s `Latch`): its labels follow what they did. The page under it is built again where it is
   (`ShowScreen.refresh`): the focus stays on the card and Play names what it named.
7. **Calendar**: the library's titles and nothing else: each episode of a show in the library on the day
   it comes out. (It listed AniList's whole season as well until 2026-11-18, six to seventeen releases a
   day that weren't the user's.) A title watched without being added is on Continue Watching, not here. An
   anime's episode takes its day and time from AniList, matched by its Kitsu id (`Live::kitsuIds`,
   `airingOf`), and an episode AniList has a time for that the Kitsu addon doesn't list yet is added. OK
   on a day with one release opens its show's page on that episode, as the card of an open day does
   (`CalendarSection.itemOf`); the page lands on it and Play stays on where you are while it is still to
   come (`ShowScreen.land`). A release with no still of its own shows its title's backdrop, in the month
   and in an open day.

## Phases

Each ends with the checks, a review and a commit; the TV tours get a route for each new screen.

A. The core in the app: `core.h`, `Account`, sign-in screen, profile and log out, Continue Watching and
   watch state from the core, the stand-in removed.
B. Progress: the player reports to the core's Player model; Continue Watching follows; Add and Remove;
   Mark watched.
C. `CardGrid`; the Library, Movies and Series tabs; any series opens.
D. Search.
E. The calendar takes the library.
F. Performance and polish across all of it, against the budgets.

## Open performance items (from the 2026-11-18 round)

What the performance pass found, once the lab could name things (`tools/lab-stacks.py` for what the GUI
thread ran in a stall, a late frame's log line for why it was late, Qt's texture and glyph timing for
what reached the GPU in it):

| What held frames up | What it cost | What changed |
|---|---|---|
| The JavaScript engine collecting garbage mid-move | 25 to 34 ms each | collected in the quiet second; 22 ms with a lighter calendar |
| A backdrop sent to the GPU whole | 15 to 20 ms in each crossfade's first frame | `BandedImage`: a band a frame, before the crossfade |
| A frost blurring a crossfading backdrop while it faded out | 30 fps for 300 ms as a page opened from a scrolled grid | its blur stays as it is on the way out |
| Letters reaching the glyph texture on first use | 2 to 7 ms a batch | `Letters` writes the alphabet at launch |
| Calendar days drawn into their textures a week at a time | 20 to 40 ms frames as the month opened or turned | a day a frame |
| A page built the moment its title arrived | 25 ms, with 20 ms to take the title in | the quiet starts 300 ms after OK; taken in and opened on separate frames |
| The stream sheet's rows made at once | 53 ms on the GUI thread | made between frames |
| Network answers parsed on the GUI thread | stalls of 50 to 120 ms | a data thread |
| Every title's meta asked for again when the account's watch state changed | the row followed a removal 2.2 s after the press | metas and a franchise's fetch kept ten minutes: 0.7 s (0.4 s of it the wait for more changes) |

The lab had been wrong in four ways, each measured before it was changed: its own report cost 30 ms every
3 s of a timed run; a pause under 150 ms with nothing moving read as a late frame; a stamp 3 to 4 ms late
read as a frame shown late (more than half of the 20 to 22 ms gaps were followed by one of 10 to 14 ms);
and the GUI thread waiting to hand a frame over, or on the compositor over video, read as a stall (a
stall is now more than 50 ms of the GUI thread's own work, which is what the budget's words say).

Late frames a tour (budget 8; 40 for play and player), the full check before the pass and the range of
the last five after it, each of which passed every tour's budgets:

| Tour | Before | After |
|---|---|---|
| home | 22 | 2 to 8 |
| calendar | 17 | 2 to 6 |
| show | 6 | 0 to 2 |
| menu | 4 | 0 to 1 |
| play | 22 | 4 to 9 |
| streams | 11 | 0 to 4 |
| player | 40 | 8 to 14 |
| browse | 17 | 1 to 4 |

Still there, and why:

- A tab's first visit after launch still costs a frame of 20 to 30 ms: its bars' glass and its first row
  of posters reach the GPU then (the rows after it come a frame apart). Drawing the Anime tab ahead at
  rest was tried and taken out: its heavy frames came 8 s after launch, with the first key presses.
- The first key after a rest shows one frame later: what moves by itself comes back from the render
  thread.
- A title or a show opened from a grid within 1.2 s of landing on it waits for the network before its
  page opens (about 900 ms); nothing is drawn late, but nothing happens either.
