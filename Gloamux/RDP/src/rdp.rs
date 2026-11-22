use crate::{CERTIFICATE, CONNECTED, Input, Login, Lost, checked_pixels, clip, clipboard, frame, send};
use anyhow::{Context, Result, bail, ensure};
use ironrdp_blocking::Framed;
use ironrdp_connector::sspi::{self, generator::NetworkRequest, network_client::NetworkClient};
use ironrdp_connector::connection_activation::{ConnectionActivationFactory, ConnectionActivationState};
use ironrdp_cliprdr::CliprdrClient;
use ironrdp_cliprdr::pdu::ClipboardFormatId;
use ironrdp_connector::{self as connector, Credentials, DesktopSize, Sequence};
use ironrdp_core::WriteBuf;
use ironrdp_displaycontrol::client::DisplayControlClient;
use ironrdp_dvc::DrdynvcClient;
use ironrdp_graphics::image_processing::PixelFormat;
use ironrdp_input::{Database, MouseButton, MousePosition, Operation, Scancode, WheelRotations};
use ironrdp_pdu::gcc::{ConnectionType, KeyboardType};
use ironrdp_pdu::rdp::capability_sets::{MajorPlatformType, RailSupportLevel};
use ironrdp_pdu::rdp::client_info::{CompressionType, PerformanceFlags, TimezoneInfo};
use ironrdp_session::{ActiveStageBuilder, ActiveStageOutput, image::DecodedImage};
use sha2::{Digest, Sha256};
use std::io::{self, Write};
use std::net::TcpStream;
use std::sync::mpsc::{Receiver, TryRecvError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use x509_cert::der::Decode;

struct NoNetwork;

impl NetworkClient for NoNetwork {
    fn send(&self, _: &NetworkRequest) -> sspi::Result<Vec<u8>> {
        Err(sspi::Error::new(
            sspi::ErrorKind::NoAuthenticatingAuthority,
            "Kerberos network requests are unavailable",
        ))
    }
}

pub fn run(
    socket: TcpStream,
    login: Login,
    input: Receiver<Input>,
    output: &mut impl Write,
) -> Result<()> {
    let address = socket
        .local_addr()
        .context("Cannot configure the RDP connection.")?;
    let host = login.host.clone();
    let pin = login.fingerprint.clone();
    // Display Control lets the desktop follow the size of the view after sign-in.
    let channels = DrdynvcClient::new().with_dynamic_channel(DisplayControlClient::new(|_| Ok(Vec::new())));
    // CLIPRDR shares clipboard text with the Mac.
    let (clipboard_channel, clipboard_events) = clip::client();
    let mut connector = connector::ClientConnector::new(settings(login), address)
        .with_static_channel(channels)
        .with_static_channel(clipboard_channel);
    let mut framed = Framed::new(socket);
    let upgrade = ironrdp_blocking::connect_begin(&mut framed, &mut connector)
        .context("The server refused the RDP connection.")?;
    let (socket, leftover) = framed.into_inner();
    ensure!(
        leftover.is_empty(),
        "The server returned invalid RDP negotiation data."
    );
    let Some((tls, public_key)) = connect_tls(socket, host.clone(), pin.as_deref(), output)? else {
        // The UI can ask the user to verify the certificate and try again.
        return Ok(());
    };
    let upgraded = ironrdp_blocking::mark_as_upgraded(upgrade, &mut connector);
    let mut transport = Framed::new(tls);
    let result = ironrdp_blocking::connect_finalize(
        upgraded,
        connector,
        &mut transport,
        &mut NoNetwork,
        host.into(),
        public_key,
        None,
    )
    .and_then(connector::ConnectionOutcome::into_connected)
    .context("RDP sign-in failed. Check the account, password, and server settings.")?;
    transport
        .get_inner()
        .0
        .sock
        .set_read_timeout(Some(Duration::from_millis(25)))
        .context("Cannot configure the RDP connection.")?;
    let size = result.desktop_size;
    checked_pixels(size.width, size.height)?;
    let mut image = DecodedImage::new(PixelFormat::RgbA32, size.width, size.height);
    let (io_channel_id, user_channel_id) = (result.io_channel_id, result.user_channel_id);
    let activation = result.activation_factory.clone();
    let mut stage = ActiveStageBuilder {
        static_channels: result.static_channels,
        user_channel_id: result.user_channel_id,
        io_channel_id: result.io_channel_id,
        message_channel_id: result.message_channel_id,
        share_id: result.share_id,
        compression_type: result.compression_type,
        enable_server_pointer: result.enable_server_pointer,
        pointer_software_rendering: result.pointer_software_rendering,
    }
    .build();
    send(output, CONNECTED, &[])?;
    let mut keyboard = Database::new();
    let mut buttons = 0;
    let mut updated = false;
    // A size the view asked for that the server has not been sent yet: Display Control may still be opening.
    let mut wanted: Option<(u32, u32)> = None;
    // The newest Mac clipboard text, offered to the server until the next copy replaces it.
    let mut local_text: Option<String> = None;
    let interval = Duration::from_millis(45);
    let mut last_frame = Instant::now() - interval;
    loop {
        for _ in 0..32 {
            let event = match input.try_recv() {
                Ok(event) => event,
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => return Ok(()),
            };
            let events = match event {
                Input::Resize { width, height } => {
                    wanted = Some(desktop_size(width, height));
                    continue;
                }
                Input::Clipboard { text } => {
                    local_text = Some(text);
                    if let Some(channel) = stage.get_svc_processor_mut::<CliprdrClient>()
                        && channel.is_ready()
                    {
                        let messages = channel
                            .initiate_copy(&clip::formats(local_text.as_deref()))
                            .context("Cannot share the clipboard.")?;
                        send_clipboard(&mut stage, &mut transport, messages)?;
                    }
                    continue;
                }
                Input::Release => {
                    buttons = 0;
                    keyboard.release_all()
                }
                _ => keyboard.apply(operations(event, &mut buttons)),
            };
            for response in stage
                .process_fastpath_input(&mut image, &events)
                .context("Cannot send input to the RDP session.")?
            {
                if let ActiveStageOutput::ResponseFrame(packet) = response {
                    transport
                        .write_all(&packet)
                        .context("The RDP session stopped responding.")
                        .context(Lost)?;
                }
            }
        }
        if let Some((width, height)) = wanted {
            let current = (u32::from(image.width()), u32::from(image.height()));
            if current == (width, height) {
                wanted = None;
            } else if let Some(request) = stage.encode_resize(width, height, None, None) {
                let packet = request.context("Cannot ask the RDP server for a new size.")?;
                transport
                    .write_all(&packet)
                    .context("The RDP session stopped responding.")
                    .context(Lost)?;
                wanted = None;
            }
        }
        match transport.read_pdu() {
            Ok((kind, bytes)) => {
                let outputs = stage
                    .process(&mut image, kind, &bytes, transport.last_read_at())
                    .context("Cannot read the RDP session output.")?;
                for event in outputs {
                    match event {
                        ActiveStageOutput::ResponseFrame(packet) => {
                            transport
                                .write_all(&packet)
                                .context("The RDP session stopped responding.")
                                .context(Lost)?;
                        }
                        ActiveStageOutput::GraphicsUpdate(_) => updated = true,
                        ActiveStageOutput::DeactivateAll => {
                            // The server changes the desktop, after a resize for one: sign the session in again
                            // at the new size, keeping the connection.
                            let size = reactivate(&mut transport, &activation, &mut stage, io_channel_id, user_channel_id)?;
                            checked_pixels(size.width, size.height)?;
                            image = DecodedImage::new(PixelFormat::RgbA32, size.width, size.height);
                            updated = false;
                        }
                        ActiveStageOutput::Terminate(_) => return Ok(()),
                        _ => {}
                    }
                }
                answer_clipboard(&mut stage, &mut transport, &clipboard_events, local_text.as_deref(), output)?;
            }
            Err(ref error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                ) => {}
            // The server ends a session with a Terminate output first; a bare end of stream is a broken connection.
            Err(ref error) if error.kind() == io::ErrorKind::UnexpectedEof => return Err(Lost.into()),
            Err(error) => {
                return Err(error)
                    .context("The RDP session stopped responding.")
                    .context(Lost);
            }
        }
        if updated && last_frame.elapsed() >= interval {
            frame(output, image.width(), image.height(), image.data())?;
            updated = false;
            last_frame = Instant::now();
        }
    }
}

type TlsStream = rustls::StreamOwned<rustls::ClientConnection, TcpStream>;

fn send_clipboard(
    stage: &mut ironrdp_session::ActiveStage,
    transport: &mut Framed<TlsStream>,
    messages: clip::Messages,
) -> Result<()> {
    let packet = stage
        .process_svc_processor_messages(messages)
        .context("Cannot share the clipboard.")?;
    transport
        .write_all(&packet)
        .context("The RDP session stopped responding.")
        .context(Lost)
}

/// Answers what the clipboard channel noted while the last server message was handled.
fn answer_clipboard(
    stage: &mut ironrdp_session::ActiveStage,
    transport: &mut Framed<TlsStream>,
    events: &Mutex<clip::Events>,
    local: Option<&str>,
    output: &mut impl Write,
) -> Result<()> {
    let noted = match events.lock() {
        Ok(mut events) => std::mem::take(&mut *events),
        Err(_) => return Ok(()),
    };
    if let Some(text) = noted.received {
        clipboard(output, &text)?;
    }
    let Some(channel) = stage.get_svc_processor_mut::<CliprdrClient>() else {
        return Ok(());
    };
    let mut messages = Vec::new();
    if noted.wants_formats {
        messages.push(channel.initiate_copy(&clip::formats(local)).context("Cannot share the clipboard.")?);
    }
    if noted.remote_text && channel.is_ready() {
        messages.push(
            channel
                .initiate_paste(ClipboardFormatId::CF_UNICODETEXT)
                .context("Cannot read the remote clipboard.")?,
        );
    }
    for format in noted.requests {
        if channel.is_ready() {
            messages.push(channel.submit_format_data(clip::answer(format, local)).context("Cannot share the clipboard.")?);
        }
    }
    for batch in messages {
        send_clipboard(stage, transport, batch)?;
    }
    Ok(())
}

/// The size to ask for: RDP wants an even width from 200 to 8192 and a height from 200 to 8192, and this
/// engine draws at most `MAX_PIXELS`, so a larger view gets a smaller desktop with the same shape.
pub(crate) fn desktop_size(width: u16, height: u16) -> (u32, u32) {
    let (mut width, mut height) = (f64::from(width.max(200)), f64::from(height.max(200)));
    let limit = crate::MAX_PIXELS as f64;
    if width * height > limit {
        let scale = (limit / (width * height)).sqrt();
        width *= scale;
        height *= scale;
    }
    let width = (width as u32).clamp(200, 8192) & !1;
    let height = (height as u32).clamp(200, 8192);
    (width, height)
}

/// The Deactivation-Reactivation Sequence: capabilities and finalization again, on the same connection.
fn reactivate(
    transport: &mut Framed<TlsStream>,
    activation: &ConnectionActivationFactory,
    stage: &mut ironrdp_session::ActiveStage,
    io_channel_id: u16,
    user_channel_id: u16,
) -> Result<DesktopSize> {
    let mut sequence = activation.create();
    let mut buffer = WriteBuf::new();
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        buffer.clear();
        let written = if let Some(hint) = sequence.next_pdu_hint() {
            let pdu = loop {
                match transport.read_by_hint(hint) {
                    Ok(pdu) => break pdu,
                    Err(ref error)
                        if matches!(error.kind(), io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock)
                            && Instant::now() < deadline => {}
                    Err(error) => {
                        return Err(error)
                            .context("The RDP session stopped responding.")
                            .context(Lost);
                    }
                }
            };
            sequence
                .step(&pdu, transport.last_read_at(), &mut buffer)
                .context("Cannot resize the RDP desktop.")?
        } else {
            sequence
                .step_no_input(&mut buffer)
                .context("Cannot resize the RDP desktop.")?
        };
        if let Some(length) = written.size() {
            transport
                .write_all(&buffer[..length])
                .context("The RDP session stopped responding.")
                .context(Lost)?;
        }
        match sequence.connection_activation_state() {
            ConnectionActivationState::Finalized {
                desktop_size,
                share_id,
                static_channel_chunk_size,
                enable_server_pointer,
                pointer_software_rendering,
                ..
            } => {
                ensure!(
                    stage.reactivate(
                        io_channel_id,
                        user_channel_id,
                        share_id,
                        enable_server_pointer,
                        pointer_software_rendering,
                        static_channel_chunk_size,
                    ),
                    "Cannot resize the RDP desktop."
                );
                return Ok(desktop_size);
            }
            ConnectionActivationState::Redirected { .. } => {
                bail!("The RDP server redirected the session, which Gloamux does not support.")
            }
            _ => {}
        }
    }
}

