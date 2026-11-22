mod ard;
mod clip;
mod rdp;
mod vnc;
mod zrle;

use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use std::io::{self, BufRead, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::mpsc::{Receiver, sync_channel};
use std::time::Duration;

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum Protocol {
    Rdp,
    Vnc,
}

#[derive(Deserialize)]
struct Login {
    protocol: Protocol,
    host: String,
    port: u16,
    username: String,
    password: String,
    fingerprint: Option<String>,
    /// The desktop size to ask an RDP server for; 0 uses 1280×800.
    #[serde(default)]
    width: u16,
    #[serde(default)]
    height: u16,
    /// A port on 127.0.0.1 that the app tunnels to the desktop over SSH. `host` still names the desktop for
    /// certificates and sign-in.
    #[serde(default)]
    via_port: Option<u16>,
}

/// The connection broke rather than ending: the app may connect again.
#[derive(Debug)]
pub struct Lost;

impl std::fmt::Display for Lost {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("The remote desktop connection was lost.")
    }
}

impl std::error::Error for Lost {}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum Input {
    Key {
        scan: u16,
        keysym: u32,
        pressed: bool,
    },
    Pointer {
        x: u16,
        y: u16,
        mask: u8,
    },
    Wheel {
        x: u16,
        y: u16,
        delta: i16,
    },
    /// The view changed size; an RDP server is asked to match it.
    Resize {
        width: u16,
        height: u16,
    },
    /// The Mac clipboard's text, for the remote clipboard.
    Clipboard {
        text: String,
    },
    Release,
}

const CONNECTED: u8 = 1;
const FRAME: u8 = 2;
const CERTIFICATE: u8 = 3;
const ERROR: u8 = 4;
const CLOSED: u8 = 5;
/// Clipboard text from the remote desktop, UTF-8.
const CLIPBOARD: u8 = 6;
/// The connection broke, as opposed to ERROR before or during sign-in and CLOSED when the session ended.
const LOST: u8 = 7;
/// The largest clipboard text passed either way.
const MAX_CLIPBOARD: usize = 256 * 1024;
/// The largest desktop Gloamux asks an RDP server for.
const MAX_PIXELS: usize = 2560 * 1600;
/// The largest desktop image accepted. A VNC server picks its own size, which for a Mac is its screen in pixels, so
/// this allows a 6K display.
const MAX_IMAGE_PIXELS: usize = 6144 * 3456;

fn main() {
    let mut output = io::BufWriter::with_capacity(64 * 1024, io::stdout().lock());
    let result = run(&mut output);
    // Report only the local context, never peer strings or credentials.
    if let Err(error) = result {
        let kind = if error.downcast_ref::<Lost>().is_some() { LOST } else { ERROR };
        let _ = send(&mut output, kind, &[error.to_string().as_bytes()]);
    } else {
        let _ = send(&mut output, CLOSED, &[]);
    }
}

fn run(output: &mut impl Write) -> Result<()> {
    let mut commands = io::BufReader::new(io::stdin());
    let login = serde_json::from_slice(&read_message(&mut commands)?)
        .context("Invalid remote desktop settings.")?;
    let (send_input, receive) = sync_channel(128);
    std::thread::spawn(move || {
        while let Ok(line) = read_message(&mut commands) {
            let Ok(input) = serde_json::from_slice::<Input>(&line) else {
                break;
            };
            if send_input.send(input).is_err() {
                break;
            }
        }
    });
    connect_and_run(login, receive, output)
}

fn connect_and_run(login: Login, input: Receiver<Input>, output: &mut impl Write) -> Result<()> {
    let (host, port) = match login.via_port {
        Some(port) => ("127.0.0.1", port),
        None => (login.host.as_str(), login.port),
    };
    let mut addresses = (host, port)
        .to_socket_addrs()
        .context("Cannot find the remote desktop host.")?;
    let socket = addresses
        .by_ref()
        .take(4)
        .find_map(|address| TcpStream::connect_timeout(&address, Duration::from_secs(4)).ok())
        .context("Cannot connect to the remote desktop host.")?;
    socket
        .set_nodelay(true)
        .context("Cannot configure the network connection.")?;
    socket
        .set_read_timeout(Some(Duration::from_secs(12)))
        .context("Cannot configure the network connection.")?;
    socket
        .set_write_timeout(Some(Duration::from_secs(5)))
        .context("Cannot configure the network connection.")?;
    match login.protocol {
        Protocol::Rdp => rdp::run(socket, login, input, output),
        Protocol::Vnc => vnc::run(socket, &login.username, &login.password, input, output),
    }
}

fn read_message(input: &mut impl BufRead) -> Result<Vec<u8>> {
    let mut line = Vec::new();
    input
        .take(MAX_CLIPBOARD as u64 * 2 + 4096)
        .read_until(b'\n', &mut line)
        .context("Cannot read remote desktop input.")?;
    ensure!(line.last() == Some(&b'\n'), "Invalid remote desktop input.");
    Ok(line)
}

fn send(output: &mut impl Write, kind: u8, pieces: &[&[u8]]) -> io::Result<()> {
    let count: usize = pieces.iter().map(|part| part.len()).sum();
    output.write_all(&[kind])?;
    output.write_all(&(count as u32).to_le_bytes())?;
    for part in pieces {
        output.write_all(part)?;
    }
    output.flush()
}

fn frame(output: &mut impl Write, width: u16, height: u16, data: &[u8]) -> Result<()> {
    ensure!(
        checked_pixels(width, height)? * 4 == data.len(),
        "Invalid remote desktop image."
    );
    send(
        output,
        FRAME,
        &[&width.to_le_bytes(), &height.to_le_bytes(), data],
    )
    .context("Cannot show the remote desktop image.")
}

/// Sends remote clipboard text to the app, cut to `MAX_CLIPBOARD` bytes at a character boundary.
fn clipboard(output: &mut impl Write, text: &str) -> Result<()> {
    let mut end = text.len().min(MAX_CLIPBOARD);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    send(output, CLIPBOARD, &[&text.as_bytes()[..end]]).context("Cannot pass on the remote clipboard.")
}

fn checked_pixels(width: u16, height: u16) -> Result<usize> {
    let pixels = usize::from(width) * usize::from(height);
    ensure!(
        width > 0 && height > 0 && pixels <= MAX_IMAGE_PIXELS,
        "Unsupported remote desktop size."
    );
    Ok(pixels)
}
