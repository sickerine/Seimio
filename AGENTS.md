# Seimio

A native Stremio client for LG webOS TVs in QML (Qt 5.12 on the TV, Qt 5.15 from Homebrew for Mac
previews). `README.md` has the layout and how to build and run.

## Before every push of UI or performance changes

Run `tools/check.sh` (`--mac` when the TV is off) and push only when it ends with "all checks passed".

- The visual check renders fixed states and `tools/preview/gallery.qml` and `gallery2.qml` (every control in every state)
  and compares them with `tools/preview/baseline/`. A CHANGED state leaves the render and a brightened
  diff in `.lab/shots/`. Look at both: an intended change gets `tools/preview/shots.sh --approve <state>`,
  anything else gets fixed. A new control or state goes into the gallery or the state list too.
  A preview's window is the app's size, larger than the Mac's screen: macOS doesn't draw a window that
  is wholly behind another, and a capture asked of one never comes (the galleries', when they were
  smaller). Renders load images from a fixed cache (`.lab/preview-images`, with redirects and missing stills pinned
  in `pinned.json`); a state that had to fetch one renders again, so no render shows art half arrived.
- The TV check deploys and runs `tools/tour.sh home|calendar|show|menu|play|streams|player|browse` against the frame budget in
  `tour.sh`. A new screen or interaction gets a route there too. (`search` is a route but not in the
  check: the TV's own keyboard slides in as the lab types into the bar, and the frames under it come
  late by their render time with 2 ms of the app's work in them, three a run; two runs came to 3 and 7
  of the budget of 8. Its rows, a title opening, the kinds and Back are what to read in it.) TV runs vary by about 2x, so judge a
  change by three runs, not one. An OVER BUDGET line means a regression; find it like this:
  1. `VARIANT='{"timing": true}' tools/tour.sh <route>`, then `tools/lab-timeline.py` lines up key
     presses with GUI stalls and late frames. A stall a fixed time after a key (280 ms is the selection
     committing) names its cause.
  2. With Qt's renderer timing in the variant, `tools/lab-frames.py` says whether slow frames are
     JavaScript-bound (short render, long GUI stall), draw-call bound (long render, one pass) or
     capture-bound (many passes).
  3. With `"sample": true` beside the timing, `tools/lab-stacks.py` lists what the GUI thread was
     running in each stall (a sample every 4 ms while it runs): `MemoryManager::mark` is a JavaScript
     collection, `QQmlObjectCreator` items being made, `QTextEngine` text laid out, `fromVariant` data
     converted for QML. `"sample": "render"` samples the render thread too (`rstack` lines: where it
     is and its caller only, since unwinding through the GPU driver crashes the app).
  4. To find which layer makes a transition heavy, hide one before the transition and time it again;
     hide nothing that has to take the key (a hidden grid can't be pressed, and the transition then
     never happens).
  A `gui stall`, `gui waited` or `gui tick` (a late animation tick) line ends with `busy`, the GUI thread's own CPU time in the gap: close to the gap means
  our code (JavaScript, bindings, item creation) ran; a few ms means the thread was blocked or starved,
  which under the video is the TV holding the swap (the threaded loop's sync waits for it), not
  something to fix in QML. A stream of 33 ms ticks with `busy 1` is the GUI thread getting its turn
  every other frame: something is animating on the render thread (see `Ambient`). A late tick with
  little work in it is logged as `gui waited` and isn't a stall; with the sampler on, a GUI thread 40 ms
  overdue is sampled whether it runs or not, so `tools/lab-stacks.py <since> 0` shows what it waited in.
  Timing logs perturb the TV; take counts from runs without them. The lab's own report must stay cheap:
  the timing log goes to the lab server from a thread of its own (`LogTap.send`), because turned into
  JSON by the GUI thread it was a 30 ms stall at every report of a timed run. Raise a budget only with
  measurements showing why. A frame counts as late only when it breaks a run of on-time frames: under
  the video nothing animates, and Qt draws only when a subtitle line or the overlay changes, so the gap
  before a frame after a pause isn't lateness. A pause can be short (a frosted backdrop doesn't drift,
  so nothing draws between one move ending and the next key): the gap counts only if the GUI thread's
  work in it and the frame's own time from hand-over to screen account for all but 30 ms of it. And a
  stamp a few ms late is not a frame shown late: of the 20 to 22 ms gaps measured, more than half were
  followed by one of 10 to 14, two frames in two refreshes, so a gap up to 25 ms waits for the next
  frame and counts as on time if the pair is within 35 ms. A late frame's log line says why (`frame`:
  its own time; `gui`: the GUI thread's work in the gap). GUI stalls are counted apart, by a 16 ms heartbeat on
  the GUI thread during tours, so a long one counts whether or not anything was drawing: a stall is more
  than 50 ms of the GUI thread's own CPU time between two ticks. (Counted by the gap between ticks, a
  35 ms piece of work read as a stall of 50 to 100 ms on some runs: the timer's phase and the waits on
  the render thread and the compositor came with it.)

