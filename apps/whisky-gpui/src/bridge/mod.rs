//! Live connection to the Swift `whisky-bridge` helper.
//!
//! M1b reads the container catalogue and each bottle's library over the bridge.
//! M2b adds the runtime session: configure on bottle selection, a cursor poll
//! over `runtime.events`, and launch/cancel/stop commands. The supervisor is
//! restartable: a failed or timed-out session can be replaced without
//! restarting the UI process.

pub(crate) mod dto;
mod supervisor;

pub(crate) use supervisor::{
    BottleCreateUpdate, BridgeEvent, BridgeSupervisor, EntryMutation, FolderEdit, ProgramMutation,
    ScanUpdate, diagnose_launch, print_config, print_folders, print_library, print_processes,
    print_programs, print_runtime, print_status, watch_runtime,
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
