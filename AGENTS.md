# Seimio

A native Stremio client for LG webOS TVs in QML (Qt 5.12 on the TV, Qt 5.15 from Homebrew for Mac
previews). `README.md` has the layout and how to build and run.

## Before every push of UI or performance changes

Run `tools/check.sh` (`--mac` when the TV is off) and push only when it ends with "all checks passed".

- The visual check renders fixed states and `tools/preview/gallery.qml` (every control in every state)
  and compares them with `tools/preview/baseline/`. A CHANGED state leaves the render and a brightened
  diff in `.lab/shots/`. Look at both: an intended change gets `tools/preview/shots.sh --approve <state>`,
  anything else gets fixed. A new control or state goes into the gallery or the state list too.
- The TV check deploys and runs `tools/tour.sh home|show|menu` against the frame budget in `tour.sh`.
  An OVER BUDGET line means a regression: find it with `VARIANT='{"timing": true}' tools/tour.sh <route>`
  and `.lab/reports/*-design.json`, whose `log` lines stamp key presses, late frames and GUI-thread
  stalls. Raise a budget only with measurements showing why.

## Performance rules

Each rule comes from a measured stall on the C5.

- Keep Qt's texture atlas off (the plugin sets `QSG_ATLAS_SIZE_LIMIT`). Uploading into the shared atlas
  while the GPU reads it stalled the driver 10 to 15 ms per image.
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
