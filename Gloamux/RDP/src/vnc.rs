use crate::zrle::{Image, Zrle};
use crate::{CONNECTED, Input, Lost, MAX_CLIPBOARD, checked_pixels, clipboard, frame, send};
use anyhow::{Context, Result, bail, ensure};
use des::Des;
use des::cipher::{Block, BlockEncrypt, KeyInit};
use std::collections::HashSet;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpStream};
use std::sync::{Arc, Mutex, mpsc::Receiver};

const NONE: u8 = 1;
const VNC_AUTH: u8 = 2;
/// Apple Remote Desktop: a Mac account name and password, used by macOS Screen Sharing.
const APPLE: u8 = 30;
/// The largest compressed rectangle accepted, well above what the largest accepted screen needs.
const MAX_COMPRESSED: u32 = 128 * 1024 * 1024;

pub fn run(
    mut server: TcpStream,
    username: &str,
    password: &str,
    input: Receiver<Input>,
    output: &mut impl Write,
) -> Result<()> {
    sign_in(&mut server, username, password)
        .context("VNC sign-in failed. Check the user name, password, and server security settings.")?;
    let (width, height) = start(&mut server)?;
    let mut image = Image::new(usize::from(width), checked_pixels(width, height)? / usize::from(width));
    let mut zrle = Zrle::default();
    server.set_read_timeout(None)?;
    let writer = Arc::new(Mutex::new(server.try_clone()?));
    let input_writer = writer.clone();
    std::thread::spawn(move || {
        let _ = send_input(&input_writer, input);
        if let Ok(socket) = input_writer.lock() {
            let _ = socket.shutdown(Shutdown::Both);
        }
    });
    send(output, CONNECTED, &[])?;
    write(&writer, &update(false, width, height))?;
    loop {
        let mut message = [0; 1];
        match server.read_exact(&mut message) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(()),
            Err(error) => {
                return Err(error)
                    .context("The VNC session stopped responding.")
                    .context(Lost);
            }
        }
        match message[0] {
            0 => {
                let resized = read_update(&mut server, &mut image, &mut zrle)
                    .context("Cannot read the VNC desktop image.")?;
                let (width, height) = (image.width as u16, image.height as u16);
                frame(output, width, height, &image.pixels)?;
                write(&writer, &update(!resized, width, height))?;
            }
            2 => {} // Bell.
            3 => {
                // ServerCutText: Latin-1 text with LF line ends.
                let mut header = [0; 7];
                server.read_exact(&mut header)?;
                let size = u32::from_be_bytes(header[3..].try_into()?);
                ensure!(size <= 1024 * 1024, "Invalid VNC clipboard message.");
                let mut text = vec![0; size as usize];
                server.read_exact(&mut text)?;
                clipboard(output, &latin1_text(&text))?;
            }
            _ => bail!("The VNC server sent an unsupported message."),
        }
    }
}

fn sign_in(server: &mut (impl Read + Write), username: &str, password: &str) -> Result<()> {
    let mut version = [0; 12];
    server.read_exact(&mut version)?;
    let minor = negotiate_version(&version)?;
    server.write_all(format!("RFB 003.{minor:03}\n").as_bytes())?;
    let chosen = if minor == 3 {
        let mut value = [0; 4];
        server.read_exact(&mut value)?;
        u8::try_from(u32::from_be_bytes(value))?
    } else {
        let mut count = [0; 1];
        server.read_exact(&mut count)?;
        ensure!(count[0] != 0, "The VNC server refused to negotiate security.");
        let mut methods = vec![0; usize::from(count[0])];
        server.read_exact(&mut methods)?;
        let requested = choose_security(&methods, username, password)?;
        server.write_all(&[requested])?;
        requested
    };
    ensure!(
        (chosen == NONE && password.is_empty())
            || (chosen == VNC_AUTH && !password.is_empty())
            || (chosen == APPLE && !username.is_empty()),
        "The VNC server does not support the selected authentication."
    );
    match chosen {
        VNC_AUTH => {
            let mut challenge = [0; 16];
            server.read_exact(&mut challenge)?;
            server.write_all(&vnc_response(password, challenge)?)?;
        }
        APPLE => apple_sign_in(server, username, password)?,
        _ => {}
    }
    if chosen != NONE || minor >= 8 {
        let mut result = [0; 4];
        server.read_exact(&mut result)?;
        ensure!(result == [0; 4], "The VNC server rejected the sign-in.");
    }
    Ok(())
}

