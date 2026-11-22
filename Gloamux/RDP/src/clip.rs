//! Text clipboard sharing over the RDP CLIPRDR channel.
//!
//! The channel calls the backend while it reads server messages, but the backend cannot answer on its own: it
//! notes what the server asked for, and the session loop answers once the message is handled.

use ironrdp_cliprdr::backend::CliprdrBackend;
use ironrdp_cliprdr::pdu::{
    ClipboardFormat, ClipboardFormatId, ClipboardGeneralCapabilityFlags, FileContentsRequest,
    FileContentsResponse, FormatDataRequest, FormatDataResponse, LockDataId, OwnedFormatDataResponse,
};
use ironrdp_cliprdr::{CliprdrClient, CliprdrSvcMessages};
use std::sync::{Arc, Mutex};

/// What the server asked for since the session loop last looked.
#[derive(Debug, Default)]
pub(crate) struct Events {
    /// The channel is ready for the list of formats the Mac clipboard offers.
    pub wants_formats: bool,
    /// The remote clipboard has new text, which this side should ask for.
    pub remote_text: bool,
    /// Formats the server asked for, oldest first.
    pub requests: Vec<ClipboardFormatId>,
    /// Text that arrived from the remote clipboard.
    pub received: Option<String>,
}

#[derive(Debug)]
pub(crate) struct Backend {
    events: Arc<Mutex<Events>>,
}

ironrdp_core::impl_as_any!(Backend);

pub(crate) fn client() -> (CliprdrClient, Arc<Mutex<Events>>) {
    let events = Arc::new(Mutex::new(Events::default()));
    let backend = Backend { events: events.clone() };
    (CliprdrClient::new(Box::new(backend)), events)
}

impl Backend {
    fn note(&self, change: impl FnOnce(&mut Events)) {
        if let Ok(mut events) = self.events.lock() {
            change(&mut events);
        }
    }
}

impl CliprdrBackend for Backend {
    fn temporary_directory(&self) -> &str {
        ".cliprdr"
    }

    fn client_capabilities(&self) -> ClipboardGeneralCapabilityFlags {
        // Text only: no file copy, so no locks or file streams.
        ClipboardGeneralCapabilityFlags::USE_LONG_FORMAT_NAMES
    }

    fn on_ready(&mut self) {}

    fn on_request_format_list(&mut self) {
        self.note(|events| events.wants_formats = true);
    }

    fn on_process_negotiated_capabilities(&mut self, _: ClipboardGeneralCapabilityFlags) {}

    fn on_remote_copy(&mut self, available_formats: &[ClipboardFormat]) {
        let text = available_formats
            .iter()
            .any(|format| format.id == ClipboardFormatId::CF_UNICODETEXT);
        self.note(|events| events.remote_text = text);
    }

    fn on_format_data_request(&mut self, request: FormatDataRequest) {
        self.note(|events| {
            // A server that keeps asking without reading the answers gets the newest requests only.
            if events.requests.len() >= 8 {
                events.requests.remove(0);
            }
            events.requests.push(request.format);
        });
    }

    fn on_format_data_response(&mut self, response: FormatDataResponse<'_>) {
        if response.is_error() {
            return;
        }
        if let Ok(text) = response.to_unicode_string() {
            self.note(|events| events.received = Some(from_windows(&text)));
        }
    }

    fn on_file_contents_request(&mut self, _: FileContentsRequest) {}

    fn on_file_contents_response(&mut self, _: FileContentsResponse<'_>) {}

    fn on_lock(&mut self, _: LockDataId) {}

    fn on_unlock(&mut self, _: LockDataId) {}
}

/// The formats to offer the server for the Mac clipboard text, if any.
pub(crate) fn formats(local: Option<&str>) -> Vec<ClipboardFormat> {
    match local {
        Some(_) => vec![ClipboardFormat::new(ClipboardFormatId::CF_UNICODETEXT)],
        None => Vec::new(),
    }
}

/// The answer to a server request for `format`.
pub(crate) fn answer(format: ClipboardFormatId, local: Option<&str>) -> OwnedFormatDataResponse {
    match local {
        Some(text) if format == ClipboardFormatId::CF_UNICODETEXT => {
            OwnedFormatDataResponse::new_unicode_string(&to_windows(text))
        }
        _ => OwnedFormatDataResponse::new_error(),
    }
}

pub(crate) type Messages = CliprdrSvcMessages<ironrdp_cliprdr::Client>;

/// Windows clipboard text ends lines with CR LF and may end with a NUL; the Mac uses LF.
pub(crate) fn from_windows(text: &str) -> String {
    text.trim_end_matches('\0').replace("\r\n", "\n")
}

pub(crate) fn to_windows(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\n', "\r\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line_ends_convert_both_ways() {
        assert_eq!(to_windows("a\nb\r\nc"), "a\r\nb\r\nc");
        assert_eq!(from_windows("a\r\nb\0"), "a\nb");
        assert_eq!(from_windows(&to_windows("一\n二\n")), "一\n二\n");
    }

    #[test]
    fn only_text_is_offered_and_answered() {
        assert!(formats(None).is_empty());
        assert_eq!(formats(Some("x"))[0].id, ClipboardFormatId::CF_UNICODETEXT);
        assert!(answer(ClipboardFormatId::CF_TEXT, Some("x")).is_error());
        assert!(answer(ClipboardFormatId::CF_UNICODETEXT, None).is_error());
        let reply = answer(ClipboardFormatId::CF_UNICODETEXT, Some("中\n"));
        assert_eq!(reply.to_unicode_string().map(|text| from_windows(&text)).ok(), Some("中\n".into()));
    }

    #[test]
    fn remote_text_and_requests_are_noted() {
        let events = Arc::new(Mutex::new(Events::default()));
        let mut backend = Backend { events: events.clone() };
        backend.on_remote_copy(&[ClipboardFormat::new(ClipboardFormatId::CF_UNICODETEXT)]);
        for _ in 0..10 {
            backend.on_format_data_request(FormatDataRequest { format: ClipboardFormatId::CF_UNICODETEXT });
        }
        backend.on_format_data_response(OwnedFormatDataResponse::new_unicode_string("hi\r\nthere"));
        let events = events.lock().unwrap();
        assert!(events.remote_text);
        assert_eq!(events.requests.len(), 8);
        assert_eq!(events.received.as_deref(), Some("hi\nthere"));
    }
}
