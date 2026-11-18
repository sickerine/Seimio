//! The core from a terminal, for experiments: HTTP through curl, state printed as JSON.
//! usage: core-lab <storage-dir> <steps...>   each step: `wait:<ms>`, `state:<model>`, `view:<name>`, `select:<what>=<choice>`, `mark:<type>,<meta id>,<the addon's manifest address>,<video id | season:N | *>,<true|false>[,<episode id>=<its day>...]` (the days the app would give for episodes, "YYYY-MM-DD"), `<model>|<action json>` ("" for all)
use std::{io::Read, process::{Command, Stdio}, sync::mpsc, time::{Duration, Instant}};

use seimio_core::env::{fetched, Fetch};

fn main() {
    let mut args = std::env::args().skip(1);
    let dir = args.next().expect("usage: core-lab <storage-dir> <steps...>");
    let t0 = Instant::now();
    let (tx, rx) = mpsc::channel::<(String, String)>();
    seimio_core::start(
        &dir,
        |f: Fetch| {
            std::thread::spawn(move || {
                let started = Instant::now();
                let mut cmd = Command::new("curl");
                cmd.args(["-s", "-L", "--max-time", "30", "-A", "Seimio-dev", "-w", "\n%{http_code}", "-X", &f.method]);
                for (k, v) in &f.headers { cmd.args(["-H", &format!("{k}: {v}")]); }
                if !f.body.is_empty() { cmd.args(["--data-binary", "@-"]); }
                let mut child = cmd.arg(&f.url).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().expect("curl");
                if !f.body.is_empty() { use std::io::Write; child.stdin.take().unwrap().write_all(&f.body).ok(); } else { drop(child.stdin.take()); }
                let mut out = vec![];
                child.stdout.take().unwrap().read_to_end(&mut out).ok();
                child.wait().ok();
                let cut = out.iter().rposition(|&b| b == b'\n').unwrap_or(0);
                let status: u16 = String::from_utf8_lossy(&out[cut..]).trim().parse().unwrap_or(0);
                eprintln!("  fetch {} {} -> {} ({} bytes, {} ms)", f.method, &f.url[..f.url.len().min(110)], status, cut, started.elapsed().as_millis());
                fetched(f.id, status, out[..cut].to_vec());
            });
        },
        move |kind, json| { let _ = tx.send((kind.to_owned(), json.to_owned())); },
    );
    let drain = |ms: u64| {
        let until = Instant::now() + Duration::from_millis(ms);
        while let Ok((kind, json)) = rx.recv_timeout(until.saturating_duration_since(Instant::now())) {
            // an event by its name only: UserAuthenticated and SessionDeleted carry the account's key
            let what = if kind == "event" { json.split('"').nth(3).unwrap_or_default() } else { &json[..json.len().min(160)] };
            eprintln!("{:6} ms  {kind} {what}", t0.elapsed().as_millis());
        }
    };
    drain(300);
    for step in args {
        if let Some(ms) = step.strip_prefix("wait:") { drain(ms.parse().unwrap()); }
        else if let Some(model) = step.strip_prefix("state:") { println!("{}", seimio_core::state(model).unwrap_or_else(|| "null".into())); }
        else if let Some((what, choice)) = step.strip_prefix("select:").and_then(|s| s.split_once('=')) {
            if let Err(e) = seimio_core::select(what, choice) { eprintln!("select failed: {e}"); }
            drain(50);
        }
        else if let Some(mark) = step.strip_prefix("mark:") {
            let p: Vec<_> = mark.split(',').collect();
            let today = chrono::Local::now().format("%Y-%m-%d").to_string();
            let days = p[5..].iter().filter_map(|d| d.split_once('=')).map(|(id, day)| (id.to_owned(), day.to_owned())).collect();
            if let Err(e) = seimio_core::mark(p[0], p[1], p[2], p[3], p[4] == "true", &today, days) { eprintln!("mark failed: {e}"); }
            drain(50);
        }
        else if let Some(name) = step.strip_prefix("view:") { println!("{}", seimio_core::view(name).unwrap_or_else(|| "null".into())); }
        else if let Some((model, action)) = step.split_once('|') {
            if let Err(e) = seimio_core::dispatch(model, action) { eprintln!("dispatch failed: {e}"); }
            drain(50);
        }
    }
}