/// Asks for a shared desktop after sign-in and returns its size. Its failures are not sign-in failures, so they keep
/// their own messages.
fn start(server: &mut (impl Read + Write)) -> Result<(u16, u16)> {
    const FAILED: &str = "The VNC server did not start the session.";
    server.write_all(&[1]).context(FAILED)?; // Shared desktop.
    let mut initial = [0; 24];
    server.read_exact(&mut initial).context(FAILED)?;
    let width = u16::from_be_bytes([initial[0], initial[1]]);
    let height = u16::from_be_bytes([initial[2], initial[3]]);
    checked_pixels(width, height)?;
    let name_size = u32::from_be_bytes([initial[20], initial[21], initial[22], initial[23]]);
    ensure!(name_size <= 65536, FAILED);
    server.read_exact(&mut vec![0; name_size as usize]).context(FAILED)?;
    // 32 bits a pixel, true colour, little-endian, R, G, B at shifts 0, 8, 16: RGBX bytes, and ZRLE's compact pixels
    // are the first three.
    server.write_all(&[
        0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 0, 8, 16, 0, 0, 0,
    ])
    .context(FAILED)?;
    // ZRLE, CopyRect, Raw, and desktop resizing, in order of preference.
    server.write_all(&[
        2, 0, 0, 4, 0, 0, 0, 16, 0, 0, 0, 1, 0, 0, 0, 0, 255, 255, 255, 33,
    ])
    .context(FAILED)?;
    Ok((width, height))
}

/// The version to answer: 3.3, 3.7, or 3.8. Newer servers, such as macOS with its 3.889, accept 3.8.
fn negotiate_version(version: &[u8; 12]) -> Result<u32> {
    ensure!(
        version.starts_with(b"RFB ") && version[7] == b'.' && version[11] == b'\n',
        "Unsupported VNC version."
    );
    let number = |digits: &[u8]| -> Result<u32> {
        ensure!(digits.iter().all(u8::is_ascii_digit), "Unsupported VNC version.");
        Ok(std::str::from_utf8(digits)?.parse()?)
    };
    let (major, minor) = (number(&version[4..7])?, number(&version[8..11])?);
    Ok(match (major, minor) {
        (3, 3..=6) => 3,
        (3, 7) => 7,
        (3, 8..) | (4.., _) => 8,
        _ => bail!("Unsupported VNC version."),
    })
}

/// A Mac account when a user name is given, the VNC password when only a password is, and no sign-in otherwise.
fn choose_security(methods: &[u8], username: &str, password: &str) -> Result<u8> {
    if !username.is_empty() && methods.contains(&APPLE) {
        return Ok(APPLE);
    }
    let requested = if password.is_empty() { NONE } else { VNC_AUTH };
    if methods.contains(&requested) {
        return Ok(requested);
    }
    ensure!(
        !methods.contains(&APPLE),
        "This Mac needs its account user name and password."
    );
    bail!("The VNC server does not support the selected authentication.")
}

fn vnc_response(password: &str, mut challenge: [u8; 16]) -> Result<[u8; 16]> {
    let mut key = [0; 8];
    for (place, byte) in key.iter_mut().zip(password.bytes()) {
        *place = byte.reverse_bits();
    }
    let cipher = Des::new_from_slice(&key).context("Cannot prepare VNC authentication.")?;
    for chunk in challenge.chunks_exact_mut(8) {
        cipher.encrypt_block(Block::<Des>::from_mut_slice(chunk));
    }
    Ok(challenge)
}

