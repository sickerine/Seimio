//! Stremio's core for the app: one runtime holding the models the screens need, a way to send it
//! actions, and its state as JSON. `ffi` is the same thing for C++.
pub mod env;
pub mod ffi;

use std::{
    collections::{HashMap, VecDeque},
    sync::{Arc, Mutex, RwLock},
};

use futures::StreamExt;
use once_cell::sync::OnceCell;
use stremio_core::{
    constants::*,
    models::{
        catalog_with_filters::{CatalogWithFilters, Selected as CatalogSelected},
        common::Loadable,
        continue_watching_preview::ContinueWatchingPreview,
        ctx::Ctx,
        library_with_filters::{LibraryWithFilters, NotRemovedFilter, Selected as LibrarySelected, Sort},
        link::Link,
        meta_details::{MetaDetails, Selected as DetailsSelected},
        player::Player,
    },
    runtime::{
        msg::{Action, ActionLoad, ActionMetaDetails, Event},
        Env, Runtime, RuntimeAction, RuntimeEvent,
    },
    types::{
        addon::ResourcePath, api::LinkAuthKey, events::DismissedEventsBucket, library::LibraryBucket, notifications::NotificationsBucket,
        profile::Profile, resource::{MetaItemPreview, Video}, search_history::SearchHistoryBucket, server_urls::ServerUrlsBucket,
        streams::StreamsBucket,
    },
    Model,
};

use env::TvEnv;

/// What the app shows, each a model of the core's.
#[derive(Model, Clone)]
#[model(TvEnv)]
pub struct TvModel {
    pub ctx: Ctx,
    pub link: Link<LinkAuthKey>,
    pub continue_watching: ContinueWatchingPreview,
    pub library: LibraryWithFilters<NotRemovedFilter>,
    pub discover: CatalogWithFilters<MetaItemPreview>,
    pub player: Player,
    pub details: MetaDetails,
}

static RUNTIME: OnceCell<Arc<Runtime<TvEnv, TvModel>>> = OnceCell::new();
static STATE: RwLock<Option<String>> = RwLock::new(None);

fn field(name: &str) -> Option<TvModelField> {
    Some(match name {
        "ctx" => TvModelField::Ctx,
        "link" => TvModelField::Link,
        "continue_watching" => TvModelField::ContinueWatching,
        "library" => TvModelField::Library,
        "discover" => TvModelField::Discover,
        "player" => TvModelField::Player,
        "details" => TvModelField::Details,
        _ => return None,
    })
}

fn name(field: &TvModelField) -> &'static str {
    match field {
        TvModelField::Ctx => "ctx",
        TvModelField::Link => "link",
        TvModelField::ContinueWatching => "continue_watching",
        TvModelField::Library => "library",
        TvModelField::Discover => "discover",
        TvModelField::Player => "player",
        TvModelField::Details => "details",
    }
}

/// Starts the core on its own thread. `on_event("ready", "")` once the stored account is loaded,
/// `("state", "[\"library\", …]")` when models changed, `("event", json)` for the core's events,
/// `("unmarked", "<title> <what>: <why>")` for a mark that couldn't be made after all (`mark`).
pub fn start(storage_dir: &str, fetch: impl Fn(env::Fetch) + Send + Sync + 'static, on_event: impl Fn(&str, &str) + Send + 'static) {
    std::fs::create_dir_all(storage_dir).ok();
    if env::STORAGE_DIR.set(storage_dir.into()).is_err() || env::FETCH.set(Box::new(fetch)).is_err() {
        return; // started already
    }
    std::thread::Builder::new().name("core-main".into()).spawn(move || futures::executor::block_on(run(on_event))).ok();
}

