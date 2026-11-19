# State, transitions and queries: what mature libraries do

Research for a shared way to handle state changes, animated swaps and network requests in Seimio.
Read on 2026-11-18 from the libraries' own docs and source. Nothing here is built yet.

What the TV can take, checked on the device and in `native/build.sh`:

- The plugins are built with `arm-webos-linux-gnueabi-g++ -std=c++17`, so header-only C++11, C++14 and
  C++17 libraries compile.
- The TV has Qt 5.12.12 with `QtConcurrent` and the `QtQml.StateMachine` QML module. It has no `QtScxml`.
- The TV's C++ runtime is `libstdc++.so.6.0.32`.

## Queries

TanStack Query, SWR and RTK Query agree on one model. Each rule below names where it is written down.

1. **A request has a key, and the cache holds one entry per key.** Every consumer of a key reads the
   same entry, and all of them change together when it changes. TanStack Query: "both queries' status
   are updated ... because they have the same query key" [1]. RTK Query serialises the endpoint and
   its arguments into a `queryCacheKey` [2].
2. **Two separate questions, two separate fields.** `status` (pending, error, success) says whether
   there is data. `fetchStatus` (fetching, paused, idle) says whether a request is running. "Background
   refetches and stale-while-revalidate logic make all combinations ... possible" [3]. SWR has the same
   split as `isLoading` (a request and no data yet) and `isValidating` (any request) [4].
3. **A second request for a key joins the one in flight.** `Query.fetch` returns the running promise
   when `fetchStatus` isn't idle [5]. RTK Query: a request with the same key "will be de-duped against
   the original" [2]. SWR dedupes by key for 2 s (`dedupingInterval`) [6].
4. **Fresh and kept are different times.** `staleTime` is how long data counts as fresh (default 0).
   `gcTime` is how long an entry nobody uses is kept (default 5 minutes) [7]. RTK Query counts
   subscribers and removes an entry 60 s after the count reaches zero (`keepUnusedDataFor`) [2].
   Stale data is shown at once and refreshed behind it, which is HTTP's `stale-while-revalidate`.
   `stale-if-error` returns stale data when the refresh fails [8].
5. **The data on screen stays while the key changes.** `placeholderData: keepPreviousData` shows the
   last key's data until the new key's arrives, with `isPlaceholderData` to mark it [9]. SWR:
   `keepPreviousData` [6].
6. **Cancelling has a defined result.** The request function gets an abort signal. A cancelled query
   goes back to the state it had before the fetch [10]. When the last consumer leaves, the fetch is
   cancelled only if the transport can cancel. Otherwise "we'll let the query continue so the result
   can be cached" [5]. That is the rule `BandedImage`'s asides follow.
7. **A failure is retried before anyone sees it.** Three retries, the delay doubling from 1 s and
   capped at 30 s. The error shows after the last one, and `failureReason` carries it meanwhile [11].
8. **An answer that lost a race is dropped by the library.** SWR names the event: `onDiscarded`, "when
   a request is ignored due to race conditions" [6].
9. **State changes through one reducer.** A query's state changes only in `#dispatch`, on eight
   actions: fetch, success, error, failed, pause, continue, invalidate, setState [5].
10. **Consumers are told in batches.** `notifyManager.batch` queues notifications and flushes once
    when the outermost batch ends [12].
11. **Unchanged data keeps its identity.** Results are "structurally shared to detect if data has
    actually changed and if not, the data reference remains unchanged" [7].
12. **The cache can be looked at.** The devtools "visualize all the inner workings", and a predefined
    error can be switched on for one query from their UI to see how a screen takes it [13].

Seimio today: `Live::title` and `Franchise` each keep answers ten minutes in their own way, six C++
files have a private "latest wins" counter, and a failed request is mostly dropped where it arrives.

## Transitions and animation

