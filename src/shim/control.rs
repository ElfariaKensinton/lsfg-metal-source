use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::thread;

use super::Layer;
use crate::settings;

pub fn socket_path() -> PathBuf {
    PathBuf::from(format!("/tmp/lsfg-metal-{}.sock", std::process::id()))
}

pub fn start(layer: &'static Layer) {
    static START: std::sync::Once = std::sync::Once::new();
    START.call_once(|| {
        let path = socket_path();
        let _ = fs::remove_file(&path);

        let listener = match UnixListener::bind(&path) {
            Ok(listener) => listener,
            Err(e) => {
                crate::log::warn(&format!("live control socket disabled: {e}"));
                return;
            }
        };

        if let Err(e) = fs::set_permissions(&path, fs::Permissions::from_mode(0o600)) {
            crate::log::warn(&format!("cannot secure live control socket: {e}"));
            let _ = fs::remove_file(&path);
            return;
        }

        crate::log::info(&format!("live control socket: {}", path.display()));

        thread::Builder::new()
            .name("lsfg-control".into())
            .spawn(move || serve(listener, layer))
            .ok();
    });
}

fn serve(listener: UnixListener, layer: &'static Layer) {
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                if let Err(e) = handle(stream, layer) {
                    crate::log::warn(&format!("live control request failed: {e}"));
                }
            }
            Err(e) => {
                crate::log::warn(&format!("live control accept failed: {e}"));
                break;
            }
        }
    }
    let _ = fs::remove_file(socket_path());
}

fn handle(mut stream: UnixStream, layer: &'static Layer) -> Result<(), String> {
    let mut line = String::new();
    BufReader::new(stream.try_clone().map_err(|e| e.to_string())?)
        .read_line(&mut line)
        .map_err(|e| e.to_string())?;

    let command = line.trim();
    if command.eq_ignore_ascii_case("GET") {
        write_response(&mut stream, &format!("OK	{}", encode_profile(&layer.profile())))?;
        return Ok(());
    }

    if command.eq_ignore_ascii_case("CLEAR") {
        layer.clear_live_profile();
        write_response(&mut stream, &format!("OK	{}", encode_profile(&layer.profile())))?;
        return Ok(());
    }

    if let Some(rest) = command.strip_prefix("SET ") {
        let mut changes = Vec::new();
        for item in rest.split_whitespace() {
            let Some((key, value)) = item.split_once('=') else {
                return write_response(&mut stream, "ERR invalid key=value");
            };
            changes.push((key.to_string(), value.to_string()));
        }
        if changes.is_empty() {
            return write_response(&mut stream, "ERR no changes");
        }
        layer.apply_live_changes(&changes)?;
        return write_response(
            &mut stream,
            &format!("OK	{}", encode_profile(&layer.profile())),
        );
    }

    write_response(&mut stream, "ERR unknown command")
}

fn write_response(stream: &mut UnixStream, text: &str) -> Result<(), String> {
    stream.write_all(text.as_bytes()).map_err(|e| e.to_string())
}

fn encode_profile(p: &settings::Profile) -> String {
    format!(
        "profile={}	multiplier={}	flow_scale={:.3}	performance_mode={}	pacing_mode={}	override_present_mode={}	preserve_swapchain_image_count={}",
        p.name.replace('\t', " "),
        p.multiplier,
        p.flow_scale,
        p.performance_mode as u8,
        p.pacing_mode.name(),
        p.override_present_mode as u8,
        p.preserve_swapchain_image_count as u8
    )
}