## Performance rules

Each rule comes from a measured stall on the C5.

- Keep Qt's texture atlas off (the plugin sets `QSG_ATLAS_SIZE_LIMIT`). Uploading into the shared atlas
  while the GPU reads it stalled the driver 10 to 15 ms per image.
- Rows a list builds when its data arrives are made asynchronously (`Loader { asynchronous: true }`
  around the row's content, which deals in when ready): a screenful of stream rows made at once was a
  50-65 ms stall. A list on a hidden screen takes its model only while the screen is up.
- Create items once. `CardStrip` recycles a fixed pool of cards; a Repeater takes `model: array.length`
  and reads `array[index]`, so a new array of the same length rebinds instead of rebuilding. A
  MediaCard costs about 2 ms to create on the TV (`{"bench": true}` measures it).
- Hidden screens take their data through an explicit call (`ShowScreen.load()`, `showSeason()`), never
  a binding to the Home selection. Build expensive screens ahead of time while Home is idle: `App.still`
  fires once nothing has moved for a second (a key, rows coming in, a backdrop crossfade all restart it
  through `Remote.stir()`, and so does any change of screen), and the quiet then takes its work a piece
  at a time, a few frames apart
  (`App.quietWork`): the Anime tab once, the selection's page, then the garbage. A page built the moment
  its franchise arrived landed on the tab bar as a 90 ms frame. OK on a title that has to come in first
  is a wait with nothing moving: the quiet begins 300 ms after it, so the page built on arrival (25 ms)
  holds no frame up.
- The JavaScript engine's garbage is collected in that quiet (`gc()`), not when the engine decides to: a
  collection stops the GUI thread for 22 to 35 ms on the TV and came in the middle of a move, sometimes
  twice as a page opened. Its length follows the number of QML objects alive (it walks every one that
  JavaScript has touched), not the data: 11,400 objects took 25 to 34 ms, 8,800 take 22. So what a screen
  keeps many of is made of as few objects as it needs: a calendar day stacks `CardArt` (12 objects), not
  `MediaCard` (45).
- What moves by itself and never ends (the backdrop's drift, the light around today) goes through
  `Ambient`: on the render thread at rest (`Remote.resting`), where a busy GUI thread can't hold it up,
  and on the GUI thread while anything else moves. Never leave an animation on the render thread while
  the GUI thread animates: the render loop then runs by itself and the GUI thread's animations tick every
  other frame (33 ms ticks) on frames that all arrive on time, which the tours can't see. The price is
  one frame more before the first key after a rest shows.
- A component that shows a page of data takes it as one value (`PagedStrip.show(page, index)`, an
  explicit `load()`): as separate inputs set one after another, every card was rebound for each. A page
  that opens on an episode is built once, for the place it lands on.
- A row whose cards change size says how narrow they get (`CardStrip.narrowest`), so its pool is made
  once: sized by the width of the moment, every card was destroyed and made again (22-26 ms).
- Card art stays decoded. Qt keeps ~2 MB of images nothing shows, so a card that a row hands other data
  lets its art go and decodes it again on the way back (covers that came back empty and faded in).
  `ArtCache` holds every `MediaCard`'s art, decoded as the card decodes it; a screen can hold a view's art
  ahead (`ArtCache.keep`). Art goes through `CardArt` (a `MediaCard`'s picture), never a bare `Image` in a
  row or a grid.
  `ArtCache.loads` in the lab state counts cards that had to wait for art: a walk back adds none.
- One shader per full-screen layer, and glass and frost only through `Glass`, `Frost` and `BlurChain`,
  which capture only while visible (`frozen` captures once, and again while `sourceBusy`). A small glass
  over the drifting backdrop (the tab bar) stays live: refreshed twice a second instead, each capture was
  a 14-16 ms frame on its own and often late, where the steady chain costs ~2 ms a frame.
- A full-screen texture nobody sees is not free. `Backdrop` lets go of the picture that faded out: its
  shader samples both, and the second 1080p texture cost 2 to 3.5 ms of every frame.
- Icons are `Icon` (distance-field shaders). Canvas paints in JS and uploads a texture per instance.
- State has one source: selection is `App.displayItem`, changed only by `commit()`; components take one
  input and apply explicit rules, as `Backdrop` and `HeroInfo` document at their top.
  Expect handlers to re-enter: setting a property can emit a signal synchronously (a cached image turns
  Ready inside the assignment), so change your own state before the assignment that may call back. A
  state bug gets a QtQuick test in `tools/tests` that fails before the fix; `check.sh` runs them.
- What was fetched for a title is kept ten minutes (`Live::title`'s metas, `Franchise`'s finished jobs).
  Home is taken again whenever the account's watch state changes (an episode marked, a title off Continue
  Watching, a film ended), and the page in hand asks for its franchise again: with every meta asked of
  the network again, a card left its row 2.2 s after the press. Kept, the row follows in 0.7 s and an
  anime's page in 1.1 s, put together again with the library as it is then.
- A network answer is read off the GUI thread. `Live` and `Franchise` fetch, parse and assemble on
  `Catalog`'s data thread and hand over finished data; `Account` reads the core's views on a worker;
  `Streams` parses its list on one. A show's meta is hundreds of kilobytes of JSON, and reading it where
  it arrived stalled the screen whenever the network answered, at moments no key press explains.
- Data lives in C++ (`Seimio.Data`, `native/src/catalog.h`), parsed on a worker thread. QML asks for
  what a screen needs when it needs it (`Catalog.show(id)`, `Catalog.day(key)`) and keeps the answer
  if identity matters. JavaScript is glue: QML bindings and handlers run in a JS engine whose
  stop-the-world GC grows with what's alive, and moving the catalog and the calendar's day maths to C++
  took the calendar tour from 9-14 late frames to 4-7 and removed its random 120 ms stalls. Models for
  repeated items are C++ `QAbstractListModel`s that signal only the rows that changed.
- Each item costs a draw call and Qt draws items that are off screen. A screen of repeated composites
  (a month of calendar days, each a stack of cards with chips and text) draws each one into its own
  texture (`layer.enabled`): 460 draw calls became 42 quads and the main pass went from 12-15 ms to 2-3.
  Keep anything that animates every frame (today's light) outside the layer, or it re-renders it.
- Fade, move and scale whole composites, never their parts. Opacity on a layered item fades it as one
  piece, natively, without re-rendering it. Per-part fades (darkening colours, child opacities) are
  JavaScript bindings per frame per item and re-render the layer each frame.
- Never drive many items from one animated value: a 0-to-1 property read by 42 days' bindings cost
  30 ms a frame. Give each item its own animation on its own properties (with per-item delays for a
  ripple or stagger), which runs without JavaScript.
- Never ease (Behavior) a value that another animation already drives: the easing restarts every frame
  and lags far behind, so the result looks stuck.
- Bulk updates go a few items per frame. A day's update (bindings, text layout, image source) is ~3 ms
  on the TV: a month at once was 80-110 ms, a week at a time 25 ms a frame. `MonthGrid.refill()` updates
  what's on screen at once and the rest three days a frame, each before its own fade-in starts.
- Precompute what an item shows in one JavaScript call and hand it over as plain fields; Date maths and
  helper calls inside each item's bindings multiply by the item count.
- A Repeater's count never depends on data in something that refreshes: keep a fixed pool and hide what
  isn't needed (two back cards per day; creating them per month cost ~100 ms).
- Under the video, nothing behind it may animate: the scene is made invisible (not just transparent)
  once it has faded out, which stops the backdrop's zoom and the calendar's light. Every frame Qt draws
  over a playing video risks a late swap on the TV.
- Hidden things don't follow the selection (`HeroInfo` gets `null` while the calendar hides it), and
  work that runs while something slides away waits until it has (the calendar returns to today 520 ms
  after it leaves).
- A frozen blur refreshes every 50 ms, not every frame, while its source changes (`BlurChain`); every
  frame cost ~10 render passes and a blur that wide hides the difference, except during the backdrop's 700 ms crossfade
  (`sourceMoving`), where a full-screen frost stepping at 20 Hz showed; that costs no late frames.
- Blur once. Glass over a Frost samples the frost directly (`preblurred`) instead of blurring it again.
- Nothing opaque is drawn over something still drawn under it. A frost fully faded in covers the
  backdrop: it hides it (`hideCovered`, ShaderEffectSource `hideSource`, still captured) and the backdrop's
  zoom pauses (`covered`). Drawing it under the frost was a full-screen pass a frame; with the
  off-screen cards (below) it held the Anime schedule at 30 fps (55 late frames a tour, now ~10).
- Off screen is not free: a strip's cards and a list's rows that are fully off screen are `visible:
  false`. A sliding row keeps cards past both edges, and a recycled row slot sits below the screen.
- What the GPU sees for the first time costs the frame that shows it, so it is sent ahead or in pieces:
  - A picture the size of the screen goes up a band a frame (`BandedImage`, the backdrop's): sent whole it
    took 15 to 20 ms in the frame that first drew it, a late frame at every backdrop change (Qt's own
    texture log says 3 ms; the driver does the rest at first use). Never write to a texture the last
    frame read: the driver stalls 10 to 15 ms.
  - Letters go to the glyph texture in batches of 2 to 7 ms. `Letters` writes the whole alphabet in each
    weight at launch, off screen, so a title that comes in later uploads nothing.
  - `VARIANT` with `qt.scenegraph.time.texture.debug=true` and `...time.glyph.debug=true` lists both per
    frame.
- What a list makes, it makes a row a frame: a ListView one pixel tall with a `cacheBuffer` builds its
  first row at once and the rest between frames (the player's stream sheet: nine rows at once were 53 ms
  on the GUI thread), and a title that arrives from the network is taken in on one frame and its page
  opened on the next (together they were one 60 to 70 ms stall).
- A frost follows its source only while it is wanted. On its way out its blur is left as it is
  (`backdropFrost.leaving`): a backdrop still crossfading under it as a page opened had it blurred again
  every frame of the fade, five passes more, and the page opened at 30 fps.
  - A grid coming on screen shows its rows a frame apart (`CardGrid.arrived`): a tab's first visit drew
    two rows of new posters in one frame, 25 to 35 ms. Drawing a tab ahead at rest instead (faintly, as
    it is built) was tried and taken out: its heavy frames come 8 s after launch, when the first keys do.
- A layer is drawn again whenever its item comes back on screen, at any opacity: the calendar's 42 days
  (a texture each) cost 13 to 15 ms in the frame Home returns in. Hiding the days a peek doesn't show is
  worse: they then draw, and send their art to the GPU, only as the month opens (28 days in one 134 ms
  frame) instead of one by one as the art arrives at launch. And no layer the size of the screen for a
  passing effect: a grid dimmed through one made the texture anew each time a list loaded (a 13 ms
  frame); it dims by opacity.
- A recycled row slot rebinds its cards (7 at once, 40-60 ms) when nothing shows it: right away if
  it will be on screen when the scroll ends, else once the scroll ends. New rows reach the slots a frame
  apart, top first, while the list fades in, and a row's layout (card size) travels with its data.
- Batch data arrival: the calendar is built once when all its sources have arrived, and a refresh goes
  through the same staging as a month turn.

## Data

Nothing is baked into the app: everything comes live from the services when it starts (`native/src/live.h`:
Cinemeta, the Kitsu addon, AniList, ARM, metahub), and images go through a disk cache. Never add a fetched
snapshot of data or art to make something look finished; the Mac's visual check alone replays recorded
answers (`tools/preview/api/`) so its renders stay fixed.

The Stremio account is Stremio's own core (`core/`, Rust: `stremio-core` behind a C interface;
`native/src/core.h`, `account.h`): signing in with a link code, the library, Continue Watching, watch
state and its rules. Nothing about the account is reimplemented: what counts as watched, what Continue
Watching holds and how devices merge are the core's. `docs/stremio-integration.md` has the plan and what
was measured. The core's HTTP goes through `Http` like everything else; a request to Stremio's API (it
carries the account's key) is never recorded and never made in a preview. The previews' account is the
core's storage in `tools/preview/account/` (not in git), signed in once:
`core/target/release/core-lab tools/preview/account '|{"action":"Ctx","args":{"action":"Authenticate","args":{"type":"Login","email":"…","password":"…","facebook":false}}}' wait:6000`.
On the TV a tour can't approve a code, so the lab signs in: `{"signIn": ["email", "password"]}` in the
variant.

What a menu does to a title is done to the account, on every device: Add to library, Mark watched, an
episode marked, Remove from Continue Watching. Trying one on the TV, read which title has the focus from
the lab report before every press (`focusItem`, `library.item`), and stop when it isn't the one meant: a
film marked watched leaves Continue Watching, the focus moves to the next card, and the next press lands
on that title. Use a film nobody is watching, put on Continue Watching from the Mac
(`core/target/release/core-lab`: load the Player model on it and send `TimeChanged`), and
`'mark:<type>,<title>,<the addon's manifest address>,<episode | season:N | *>,<true|false>'` for an
episode, a season or all of a title (then `<episode>=<day>` for each day the app would give). A long OK
over the network remote is `tools/tvremote.mjs press ENTER 16 40`, and the lab report says which card the
open menu is for and what it lists (`menuCard`, `menuEntries`).

A card's menu follows what the card is, the same wherever that kind of card is (`App.menuEntries`): Play
AI Pick and Play from Stream for what plays, the library's two entries for a title, watched or not for an
episode. Every card has one on a long OK: a show's row (episodes, films, specials, related shows), a
grid's titles (the Anime tab, Movies, Series, the Library, a search: `CardGrid.cardHeld`), a release in an
open calendar day, a Continue Watching card. A new row of cards takes its menu from there; a kind of card
with no menu is a bug. Only what has nothing to offer opens none: a release that airs later, an anime
that Kitsu doesn't have (it is no title of Stremio's).

A card never stays gray when its title has art: an episode shows its own still (the addon's, Kitsu's or
Cinemeta's), and where that can't be had (one still to come has none; Cinemeta's address for it answers
404) its entry's backdrop, else the title's (`CardArt.fallback`: `ShowScreen.backdropOf`, a release's
`fallback`, a calendar cell's `back0..2`). A new kind of card gets a fallback with its art.

What is watched wears the check wherever its card is: an episode, a film or a related show by its own
data, a title's poster in a grid by the account's watched titles (`Account.watchedTitles` to
`CardGrid.marks`; an anime by its `kitsu` id, which `Live::kitsuIds` gives the chart's and a search's
shows). A mark that can't be made says so (`App.say`, the one chip at the bottom of the screen). A series
marked watched takes its episodes with it and a season's tab marks all of it (`Account.markWatched`,
`markSeason`: the core's own actions, queued in `core/src/lib.rs`, one write to Stremio at a time), the
ones that are out by the days the page shows (docs/stremio-integration.md); a page's check button shows
the title's state at rest.

What is done to one title redraws that title and nothing else: no page is shown again, no cursor goes
back to the top. The Library's grid changes where it is when a title leaves or joins it, the cards after
a removed one sliding over (`BrowseScreen.take`, `CardGrid.closeUp`), and leaves another order of the
same titles for when it next comes on screen. To check a change on the TV, count: the lab report's
`redraws` (`Remote.tally`: "grid shown" is a whole page shown again, "grid replaced" rows changed in
place, "info" and "backdrop" the title above, "page loaded" and "page refreshed" a show page, "home
taken" Continue Watching's row, "day built" an open calendar day, "info cut" a title replaced while it
was still fading in, which is a flicker and should stay at none). Read it before and after the action;
only what the action is about may have moved. Measured on 2026-11-18 for adding to and removing from
the library (search, Home, the Anime tab, the Library), marking watched (the Library, an episode on its
page) and Remove from Continue Watching: none shows a grid again.

The cursor on Continue Watching stays on its title when the row comes back in another order
(`HomeScreen.take`): what has the focus is set whole, with the row, never by a place in it.

## Playback

What the TV plays is measured: `docs/playback.md` has the table, and `native/src/playback.h` is that table
as code, read by the picker and the player, so a codec rule lives there and nowhere else. A claim about a
format comes from that table or from a new run of `tools/playback-matrix.py`, confirmed on the screen and
by ear. LG's pipeline reports "playing" for sound it can't decode and for pictures it breaks, and LG's own
format list differs from the TV, so neither settles anything.

## Visual rules

- Balance by what is drawn. Centre a control's content from the tops of the capitals, pad icons by
  `Icon.inkLeft`/`inkRight`, and centre a label and anything under it (a progress bar) as one block.
  Measure the gaps on a 2x render (see the gallery) rather than trusting box maths.
- Nothing shifts once shown: give placeholders the final size, and fade art in when it's decoded.
- One version of everything. A title's backdrop, logo, name and facts show once, in their final form:
  never a name that a logo then replaces, a small backdrop that a larger one replaces, or the same
  picture again from another URL. Load first (preload, then commit; `TitleArt`, `HeroInfo`, `Backdrop`
  wait for the image), and when better data arrives for something already on screen, keep what's shown
  (a franchise's item is the chart's or the row's own, with its Kitsu id: `Franchise`). A screen gets its data whole: `Live`
  fetches every piece of art and fact it needs before the screen's data is ready. The name stands in only
  when there's no logo at all.
  A preload only preloads if it asks for the picture exactly as the element that shows it does: Qt
  keeps a picture by its address, `sourceSize` and `fillMode`, so a hidden `Image` with another fit
  fetches a copy nothing uses and the visible one is fetched after it (a logo came in a second or more
  after its title, from fanart.tv at 25 KB/s). And what is on screen stays until its replacement is
  loaded: `HeroInfo` fades the old title out only then, and its swap takes no longer than the rest a
  title is taken after (`Theme.settle`), so a fade-in is never cut short by the next title.
- What fades out keeps showing what it showed until its fade ends: the end of the animation is the end,
  not its start. Things come and go through `Fade`, whose content can only read the value it holds
  (`current`); a panel with its own motion holds what it shows in a `Latch` (`live` while open). Never an
  `opacity` switched by a condition with content that reads that condition: the subtitle panel's delay
  row vanished the moment its fade began, and so did the "Loading Summer 2026" chip. `check.sh` fails on
  any `opacity` a condition switches, in a screen or a component, unless its line says why what it shows
  holds (`// holds: ...`).
- Reuse the library (`app/Seimio/UI`) before writing a new control; extend it when a screen needs a
  variant, so every screen keeps the same chips, buttons, glass and motion (`Theme` durations and
  easing).

## Qt 5.12 on the TV

The Mac runs Qt 5.15, so code that works there can fail on the TV. Use `onFoo:` handlers in
`Connections` (the function syntax is 5.15), and check property names against FINAL ones (`left`,
`right`, `bottom` on Item) and reserved GLSL words (`half`).