async fn run(on_event: impl Fn(&str, &str)) {
    if let Err(e) = TvEnv::migrate_storage_schema().await {
        *STATE.write().unwrap() = Some(format!("storage: {e:?}"));
    }
    let (profile, recent, other, streams, urls, notifications, search, dismissed) = futures::join!(
        TvEnv::get_storage::<Profile>(PROFILE_STORAGE_KEY),
        TvEnv::get_storage::<LibraryBucket>(LIBRARY_RECENT_STORAGE_KEY),
        TvEnv::get_storage::<LibraryBucket>(LIBRARY_STORAGE_KEY),
        TvEnv::get_storage::<StreamsBucket>(STREAMS_STORAGE_KEY),
        TvEnv::get_storage::<ServerUrlsBucket>(STREAMING_SERVER_URLS_STORAGE_KEY),
        TvEnv::get_storage::<NotificationsBucket>(NOTIFICATIONS_STORAGE_KEY),
        TvEnv::get_storage::<SearchHistoryBucket>(SEARCH_HISTORY_STORAGE_KEY),
        TvEnv::get_storage::<DismissedEventsBucket>(DISMISSED_EVENTS_STORAGE_KEY),
    );
    // a file that can't be read is a fresh start for that part, not a dead app
    let profile = profile.ok().flatten().unwrap_or_default();
    let uid = profile.uid();
    let mut library = LibraryBucket::new(uid.clone(), vec![]);
    for bucket in [recent, other].into_iter().filter_map(|b| b.ok().flatten()) {
        library.merge_bucket(bucket);
    }
    let notifications = notifications.ok().flatten().unwrap_or_else(|| NotificationsBucket::new::<TvEnv>(uid.clone(), vec![]));
    let (continue_watching, cw_effects) = ContinueWatchingPreview::new(&library, &notifications);
    let (library_view, library_effects) = LibraryWithFilters::new(&library, &notifications);
    let (discover, discover_effects) = CatalogWithFilters::<MetaItemPreview>::new(&profile);
    let model = TvModel {
        ctx: Ctx::new(
            profile,
            library,
            streams.ok().flatten().unwrap_or_else(|| StreamsBucket::new(uid.clone())),
            urls.ok().flatten().unwrap_or_else(|| ServerUrlsBucket::new::<TvEnv>(uid.clone())),
            notifications,
            search.ok().flatten().unwrap_or_else(|| SearchHistoryBucket::new(uid.clone())),
            dismissed.ok().flatten().unwrap_or_else(|| DismissedEventsBucket::new(uid)),
        ),
        link: Default::default(),
        continue_watching,
        library: library_view,
        discover,
        player: Default::default(),
        details: Default::default(),
    };
    let effects = cw_effects.join(library_effects).join(discover_effects);
    let (runtime, mut events) = Runtime::<TvEnv, _>::new(model, effects.into_iter().collect(), 1000);
    let _ = RUNTIME.set(Arc::new(runtime));
    on_event("ready", "");
    while let Some(event) = events.next().await {
        match event {
            RuntimeEvent::NewState(fields, ..) => {
                let names: Vec<_> = fields.iter().map(name).collect();
                on_event("state", &serde_json::to_string(&names).unwrap_or_default());
                if fields.contains(&TvModelField::Details) {
                    for why in mark_next() {
                        on_event("unmarked", &why);
                    }
                }
            }
            RuntimeEvent::CoreEvent(event) => {
                on_event("event", &serde_json::to_string(&event).unwrap_or_default());
                // a write of the library that reached the API, or failed to
                let written_ids = match &event {
                    Event::LibraryItemsPushedToAPI { ids } => Some(ids),
                    Event::Error { source, .. } => match source.as_ref() {
                        Event::LibraryItemsPushedToAPI { ids } => Some(ids),
                        _ => None,
                    },
                    _ => None,
                };
                for why in written_ids.map(|ids| written(ids)).unwrap_or_default() {
                    on_event("unmarked", &why);
                }
            }
        }
    }
}

/// Sends the core an action (its `Action` as JSON), to one model (`field`) or, with "", to all.
pub fn dispatch(field_name: &str, action: &str) -> Result<(), String> {
    let runtime = RUNTIME.get().ok_or("the core hasn't started")?;
    let action: Action = serde_json::from_str(action).map_err(|e| e.to_string())?;
    let field = if field_name.is_empty() { None } else { Some(field(field_name).ok_or("no such model")?) };
    runtime.dispatch(RuntimeAction { field, action });
    Ok(())
}

