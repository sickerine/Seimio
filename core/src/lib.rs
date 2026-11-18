//! Stremio's core for the app: one runtime holding the models the screens need, a way to send it
//! actions, and its state as JSON. `ffi` is the same thing for C++.
pub mod env;
pub mod ffi;

use std::sync::{Arc, RwLock};

use futures::StreamExt;
use once_cell::sync::OnceCell;
use stremio_core::{
    constants::*,
    models::{
        catalog_with_filters::CatalogWithFilters,
        continue_watching_preview::ContinueWatchingPreview,
        ctx::Ctx,
        library_with_filters::{LibraryWithFilters, NotRemovedFilter},
        link::Link,
        player::Player,
    },
    runtime::{msg::Action, Env, Runtime, RuntimeAction, RuntimeEvent},
    types::{
        api::LinkAuthKey, events::DismissedEventsBucket, library::LibraryBucket, notifications::NotificationsBucket,
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
    }
}

/// Starts the core on its own thread. `on_event("ready", "")` once the stored account is loaded,
/// `("state", "[\"library\", …]")` when models changed, `("event", json)` for the core's events.
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
    }
    .ok()
}

/// State shaped for the app where a model's own JSON is more than it needs:
/// - `account`: { signedIn, email, avatar }
/// - `watching`: Continue Watching, newest first: [{ id, type, name, poster, videoId, progress, notifications }]
/// - `library`: every library item, with its state: [{ _id, name, type, poster, removed, temp, state }]
pub fn view(name: &str) -> Option<String> {
    let model = RUNTIME.get()?.model().ok()?;
    let value = match name {
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
