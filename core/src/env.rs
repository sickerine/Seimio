//! The core's environment: storage as JSON files, two thread pools, and HTTP handed to the host.
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex,
    },
};

use chrono::{DateTime, Utc};
use futures::{channel::oneshot, executor::ThreadPool, future, Future};
use http::Request;
use once_cell::sync::{Lazy, OnceCell};
use serde::{Deserialize, Serialize};
use stremio_core::{
    models::{ctx::Ctx, streaming_server::StreamingServer},
    runtime::{Env, EnvError, EnvFuture, EnvFutureExt, TryEnvFuture},
    types::remote_config::ClientInfo,
};

/// One HTTP request for the host to make; it answers with `fetched(id, status, body)`.
pub struct Fetch {
    pub id: u64,
    pub method: String,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

pub static STORAGE_DIR: OnceCell<PathBuf> = OnceCell::new();
pub static FETCH: OnceCell<Box<dyn Fn(Fetch) + Send + Sync>> = OnceCell::new();
static PENDING: Lazy<Mutex<HashMap<u64, oneshot::Sender<(u16, Vec<u8>)>>>> = Lazy::new(Default::default);
static NEXT: AtomicU64 = AtomicU64::new(1);
static CONCURRENT: Lazy<ThreadPool> = Lazy::new(|| ThreadPool::builder().pool_size(3).name_prefix("core-").create().unwrap());
static SEQUENTIAL: Lazy<ThreadPool> = Lazy::new(|| ThreadPool::builder().pool_size(1).name_prefix("core-seq-").create().unwrap());

/// The host's answer to a `Fetch`. A status of 0 is a request that never got an answer.
pub fn fetched(id: u64, status: u16, body: Vec<u8>) {
    if let Some(tx) = PENDING.lock().unwrap().remove(&id) {
        let _ = tx.send((status, body));
    }
}

pub enum TvEnv {}

impl Env for TvEnv {
    fn fetch<IN: Serialize + Send + 'static, OUT: for<'de> Deserialize<'de> + Send + 'static>(
        request: Request<IN>,
    ) -> TryEnvFuture<OUT> {
        let (parts, body) = request.into_parts();
        let body = match serde_json::to_vec(&body) {
            Ok(b) if b != b"null" && parts.method != http::Method::GET => b,
            Ok(_) => vec![],
            Err(e) => return future::err(EnvError::Serde(e.to_string())).boxed_env(),
        };
        let headers = parts.headers.iter().filter_map(|(k, v)| Some((k.to_string(), v.to_str().ok()?.to_owned()))).collect();
        let (tx, rx) = oneshot::channel();
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        PENDING.lock().unwrap().insert(id, tx);
        match FETCH.get() {
            Some(fetch) => fetch(Fetch { id, method: parts.method.to_string(), url: parts.uri.to_string(), headers, body }),
            None => fetched(id, 0, vec![]),
        }
        async move {
            let (status, bytes) = rx.await.map_err(|_| EnvError::Fetch("the request was dropped".into()))?;
            if !(200..300).contains(&status) {
                return Err(EnvError::Fetch(if status == 0 { "no answer".into() } else { format!("HTTP {status}") }));
            }
            serde_json::from_slice(&bytes).map_err(|e| EnvError::Serde(e.to_string()))
        }
        .boxed_env()
    }
    fn get_storage<T: for<'de> Deserialize<'de> + Send + 'static>(key: &str) -> TryEnvFuture<Option<T>> {
        let path = STORAGE_DIR.get().unwrap().join(format!("{key}.json"));
        future::ready(match std::fs::read(&path) {
            Ok(b) => serde_json::from_slice(&b).map(Some).map_err(|e| EnvError::Serde(format!("{}: {e}", path.display()))),
            Err(_) => Ok(None),
        })
        .boxed_env()
    }
    fn set_storage<T: Serialize>(key: &str, value: Option<&T>) -> TryEnvFuture<()> {
        let path = STORAGE_DIR.get().unwrap().join(format!("{key}.json"));
        // written beside and renamed, so a crash mid-write never leaves half a library
        future::ready(match value.map(serde_json::to_vec) {
            Some(Ok(b)) => {
                let tmp = path.with_extension("json.new");
                std::fs::write(&tmp, b).and_then(|_| std::fs::rename(&tmp, &path)).map_err(|e| EnvError::StorageWriteError(e.to_string()))
            }
            Some(Err(e)) => Err(EnvError::Serde(e.to_string())),
            None => {
                let _ = std::fs::remove_file(&path);
                Ok(())
            }
        })
        .boxed_env()
    }
    fn exec_concurrent<F: Future<Output = ()> + Send + 'static>(future: F) {
        CONCURRENT.spawn_ok(future);
    }
    fn exec_sequential<F: Future<Output = ()> + Send + 'static>(future: F) {
        SEQUENTIAL.spawn_ok(future);
    }
    fn now() -> DateTime<Utc> {
        Utc::now()
    }
    fn flush_analytics() -> EnvFuture<'static, ()> {
        future::ready(()).boxed_env()
    }
    fn client_info() -> ClientInfo {
        ClientInfo { platform: "webos".into(), ..Default::default() }
    }
    fn analytics_context(_: &Ctx, _: &StreamingServer, _: &str) -> serde_json::Value {
        serde_json::Value::Null
    }
    #[cfg(debug_assertions)]
    fn log(message: String) {
        eprintln!("{message}");
    }
}
