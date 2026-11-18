//! The core for C++ (native/src/core.h). Strings are UTF-8 and NUL-terminated; a string the core returns
//! is freed with `seimio_core_free`. The callbacks run on the core's threads.
use std::{
    ffi::{c_char, c_void, CStr, CString},
    slice,
};

use crate::env::{self, Fetch};

type OnEvent = extern "C" fn(user: *mut c_void, kind: *const c_char, json: *const c_char);
type OnFetch = extern "C" fn(user: *mut c_void, id: u64, method: *const c_char, url: *const c_char, headers: *const c_char, body: *const u8, len: usize);

#[derive(Clone, Copy)]
struct Host(*mut c_void);
// the host's pointer is only handed back to its own callbacks, which are thread-safe by contract
unsafe impl Send for Host {}
unsafe impl Sync for Host {}

fn text(s: *const c_char) -> String {
    if s.is_null() { String::new() } else { unsafe { CStr::from_ptr(s) }.to_string_lossy().into_owned() }
}
fn c(s: &str) -> CString {
    CString::new(s.replace('\0', "")).unwrap_or_default()
}

#[no_mangle]
pub extern "C" fn seimio_core_start(storage_dir: *const c_char, on_event: OnEvent, on_fetch: OnFetch, user: *mut c_void) {
    let host = Host(user);
    crate::start(
        &text(storage_dir),
        move |f: Fetch| {
            let host = host;
            let headers = serde_json::to_string(&f.headers).unwrap_or_default();
            on_fetch(host.0, f.id, c(&f.method).as_ptr(), c(&f.url).as_ptr(), c(&headers).as_ptr(), f.body.as_ptr(), f.body.len());
        },
        move |kind, json| {
            let host = host;
            on_event(host.0, c(kind).as_ptr(), c(json).as_ptr());
        },
    );
}

#[no_mangle]
pub extern "C" fn seimio_core_fetched(id: u64, status: u16, body: *const u8, len: usize) {
    let body = if body.is_null() || len == 0 { vec![] } else { unsafe { slice::from_raw_parts(body, len) }.to_vec() };
    env::fetched(id, status, body);
}

/// Null when sent; otherwise why not (freed by the caller).
#[no_mangle]
pub extern "C" fn seimio_core_dispatch(field: *const c_char, action: *const c_char) -> *mut c_char {
    match crate::dispatch(&text(field), &text(action)) {
        Ok(()) => std::ptr::null_mut(),
        Err(why) => c(&why).into_raw(),
    }
}

/// A model's state as JSON, or null.
#[no_mangle]
pub extern "C" fn seimio_core_state(field: *const c_char) -> *mut c_char {
    crate::state(&text(field)).map_or(std::ptr::null_mut(), |s| c(&s).into_raw())
}

/// One choice of a browsable model (`select` in lib.rs). Null when sent; otherwise why not (freed by the caller).
#[no_mangle]
pub extern "C" fn seimio_core_select(what: *const c_char, choice: *const c_char) -> *mut c_char {
    match crate::select(&text(what), &text(choice)) {
        Ok(()) => std::ptr::null_mut(),
        Err(why) => c(&why).into_raw(),
    }
}

/// An episode, a season or all of a title watched or not (`mark` in lib.rs; `days`: a JSON object, episode
/// id to day). Null when asked; otherwise why not (freed by the caller).
#[no_mangle]
pub extern "C" fn seimio_core_mark(
    kind: *const c_char, meta: *const c_char, base: *const c_char, what: *const c_char, watched: bool, today: *const c_char, days: *const c_char,
) -> *mut c_char {
    let days = serde_json::from_str(&text(days)).unwrap_or_default();
    match crate::mark(&text(kind), &text(meta), &text(base), &text(what), watched, &text(today), days) {
        Ok(()) => std::ptr::null_mut(),
        Err(why) => c(&why).into_raw(),
    }
}

/// State shaped for the app (`view` in lib.rs), or null.
#[no_mangle]
pub extern "C" fn seimio_core_view(name: *const c_char) -> *mut c_char {
    crate::view(&text(name)).map_or(std::ptr::null_mut(), |s| c(&s).into_raw())
}

#[no_mangle]
pub extern "C" fn seimio_core_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}