/// A model's state as JSON, as the core serialises it.
pub fn state(field_name: &str) -> Option<String> {
    let model = RUNTIME.get()?.model().ok()?;
    match field(field_name)? {
        TvModelField::Ctx => serde_json::to_string(&model.ctx),
        TvModelField::Link => serde_json::to_string(&model.link),
        TvModelField::ContinueWatching => serde_json::to_string(&model.continue_watching),
        TvModelField::Library => serde_json::to_string(&model.library),
        TvModelField::Discover => serde_json::to_string(&model.discover),
        TvModelField::Player => serde_json::to_string(&model.player),
        TvModelField::Details => serde_json::to_string(&model.details),
    }
    .ok()
}

/// Something of a title to mark watched or not: the title (`kind`, `meta`), the addon whose list of
/// episodes the app shows for it (`base`, its manifest's address), and `what` of it: an episode by its id,
/// a season ("season:N"), or all of it ("*": every season, and the title itself as watched or not).
#[derive(Clone)]
struct Mark {
    kind: String,
    meta: String,
    base: String,
    what: String,
    watched: bool,
    /// what is out, for a season or all of a title: an episode whose day has come by `today` ("YYYY-MM-DD",
    /// the app's). `days`: the app's day for an episode, by its id, where it knows better than the addon
    /// (AniList's, for an anime of this season: Kitsu's are a guess of one a week)
    today: String,
    days: HashMap<String, String>,
    /// how many of its actions have been done (all of a title is the title's own, then its seasons')
    done: usize,
}
/// The marks asked for, in order, and the one thread working through them.
static MARKS: Mutex<VecDeque<Mark>> = Mutex::new(VecDeque::new());
static MARKING: Mutex<()> = Mutex::new(());
/// A write of a title's library item to Stremio's API is on its way (the title's id), and the next action
/// waits for it. Each action is a write of the title's whole state, and the API keeps the one that reaches
/// it last: all of a title's seasons sent at once arrived in any order, and the account was left with
/// seasons still watched that the TV had unmarked.
static WRITING: Mutex<Option<String>> = Mutex::new(None);

