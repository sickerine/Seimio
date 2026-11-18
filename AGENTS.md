# Seimio

A native Stremio client for LG webOS TVs in QML (Qt 5.12 on the TV, Qt 5.15 from Homebrew for Mac
previews). `README.md` has the layout and how to build and run.

## Before every push of UI or performance changes

Run `tools/check.sh` (`--mac` when the TV is off) and push only when it ends with "all checks passed".

- The visual check renders fixed states and `tools/preview/gallery.qml` and `gallery2.qml` (every control in every state)
  and compares them with `tools/preview/baseline/`. A CHANGED state leaves the render and a brightened
  diff in `.lab/shots/`. Look at both: an intended change gets `tools/preview/shots.sh --approve <state>`,
  anything else gets fixed. A new control or state goes into the gallery or the state list too.
  Renders load images from a fixed cache (`.lab/preview-images`, with redirects and missing stills pinned
  in `pinned.json`); a state that had to fetch one renders again, so no render shows art half arrived.
- The TV check deploys and runs `tools/tour.sh home|calendar|show|menu|play|streams|player` against the frame budget in
  `tour.sh`. A new screen or interaction gets a route there too. TV runs vary by about 2x, so judge a
  change by three runs, not one. An OVER BUDGET line means a regression; find it like this:
  1. `VARIANT='{"timing": true}' tools/tour.sh <route>`, then `tools/lab-timeline.py` lines up key
     presses with GUI stalls and late frames. A stall a fixed time after a key (280 ms is the selection
     committing) names its cause.
  2. With Qt's renderer timing in the variant, `tools/lab-frames.py` says whether slow frames are
     JavaScript-bound (short render, long GUI stall), draw-call bound (long render, one pass) or
     capture-bound (many passes).
  A GUI stall line ends with `busy`, the GUI thread's own CPU time in the gap: close to the gap means
  our code (JavaScript, bindings, item creation) ran; a few ms means the thread was blocked or starved,
  which under the video is the TV holding the swap (the threaded loop's sync waits for it), not
  something to fix in QML. A forced JS collection measured 19 ms, so a 100 ms stall isn't the GC.
  Timing logs perturb the TV; take counts from runs without them. Raise a budget only with
  measurements showing why. A frame counts as late only when it breaks a run of on-time frames: under
  the video nothing animates, and Qt draws only when a subtitle line or the overlay changes, so the gap
  before a frame after a pause isn't lateness. GUI stalls are counted apart, by a 16 ms heartbeat on
  the GUI thread during tours, so a long one counts whether or not anything was drawing.

## Performance rules

Each rule comes from a measured stall on the C5.

- Keep Qt's texture atlas off (the plugin sets `QSG_ATLAS_SIZE_LIMIT`). Uploading into the shared atlas
  while the GPU reads it stalled the driver 10 to 15 ms per image.
- Rows a list builds when its data arrives are made asynchronously (`Loader { asynchronous: true }`
  around the row's content, which deals in when ready): a screenful of stream rows made at once was a
  50-65 ms stall. A list on a hidden screen takes its model only while the screen is up.
- Create items once. `CardStrip` recycles a fixed pool of cards; a Repeater takes `model: array.length`
  and reads `array[index]`, so a new array of the same length rebinds instead of rebuilding. A
  MediaCard costs about 1.3 ms to create on the TV.
- Hidden screens take their data through an explicit call (`ShowScreen.load()`, `showSeason()`), never
  a binding to the Home selection. Build expensive screens ahead of time while Home is idle: `App.still`
  fires once nothing has moved for a second (a key, a tab, a backdrop crossfade all restart it) and does
  one piece of work a firing (the selection's page, then the Anime tab once). A page built the moment its
  franchise arrived landed on the tab bar as a 90 ms frame.
- A component that shows a page of data takes it as one value (`PagedStrip.show(page, index)`, an
  explicit `load()`): as separate inputs set one after another, every card was rebound for each. A page
  that opens on an episode is built once, for the place it lands on.
- A row whose cards change size says how narrow they get (`CardStrip.narrowest`), so its pool is made
  once: sized by the width of the moment, every card was destroyed and made again (22-26 ms).
- Card art stays decoded. Qt keeps ~2 MB of images nothing shows, so a card that a row hands other data
  lets its art go and decodes it again on the way back (covers that came back empty and faded in).
  `ArtCache` holds every `MediaCard`'s art, decoded as the card decodes it; a screen can hold a view's art
  ahead (`ArtCache.keep`). Art goes through `MediaCard`, never a bare `Image` in a row or a grid.
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