fn apple_sign_in(server: &mut (impl Read + Write), username: &str, password: &str) -> Result<()> {
    let mut header = [0; 4];
    server.read_exact(&mut header)?;
    let generator = u16::from_be_bytes([header[0], header[1]]);
    let size = usize::from(u16::from_be_bytes([header[2], header[3]]));
    ensure!((16..=1024).contains(&size), "Invalid Mac sign-in request.");
    let mut prime = vec![0; size];
    let mut server_key = vec![0; size];
    server.read_exact(&mut prime)?;
    server.read_exact(&mut server_key)?;
    let mut private = vec![0; size];
    let mut filler = [0; 128];
    getrandom::fill(&mut private).map_err(|_| anyhow::anyhow!("Cannot prepare Mac sign-in."))?;
    getrandom::fill(&mut filler).map_err(|_| anyhow::anyhow!("Cannot prepare Mac sign-in."))?;
    let (secret, public) = crate::ard::response(generator, &prime, &server_key, &private, username, password, filler)?;
    server.write_all(&secret)?;
    server.write_all(&public)?;
    Ok(())
}

fn update(incremental: bool, width: u16, height: u16) -> [u8; 10] {
    let mut packet = [3, u8::from(incremental), 0, 0, 0, 0, 0, 0, 0, 0];
    packet[6..8].copy_from_slice(&width.to_be_bytes());
    packet[8..10].copy_from_slice(&height.to_be_bytes());
    packet
}

/// Applies one FramebufferUpdate. Returns true when the desktop changed size.
fn read_update(server: &mut impl Read, image: &mut Image, zrle: &mut Zrle) -> Result<bool> {
    let mut header = [0; 3];
    server.read_exact(&mut header)?;
    let count = u16::from_be_bytes([header[1], header[2]]);
    let mut resized = false;
    for _ in 0..count {
        let mut rectangle = [0; 12];
        server.read_exact(&mut rectangle)?;
        let value = |at: usize| usize::from(u16::from_be_bytes([rectangle[at], rectangle[at + 1]]));
        let (x, y, w, h) = (value(0), value(2), value(4), value(6));
        match i32::from_be_bytes(rectangle[8..12].try_into()?) {
            -223 => {
                checked_pixels(w as u16, h as u16)?;
                *image = Image::new(w, h);
                resized = true;
            }
            0 => {
                ensure!(image.fits(x, y, w, h), "Invalid VNC rectangle.");
                for row in y..y + h {
                    let start = (row * image.width + x) * 4;
                    server.read_exact(&mut image.pixels[start..start + w * 4])?;
                }
            }
            1 => {
                let mut source = [0; 4];
                server.read_exact(&mut source)?;
                let from_x = usize::from(u16::from_be_bytes([source[0], source[1]]));
                let from_y = usize::from(u16::from_be_bytes([source[2], source[3]]));
                image.copy(from_x, from_y, x, y, w, h)?;
            }
            16 => {
                let mut size = [0; 4];
                server.read_exact(&mut size)?;
                let size = u32::from_be_bytes(size);
                ensure!(size <= MAX_COMPRESSED, "Invalid VNC compressed image.");
                let mut data = vec![0; size as usize];
                server.read_exact(&mut data)?;
                zrle.decode(&data, image, x, y, w, h)?;
            }
            _ => bail!("The VNC server used an unsupported image encoding."),
        }
    }
    Ok(resized)
}

fn write(server: &Mutex<TcpStream>, packet: &[u8]) -> Result<()> {
    server
        .lock()
        .map_err(|_| anyhow::anyhow!("The VNC connection closed."))?
        .write_all(packet)
        .context("The VNC session stopped responding.")
}

