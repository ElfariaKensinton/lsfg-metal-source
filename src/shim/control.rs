// Per-process live control socket for the macOS settings GUI.
//
// Protocol:
//   GET
//   SET key=value key=value ...
//   CLEAR

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::Once;

use super::Layer;

static START: Once = Once::new();

pub fn socket_path_for_pid(pid: u32) -> PathBuf {
    PathBuf::from(format!("/tmp/lsfg-metal-{pid}.sock"))
}

pub fn start(layer: &'static Layer) {
    START.call_once(|| {
        let path = socket_path_for_pid(std::process::id());
        let _ = std::fs::remove_file(&path);
        let listener = match UnixListener::bind(&path) {
            Ok(v) => v,
            Err(e) => {
                crate::log::warn(&format!(
                    "Live settings control socket unavailable at {}: {e}",
                    path.display()
                ));
                return;
            }
        };
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));

        let _ = std::thread::Builder::new()
            .name("lsfg-metal-control".into())
            .spawn(move || {
                for stream in listener.incoming() {
                    match stream {
                        Ok(stream) => handle(stream, layer),
                        Err(e) => {
                            crate::log::debug(&format!(
                                "Live settings control accept failed: {e}"
                            ));
                            break;
                        }
                    }
                }
                let _ = std::fs::remove_file(socket_path_for_pid(std::process::id()));
            });
    });
}

fn handle(mut stream: UnixStream, layer: &'static Layer) {
    let command = {
        let mut reader = BufReader::new(&mut stream);
        let mut line = String::new();
        if reader.read_line(&mut line).is_err() {
            return;
        }
        line.trim().to_string()
    };

    let response = if command == "GET" {
        format!("OK {}\n", wire_profile(&layer.profile()))
    } else if command == "CLEAR" {
        layer.clear_live_profile();
        format!("OK {}\n", wire_profile(&layer.profile()))
    } else if let Some(rest) = command.strip_prefix("SET ") {
        match parse_changes(rest) {
            Ok(changes) => match layer.apply_live_changes(&changes) {
                Ok(()) => format!("OK {}\n", wire_profile(&layer.profile())),
                Err(e) => format!("ERR {e}\n"),
            },
            Err(e) => format!("ERR {e}\n"),
        }
    } else {
        "ERR unknown command\n".into()
    };

    let _ = stream.write_all(response.as_bytes());
}

fn parse_changes(text: &str) -> Result<Vec<(String, String)>, String> {
    let mut out = Vec::new();
    for item in text.split_whitespace() {
        let (key, value) = item
            .split_once('=')
            .ok_or_else(|| format!("invalid setting '{item}'"))?;
        out.push((key.to_string(), value.to_string()));
    }
    if out.is_empty() {
        return Err("no settings supplied".into());
    }
    Ok(out)
}

fn wire_profile(p: &crate::settings::Profile) -> String {
    format!(
        "profile={}\t{}\t{}\t{}\t{}\t{}\t{}",
        escape(&p.name),
        p.multiplier,
        p.flow_scale,
        if p.performance_mode { 1 } else { 0 },
        p.pacing_mode.name(),
        if p.override_present_mode { 1 } else { 0 },
        if p.preserve_swapchain_image_count { 1 } else { 0 },
    )
}

fn escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('\t', " ").replace('\n', " ")
}