1. **A new target starts from where the value is now.** Compose `Animatable`: `animateTo` during an
   animation continues "from its current value ... to the new targetValue. This ensures that the value
   change is always continuous", and with a spring the velocity is continuous too. The animation it
   replaces is cancelled, so only one runs [14]. Flutter's implicit animations set
   `begin = tween.evaluate(_animation)` and restart the controller [15]. CSS transitions start from the
   current value, and one that turns back takes less time in proportion (the "reversing shortening
   factor") [16]. SwiftUI: a retargeted spring "uses the velocity it had when it was retargeted" [17].
2. **Swapping content has three named policies.**
   - Both at once. Motion's `sync`, Vue's default. Flutter's `AnimatedSwitcher`: "more than one
     previous child can exist and be transitioning out while the newest one is transitioning in" [18].
     Compose's `AnimatedContent` keeps outgoing content until its exit ends, and caps it at three
     (`MaxInterruptionRetention`) so fast changes don't pile up [19].
   - One at a time. Motion's `wait`: "Wait for the exiting component to animate out before animating
     the next component in" [20]. Vue's `out-in` [21].
   - Hold what is shown until the new content is ready. React: an update marked as a Transition
     doesn't hide content already shown, `isPending` says one is under way, and a newer update
     interrupts it [22]. Compose's `DeferredTransitionState` holds a `pendingTargetState` while "the actual
     targetState remains unchanged, keeping the transition in its current visual state" [23].
   `HeroInfo` is the second and third combined, written by hand.
3. **"Finished" is a signal with a defined meaning.** SwiftUI has two: `logicallyComplete` (done, may
   still be settling) and `removed` (all animations over), and "the completion callback will always be
   fired exactly one time" [24]. Motion: `onExitComplete` [20]. Qt's own state machine:
   `propertiesAssigned()` is emitted "when the property is assigned its final value, whether this is
   done immediately or after the animation has finished playing" [25].
4. **What interrupts what is declared.** GSAP's `overwrite`: `true` kills every tween of the same
   target, `"auto"` kills only the conflicting properties, `false` kills nothing [26]. Compose's
   `MutatorMutex`: "A mutation of equal or greater priority will interrupt the current mutation in
   progress", with user input above programmatic animation [27].
5. **Leaving a state stops its work.** XState: an invoked actor is "started when the state is entered,
   and stopped when the state is exited", and a delayed transition doesn't complete if another event
   comes first [28]. Qt's state machine guarantees that a property left mid-animation ends at a value
   some state assigned, and says which [25].
6. **Identity decides whether anything animates.** Same key, the content is updated in place.
   Different key, it transitions. Flutter's `AnimatedSwitcher` [18] and Compose's `contentKey` [19].
   `HeroInfo.same()` is a private version of this.
7. **Derived values are never read half-updated.** In the TC39 Signals proposal a computed value is
   lazy, and it "always observes the Signal graph in a consistent state" [29]. QML gives no such
   promise: a handler and a binding on the same signal run in connection order. The `Preload` bug on
   2026-11-18 was a handler reading a bound `loading` flag before the binding ran.

## Pictures

Image loaders treat a picture as a query with extra rules.

- **Glide** looks in four places in order: pictures on screen, memory, the decoded picture on disk, the
  original bytes on disk. The first three key on width, height and transformation as well as the
  address [30]. That is the same trap as Qt's key of address, `sourceSize` and `fillMode`.
  `thumbnail()` loads a second request in parallel and shows it only if the main one isn't in first.
  `error()` starts another request when the main one fails [31].
- **Fresco** has "first available image": given several addresses for one picture, it checks memory
  for all of them, then disk for all of them, then the network [32]. That is "the title's own picture
  if we have it, else the quick one", decided by looking in the caches, with no timer.
- **Kingfisher** takes a list of `alternativeSources` tried in order on failure, and a cancellation by
  the user doesn't start the next one. `keepCurrentImageWhileLoading` holds the old picture [33].
- **Nuke** shares one download between requests and cancels it only when all of them have cancelled.
  Prefetches run at low priority and may use only some of the download slots. A download cut short resumes with an HTTP Range
  request when the server sends an `ETag` or `Last-Modified` [34]. fanart.tv answers a Range request
  with 206 (checked 2026-11-18) but sends neither validator.

## C++ libraries we could use as they are

| Library | What it gives | Needs | On this TV |
|---|---|---|---|
| Qt `QStateMachine`, `QtQml.StateMachine` [25][35] | Statecharts with animated transitions, `propertiesAssigned()`, defined exit mid-animation | Qt 5 | Installed. One QObject per state and per transition, cost not measured |
| Boost.SML [36] | State machine as a compile-time table, no allocation | C++14, one header | Builds. Logic only, no timers or animation |
| HFSM2 [37] | Hierarchical state machine, no allocation | C++11, header-only | Builds |
| TinyFSM [38] | Small flat state machine | C++11, header-only | Builds |
| QtPromise [39] | Promises for Qt: `then`, `fail`, `finally`, `timeout`, `all` | Qt 5.6, C++11, header-only | Builds. No cancel in its API. Last push 2024-08 |
| KDBindings [40] | Properties with lazy bindings outside QML | C++17, header-only | Builds |
| continuable [41] | Async chains with cancellation | C++14, header-only | Builds. Last push 2023-09 |
| RxCpp [42] | Reactive streams | C++11 | Builds. Large. Last push 2024-07 |
| QCoro [43] | Coroutines for Qt | Qt 6.8 | No |
| AsyncFuture [44] | Chained, cancellable `QFuture` | Qt 6.8 (the Qt 5 original is archived) | No |

No C++ or Qt port of a TanStack-style query cache turned up. GitHub searches for one returned nothing
relevant, and the ports that exist are for Dart, Rust and .NET [45]. The cache would be ours to write,
to the twelve rules above.

## What this points to

My reading, for discussion.

- **Queries.** One C++ `Query` type on top of `Http`, copied from TanStack Query's design: a key, a
  reducer over the two status fields, counted observers, a shared in-flight request, fresh and kept
  times, retry with backoff, cancel or let finish, batched notification. Nothing to import does this.
  QtPromise could replace the nested callbacks in `Franchise` and `Live`, which is a separate gain.
- **Transitions.** One component with a named policy (both at once, one at a time, hold until ready),
  a key that decides whether to animate, retargeting from the current value, a cap on outgoing
  content and one "finished" signal fired once. Qt's state machine is the only ready-made piece. It
  fits a screen's flow better than a per-card swap, and its cost on the TV needs measuring first.
- **Pictures.** A list of addresses per picture with Fresco's first-available rule, shared downloads,
  priorities, and resuming for the slow host.
- **Tooling.** A list of live queries and transitions in the lab report, and a switch to force a slow
  or failed answer, as the TanStack devtools have.

## What was built from it

| Part | Where | Tests |
|---|---|---|
| The query cache, observers, `All`, `inTurns`, `onWorker` | `native/src/query.h` | `tools/tests/native/tst_query.cpp` |
| The transport under it | `native/src/net.h` | `tst_net.cpp` |
| Watching a query from another thread | `native/src/watch.h` | `tst_watch.cpp` |
| The picture loader | `native/src/pictures.h` | `tst_pictures.cpp` |
| The swap of what is on show | `app/Seimio/UI/Swap.qml` | `tools/tests/tst_swap.qml` |

Two of the libraries above were weighed again when their turn came, and left out:

- **QtPromise** builds for the TV and its `all` is what a dozen hand-kept counters did. Its handlers
  belong to no object: one that captures `this` runs after the object is gone, and nothing in its API
  stops a chain. An answer from the cache or from `Net` is dropped with its owner, which is the
  behaviour the rest of the data code relies on. `query::All` and `query::inTurns` are the two joins
  the code needs, under forty lines with their own tests.
- **Qt's state machine** reacts only to signals sent after a state is entered, so a target that
  changed while a transition ran needs the same bookkeeping `Swap` does. `Swap` decides in one
  function instead.

## Sources

1. https://github.com/TanStack/query/blob/main/docs/framework/react/guides/caching.md
2. https://github.com/reduxjs/redux-toolkit/blob/master/docs/rtk-query/usage/cache-behavior.mdx
3. https://github.com/TanStack/query/blob/main/docs/framework/react/guides/queries.md
4. https://github.com/vercel/swr-site/blob/main/content/docs/advanced/understanding.mdx
5. https://github.com/TanStack/query/blob/main/packages/query-core/src/query.ts
6. https://github.com/vercel/swr-site/blob/main/content/docs/api.mdx
7. https://github.com/TanStack/query/blob/main/docs/framework/react/guides/important-defaults.md
8. https://www.rfc-editor.org/rfc/rfc5861.txt
9. https://github.com/TanStack/query/blob/main/docs/framework/react/guides/paginated-queries.md
10. https://github.com/TanStack/query/blob/main/docs/framework/react/guides/query-cancellation.md
11. https://github.com/TanStack/query/blob/main/docs/framework/react/guides/query-retries.md
12. https://github.com/TanStack/query/blob/main/packages/query-core/src/notifyManager.ts
13. https://github.com/TanStack/query/blob/main/docs/framework/react/devtools.md
14. https://github.com/androidx/androidx/blob/androidx-main/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/Animatable.kt
15. https://github.com/flutter/flutter/blob/master/packages/flutter/lib/src/widgets/implicit_animations.dart
16. https://www.w3.org/TR/css-transitions-1/#reversing
17. https://developer.apple.com/videos/play/wwdc2023/10158/
18. https://github.com/flutter/flutter/blob/master/packages/flutter/lib/src/widgets/animated_switcher.dart
19. https://github.com/androidx/androidx/blob/androidx-main/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/AnimatedContent.kt
20. https://github.com/motiondivision/motion/blob/main/packages/framer-motion/src/components/AnimatePresence/types.ts
21. https://github.com/vuejs/docs/blob/main/src/guide/built-ins/transition.md
22. https://github.com/reactjs/react.dev/blob/main/src/content/reference/react/Suspense.md and https://github.com/reactjs/react.dev/blob/main/src/content/reference/react/useTransition.md
23. https://github.com/androidx/androidx/blob/androidx-main/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/Transition.kt
24. https://developer.apple.com/documentation/swiftui/animationcompletioncriteria and https://developer.apple.com/documentation/swiftui/withanimation(_:completioncriteria:_:completion:)
25. https://doc.qt.io/archives/qt-5.12/statemachine-api.html
26. https://gsap.com/docs/v3/GSAP/Tween/
27. https://github.com/androidx/androidx/blob/androidx-main/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/MutatorMutex.kt
28. https://github.com/statelyai/docs/blob/main/content/docs/invoke.mdx and https://github.com/statelyai/docs/blob/main/content/docs/delayed-transitions.mdx
29. https://github.com/tc39/proposal-signals/blob/main/README.md
30. https://bumptech.github.io/glide/doc/caching.html
31. https://bumptech.github.io/glide/doc/options.html
32. https://github.com/facebook/fresco/blob/main/docs/_docs/requesting-multiple-images.md
33. https://github.com/onevcat/Kingfisher/blob/master/Sources/General/KingfisherOptionsInfo.swift
34. https://github.com/kean/Nuke/blob/main/Documentation/Nuke.docc/Performance/performance-guide.md
35. https://doc.qt.io/archives/qt-5.12/qmlstatemachine.html
36. https://github.com/boost-ext/sml
37. https://github.com/andrew-gresyk/HFSM2
38. https://github.com/digint/tinyfsm
39. https://github.com/simonbrunel/qtpromise
40. https://github.com/KDAB/KDBindings
41. https://github.com/Naios/continuable
42. https://github.com/ReactiveX/RxCpp
43. https://github.com/qcoro/qcoro/blob/main/docs/index.md
44. https://github.com/vpicaver/asyncfuture
45. https://pub.dev/documentation/tanquery/latest/ , https://github.com/hmziqagent/gpui-query , https://www.nuget.org/packages/RabstackQuery