fn connect_tls(
    socket: TcpStream,
    host: String,
    pin: Option<&str>,
    output: &mut impl Write,
) -> Result<Option<(TlsStream, Vec<u8>)>> {
    let observed = Arc::new(Mutex::new(None));
    let saved = pin.map(str::to_owned);
    let callback = {
        let observed = Arc::clone(&observed);
        Arc::new(move |der: &[u8], _: &str, _: &str| {
            let fingerprint = fingerprint(der);
            let accepted = saved.as_deref() == Some(fingerprint.as_str());
            if let Ok(mut locked) = observed.lock() {
                *locked = Some(fingerprint);
            }
            accepted
        })
    };
    let mut config = ironrdp_tls::rustls_client_config(
        ironrdp_tls::CertificateValidation::Strict,
        &host,
        Some(callback),
    )
    .context("Cannot load trusted RDP certificates.")?;
    config.key_log = Arc::new(rustls::NoKeyLog {});
    let server_name = host
        .try_into()
        .context("Invalid remote desktop host name.")?;
    let client = rustls::ClientConnection::new(Arc::new(config), server_name)
        .context("Cannot start RDP encryption.")?;
    let mut tls = rustls::StreamOwned::new(client, socket);
    if let Err(error) = tls.flush() {
        if let Ok(candidate) = observed.lock() {
            if let Some(value) = candidate.as_deref() {
                send(output, CERTIFICATE, &[value.as_bytes()])?;
                return Ok(None);
            }
        }
        return Err(error).context("Cannot verify the RDP server certificate.");
    }
    let der = tls
        .conn
        .peer_certificates()
        .and_then(|chain| chain.first())
        .context("The RDP server sent no certificate.")?;
    let actual = fingerprint(der);
    if pin.is_some_and(|pin| pin != actual) {
        send(output, CERTIFICATE, &[actual.as_bytes()])?;
        return Ok(None);
    }
    let certificate =
        x509_cert::Certificate::from_der(der).context("Cannot read the RDP server certificate.")?;
    let key = ironrdp_tls::extract_tls_server_public_key(&certificate)
        .context("Cannot read the RDP server public key.")?
        .to_vec();
    Ok(Some((tls, key)))
}