fn send_input(server: &Mutex<TcpStream>, input: Receiver<Input>) -> Result<()> {
    let mut pointer = (0, 0, 0);
    let mut keys = HashSet::new();
    for event in input {
        match event {
            Input::Key { keysym: 0, .. } => {}
            Input::Key {
                keysym, pressed, ..
            } => {
                if pressed {
                    keys.insert(keysym);
                } else {
                    keys.remove(&keysym);
                }
                key(server, keysym, pressed)?;
            }
            Input::Pointer { x, y, mask } => {
                pointer = (x, y, mask);
                mouse(server, x, y, mask)?;
            }
            Input::Wheel { x, y, delta } => {
                if delta == 0 {
                    continue;
                }
                mouse(server, x, y, pointer.2 | if delta > 0 { 8 } else { 16 })?;
                mouse(server, x, y, pointer.2)?;
            }
            Input::Resize { .. } => {}
            Input::Clipboard { text } => {
                // Text the RFB clipboard cannot hold, such as Chinese, would arrive as question marks. Sent anyway,
                // it would also replace the Mac's own clipboard when the server runs on the same Mac.
                let Some(bytes) = latin1_bytes(&text) else {
                    continue;
                };
                let mut packet = vec![6, 0, 0, 0];
                packet.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
                packet.extend_from_slice(&bytes);
                write(server, &packet)?;
            }
            Input::Release => {
                for keysym in keys.drain() {
                    key(server, keysym, false)?;
                }
                mouse(server, pointer.0, pointer.1, 0)?;
                pointer.2 = 0;
            }
        }
    }
    Ok(())
}

/// RFB clipboard text is Latin-1 with LF line ends.
pub(crate) fn latin1_text(bytes: &[u8]) -> String {
    bytes.iter().map(|&byte| char::from(byte)).collect()
}

/// Text for the RFB clipboard: Latin-1 with LF line ends, at most `MAX_CLIPBOARD` bytes. None when the text has a
/// character Latin-1 cannot hold.
pub(crate) fn latin1_bytes(text: &str) -> Option<Vec<u8>> {
    text.replace("\r\n", "\n")
        .chars()
        .take(MAX_CLIPBOARD)
        .map(|character| u8::try_from(u32::from(character)).ok())
        .collect()
}

fn key(server: &Mutex<TcpStream>, keysym: u32, pressed: bool) -> Result<()> {
    let mut packet = [4, u8::from(pressed), 0, 0, 0, 0, 0, 0];
    packet[4..].copy_from_slice(&keysym.to_be_bytes());
    write(server, &packet)
}

fn mouse(server: &Mutex<TcpStream>, x: u16, y: u16, mask: u8) -> Result<()> {
    let mut packet = [5, mask, 0, 0, 0, 0];
    packet[2..4].copy_from_slice(&x.to_be_bytes());
    packet[4..6].copy_from_slice(&y.to_be_bytes());
    write(server, &packet)
}

#[cfg(test)]
mod clipboard_tests {
    use super::{latin1_bytes, latin1_text};

