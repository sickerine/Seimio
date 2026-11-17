# Seimio

A native Stremio client for LG webOS TVs in QML (Qt 5.12 on the TV, Qt 5.15 from Homebrew for Mac
previews). `README.md` has the layout and how to build and run.

## Before every push of UI or performance changes

Run `tools/check.sh` (`--mac` when the TV is off) and push only when it ends with "all checks passed".

- The visual check renders fixed states and `tools/preview/gallery.qml` (every control in every state)
  and compares them with `tools/preview/baseline/`. A CHANGED state leaves the render and a brightened
  diff in `.lab/shots/`. Look at both: an intended change gets `tools/preview/shots.sh --approve <state>`,
  anything else gets fixed. A new control or state goes into the gallery or the state list too.
- The TV check deploys and runs `tools/tour.sh home|calendar|show|menu|play|streams|player` against the frame budget in
  `tour.sh`. A new screen or interaction gets a route there too. TV runs vary by about 2x, so judge a
  change by three runs, not one. An OVER BUDGET line means a regression; find it like this:
  1. `VARIANT='{"timing": true}' tools/tour.sh <route>`, then `tools/lab-timeline.py` lines up key
     presses with GUI stalls and late frames. A stall a fixed time after a key (280 ms is the selection
     committing) names its cause.
  2. With Qt's renderer timing in the variant, `tools/lab-frames.py` says whether slow frames are
     JavaScript-bound (short render, long GUI stall), draw-call bound (long render, one pass) or
     capture-bound (many passes).
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
  a binding to the Home selection. Build expensive screens ahead of time while Home is idle.
- One shader per full-screen layer, and glass and frost only through `Glass`, `Frost` and `BlurChain`,
  which capture only while visible (`frozen` captures once, and again while `sourceBusy`).
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
  frame cost ~10 render passes and a blur that wide hides the difference.
- Blur once. Glass over a Frost samples the frost directly (`preblurred`) instead of blurring it again.
- Batch data arrival: the calendar is built once when all its sources have arrived, and a refresh goes
  through the same staging as a month turn.

## Visual rules

- Balance by what is drawn. Centre a control's content from the tops of the capitals, pad icons by
  `Icon.inkLeft`/`inkRight`, and centre a label and anything under it (a progress bar) as one block.
  Measure the gaps on a 2x render (see the gallery) rather than trusting box maths.
- Nothing shifts once shown: give placeholders the final size, and fade art in when it's decoded.
- Reuse the library (`app/Seimio/UI`) before writing a new control; extend it when a screen needs a
  variant, so every screen keeps the same chips, buttons, glass and motion (`Theme` durations and
  easing).

## Qt 5.12 on the TV

The Mac runs Qt 5.15, so code that works there can fail on the TV. Use `onFoo:` handlers in
`Connections` (the function syntax is 5.15), and check property names against FINAL ones (`left`,
`right`, `bottom` on Item) and reserved GLSL words (`half`).
