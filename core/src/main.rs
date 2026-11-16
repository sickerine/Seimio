//! Runs Stremio's core natively on the TV: a minimal Env (tokio, reqwest with rustls, JSON files for
//! storage), the account loaded from storage copied out of the current app, then addon and library
//! sync and every Home catalog loaded. Prints how long each took and the memory used.
//! usage: core-probe <storage-dir>
use std::{path::PathBuf, sync::Arc, time::Instant};

use chrono::{DateTime, Utc};
use futures::{future, Future, StreamExt};
use http::Request;
use once_cell::sync::{Lazy, OnceCell};
use serde::{Deserialize, Serialize};
use stremio_core::{
    constants::*,
    models::{
        catalogs_with_extra::{CatalogsWithExtra, Selected},
        common::Loadable,
        continue_watching_preview::ContinueWatchingPreview,
        ctx::Ctx,
        streaming_server::StreamingServer,
    },
    runtime::{
        msg::{Action, ActionCatalogsWithExtra, ActionCtx, ActionLoad},
        Env, EnvError, EnvFuture, EnvFutureExt, Runtime, RuntimeAction, RuntimeEvent, TryEnvFuture,
    },
    types::{
        events::DismissedEventsBucket, library::LibraryBucket, notifications::NotificationsBucket,
        profile::Profile, remote_config::ClientInfo, search_history::SearchHistoryBucket,
        server_urls::ServerUrlsBucket, streams::StreamsBucket,
    },
    Model,
};

static STORAGE_DIR: OnceCell<PathBuf> = OnceCell::new();
static CONCURRENT: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread().worker_threads(3).enable_all().build().unwrap()
});
static SEQUENTIAL: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread().worker_threads(1).enable_all().build().unwrap()
});
static CLIENT: Lazy<reqwest::Client> = Lazy::new(|| reqwest::Client::builder().use_rustls_tls().build().unwrap());

enum TvEnv {}

impl Env for TvEnv {
    fn fetch<IN: Serialize + Send + 'static, OUT: for<'de> Deserialize<'de> + Send + 'static>(
        request: Request<IN>,
    ) -> TryEnvFuture<OUT> {
        let (parts, body) = request.into_parts();
        let body = match serde_json::to_string(&body) {
            Ok(b) if b != "null" && parts.method != http::Method::GET => b.into_bytes(),
            Ok(_) => vec![],
            Err(e) => return future::err(EnvError::Serde(e.to_string())).boxed_env(),
        };
        let request = match reqwest::Request::try_from(Request::from_parts(parts, body)) {
            Ok(r) => r,
            Err(e) => return future::err(EnvError::Fetch(e.to_string())).boxed_env(),
        };
        async move {
            let resp = CLIENT.execute(request).await.map_err(|e| EnvError::Fetch(e.to_string()))?;
            if !resp.status().is_success() {
                return Err(EnvError::Fetch(format!("HTTP {}", resp.status())));
            }
            let bytes = resp.bytes().await.map_err(|e| EnvError::Fetch(e.to_string()))?;
            serde_json::from_slice(&bytes).map_err(|e| EnvError::Serde(e.to_string()))
        }
        .boxed_env()
    }
    fn get_storage<T: for<'de> Deserialize<'de> + Send + 'static>(key: &str) -> TryEnvFuture<Option<T>> {
        let path = STORAGE_DIR.get().unwrap().join(format!("{key}.json"));
        async move {
            match std::fs::read(&path) {
                Ok(b) => serde_json::from_slice(&b).map(Some).map_err(|e| EnvError::Serde(format!("{}: {e}", path.display()))),
                Err(_) => Ok(None),
            }
        }
        .boxed_env()
    }
    fn set_storage<T: Serialize>(key: &str, value: Option<&T>) -> TryEnvFuture<()> {
        let path = STORAGE_DIR.get().unwrap().join(format!("{key}.json"));
        let data = value.map(serde_json::to_vec);
        async move {
            match data {
                Some(Ok(b)) => std::fs::write(&path, b).map_err(|e| EnvError::StorageWriteError(e.to_string())),
                Some(Err(e)) => Err(EnvError::Serde(e.to_string())),
                None => { let _ = std::fs::remove_file(&path); Ok(()) }
            }
        }
        .boxed_env()
    }
    fn exec_concurrent<F: Future<Output = ()> + Send + 'static>(future: F) { CONCURRENT.spawn(future); }
    fn exec_sequential<F: Future<Output = ()> + Send + 'static>(future: F) { SEQUENTIAL.spawn(future); }
    fn now() -> DateTime<Utc> { Utc::now() }
    fn flush_analytics() -> EnvFuture<'static, ()> { future::ready(()).boxed_env() }
    fn client_info() -> ClientInfo { ClientInfo { platform: "webos".into(), ..Default::default() } }
    fn analytics_context(_: &Ctx, _: &StreamingServer, _: &str) -> serde_json::Value { serde_json::Value::Null }
    #[cfg(debug_assertions)]
    fn log(message: String) { eprintln!("{message}"); }
}