    #[test]
    fn clipboard_text_is_latin1_with_lf_line_ends() {
        assert_eq!(latin1_bytes("café\r\nnext"), Some(b"caf\xe9\nnext".to_vec()));
        assert_eq!(latin1_bytes("café 中文"), None);
        assert_eq!(latin1_text(b"caf\xe9\n"), "café\n");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn answers_the_vnc_challenge() {
        // Checked against OpenSSL DES-ECB with the bit-reversed key of "password".
        let response = vnc_response("password", *b"0123456789abcdef").unwrap();
        let expected = [
            0x56, 0x45, 0xab, 0xeb, 0x5f, 0x1e, 0x64, 0x75, 0xe8, 0xfe, 0xb1, 0x1b, 0xeb, 0x66, 0xea, 0x19,
        ];
        assert_eq!(response, expected);
    }

    #[test]
    fn negotiates_versions() {
        assert_eq!(negotiate_version(b"RFB 003.003\n").unwrap(), 3);
        assert_eq!(negotiate_version(b"RFB 003.007\n").unwrap(), 7);
        assert_eq!(negotiate_version(b"RFB 003.008\n").unwrap(), 8);
        assert_eq!(negotiate_version(b"RFB 003.889\n").unwrap(), 8);
        assert!(negotiate_version(b"RFB 002.000\n").is_err());
        assert!(negotiate_version(b"RFB 003.0+8\n").is_err());
        assert!(negotiate_version(b"HTTP/1.1 200").is_err());
    }

    #[test]
    fn chooses_security() {
        assert_eq!(choose_security(&[2, 30], "me", "secret").unwrap(), APPLE);
        assert_eq!(choose_security(&[2, 30], "", "secret").unwrap(), VNC_AUTH);
        assert_eq!(choose_security(&[1, 2], "me", "").unwrap(), NONE);
        assert_eq!(choose_security(&[1, 2], "me", "secret").unwrap(), VNC_AUTH);
        assert!(choose_security(&[30], "", "secret").is_err());
        assert!(choose_security(&[2], "", "").is_err());
    }

    #[test]
    fn applies_raw_copy_and_resize_rectangles() {
        let mut image = Image::new(2, 1);
        let mut zrle = Zrle::default();
        let mut message = vec![0, 0, 2]; // Padding and the rectangle count.
        message.extend([0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 7, 8, 9, 0]); // Raw pixel at 0,0.
        message.extend([0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0]); // Copy 0,0 to 1,0.
        assert!(!read_update(&mut message.as_slice(), &mut image, &mut zrle).unwrap());
        assert_eq!(image.pixels, vec![7, 8, 9, 0, 7, 8, 9, 0]);

        let resize = [0, 0, 1, 0, 0, 0, 0, 0, 3, 0, 2, 255, 255, 255, 33];
        assert!(read_update(&mut resize.as_slice(), &mut image, &mut zrle).unwrap());
        assert_eq!((image.width, image.height, image.pixels.len()), (3, 2, 24));

        let outside = [0, 0, 1, 0, 2, 0, 0, 0, 2, 0, 1, 0, 0, 0, 0];
        assert!(read_update(&mut outside.as_slice(), &mut image, &mut zrle).is_err());
        let huge = [0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 16, 255, 255, 255, 255];
        assert!(read_update(&mut huge.as_slice(), &mut image, &mut zrle).is_err());
    }

    /// A server that replays `incoming` and keeps what the client writes.
    struct Replay {
        incoming: std::io::Cursor<Vec<u8>>,
        written: Vec<u8>,
    }

    impl Read for Replay {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            self.incoming.read(buffer)
        }
    }

    impl Write for Replay {
        fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
            self.written.extend_from_slice(buffer);
            Ok(buffer.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn server_init(width: u16, height: u16) -> Replay {
        let mut incoming = Vec::new();
        incoming.extend(width.to_be_bytes());
        incoming.extend(height.to_be_bytes());
        incoming.extend([0; 16]); // Pixel format.
        incoming.extend(3u32.to_be_bytes());
        incoming.extend(b"Mac");
        Replay { incoming: std::io::Cursor::new(incoming), written: Vec::new() }
    }

    #[test]
    fn starts_a_retina_mac_screen() {
        // A 13-inch MacBook Air shares its screen as 2560×1664 pixels.
        let mut server = server_init(2560, 1664);
        assert_eq!(start(&mut server).unwrap(), (2560, 1664));
        assert_eq!(server.written[0], 1, "asks for a shared desktop");
        assert_eq!(start(&mut server_init(6016, 3384)).unwrap(), (6016, 3384));
    }

    #[test]
    fn start_failures_are_not_sign_in_failures() {
        let error = start(&mut server_init(8192, 8192)).unwrap_err();
        assert_eq!(error.to_string(), "Unsupported remote desktop size.");
        let mut cut = server_init(2560, 1664);
        cut.incoming.get_mut().truncate(10);
        assert_eq!(start(&mut cut).unwrap_err().to_string(), "The VNC server did not start the session.");
    }
}
