use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

fn socket_path(pid: u32) -> PathBuf {
    PathBuf::from(format!("/tmp/lsfg-metal-{pid}.sock"))
}

fn send(pid: u32, command: &str) -> Result<String, String> {
    let path = socket_path(pid);
    let mut stream = UnixStream::connect(&path)
        .map_err(|e| format!("cannot connect to {}: {e}", path.display()))?;
    stream
        .write_all(format!("{command}\n").as_bytes())
        .map_err(|e| e.to_string())?;
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line).map_err(|e| e.to_string())?;
    Ok(line.trim_end().to_string())
}

fn list() -> Result<(), String> {
    let dir = std::fs::read_dir("/tmp").map_err(|e| e.to_string())?;
    let mut pids = Vec::new();
    for entry in dir.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let Some(rest) = name.strip_prefix("lsfg-metal-") else { continue };
        let Some(pid_text) = rest.strip_suffix(".sock") else { continue };
        if let Ok(pid) = pid_text.parse::<u32>() {
            pids.push(pid);
        }
    }
    pids.sort_unstable();

    for pid in pids {
        match send(pid, "GET") {
            Ok(line) if line.starts_with("OK ") => println!("{}\t{}", pid, line[3..].trim()),
            Ok(_) => {}
            Err(_) => {
                let _ = std::fs::remove_file(socket_path(pid));
            }
        }
    }
    Ok(())
}

fn usage() -> ! {
    eprintln!("usage: lsfg-control list | get <pid> | set <pid> key=value [...] | clear <pid>");
    std::process::exit(2)
}

fn main() {
    let mut args = std::env::args().skip(1);
    let Some(command) = args.next() else { usage() };

    let result = match command.as_str() {
        "list" => list(),
        "get" => {
            let pid = args.next().and_then(|v| v.parse().ok()).unwrap_or_else(|| usage());
            match send(pid, "GET") {
                Ok(v) => {
                    println!("{v}");
                    Ok(())
                }
                Err(e) => Err(e),
            }
        }
        "clear" => {
            let pid = args.next().and_then(|v| v.parse().ok()).unwrap_or_else(|| usage());
            match send(pid, "CLEAR") {
                Ok(v) => {
                    println!("{v}");
                    Ok(())
                }
                Err(e) => Err(e),
            }
        }
        "set" => {
            let pid = args.next().and_then(|v| v.parse().ok()).unwrap_or_else(|| usage());
            let changes: Vec<String> = args.collect();
            if changes.is_empty() {
                usage();
            }
            match send(pid, &format!("SET {}", changes.join(" "))) {
                Ok(v) => {
                    println!("{v}");
                    Ok(())
                }
                Err(e) => Err(e),
            }
        }
        _ => usage(),
    };

    if let Err(e) = result {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
