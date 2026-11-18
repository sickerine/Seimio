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

- **`core/`** (Rust): `TvModel` = `ctx`, `link`, `continue_watching`, `library`, `discover`, `player`.
  C interface: `start(dir, onEvent, onFetch)`, `dispatch(model, actionJson)`, `state(model)`, `view(name)`
  (JSON shaped for the UI where the core's own is too large), `fetched(id, status, body)`.
- **`native/src/core.h`**: owns the core, hops its callbacks to Qt's thread, answers `fetch` with the same
  HTTP helper `Live` uses (moved out of `Live` so both share it and its replay).
- **`Account`** (QML type): `signedIn`, `email`, `avatar`; `link` (code, address, QR, waiting or failed);
  `signOut()`; `inLibrary(id)`, `addToLibrary(item)`, `removeFromLibrary(id)`, `markWatched(id, bool)`;
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
5. **Search**: the search tab opens into a text field and the TV's keyboard comes up. Results under it as
   three rows: Movies, Series, Anime.
6. **Add to library / Remove from library** on the show and title pages, by the core's state.
7. **Calendar**: library titles' releases, first in each day.

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

- The Home tour runs 9 to 13 late frames against 8 on a day when the last commit measures 8 to 15. What
  is left is single frames a few ms late at crossfade starts and tab changes, and GUI time outside our
  handlers that the lab can't attribute yet (the handlers themselves measure 0 to 18 ms).
- Opening a franchise page that wasn't built ahead is a ~50 ms GUI stall (the row's cards and the season
  bar). A staged load (header, then row) would halve it.
- The browse tour (Movies, Series, Library): the rows themselves scroll without a late frame. A title
  opened 700 ms after a move, before it was fetched ahead, opens while the backdrop crossfades and the
  grid fades: 6 to 10 frames at 30 fps. Opened a second later it costs one or two. A tab's first show
  is a 60 to 70 ms GUI stall (its rows' first cards).
