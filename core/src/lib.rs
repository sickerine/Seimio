//! Stremio's core for the app: one runtime holding the models the screens need, a way to send it
//! actions, and its state as JSON. `ffi` is the same thing for C++.
pub mod env;
pub mod ffi;

use std::{
    collections::VecDeque,
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
        msg::{Action, ActionLoad, ActionMetaDetails},
        Env, Runtime, RuntimeAction, RuntimeEvent,
    },
    types::{
        addon::ResourcePath, api::LinkAuthKey, events::DismissedEventsBucket, library::LibraryBucket, notifications::NotificationsBucket,
        profile::Profile, resource::MetaItemPreview, search_history::SearchHistoryBucket, server_urls::ServerUrlsBucket,
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
/// `("unmarked", "<episode>: <why>")` for a mark that couldn't be made after all (`mark_video`).
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
            RuntimeEvent::CoreEvent(event) => on_event("event", &serde_json::to_string(&event).unwrap_or_default()),
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

/// An episode to mark watched or not: its title (`kind`, `meta`), the addon whose list of episodes the
/// app shows for it (`base`, its manifest's address), and the episode.
#[derive(Clone)]
struct Mark {
    kind: String,
    meta: String,
    base: String,
    video: String,
    watched: bool,
}
/// The marks asked for, in order, and the one thread working through them.
static MARKS: Mutex<VecDeque<Mark>> = Mutex::new(VecDeque::new());
static MARKING: Mutex<()> = Mutex::new(());

enum Marking {
    Wait,
    Do(ActionMetaDetails),
    Fail(&'static str),
}

/// Marks one episode of a title watched or not. The core does that on its details of the title (the
/// `details` model: the meta from the account's addons, the library item and its watched field), by the
/// rules every Stremio device has: the title's watched field takes the episode, and Continue Watching
/// moves on when it was the one you were on. The details are loaded first and the mark waits for them,
/// behind any mark asked before it. `Err`: what couldn't be marked now, and why; a mark that fails later
/// is an `unmarked` event.
pub fn mark_video(kind: &str, meta: &str, base: &str, video: &str, watched: bool) -> Result<(), String> {
    RUNTIME.get().ok_or("the core hasn't started")?;
    MARKS.lock().unwrap().push_back(Mark { kind: kind.into(), meta: meta.into(), base: base.into(), video: video.into(), watched });
    let failed = mark_next();
    if failed.is_empty() { Ok(()) } else { Err(failed.join("; ")) }
}

/// Works through the marks asked for: the first one's title is loaded into `details` unless it is the one
/// there, and it is marked once the core would mark against the right list of episodes. Returns the ones
/// that can't be marked ("<episode>: <why>").
fn mark_next() -> Vec<String> {
    let mut failed = vec![];
    let Some(runtime) = RUNTIME.get() else { return failed };
    let _one = MARKING.lock().unwrap();
    loop {
        let Some(mark) = MARKS.lock().unwrap().front().cloned() else { break };
        let loaded = runtime.model().is_ok_and(|m| m.details.selected.as_ref().is_some_and(|s| s.meta_path.id == mark.meta && s.meta_path.r#type == mark.kind));
        if !loaded {
            let selected = DetailsSelected { meta_path: ResourcePath::without_extra(META_RESOURCE_NAME, &mark.kind, &mark.meta), stream_path: None, guess_stream: false };
            runtime.dispatch(RuntimeAction { field: Some(TvModelField::Details), action: Action::Load(ActionLoad::MetaDetails(selected)) });
        }
        let Ok(marking) = runtime.model().map(|m| marking(&m.details, &mark)) else { break };
        match marking {
            Marking::Wait => break,
            Marking::Do(action) => runtime.dispatch(RuntimeAction { field: Some(TvModelField::Details), action: Action::MetaDetails(action) }),
            Marking::Fail(why) => failed.push(format!("{}: {why}", mark.video)),
        }
        MARKS.lock().unwrap().pop_front();
    }
    failed
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
    match &details.meta_items[at].content {
        Some(Loadable::Ready(meta)) => match meta.videos.iter().find(|v| v.id == mark.video) {
            Some(video) => Marking::Do(ActionMetaDetails::MarkVideoAsWatched(video.to_owned(), mark.watched)),
            None => Marking::Fail("its title doesn't list it"),
        },
        Some(Loadable::Err(_)) => Marking::Fail("its title couldn't be loaded"),
        _ => Marking::Wait,
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