fn fingerprint(der: &[u8]) -> String {
    Sha256::digest(der)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn operations(input: Input, buttons: &mut u8) -> Vec<Operation> {
    match input {
        Input::Key { scan: 0, .. } => Vec::new(),
        Input::Key { scan, pressed, .. } => vec![if pressed {
            Operation::KeyPressed(Scancode::from_u16(scan))
        } else {
            Operation::KeyReleased(Scancode::from_u16(scan))
        }],
        Input::Pointer { x, y, mask } => {
            let mut operations = vec![Operation::MouseMove(MousePosition { x, y })];
            for (bit, button) in [
                (1, MouseButton::Left),
                (2, MouseButton::Middle),
                (4, MouseButton::Right),
            ] {
                if (*buttons ^ mask) & bit != 0 {
                    operations.push(if mask & bit != 0 {
                        Operation::MouseButtonPressed(button)
                    } else {
                        Operation::MouseButtonReleased(button)
                    });
                }
            }
            *buttons = mask;
            operations
        }
        Input::Wheel { x, y, delta } => vec![
            Operation::MouseMove(MousePosition { x, y }),
            Operation::WheelRotations(WheelRotations {
                is_vertical: true,
                rotation_units: delta.clamp(-255, 255),
            }),
        ],
        Input::Release | Input::Resize { .. } | Input::Clipboard { .. } => Vec::new(),
    }
}

fn settings(login: Login) -> connector::Config {
    let (width, height) = if login.width == 0 || login.height == 0 {
        (1280, 800)
    } else {
        desktop_size(login.width, login.height)
    };
    let (username, domain) = match login.username.split_once('\\') {
        Some((domain, username)) => (username.to_owned(), Some(domain.to_owned())),
        None => (login.username, None),
    };
    connector::Config {
        credentials: Credentials::UsernamePassword {
            username,
            password: login.password,
        },
        domain,
        enable_tls: true,
        enable_credssp: true,
        enable_standard_rdp_security: false,
        keyboard_type: KeyboardType::IBM_ENHANCED,
        keyboard_subtype: 0,
        keyboard_layout: 0x0409,
        keyboard_functional_keys_count: 12,
        connection_type: ConnectionType::Lan,
        ime_file_name: String::new(),
        dig_product_id: String::new(),
        desktop_size: DesktopSize {
            width: width as u16,
            height: height as u16,
        },
        monitor_layout: None,
        bitmap: None,
        client_build: 0,
        client_name: "Gloamux".to_owned(),
        client_dir: String::new(),
        platform: MajorPlatformType::MACINTOSH,
        enable_server_pointer: false,
        request_data: None,
        autologon: true,
        enable_audio_playback: false,
        enable_audio_capture: false,
        compression_type: Some(CompressionType::Rdp61),
        pointer_software_rendering: false,
        multitransport_flags: None,
        support_dyn_vc_gfx_protocol: false,
        performance_flags: PerformanceFlags::default(),
        desktop_scale_factor: 0,
        desktop_physical_size: None,
        desktop_orientation: None,
        device_scale_factor: None,
        monitor_extended_layout: None,
        relative_mouse_input: false,
        hardware_id: None,
        license_cache: None,
        timezone_info: TimezoneInfo::default(),
        alternate_shell: String::new(),
        work_dir: String::new(),
        remote_application_mode: false,
        rail_support_level: RailSupportLevel::empty(),
    }
}

#[cfg(test)]
mod tests {
    use super::desktop_size;

    #[test]
    fn sizes_are_even_within_limits_and_keep_their_shape() {
        assert_eq!(desktop_size(1281, 801), (1280, 801));
        assert_eq!(desktop_size(50, 50), (200, 200));
        let (width, height) = desktop_size(5120, 3200);
        assert!(width as usize * height as usize <= crate::MAX_PIXELS);
        assert_eq!(width % 2, 0);
        assert!((f64::from(width) / f64::from(height) - 1.6).abs() < 0.01);
    }
}