#[derive(Model, Clone)]
#[model(TvEnv)]
struct TvModel {
    ctx: Ctx,
    continue_watching_preview: ContinueWatchingPreview,
    board: CatalogsWithExtra,
}

fn rss_mb() -> String {
    std::fs::read_to_string("/proc/self/status").ok()
        .and_then(|s| s.lines().find(|l| l.starts_with("VmRSS")).map(|l| l.split_whitespace().nth(1).unwrap_or("0").to_owned()))
        .map(|kb| format!("{:.1} MB", kb.parse::<f64>().unwrap_or(0.0) / 1024.0)).unwrap_or_default()
}

fn main() {
    let dir = std::env::args().nth(1).expect("usage: core-probe <storage-dir>");
    STORAGE_DIR.set(PathBuf::from(dir)).unwrap();
    let t0 = Instant::now();
    let ms = move || t0.elapsed().as_millis();
    CONCURRENT.block_on(async move {
        TvEnv::migrate_storage_schema().await.expect("storage migration");
        let (profile, recent, other, streams, urls, notifications, search, dismissed) = futures::try_join!(
            TvEnv::get_storage::<Profile>(PROFILE_STORAGE_KEY),
            TvEnv::get_storage::<LibraryBucket>(LIBRARY_RECENT_STORAGE_KEY),
            TvEnv::get_storage::<LibraryBucket>(LIBRARY_STORAGE_KEY),
            TvEnv::get_storage::<StreamsBucket>(STREAMS_STORAGE_KEY),
            TvEnv::get_storage::<ServerUrlsBucket>(STREAMING_SERVER_URLS_STORAGE_KEY),
            TvEnv::get_storage::<NotificationsBucket>(NOTIFICATIONS_STORAGE_KEY),
            TvEnv::get_storage::<SearchHistoryBucket>(SEARCH_HISTORY_STORAGE_KEY),
            TvEnv::get_storage::<DismissedEventsBucket>(DISMISSED_EVENTS_STORAGE_KEY),
        ).expect("storage read");
        let profile = profile.unwrap_or_default();
        let mut library = LibraryBucket::new(profile.uid(), vec![]);
        if let Some(b) = recent { library.merge_bucket(b) }
        if let Some(b) = other { library.merge_bucket(b) }
        println!("{:5} ms  storage loaded: signed in {}, {} addons, {} library items, rss {}", ms(),
            profile.auth.is_some(), profile.addons.len(), library.items.len(), rss_mb());
        let (cw, cw_effects) = ContinueWatchingPreview::new(&library, &notifications.clone().unwrap_or(NotificationsBucket::new::<TvEnv>(profile.uid(), vec![])));
        let uid = profile.uid();
        let model = TvModel {
            ctx: Ctx::new(
                profile, library,
                streams.unwrap_or_else(|| StreamsBucket::new(uid.clone())),
                urls.unwrap_or(ServerUrlsBucket::new::<TvEnv>(uid.clone())),
                notifications.unwrap_or(NotificationsBucket::new::<TvEnv>(uid.clone(), vec![])),
                search.unwrap_or(SearchHistoryBucket::new(uid.clone())),
                dismissed.unwrap_or(DismissedEventsBucket::new(uid)),
            ),
            continue_watching_preview: cw,
            board: Default::default(),
        };
        let (runtime, mut rx) = Runtime::<TvEnv, _>::new(model, cw_effects.into_iter().collect(), 1000);
        let runtime = Arc::new(runtime);
        println!("{:5} ms  core ready, continue watching {} items, rss {}", ms(),
            runtime.model().unwrap().continue_watching_preview.items.len(), rss_mb());

        runtime.dispatch(RuntimeAction { field: None, action: Action::Ctx(ActionCtx::PullAddonsFromAPI) });
        runtime.dispatch(RuntimeAction { field: None, action: Action::Ctx(ActionCtx::SyncLibraryWithAPI) });
        let board_start = ms();
        runtime.dispatch(RuntimeAction {
            field: Some(TvModelField::Board),
            action: Action::Load(ActionLoad::CatalogsWithExtra(Selected { r#type: None, extra: vec![] })),
        });
        runtime.dispatch(RuntimeAction {
            field: Some(TvModelField::Board),
            action: Action::CatalogsWithExtra(ActionCatalogsWithExtra::LoadRange(0..8)),
        });
        let (mut first, mut done) = (None, false);
        let deadline = tokio::time::sleep(std::time::Duration::from_secs(40));
        tokio::pin!(deadline);
        loop {
            tokio::select! {
                _ = &mut deadline => { println!("{:5} ms  stopped waiting", ms()); break; }
                ev = rx.next() => match ev {
                    Some(RuntimeEvent::CoreEvent(_)) => {}
                    Some(RuntimeEvent::NewState(fields, ..)) => {
                        if !fields.iter().any(|f| matches!(f, TvModelField::Board)) { continue }
                        let m = runtime.model().unwrap();
                        let rows: Vec<_> = m.board.catalogs.iter().flatten().collect();
                        let ready = rows.iter().filter(|c| matches!(c.content, Some(Loadable::Ready(_)))).count();
                        let loading = rows.iter().filter(|c| matches!(c.content, Some(Loadable::Loading))).count();
                        let requested = rows.iter().filter(|c| c.content.is_some()).count();
                        if ready > 0 && first.is_none() { first = Some(ms()); println!("{:5} ms  first Home row ready ({} ms after asking)", ms(), ms() - board_start) }
                        if loading == 0 && requested > 0 && !done {
                            done = true;
                            let items: usize = rows.iter().filter_map(|c| match &c.content { Some(Loadable::Ready(v)) => Some(v.len()), _ => None }).sum();
                            println!("{:5} ms  all {} requested Home rows settled ({} ready, {} items) {} ms after asking, rss {}", ms(), requested, ready, items, ms() - board_start, rss_mb());
                        }
                    }
                    None => break,
                }
            }
            if done { tokio::time::sleep(std::time::Duration::from_secs(3)).await; break; }
        }
        {
            let m = runtime.model().unwrap();
            println!("board selected {:?}, {} row groups", m.board.selected.is_some(), m.board.catalogs.len());
            for c in m.board.catalogs.iter().flatten().take(12) {
                let state = match &c.content { None => "none".to_owned(), Some(Loadable::Loading) => "loading".to_owned(), Some(Loadable::Ready(v)) => format!("ready {}", v.len()), Some(Loadable::Err(e)) => format!("error {e}") };
                println!("  {} {}", c.request.path.id, state);
            }
        }
        let m = runtime.model().unwrap();
        // the Continue Watching row as the UI would show it, for design work
        let cw: Vec<_> = m.continue_watching_preview.items.iter().map(|i| serde_json::json!({
            "id": i.library_item.id, "type": i.library_item.r#type, "name": i.library_item.name,
            "poster": i.library_item.poster, "videoId": i.library_item.state.video_id,
            "progress": i.library_item.progress(), "notifications": i.notifications,
        })).collect();
        std::fs::write(STORAGE_DIR.get().unwrap().join("cw.out.json"), serde_json::to_vec_pretty(&cw).unwrap()).ok();
        println!("{:5} ms  after sync: {} addons, {} library items, continue watching {}, rss {}", ms(),
            m.ctx.profile.addons.len(), m.ctx.library.items.len(), m.continue_watching_preview.items.len(), rss_mb());
    });
}

/// The webOS toolchain links against glibc 2.12, which predates getauxval (the TV runs 2.39).
/// Rust's std and ring call it, so answer from /proc/self/auxv (pairs of u32 on armv7).
#[no_mangle]
pub extern "C" fn getauxval(kind: u32) -> u32 {
    let Ok(raw) = std::fs::read("/proc/self/auxv") else { return 0 };
    raw.chunks_exact(8)
        .map(|c| (u32::from_ne_bytes([c[0], c[1], c[2], c[3]]), u32::from_ne_bytes([c[4], c[5], c[6], c[7]])))
        .find(|&(k, _)| k == kind)
        .map_or(0, |(_, v)| v)
}
