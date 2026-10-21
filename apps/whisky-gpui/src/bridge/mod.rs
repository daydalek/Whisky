//! Live connection to the Swift `whisky-bridge` helper.
//!
//! M1b reads the container catalogue and each bottle's library over the bridge.
//! The supervisor is restartable: a failed or timed-out session can be replaced
//! without restarting the UI process.

pub(crate) mod dto;
mod supervisor;

pub(crate) use supervisor::{
    BridgeEvent, BridgeSupervisor, print_library, print_runtime, print_status,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum BridgeStatus {
    Locating,
    Starting,
    Connected {
        helper: String,
        version: String,
        methods: usize,
    },
    Failed {
        reason: String,
        retryable: bool,
    },
    Stopped,
}

impl BridgeStatus {
    pub(crate) fn label(&self) -> &'static str {
        match self {
            Self::Locating | Self::Starting => "Connecting…",
            Self::Connected { .. } => "Connected",
            Self::Failed { .. } | Self::Stopped => "Unavailable",
        }
    }
}