enum Marking {
    Wait,
    Do(Vec<ActionMetaDetails>),
    Fail(&'static str),
}

/// Marks an episode, a season or all of a title watched or not. The core does that on its details of the
/// title (the `details` model: the meta from the account's addons, the library item and its watched
/// field), by the rules every Stremio device has: the title's watched field takes the episodes, and
/// Continue Watching moves on when the one you were on is among them. The details are loaded first and the
/// mark waits for them, behind any mark asked before it. `Err`: what couldn't be marked now, and why; a
/// mark that fails later is an `unmarked` event.
pub fn mark(kind: &str, meta: &str, base: &str, what: &str, watched: bool, today: &str, days: HashMap<String, String>) -> Result<(), String> {
    RUNTIME.get().ok_or("the core hasn't started")?;
    MARKS.lock().unwrap().push_back(Mark { kind: kind.into(), meta: meta.into(), base: base.into(), what: what.into(), watched, today: today.into(), days, done: 0 });
    let failed = mark_next();
    if failed.is_empty() { Ok(()) } else { Err(failed.join("; ")) }
}

/// Works through the marks asked for: the first one's title is loaded into `details` unless it is the one
/// there, and it is marked once the core would mark against the right list of episodes, an action at a
/// time, each after the write before it has reached the API (`written`). Returns the ones that can't be
/// marked ("<title> <what>: <why>").
fn mark_next() -> Vec<String> {
    let mut failed = vec![];
    let Some(runtime) = RUNTIME.get() else { return failed };
    let _one = MARKING.lock().unwrap();
    // the title's library item, as the core has it
    let item = |id: &str| runtime.model().ok().and_then(|m| m.ctx.library.items.get(id).cloned());
    loop {
        if WRITING.lock().unwrap().is_some() {
            break;
        }
        let Some(mark) = MARKS.lock().unwrap().front().cloned() else { break };
        let loaded = runtime.model().is_ok_and(|m| m.details.selected.as_ref().is_some_and(|s| s.meta_path.id == mark.meta && s.meta_path.r#type == mark.kind));
        if !loaded {
            let selected = DetailsSelected { meta_path: ResourcePath::without_extra(META_RESOURCE_NAME, &mark.kind, &mark.meta), stream_path: None, guess_stream: false };
            runtime.dispatch(RuntimeAction { field: Some(TvModelField::Details), action: Action::Load(ActionLoad::MetaDetails(selected)) });
        }
        let Ok(marking) = runtime.model().map(|m| marking(&m.details, &mark)) else { break };
        match marking {
            Marking::Wait => break,
            Marking::Do(mut actions) if mark.done < actions.len() => {
                let before = item(&mark.meta);
                let signed_in = runtime.model().is_ok_and(|m| m.ctx.profile.auth_key().is_some());
                runtime.dispatch(RuntimeAction { field: Some(TvModelField::Details), action: Action::MetaDetails(actions.swap_remove(mark.done)) });
                // (an action that changed nothing, or an account that isn't signed in, writes nothing to wait for)
                if signed_in && item(&mark.meta) != before {
                    *WRITING.lock().unwrap() = Some(mark.meta.to_owned());
                }
                if let Some(first) = MARKS.lock().unwrap().front_mut() {
                    first.done += 1;
                }
                continue;
            }
            Marking::Do(_) => {}
            Marking::Fail(why) => failed.push(format!("{} {}: {why}", mark.meta, mark.what)),
        }
        MARKS.lock().unwrap().pop_front();
    }
    failed
}

/// A write of the library reached the API, or failed to. The one waited for is of that title alone (an
/// action writes its own; a sync writes all it has to): then the next action can go.
fn written(ids: &[String]) -> Vec<String> {
    {
        let mut writing = WRITING.lock().unwrap();
        if !writing.as_ref().is_some_and(|id| ids.len() == 1 && ids[0] == *id) {
            return vec![];
        }
        *writing = None;
    }
    mark_next()
}

/// The core marks against the first meta that is ready, in the order of the account's addons. They answer
/// in any order and their lists of episodes differ (this account has two that know the same ids), so a mark
/// is made only when that first one is the addon the app shows the title from: once it has answered, and
/// every addon before it has failed.
fn marking(details: &MetaDetails, mark: &Mark) -> Marking {
    let Some(at) = details.meta_items.iter().position(|m| m.request.base.as_str() == mark.base) else {
        return Marking::Fail("the account doesn't have the addon its episodes are from");
    };
    for before in &details.meta_items[..at] {
        match before.content {
            Some(Loadable::Err(_)) => {}
            Some(Loadable::Ready(_)) => return Marking::Fail("another addon's list of its episodes comes first"),
            _ => return Marking::Wait,
        }
    }
    let meta = match &details.meta_items[at].content {
        Some(Loadable::Ready(meta)) => meta,
        Some(Loadable::Err(_)) => return Marking::Fail("its title couldn't be loaded"),
        _ => return Marking::Wait,
    };
    // the seasons its episodes are in, in order
    let mut seasons: Vec<u32> = meta.videos.iter().filter_map(|v| v.series_info.as_ref().map(|s| s.season)).collect();
    seasons.sort_unstable();
    seasons.dedup();
    // out: its day has come, or it has no date to say it hasn't (the rule the app shows "still to come" by)
    let out = |v: &Video| {
        let day = mark.days.get(&v.id).cloned().or_else(|| v.released.map(|at| at.format("%Y-%m-%d").to_string()));
        day.is_none_or(|day| day.as_str() <= mark.today.as_str())
    };
    let one = |v: &Video| ActionMetaDetails::MarkVideoAsWatched(v.to_owned(), mark.watched);
    // Stremio's action for a season takes every episode the season lists, the ones still to come too, and
    // moves "last watched" to the last of them, which keeps their notifications from ever showing. So a
    // season still airing is marked watched an episode at a time, the ones that are out. A season that is
    // all out, and unmarking, is the one action.
    // ponytail: an episode at a time is a write each, one after another, so an airing show with a
    // thousand episodes in one season takes minutes; send several at once and the last alone if it matters
    let season = |n: u32| {
        let videos = meta.videos_by_season(n);
        if !mark.watched || videos.iter().all(|v| out(v)) {
            vec![ActionMetaDetails::MarkSeasonAsWatched(n, mark.watched)]
        } else {
            videos.into_iter().filter(|v| out(v)).map(one).collect()
        }
    };
    if mark.what == "*" {
        // the title itself (Stremio's "watched" of a library item), then every season's episodes, then the
        // episodes that are in no season
        let loose = meta.videos.iter().filter(|v| v.series_info.is_none() && (!mark.watched || out(v))).map(one);
        return Marking::Do(std::iter::once(ActionMetaDetails::MarkAsWatched(mark.watched)).chain(seasons.into_iter().flat_map(season)).chain(loose).collect());
    }
    if let Some(n) = mark.what.strip_prefix("season:").and_then(|n| n.parse::<u32>().ok()) {
        return if seasons.contains(&n) { Marking::Do(season(n)) } else { Marking::Fail("its title has no such season") };
    }
    match meta.videos.iter().find(|v| v.id == mark.what) {
        Some(video) => Marking::Do(vec![ActionMetaDetails::MarkVideoAsWatched(video.to_owned(), mark.watched)]),
        None => Marking::Fail("its title doesn't list it"),
    }
}

/// One choice of a browsable model, by its place in the view's list: the library's `library.type` and
/// `library.sort`, Discover's `discover.type` (by name: "movie", "series"), `discover.list` and
/// `discover.genre`. Each choice carries the request that shows it, so choosing is loading that.
pub fn select(what: &str, choice: &str) -> Result<(), String> {
    let runtime = RUNTIME.get().ok_or("the core hasn't started")?;
    let index = choice.parse::<usize>().unwrap_or(usize::MAX);
    let (field, load) = {
        let model = runtime.model().map_err(|_| "the model is locked")?;
        let (library, discover) = (&model.library.selectable, &model.discover.selectable);
        let library_load = |request| ActionLoad::LibraryWithFilters(LibrarySelected { request });
        let discover_load = |request| ActionLoad::CatalogWithFilters(Some(CatalogSelected { request }));
        match what {
            "library.type" => (TvModelField::Library, library.types.get(index).map(|t| library_load(t.request.to_owned()))),
            "library.sort" => (TvModelField::Library, library.sorts.get(index).map(|t| library_load(t.request.to_owned()))),
            "discover.type" => (TvModelField::Discover, discover.types.iter().find(|t| t.r#type == choice).map(|t| discover_load(t.request.to_owned()))),
            "discover.list" => (TvModelField::Discover, discover.catalogs.get(index).map(|t| discover_load(t.request.to_owned()))),
            "discover.genre" => (
                TvModelField::Discover,
                discover.extra.iter().find(|e| e.name == "genre").and_then(|e| e.options.get(index)).map(|t| discover_load(t.request.to_owned())),
            ),
            _ => return Err("no such choice".into()),
        }
    };
    runtime.dispatch(RuntimeAction { field: Some(field), action: Action::Load(load.ok_or("no such choice")?) });
    Ok(())
}

fn named(choices: impl Iterator<Item = (String, bool)>) -> serde_json::Value {
    choices.map(|(name, selected)| serde_json::json!({ "name": name, "selected": selected })).collect()
}

/// State shaped for the app where a model's own JSON is more than it needs:
/// - `account`: { signedIn, email, avatar }
/// - `watching`: Continue Watching, newest first: [{ id, type, name, poster, videoId, progress, notifications }]
/// - `library`: every library item, with its state: [{ _id, name, type, poster, removed, temp, state }]
/// - `library.page`, `discover.page`: a grid's worth: { filters by name: [{ name, selected }], items, more, loading }
pub fn view(name: &str) -> Option<String> {
    let model = RUNTIME.get()?.model().ok()?;
    let value = match name {
        "library.page" => {
            let library = &model.library;
            serde_json::json!({
                "type": named(library.selectable.types.iter().map(|t| (match t.r#type.as_deref() {
                    None => "All".to_owned(), Some("movie") => "Movies".to_owned(), Some("series") => "Series".to_owned(), Some(other) => other.to_owned(),
                }, t.selected))),
                "sort": named(library.selectable.sorts.iter().map(|t| (match t.sort {
                    Sort::LastWatched => "Last watched", Sort::Name => "A to Z", Sort::NameReverse => "Z to A",
                    Sort::TimesWatched => "Most watched", Sort::Watched => "Watched", Sort::NotWatched => "Not watched",
                }.to_owned(), t.selected))),
                "items": library.catalog.iter().map(|i| serde_json::json!({ "id": i.id, "type": i.r#type, "name": i.name, "poster": i.poster })).collect::<Vec<_>>(),
                "more": library.selectable.next_page.is_some(),
                "loading": false,
            })
        }
        "discover.page" => {
            let discover = &model.discover;
            let pages = discover.catalog.iter().map(|page| page.content.as_ref());
            serde_json::json!({
                "list": named(discover.selectable.catalogs.iter().map(|c| (c.catalog.to_owned(), c.selected))),
                "genre": named(discover.selectable.extra.iter().filter(|e| e.name == "genre").flat_map(|e| e.options.iter())
                    .map(|o| (o.value.to_owned().unwrap_or_else(|| "All genres".to_owned()), o.selected))),
                "items": discover.catalog.iter().filter_map(|page| match &page.content { Some(Loadable::Ready(items)) => Some(items), _ => None }).flatten()
                    .map(|i| {
                        let links = |category: &str| i.links.iter().filter(|l| l.category == category).map(|l| l.name.to_owned()).collect::<Vec<_>>();
                        serde_json::json!({
                            "id": i.id, "type": i.r#type, "name": i.name, "poster": i.poster, "backdrop": i.background, "logo": i.logo,
                            "description": i.description, "year": i.release_info, "runtime": i.runtime,
                            "rating": links("imdb").into_iter().next(), "genres": links("Genres"),
                        })
                    }).collect::<Vec<_>>(),
                "more": discover.selectable.next_page.is_some(),
                "loading": pages.clone().any(|content| matches!(content, Some(Loadable::Loading))),
            })
        }
        "account" => {
            let user = model.ctx.profile.auth.as_ref().map(|a| &a.user);
            serde_json::json!({
                "signedIn": user.is_some(),
                "email": user.map(|u| u.email.as_str()).unwrap_or_default(),
                "avatar": user.and_then(|u| u.avatar.as_deref()).unwrap_or_default(),
            })
        }
        "watching" => model.continue_watching.items.iter().map(|i| serde_json::json!({
            "id": i.library_item.id, "type": i.library_item.r#type, "name": i.library_item.name,
            "poster": i.library_item.poster, "videoId": i.library_item.state.video_id,
            "progress": i.library_item.progress(), "notifications": i.notifications,
        })).collect(),
        "library" => serde_json::to_value(model.ctx.library.items.values().collect::<Vec<_>>()).ok()?,
        _ => return None,
    };
    serde_json::to_string(&value).ok()
}

/// The webOS toolchain links against glibc 2.12, which has no getauxval (the TV runs 2.39 and uses its
/// own). Rust's std asks for it, so the linker gets one: from /proc/self/auxv (pairs of u32 on armv7).
#[cfg(target_arch = "arm")]
#[no_mangle]
pub extern "C" fn getauxval(kind: u32) -> u32 {
    let Ok(raw) = std::fs::read("/proc/self/auxv") else { return 0 };
    raw.chunks_exact(8)
        .map(|c| (u32::from_ne_bytes([c[0], c[1], c[2], c[3]]), u32::from_ne_bytes([c[4], c[5], c[6], c[7]])))
        .find(|&(k, _)| k == kind)
        .map_or(0, |(_, v)| v)
}
