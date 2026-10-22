//! Discovered Linux terminal capabilities from the active helper session.
use serde::Deserialize;

#[derive(Clone, Debug, Deserialize)]
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) struct TerminalDto {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) path: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TerminalsDto {
    pub(crate) available: Vec<TerminalDto>,
    pub(crate) display_available: bool,
}

impl TerminalsDto {
    pub(crate) fn can_open(&self, preferred: &str) -> bool {
        self.display_available
            && self
                .available
                .iter()
                .any(|term| preferred == "auto" || term.id == preferred)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn terminal_selection_requires_a_display_and_the_selected_executable() {
        let mut status: TerminalsDto = serde_json::from_value(serde_json::json!({
            "available": [{"id":"xterm","name":"XTerm","path":"/usr/bin/xterm"}],
            "displayAvailable": true
        }))
        .unwrap();
        assert!(status.can_open("auto"));
        assert!(status.can_open("xterm"));
        assert!(!status.can_open("gnome-terminal"));
        status.display_available = false;
        assert!(!status.can_open("xterm"));
        status.available.clear();
        status.display_available = true;
        assert!(!status.can_open("auto"));
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) struct DesktopDto {
    pub(crate) installed: bool,
    pub(crate) path: String,
    pub(crate) cache_updated: Option<bool>,
}
