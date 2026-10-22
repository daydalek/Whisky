//! Helper discovery, process lifecycle, handshake validation, reconnects, the
//! small read-request queue the UI drives, and the runtime session.
//!
//! All bridge work is blocking, so it runs on one dedicated thread. The UI only
//! receives events over an async channel and sends commands; it never touches
//! the child process. Requests are handled one at a time (one in-flight call),
//! and the last successful `library.entries` result is cached for the current
//! bottle only, so switching bottles always refetches.
//!
//! The runtime session is a cursor poll, not a push channel: `library.entries`
//! reads and `runtime.*` calls share the same worker, so a `runtime.events`
//! poll can never overlap a `runtime.configure`. A poll is scheduled with
//! `recv_timeout`, which also means any command pre-empts the wait.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{
    self, Receiver as CommandReceiver, RecvTimeoutError, Sender as CommandSender,
};
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde::Serialize;
use serde_json::json;
use whisky_bridge::Client;

use super::{
    BridgeStatus,
    dto::{
        ActivityDto, AudioResultDto, BottleOperationResultDto, BridgeFailureDto, CandidatesDto,
        ChecksReplyDto, ConfigChangeDto, Container, ContainerList, DescribeResponse,
        DiagnosticsReportDto,
        EntryDto, EntryList, FoldersDto, GameConfigApplyReplyDto, GameConfigMatchReplyDto,
        HiddenReplyDto, JobDto, JobStartDto, KillReplyDto, LaunchReplyDto, LibraryPageDto,
        MetadataSearchGroupDto, MetadataSearchReplyDto, MetadataSyncReplyDto, PathReplyDto,
        PreferencesSchemaDto, SetupStatusDto,
        ProcessDto, ProgramDto, RUNTIME_METHODS, RUNTIME_SESSION_METHODS, RuntimeEntryDto,
        RuntimeEventBatchDto, RuntimeEventPayloadDto, RuntimeSnapshotDto, ScanResultDto,
        SystemInfoDto,
    },
};
use crate::config::{self, ConfigField};
use crate::create_bottle::BottleCreatedDto;
use crate::program_settings::{HistoryDto, ProgramSettingsDto};
use crate::runtime::{
    CAP_LAUNCH, ClipboardDecision, ClipboardPrompt, LaunchOutcome, RuntimeAction, RuntimeState,
    RuntimeUpdate, interpret_launch_reply, poll_interval, primary_action_for,
};
use crate::scan::{self, JobStatus, PageAccumulator};
use crate::winetricks::{self, CatalogDto, InstallProgress, InstallResultDto, InstalledDto};

/// Executable product declared in `WhiskyBridge/Package.swift`.
const HELPER_PRODUCT: &str = "whisky-bridge";
const CALL_TIMEOUT: Duration = Duration::from_secs(5);
/// Native dialogs allow human interaction; Linux's chooser bounds itself at 300 s.
const PICKER_TIMEOUT: Duration = Duration::from_secs(330);
pub(crate) const BACKOFF_MIN_MS: u64 = 500;
pub(crate) const BACKOFF_MAX_MS: u64 = 8_000;
/// How long the worker blocks when there is nothing to poll and nothing to do.
/// Commands still wake it immediately.
const PARK: Duration = Duration::from_secs(3_600);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum EntryMutation {
    Rating,
    Hidden,
}

/// Which `programs.*` write a `ProgramFailed` event names, so the UI rolls
/// back exactly the flag that was rejected.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ProgramMutation {
    Pin,
    Block,
}

/// A bottle lifecycle action. `Rename` and `CleanCache` are answered directly;
/// the rest return a `BridgeJobStore` job and are polled.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BottleOperation {
    Rename,
    Remove,
    Move,
    Duplicate,
    Export,
    Repair,
    CleanCache,
}

impl BottleOperation {
    fn method(self) -> &'static str {
        match self {
            Self::Rename => "bottle.rename",
            Self::Remove => "bottle.remove",
            Self::Move => "bottle.move",
            Self::Duplicate => "bottle.duplicate",
            Self::Export => "bottle.export",
            Self::Repair => "bottle.repair",
            Self::CleanCache => "bottle.cleanCache",
        }
    }

    fn is_job(self) -> bool {
        !matches!(self, Self::Rename)
    }

    /// A mutation that changes the container catalogue and must re-read it.
    fn refreshes_catalogue(self) -> bool {
        matches!(self, Self::Rename | Self::Remove | Self::Move | Self::Duplicate)
    }
}

/// One lifecycle operation as the UI sees it.
#[derive(Debug)]
pub(crate) enum BottleOperationUpdate {
    Started,
    Completed {
        path: Option<String>,
        name: Option<String>,
    },
    Failed {
        reason: String,
    },
}

/// The three `bottle.diagnostics` / `audio.test` jobs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DiagnosticKind {
    Report,
    Export,
    Checks,
    Audio,
}

/// One diagnostics/audio job as the UI sees it.
#[derive(Debug)]
pub(crate) enum DiagnosticUpdate {
    Started,
    Report {
        report: String,
    },
    Exported {
        path: String,
    },
    Audio {
        result: crate::bridge::dto::AudioResultDto,
    },
    Checks {
        results: Vec<crate::bridge::dto::TroubleshootingCheckDto>,
    },
    Failed {
        reason: String,
    },
}

/// WhiskyWine runtime setup state.
#[derive(Debug)]
pub(crate) enum SetupUpdate {
    Status {
        installed: bool,
        version: Option<String>,
        rosetta_installed: bool,
        apple_silicon: bool,
    },
    Installing {
        stage: Option<String>,
        /// Bytes received and expected during the download stage.
        progress: Option<(u64, u64)>,
    },
    Installed {
        version: Option<String>,
    },
    RosettaInstalled,
    /// `setup.checkUpdate` found a newer runtime; `local`/`remote` are
    /// dotted version strings.
    WineUpdate {
        local: String,
        remote: String,
    },
    Failed {
        reason: String,
    },
}

/// `metadata.*` and `gameConfig.*` answers for the Game Info sheet.
#[derive(Debug)]
pub(crate) enum MetadataUpdate {
    SearchStarted {
        container: String,
        entry_id: String,
    },
    Results {
        container: String,
        entry_id: String,
        results: Vec<MetadataSearchGroupDto>,
    },
    /// A metadata write or cover change; the entry needs a library re-read.
    Applied {
        container: String,
        entry_id: String,
    },
    Matches {
        container: String,
        entry_id: String,
        matches: Vec<crate::bridge::dto::GameDbMatchDto>,
    },
    MatchesFailed { container: String, entry_id: String, reason: String },
    ConfigApplied {
        container: String,
        entry_id: String,
        changes: Vec<ConfigChangeDto>,
        pending_verbs: Vec<String>,
    },
    /// `metadata.sync` finished; the whole bottle needs a re-read. Automatic
    /// runs are silent: their cards were patched through `EntrySynced`.
    Synced {
        container: String,
        matched: u64,
        failed: u64,
        automatic: bool,
    },
    /// `metadata.sync` matched one entry; the payload carries the refreshed
    /// record so the card updates without waiting for the whole bottle
    /// re-read (Swift: `loadMetadata` writes each match into the grid).
    EntrySynced {
        container: String,
        entry: crate::bridge::dto::EntryDto,
    },
    Failed {
        reason: String,
    },
}

/// One `folders.*` mutation. Every reply is the whole folder payload, so the UI
/// never has to merge a local guess.
#[derive(Debug, Clone)]
pub(crate) enum FolderEdit {
    AddRoot(String),
    RemoveRoot(String),
    Assign { path: String, assigned: bool },
    Exclude { path: String, excluded: bool },
    Executable { path: String, executable: Option<String> },
    AutomaticMetadata(bool),
    Visibility(bool),
}

impl FolderEdit {
    fn call(&self, container: &str) -> (&'static str, serde_json::Value) {
        match self {
            Self::AddRoot(path) => (
                "folders.addRoot",
                json!({"container": container, "path": path}),
            ),
            Self::RemoveRoot(path) => (
                "folders.removeRoot",
                json!({"container": container, "path": path}),
            ),
            Self::Assign { path, assigned } => (
                "folders.assign",
                json!({"container": container, "path": path, "assigned": assigned}),
            ),
            Self::Exclude { path, excluded } => (
                "folders.exclude",
                json!({"container": container, "path": path, "excluded": excluded}),
            ),
            Self::Executable { path, executable } => (
                "folders.executable",
                json!({
                    "container": container,
                    "path": path,
                    "executable": executable.clone().map_or(serde_json::Value::Null, Into::into),
                }),
            ),
            Self::AutomaticMetadata(enabled) => (
                "folders.automaticMetadata",
                json!({ "container": container, "enabled": enabled }),
            ),
            Self::Visibility(included) => (
                "folders.visibility",
                json!({ "container": container, "included": included }),
            ),
        }
    }
}

/// Scan lifecycle as the sheet renders it. `status` is always one of the
/// `BridgeJobStore` strings; `stage` is `scanning` from the helper or `paging`
/// while this frontend walks `library.page`.
#[derive(Debug)]
pub(crate) enum ScanUpdate {
    Started {
        job_id: String,
    },
    Progress {
        status: JobStatus,
        stage: Option<String>,
        loaded: Option<usize>,
        total: Option<u64>,
    },
    Completed {
        entries: Vec<EntryDto>,
    },
    Failed {
        status: JobStatus,
        reason: String,
    },
}

/// `bottle.create` job lifecycle. On success the worker also re-reads the
/// catalogue so the new bottle appears without a separate Refresh.
#[derive(Debug)]
pub(crate) enum BottleCreateUpdate {
    Started {
        job_id: String,
    },
    Progress {
        status: JobStatus,
        stage: Option<String>,
    },
    Completed {
        path: String,
        name: String,
        containers: Vec<Container>,
    },
    Failed {
        status: JobStatus,
        reason: String,
    },
}

#[derive(Debug)]
pub(crate) enum BridgeEvent {
    ImportCandidates { request: u64, candidates: Vec<crate::container_import::Candidate> },
    ImportCandidatesFailed { request: u64, reason: String },
    CandidatesImported { request: u64, paths: Vec<String>, count: usize },
    Status(BridgeStatus),
    /// Advertised methods for the current connected helper session.
    Services(Vec<String>),
    /// The container catalogue, emitted once per connected session.
    Containers(Vec<Container>),
    /// The catalogue re-read by an explicit Refresh in the same session: the
    /// runtime session survives, unlike `Containers`.
    ContainersRefreshed(Vec<Container>),
    /// A one-shot host action (reveal, open, …) the helper refused.
    ActionFailed {
        reason: String,
    },
    /// `system.chooseFolder`: the chosen directory, or `None` on cancel.
    FolderChosen {
        path: Option<String>,
    },
    FolderChooseFailed {
        reason: String,
    },
    /// Entries for one container path, in bridge order.
    Entries {
        container: String,
        entries: Vec<EntryDto>,
    },
    /// Per-entry runtime state for the configured container.
    Runtime(RuntimeUpdate),
    /// The helper stopped before launching and needs a clipboard decision.
    ClipboardPrompt(ClipboardPrompt),
    /// Something the runtime refused. Shown on the existing error surface; a
    /// failed poll emits this once per streak and then backs off silently.
    RuntimeFailed {
        reason: String,
    },
    /// `runtime.configure` did not take effect. The bottle is removed from the
    /// configured set so the next Play retries instead of launching against an
    /// unconfigured entry.
    ConfigureFailed {
        container: String,
        reason: String,
    },
    /// A read failed. `container` is `None` for catalogue failures.
    LoadFailed {
        container: Option<String>,
        reason: String,
    },
    /// `.exe` files found under a folder entry, for the in-app picker.
    Candidates {
        candidates: CandidatesDto,
    },
    /// `preferences.read` plus the `preferences.schema` allow-list.
    Preferences {
        values: serde_json::Value,
        schema: PreferencesSchemaDto,
    },
    HostTerminals { result: Result<crate::host::TerminalsDto, String> },
    HostDesktop { install: bool, result: Result<crate::host::DesktopDto, String> },
    DesktopResolved { request: u64, result: Result<crate::desktop_open::ExternalOpen, String>, retryable: bool },
    /// `system.info`: packaged application metadata for the About panel.
    SystemInfo {
        info: SystemInfoDto,
    },
    /// The activity record `entry.rating` returned, not an echo of the request.
    EntryRating {
        container: String,
        entry_id: String,
        activity: ActivityDto,
    },
    /// The `entry.hidden` reply. The record owns the resulting visibility.
    EntryHidden {
        container: String,
        entry_id: String,
        hidden: bool,
    },
    /// A per-entry mutation was rejected; the UI rolls back its optimistic
    /// value and reuses the toast for `reason`.
    EntryFailed {
        mutation: EntryMutation,
        container: String,
        entry_id: String,
        reason: String,
    },
    /// `configuration.schema` plus `configuration.read` for one bottle.
    Configuration {
        container: String,
        capabilities: Vec<String>,
        schema: Vec<ConfigField>,
        values: BTreeMap<String, serde_json::Value>,
    },
    /// One `configuration.set` succeeded; `values` is the helper's readback.
    ConfigurationSaved {
        container: String,
        field: String,
        values: BTreeMap<String, serde_json::Value>,
    },
    /// `field` is `None` when the whole page failed to load.
    ConfigurationFailed {
        container: String,
        field: Option<String>,
        reason: String,
    },
    Folders {
        container: String,
        folders: FoldersDto,
    },
    FoldersFailed {
        container: String,
        reason: String,
    },
    /// `system.chooseFolders`: the native multi-folder picker reply.
    FoldersChosen {
        purpose: String,
        paths: Vec<String>,
    },
    /// `folders.moveRoot`: a scanned root now belongs to another bottle.
    ScanRootMoved {
        source: String,
        target: String,
    },
    Environment {
        container: String,
        values: BTreeMap<String, String>,
    },
    EnvironmentFailed {
        container: String,
        reason: String,
    },
    /// The `programs.list` payload for one container. Also the reply to a
    /// successful pin/block, so it is always authoritative; `settled` names
    /// the mutation whose optimistic edit it retires.
    Programs {
        container: String,
        programs: Vec<ProgramDto>,
        settled: Option<(ProgramMutation, String)>,
    },
    ProgramsFailed {
        container: String,
        reason: String,
    },
    /// A pin/block write was rejected; the UI rolls its optimistic flag back.
    ProgramFailed {
        mutation: ProgramMutation,
        container: String,
        path: String,
        reason: String,
    },
    /// The `processes.list` snapshot for one container.
    Processes {
        container: String,
        processes: Vec<ProcessDto>,
    },
    ProcessesFailed {
        container: String,
        reason: String,
    },
    /// The `processes.kill` reply. `killed: false` means the helper signalled
    /// nothing and the UI rolls its optimistic removal back.
    ProcessKilled {
        container: String,
        pid: i64,
        killed: bool,
    },
    ProcessKillFailed {
        container: String,
        pid: i64,
        reason: String,
    },
    Scan {
        container: String,
        update: ScanUpdate,
    },
    /// One `bottle.create` job. Completes with a refreshed catalogue.
    BottleCreate {
        update: BottleCreateUpdate,
    },
    /// The static winetricks verb catalog (`winetricks.catalog`).
    WinetricksCatalog {
        catalog: CatalogDto,
    },
    WinetricksCatalogFailed {
        reason: String,
    },
    /// The installed set for one container (`winetricks.installed`).
    WinetricksInstalled {
        container: String,
        verbs: Vec<String>,
    },
    WinetricksInstalledFailed {
        container: String,
        reason: String,
    },
    /// One `winetricks.install` job.
    WinetricksInstall {
        container: String,
        update: winetricks::InstallUpdate,
    },
    /// `programs.settings.read` or a successful `programs.settings.set`.
    ProgramSettings {
        settings: ProgramSettingsDto,
    },
    ProgramSettingsFailed {
        container: String,
        executable: String,
        reason: String,
    },
    ProgramHistory {
        container: String,
        executable: String,
        history: HistoryDto,
    },
    ProgramHistoryFailed {
        container: String,
        executable: String,
        reason: String,
    },
    ProgramShortcutCreated {
        container: String,
        executable: String,
        path: String,
    },
    ProgramShortcutFailed {
        container: String,
        executable: String,
        reason: String,
    },
    EntryMoved {
        source_container: String,
        target_container: String,
    },
    EntryMoveFailed {
        source_container: String,
        target_container: String,
        reason: String,
    },
    /// A `programs.run` job failed before the game started. Long-running jobs
    /// are no longer watched after the startup window.
    ProgramRunFailed {
        name: String,
        reason: String,
    },
    /// One `bottle.*` lifecycle action, synchronous or job-backed.
    BottleOperation {
        operation: BottleOperation,
        container: String,
        update: BottleOperationUpdate,
    },
    /// `system.choosePath`: a file, folder or save destination (or `None` on
    /// cancel) with the caller's purpose echoed back.
    PathChosen {
        purpose: String,
        path: Option<String>,
    },
    /// `bottle.tools` accepted a Wine tool launch.
    BottleToolOpened {
        container: String,
        tool: String,
    },
    /// `bottle.diagnostics` / `bottle.exportDiagnostics` / `audio.test`.
    Diagnostics {
        kind: DiagnosticKind,
        container: String,
        update: DiagnosticUpdate,
    },
    /// `metadata.*` / `gameConfig.*`.
    Metadata {
        update: MetadataUpdate,
    },
    /// `setup.status` / `setup.install`.
    Setup {
        update: SetupUpdate,
    },
}

enum Command {
    DiscoverContainers { request: u64, root: Option<String> },
    ImportCandidates { request: u64, candidates: Vec<crate::container_import::Candidate> },
    Retry,
    Shutdown,
    /// Quit the application: the helper applies the stored kill-on-terminate
    /// policy before the session closes.
    ShutdownApplication,
    LoadSystemInfo,
    LoadEntries(String),
    ConfigureRuntime(String),
    Launch {
        container: String,
        entry_id: String,
        /// Launch this executable instead of the entry's default one; the
        /// program Play path uses it (`RuntimeService.launch`'s `executable`).
        executable: Option<String>,
    },
    /// The prompt is carried as received so the second call echoes exactly the
    /// token the helper issued, through the same code path the tests cover.
    DecideClipboard {
        prompt: ClipboardPrompt,
        decision: ClipboardDecision,
    },
    Cancel {
        container: String,
        entry_id: String,
    },
    Stop {
        container: String,
        entry_id: String,
    },
    SetRating {
        container: String,
        entry_id: String,
        rating: Option<i64>,
    },
    SetHidden {
        container: String,
        entry_id: String,
        hidden: bool,
    },
    LoadPreferences,
    ResolveDesktopOpen { request: u64, id: String, path: String },
    #[cfg(target_os = "linux")]
    LoadTerminals,
    #[cfg(target_os = "linux")]
    DesktopIntegration { install: bool },
    SetPreference {
        key: String,
        value: serde_json::Value,
    },
    LoadConfiguration(String),
    SetConfiguration {
        container: String,
        field: String,
        value: serde_json::Value,
    },
    LoadFolders(String),
    EditFolders {
        container: String,
        edit: FolderEdit,
    },
    /// `folders.candidates` for one folder entry.
    LoadCandidates {
        container: String,
        folder: String,
    },
    LoadEnvironment(String),
    SetEnvironment {
        container: String,
        key: String,
        value: Option<String>,
        /// A renamed key: removed before the new one is written.
        replacing: Option<String>,
    },
    LoadPrograms(String),
    SetProgramPinned {
        container: String,
        path: String,
        name: String,
        pinned: bool,
    },
    SetProgramBlocked {
        container: String,
        path: String,
        blocked: bool,
    },
    LoadProcesses(String),
    KillProcess {
        container: String,
        pid: i64,
    },
    KillAllProcesses(String),
    StartScan(String),
    CancelScan,
    /// `bottle.create` with the Wine `WinVersion` raw value and parent directory.
    CreateBottle {
        name: String,
        parent: String,
        windows_version: String,
    },
    LoadWinetricksCatalog,
    LoadInstalledWinetricks(String),
    InstallWinetricks {
        container: String,
        verbs: Vec<String>,
    },
    CancelWinetricks,
    LoadProgramSettings {
        container: String,
        executable: String,
    },
    SaveProgramSettings {
        container: String,
        executable: String,
        patch: serde_json::Value,
    },
    LoadProgramHistory {
        container: String,
        executable: String,
    },
    DeleteProgramHistory {
        container: String,
        executable: String,
        run_id: Option<String>,
    },
    CreateProgramShortcut {
        container: String,
        executable: String,
        destination: String,
    },
    MoveEntry {
        source_container: String,
        entry_id: String,
        target_container: String,
    },
    /// Run a file the user opened or dropped, in one bottle.
    RunProgram {
        container: String,
        path: String,
        name: String,
    },
    /// `system.chooseFolder` starting at the current default location.
    ChooseFolder(String),
    /// `system.chooseFolders` with a purpose echoed back.
    ChooseFolders {
        purpose: String,
        path: String,
    },
    /// `folders.addRoots`: one atomic mutation for several picked folders.
    AddScanRoots {
        container: String,
        paths: Vec<String>,
    },
    /// `folders.moveRoot`: move a scanned root to another container.
    MoveScanRoot {
        source: String,
        root: String,
        target: String,
    },
    /// `bottle.rename` / `bottle.remove` / `bottle.move` / `bottle.duplicate`
    /// / `bottle.export` / `bottle.repair` / `bottle.cleanCache`.
    BottleOperation {
        operation: BottleOperation,
        container: String,
        name: Option<String>,
        destination: Option<String>,
        delete_files: bool,
    },
    /// `bottle.tools` (winecfg, regedit, control, terminal).
    OpenBottleTool {
        container: String,
        tool: String,
    },
    /// `system.choosePath` with the purpose echoed back in `PathChosen`.
    ChoosePath {
        purpose: String,
        mode: String,
        path: Option<String>,
        name: Option<String>,
        extensions: Vec<String>,
    },
    /// `bottle.diagnostics`: collect a stability report.
    LoadDiagnostics {
        container: String,
    },
    /// `bottle.exportDiagnostics`: write the stability report to a file.
    ExportDiagnostics {
        container: String,
        destination: String,
    },
    /// `audio.test`: run the Wine audio stack probe, optionally with a beep.
    TestAudio {
        container: String,
        beep: bool,
    },
    /// `bottle.checks`: run the curated troubleshooting checks.
    RunBottleChecks {
        container: String,
    },
    /// `metadata.search`: a job because providers talk to the network.
    SearchMetadata {
        container: String,
        entry_id: String,
        query: String,
        sources: Vec<String>,
    },
    ApplyMetadata {
        container: String,
        entry_id: String,
        metadata: serde_json::Value,
    },
    ClearMetadata {
        container: String,
        entry_id: String,
    },
    ImportMetadataCover {
        container: String,
        entry_id: String,
        path: String,
    },
    ResetMetadataCover {
        container: String,
        entry_id: String,
    },
    /// `metadata.sync`: automatic matching for folder entries. `automatic`
    /// restricts the job to entries the folder library still marks pending
    /// and honours its automatic-metadata switch; manual sync matches every
    /// folder entry that has no metadata yet.
    SyncMetadata {
        container: String,
        sources: Vec<String>,
        automatic: bool,
    },
    /// `setup.status` at connection time.
    LoadSetupStatus,
    /// `setup.checkUpdate`: is a newer WhiskyWine published?
    CheckWineUpdate,
    /// `setup.install`: download and install the Wine runtime.
    InstallSetup,
    /// `setup.installRosetta`: install Rosetta 2 on Apple Silicon.
    InstallRosetta,
    MatchGameConfig {
        container: String,
        entry_id: String,
    },
    ApplyGameConfig {
        container: String,
        entry_id: String,
        game_id: String,
        variant_id: String,
    },
    /// Window activation: polling pauses while the app is in the background.
    SetActive(bool),
    /// Re-read the bottle catalogue and drop the cached entries, as the
    /// SwiftUI library's Refresh reloads its bottles.
    ReloadLibrary,
    /// `system.reveal` (Finder selection) or `system.open`. `path` defaults to
    /// the container itself on the helper side.
    System {
        container: String,
        path: Option<String>,
        reveal: bool,
    },
}

enum Wake {
    Retry,
    Timeout,
    Stop,
}

/// Owns the supervisor thread. Dropping it asks the worker to close the helper
/// and exit; it is not joined because a helper call may still be in flight and
/// join would block the UI thread.
pub(crate) struct BridgeSupervisor {
    commands: CommandSender<Command>,
    _thread: Option<std::thread::JoinHandle<()>>,
}

impl BridgeSupervisor {
    pub(crate) fn start() -> (Self, smol::channel::Receiver<BridgeEvent>) {
        let (events, receiver) = smol::channel::unbounded();
        let (commands, command_rx) = mpsc::channel();
        let worker_events = events.clone();
        let thread = std::thread::Builder::new()
            .name("whisky-bridge".into())
            .spawn(move || run(worker_events, command_rx))
            .map_err(|error| {
                let _ = events.send_blocking(BridgeEvent::Status(BridgeStatus::Failed {
                    reason: format!("Cannot start the bridge supervisor thread: {error}"),
                    retryable: false,
                }));
                error
            })
            .ok();
        (
            Self {
                commands,
                _thread: thread,
            },
            receiver,
        )
    }

    /// Ask the worker to discard the current session and connect again now.
    pub(crate) fn retry(&self) {
        let _ = self.commands.send(Command::Retry);
    }

    /// Queue a read-only library request. The worker coalesces nothing: callers
    /// only send this on an explicit bottle switch or retry, never per frame.
    pub(crate) fn load_entries(&self, container: &str) {
        let _ = self
            .commands
            .send(Command::LoadEntries(container.to_owned()));
    }

    /// Point the runtime at one container. The reply is a resync: the UI
    /// replaces its table instead of merging.
    pub(crate) fn configure_runtime(&self, container: &str) {
        let _ = self
            .commands
            .send(Command::ConfigureRuntime(container.to_owned()));
    }

    pub(crate) fn launch(&self, container: &str, entry_id: &str, executable: Option<&str>) {
        let _ = self.commands.send(Command::Launch {
            container: container.to_owned(),
            entry_id: entry_id.to_owned(),
            executable: executable.map(str::to_owned),
        });
    }

    /// Answer the clipboard prompt. The second call carries the one-use token.
    pub(crate) fn resolve_clipboard(&self, prompt: ClipboardPrompt, decision: ClipboardDecision) {
        let _ = self
            .commands
            .send(Command::DecideClipboard { prompt, decision });
    }

    pub(crate) fn cancel(&self, container: &str, entry_id: &str) {
        let _ = self.commands.send(Command::Cancel {
            container: container.to_owned(),
            entry_id: entry_id.to_owned(),
        });
    }

    pub(crate) fn stop(&self, container: &str, entry_id: &str) {
        let _ = self.commands.send(Command::Stop {
            container: container.to_owned(),
            entry_id: entry_id.to_owned(),
        });
    }

    /// `entry.rating` with `null` clearing the rating.
    pub(crate) fn set_rating(&self, container: &str, entry_id: &str, rating: Option<i64>) {
        let _ = self.commands.send(Command::SetRating {
            container: container.to_owned(),
            entry_id: entry_id.to_owned(),
            rating,
        });
    }

    /// `entry.hidden`; the reply carries the record the UI stores.
    pub(crate) fn set_hidden(&self, container: &str, entry_id: &str, hidden: bool) {
        let _ = self.commands.send(Command::SetHidden {
            container: container.to_owned(),
            entry_id: entry_id.to_owned(),
            hidden,
        });
    }

    /// Read every preference once per connected session.
    pub(crate) fn resolve_desktop_open(&self, request: u64, id: &str, path: &str) {
        let _ = self.commands.send(Command::ResolveDesktopOpen { request, id: id.into(), path: path.into() });
    }

    #[cfg(target_os = "linux")]
    pub(crate) fn desktop_integration(&self, install: bool) {
        let _ = self.commands.send(Command::DesktopIntegration { install });
    }

    #[cfg(target_os = "linux")]
    pub(crate) fn load_terminals(&self) {
        let _ = self.commands.send(Command::LoadTerminals);
    }

    pub(crate) fn load_preferences(&self) {
        let _ = self.commands.send(Command::LoadPreferences);
    }

    /// Write one preference. The UI debounces this; the worker just executes.
    pub(crate) fn set_preference(&self, key: &str, value: serde_json::Value) {
        let _ = self.commands.send(Command::SetPreference {
            key: key.to_owned(),
            value,
        });
    }

    /// Read the packaged app version once per connected session.
    pub(crate) fn load_system_info(&self) {
        let _ = self.commands.send(Command::LoadSystemInfo);
    }

    /// Quit with the stored exit policy. The worker emits `Stopped` when the
    /// session is closed, which is when the UI may call `cx.quit()`.
    pub(crate) fn shutdown_application(&self) {
        let _ = self.commands.send(Command::ShutdownApplication);
    }

    /// `configuration.schema` + `configuration.read` for one bottle.
    pub(crate) fn load_configuration(&self, container: &str) {
        let _ = self
            .commands
            .send(Command::LoadConfiguration(container.to_owned()));
    }

    /// `configuration.set` for one field; the reply is a whole-file readback.
    pub(crate) fn set_configuration(
        &self,
        container: &str,
        field: &str,
        value: serde_json::Value,
    ) {
        let _ = self.commands.send(Command::SetConfiguration {
            container: container.to_owned(),
            field: field.to_owned(),
            value,
        });
    }

    pub(crate) fn load_folders(&self, container: &str) {
        let _ = self
            .commands
            .send(Command::LoadFolders(container.to_owned()));
    }

    pub(crate) fn edit_folders(&self, container: &str, edit: FolderEdit) {
        let _ = self.commands.send(Command::EditFolders {
            container: container.to_owned(),
            edit,
        });
    }

    /// `system.chooseFolders`: multi-select directory picker for scan roots.
    pub(crate) fn choose_folders(&self, purpose: &str, path: &str) {
        let _ = self.commands.send(Command::ChooseFolders {
            purpose: purpose.to_owned(),
            path: path.to_owned(),
        });
    }

    /// `folders.addRoots`: adds every selected directory in one write.
    pub(crate) fn add_scan_roots(&self, container: &str, paths: &[String]) {
        let _ = self.commands.send(Command::AddScanRoots {
            container: container.to_owned(),
            paths: paths.to_vec(),
        });
    }

    /// `folders.moveRoot`: reassign a scanned root to another bottle.
    pub(crate) fn move_scan_root(&self, source: &str, root: &str, target: &str) {
        let _ = self.commands.send(Command::MoveScanRoot {
            source: source.to_owned(),
            root: root.to_owned(),
            target: target.to_owned(),
        });
    }

    pub(crate) fn load_candidates(&self, container: &str, folder: &str) {
        let _ = self.commands.send(Command::LoadCandidates {
            container: container.to_owned(),
            folder: folder.to_owned(),
        });
    }

    pub(crate) fn load_environment(&self, container: &str) {
        let _ = self
            .commands
            .send(Command::LoadEnvironment(container.to_owned()));
    }

    /// `environment.set`. `value: None` removes `key`; `replacing` names an old
    /// key that is removed first, because the bridge has no rename call.
    pub(crate) fn set_environment(
        &self,
        container: &str,
        key: &str,
        value: Option<&str>,
        replacing: Option<&str>,
    ) {
        let _ = self.commands.send(Command::SetEnvironment {
            container: container.to_owned(),
            key: key.to_owned(),
            value: value.map(str::to_owned),
            replacing: replacing.map(str::to_owned),
        });
    }

    pub(crate) fn start_scan(&self, container: &str) {
        let _ = self
            .commands
            .send(Command::StartScan(container.to_owned()));
    }

    pub(crate) fn cancel_scan(&self) {
        let _ = self.commands.send(Command::CancelScan);
    }

    /// `bottle.create`. The reply is a job handle; progress and the refreshed
    /// catalogue arrive as `BridgeEvent::BottleCreate`.
    pub(crate) fn create_bottle(&self, name: &str, parent: &str, windows_version: &str) {
        let _ = self.commands.send(Command::CreateBottle {
            name: name.to_owned(),
            parent: parent.to_owned(),
            windows_version: windows_version.to_owned(),
        });
    }

    /// `winetricks.catalog`: the bundled verb index, independent of a bottle.
    pub(crate) fn load_winetricks_catalog(&self) {
        let _ = self.commands.send(Command::LoadWinetricksCatalog);
    }

    /// `winetricks.installed` for one bottle.
    pub(crate) fn load_installed_winetricks(&self, container: &str) {
        let _ = self
            .commands
            .send(Command::LoadInstalledWinetricks(container.to_owned()));
    }

    /// `winetricks.install`: a `BridgeJobStore` job. Progress, the result and
    /// the authoritative post-install verb set arrive as `WinetricksInstall`.
    pub(crate) fn install_winetricks(&self, container: &str, verbs: &[String]) {
        let _ = self.commands.send(Command::InstallWinetricks {
            container: container.to_owned(),
            verbs: verbs.to_vec(),
        });
    }

    pub(crate) fn cancel_winetricks(&self) {
        let _ = self.commands.send(Command::CancelWinetricks);
    }

    /// `programs.settings.read` for one executable.
    pub(crate) fn load_program_settings(&self, container: &str, executable: &str) {
        let _ = self.commands.send(Command::LoadProgramSettings {
            container: container.to_owned(),
            executable: executable.to_owned(),
        });
    }

    /// `programs.settings.set`; the reply is the same shape as a read.
    pub(crate) fn save_program_settings(
        &self,
        container: &str,
        executable: &str,
        patch: serde_json::Value,
    ) {
        let _ = self.commands.send(Command::SaveProgramSettings {
            container: container.to_owned(),
            executable: executable.to_owned(),
            patch,
        });
    }

    pub(crate) fn load_program_history(&self, container: &str, executable: &str) {
        let _ = self.commands.send(Command::LoadProgramHistory {
            container: container.to_owned(),
            executable: executable.to_owned(),
        });
    }

    pub(crate) fn delete_program_history(
        &self,
        container: &str,
        executable: &str,
        run_id: Option<&str>,
    ) {
        let _ = self.commands.send(Command::DeleteProgramHistory {
            container: container.to_owned(),
            executable: executable.to_owned(),
            run_id: run_id.map(str::to_owned),
        });
    }

    pub(crate) fn create_program_shortcut(
        &self,
        container: &str,
        executable: &str,
        destination: &str,
    ) {
        let _ = self.commands.send(Command::CreateProgramShortcut {
            container: container.to_owned(),
            executable: executable.to_owned(),
            destination: destination.to_owned(),
        });
    }

    /// `entry.move`: re-home a pinned or folder entry in another bottle.
    pub(crate) fn move_entry(
        &self,
        source_container: &str,
        entry_id: &str,
        target_container: &str,
    ) {
        let _ = self.commands.send(Command::MoveEntry {
            source_container: source_container.to_owned(),
            entry_id: entry_id.to_owned(),
            target_container: target_container.to_owned(),
        });
    }

    /// Run an opened or dropped Windows file in one bottle.
    pub(crate) fn run_program(&self, container: &str, path: &str, name: &str) {
        let _ = self.commands.send(Command::RunProgram {
            container: container.to_owned(),
            path: path.to_owned(),
            name: name.to_owned(),
        });
    }

    /// `programs.list` for one bottle. The pin/block mutations reply with the
    /// same payload, so one event type carries all three.
    pub(crate) fn load_programs(&self, container: &str) {
        let _ = self
            .commands
            .send(Command::LoadPrograms(container.to_owned()));
    }

    /// `programs.pin`; the reply is the refreshed program list.
    pub(crate) fn set_program_pinned(&self, container: &str, path: &str, name: &str, pinned: bool) {
        let _ = self.commands.send(Command::SetProgramPinned {
            container: container.to_owned(),
            path: path.to_owned(),
            name: name.to_owned(),
            pinned,
        });
    }

    /// `programs.block`; the reply is the refreshed program list.
    pub(crate) fn set_program_blocked(&self, container: &str, path: &str, blocked: bool) {
        let _ = self.commands.send(Command::SetProgramBlocked {
            container: container.to_owned(),
            path: path.to_owned(),
            blocked,
        });
    }

    /// `processes.list` for one bottle. The Processes page polls this.
    pub(crate) fn load_processes(&self, container: &str) {
        let _ = self
            .commands
            .send(Command::LoadProcesses(container.to_owned()));
    }

    /// `processes.kill` with the default graceful semantics.
    pub(crate) fn kill_process(&self, container: &str, pid: i64) {
        let _ = self.commands.send(Command::KillProcess {
            container: container.to_owned(),
            pid,
        });
    }

    /// `processes.killAll`: terminates all processes in the container.
    pub(crate) fn kill_all_processes(&self, container: &str) {
        let _ = self.commands.send(Command::KillAllProcesses(container.to_owned()));
    }

    pub(crate) fn set_active(&self, active: bool) {
        let _ = self.commands.send(Command::SetActive(active));
    }

    /// Re-read `workspace.containers`; the reply is `ContainersRefreshed`.
    pub(crate) fn reload_library(&self) {
        let _ = self.commands.send(Command::ReloadLibrary);
    }

    /// Select `path` in Finder (`system.reveal`).
    pub(crate) fn reveal(&self, container: &str, path: &str) {
        let _ = self.commands.send(Command::System {
            container: container.to_owned(),
            path: Some(path.to_owned()),
            reveal: true,
        });
    }

    /// Open `path` with its default application (`system.open`).
    pub(crate) fn open(&self, container: &str, path: &str) {
        let _ = self.commands.send(Command::System {
            container: container.to_owned(),
            path: Some(path.to_owned()),
            reveal: false,
        });
    }

    /// Native directory picker (`system.chooseFolder`).
    pub(crate) fn choose_folder(&self, path: &str) {
        let _ = self.commands.send(Command::ChooseFolder(path.to_owned()));
    }

    /// One bottle lifecycle mutation. The event carries the helper's own
    /// result; a job-backed operation reports `Started` first.
    pub(crate) fn bottle_operation(
        &self,
        operation: BottleOperation,
        container: &str,
        name: Option<&str>,
        destination: Option<&str>,
        delete_files: bool,
    ) {
        let _ = self.commands.send(Command::BottleOperation {
            operation,
            container: container.to_owned(),
            name: name.map(str::to_owned),
            destination: destination.map(str::to_owned),
            delete_files,
        });
    }

    /// `bottle.tools`: winecfg, regedit, control or a terminal session.
    pub(crate) fn open_bottle_tool(&self, container: &str, tool: &str) {
        let _ = self.commands.send(Command::OpenBottleTool {
            container: container.to_owned(),
            tool: tool.to_owned(),
        });
    }

    /// `bottle.diagnostics`: a job whose report arrives as `Diagnostics`.
    pub(crate) fn load_diagnostics(&self, container: &str) {
        let _ = self.commands.send(Command::LoadDiagnostics {
            container: container.to_owned(),
        });
    }

    /// `bottle.exportDiagnostics`: writes the report to `destination`.
    pub(crate) fn export_diagnostics(&self, container: &str, destination: &str) {
        let _ = self.commands.send(Command::ExportDiagnostics {
            container: container.to_owned(),
            destination: destination.to_owned(),
        });
    }

    /// `bottle.checks`: curated preflight checks for the troubleshooting sheet.
    pub(crate) fn run_bottle_checks(&self, container: &str) {
        let _ = self.commands.send(Command::RunBottleChecks {
            container: container.to_owned(),
        });
    }

    /// `audio.test`: the Wine stack probe; `beep` plays the 440 Hz tone.
    pub(crate) fn test_audio(&self, container: &str, beep: bool) {
        let _ = self.commands.send(Command::TestAudio {
            container: container.to_owned(),
            beep,
        });
    }

    /// `metadata.search`: network providers, answered by a job.
    pub(crate) fn search_metadata(
        &self,
        container: &str,
        entry_id: &str,
        query: &str,
        sources: Vec<String>,
    ) {
        let _ = self.commands.send(Command::SearchMetadata {
            container: container.to_owned(),
            entry_id: entry_id.to_owned(),
            query: query.to_owned(),
            sources,
        });
    }

    /// Store one provider snapshot as the entry's metadata.
    pub(crate) fn apply_metadata(
        &self,
        container: &str,
        entry_id: &str,
        metadata: serde_json::Value,
    ) {
        let _ = self.commands.send(Command::ApplyMetadata {
            container: container.to_owned(),
            entry_id: entry_id.to_owned(),
            metadata,
        });
    }

    pub(crate) fn clear_metadata(&self, container: &str, entry_id: &str) {
        let _ = self.commands.send(Command::ClearMetadata {
            container: container.to_owned(),
            entry_id: entry_id.to_owned(),
        });
    }

    pub(crate) fn import_metadata_cover(&self, container: &str, entry_id: &str, path: &str) {
        let _ = self.commands.send(Command::ImportMetadataCover {
            container: container.to_owned(),
            entry_id: entry_id.to_owned(),
            path: path.to_owned(),
        });
    }

    pub(crate) fn reset_metadata_cover(&self, container: &str, entry_id: &str) {
        let _ = self.commands.send(Command::ResetMetadataCover {
            container: container.to_owned(),
            entry_id: entry_id.to_owned(),
        });
    }

    pub(crate) fn load_setup_status(&self) {
        let _ = self.commands.send(Command::LoadSetupStatus);
    }

    /// `setup.install`: a job that downloads and installs the Wine runtime.
    pub(crate) fn install_setup(&self) {
        let _ = self.commands.send(Command::InstallSetup);
    }

    /// `setup.installRosetta`: installs Rosetta 2 on Apple Silicon.
    pub(crate) fn install_rosetta(&self) {
        let _ = self.commands.send(Command::InstallRosetta);
    }

    /// `setup.checkUpdate`: compares the installed runtime against the
    /// published manifest. Silent when the shared update-check default is off.
    pub(crate) fn check_wine_update(&self) {
        let _ = self.commands.send(Command::CheckWineUpdate);
    }

    /// `metadata.sync`: automatic matching for folder entries.
    pub(crate) fn sync_metadata(&self, container: &str, sources: Vec<String>, automatic: bool) {
        let _ = self.commands.send(Command::SyncMetadata {
            container: container.to_owned(),
            sources,
            automatic,
        });
    }

    /// `gameConfig.match`: the local database, so it is answered directly.
    pub(crate) fn match_game_config(&self, container: &str, entry_id: &str) {
        let _ = self.commands.send(Command::MatchGameConfig {
            container: container.to_owned(),
            entry_id: entry_id.to_owned(),
        });
    }

    pub(crate) fn apply_game_config(
        &self,
        container: &str,
        entry_id: &str,
        game_id: &str,
        variant_id: &str,
    ) {
        let _ = self.commands.send(Command::ApplyGameConfig {
            container: container.to_owned(),
            entry_id: entry_id.to_owned(),
            game_id: game_id.to_owned(),
            variant_id: variant_id.to_owned(),
        });
    }

    pub(crate) fn discover_containers(&self, request: u64, root: Option<String>) {
        let _ = self.commands.send(Command::DiscoverContainers { request, root });
    }
    pub(crate) fn import_candidates(&self, request: u64, candidates: Vec<crate::container_import::Candidate>) {
        let _ = self.commands.send(Command::ImportCandidates { request, candidates });
    }

    /// `system.choosePath`: file, folder or save panels. `purpose` comes back
    /// on `BridgeEvent::PathChosen`.
    pub(crate) fn choose_path(
        &self,
        purpose: &str,
        mode: &str,
        path: Option<&str>,
        name: Option<&str>,
        extensions: &[&str],
    ) {
        let _ = self.commands.send(Command::ChoosePath {
            purpose: purpose.to_owned(),
            mode: mode.to_owned(),
            path: path.map(str::to_owned),
            name: name.map(str::to_owned),
            extensions: extensions.iter().map(|value| (*value).to_owned()).collect(),
        });
    }
}

impl Drop for BridgeSupervisor {
    fn drop(&mut self) {
        let _ = self.commands.send(Command::Shutdown);
    }
}

fn run(events: smol::channel::Sender<BridgeEvent>, commands: CommandReceiver<Command>) {
    let mut attempt = 0_u32;
    let mut foreground = true;
    'session: loop {
        emit(&events, BridgeStatus::Locating);
        let helper = match locate_helper() {
            Ok(helper) => helper,
            Err(reason) => {
                if fail_and_wait(&events, &commands, &mut attempt, reason, true, &mut foreground) {
                    emit(&events, BridgeStatus::Stopped);
                    return;
                }
                continue;
            }
        };
        emit(&events, BridgeStatus::Starting);
        let helper_args = helper_arguments();
        let mut client = match Client::spawn(&helper, &helper_args, CALL_TIMEOUT) {
            Ok(client) => client,
            Err(error) => {
                let reason = format!("Cannot start the helper at {}: {error}", helper.display());
                if fail_and_wait(&events, &commands, &mut attempt, reason, true, &mut foreground) {
                    emit(&events, BridgeStatus::Stopped);
                    return;
                }
                continue;
            }
        };
        let describe = DescribeResponse::from_capabilities(client.capabilities());
        let missing = describe.missing_required_methods();
        if !missing.is_empty() {
            let reason = format!(
                "The helper does not advertise required method(s): {}",
                missing.join(", ")
            );
            client.close();
            if fail_and_wait(&events, &commands, &mut attempt, reason, false, &mut foreground) {
                emit(&events, BridgeStatus::Stopped);
                return;
            }
            continue;
        }
        // A session without a catalogue cannot serve the UI, so the handshake
        // is only reported as connected after the first read succeeds.
        let containers = match fetch_containers(&mut client) {
            Ok(containers) => containers,
            Err(failure) => {
                let reason = failure.into_message();
                client.close();
                if fail_and_wait(&events, &commands, &mut attempt, reason, true, &mut foreground) {
                    emit(&events, BridgeStatus::Stopped);
                    return;
                }
                continue;
            }
        };
        attempt = 0;
        emit(
            &events,
            BridgeStatus::Connected {
                helper: helper.display().to_string(),
                // The helper exposes no application version yet; the protocol
                // version is the only version in `bridge.describe`.
                version: format!("protocol {}", describe.protocol_version),
                methods: describe.methods.len(),
            },
        );
        emit_event(&events, BridgeEvent::Services(describe.methods.clone()));
        log_container_names(&containers);
        emit_event(&events, BridgeEvent::Containers(containers));
        fetch_setup_status(&mut client, &events);
        if describe.methods.iter().any(|method| method == "system.terminals") {
            fetch_terminals(&mut client, &events);
        }
        if describe.methods.iter().any(|method| method == "system.desktop.status") {
            fetch_desktop(&mut client, &events, false);
        }
        // One bottle at a time is enough: a request for another container
        // invalidates the cached snapshot, matching "invalidate on switch".
        let mut cache: Option<(String, EntryList)> = None;
        // The configured runtime, if any. Dropped on reconfigure; kept across a
        // poll failure so the last known states stay on screen.
        let mut live: Option<LiveRuntime> = None;
        // At most one scan job. Kept as state, not as a blocking loop, so a
        // cancel command still reaches the worker between polls.
        let mut scan: Option<LiveScan> = None;
        // At most one create-bottle job; independent of the scan job so a
        // folder scan does not block creating a bottle (and vice versa).
        let mut create: Option<LiveCreate> = None;
        // At most one winetricks install job.
        let mut tricks: Option<LiveWinetricks> = None;
        // At most one WhiskyWine update-check job.
        let mut update_check: Option<LiveUpdateCheck> = None;
        // At most one bottle lifecycle job (move, duplicate, export, …).
        let mut bottle_op: Option<LiveBottleOperation> = None;
        // At most one diagnostics or audio job.
        let mut diagnostic: Option<LiveDiagnostic> = None;
        // At most one metadata search job.
        let mut metadata_search: Option<LiveMetadataSearch> = None;
        // At most one automatic metadata sync job.
        let mut metadata_sync: Option<LiveMetadataSync> = None;
        // At most one Wine runtime installation job.
        let mut setup: Option<LiveSetup> = None;
        // The one opened file being watched for startup failures.
        let mut program_run: Option<LiveProgramRun> = None;
        loop {
            // A live session blocks only until its next poll is due. Anything
            // else parks, and a command still wakes the worker immediately.
            let now = Instant::now();
            let mut wait_for = PARK;
            if foreground && let Some(live) = &live {
                wait_for = wait_for.min(live.due.saturating_duration_since(now));
            }
            if let Some(scan) = &scan {
                wait_for = wait_for.min(scan.due.saturating_duration_since(now));
            }
            if let Some(create) = &create {
                wait_for = wait_for.min(create.due.saturating_duration_since(now));
            }
            if let Some(tricks) = &tricks {
                wait_for = wait_for.min(tricks.due.saturating_duration_since(now));
            }
            if let Some(run) = &program_run {
                wait_for = wait_for.min(run.due.saturating_duration_since(now));
            }
            if let Some(operation) = &bottle_op {
                wait_for = wait_for.min(operation.due.saturating_duration_since(now));
            }
            if let Some(job) = &diagnostic {
                wait_for = wait_for.min(job.due.saturating_duration_since(now));
            }
            if let Some(job) = &metadata_search {
                wait_for = wait_for.min(job.due.saturating_duration_since(now));
            }
            if let Some(job) = &metadata_sync {
                wait_for = wait_for.min(job.due.saturating_duration_since(now));
            }
            if let Some(job) = &setup {
                wait_for = wait_for.min(job.due.saturating_duration_since(now));
            }
            let command = match commands.recv_timeout(wait_for) {
                Ok(command) => Some(command),
                Err(RecvTimeoutError::Timeout) => None,
                Err(RecvTimeoutError::Disconnected) => Some(Command::Shutdown),
            };
            let mut reconnect: Option<String> = None;
            match command {
                // The poll timer fired.
                None => {
                    if let Some(session) = live.as_mut() {
                        match poll_runtime(&mut client, session, &events) {
                            Ok(()) => {}
                            // A poll failure is not a session failure: keep the
                            // last known states, back off, and try again.
                            Err(CallFailure::Remote(reason)) => {
                                session.failures = session.failures.saturating_add(1);
                                session.due =
                                    Instant::now() + backoff_delay(session.failures - 1);
                                if session.failures == 1 {
                                    emit_event(&events, BridgeEvent::RuntimeFailed { reason });
                                }
                            }
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                    if let Some(active) = scan.as_mut() {
                        let container = active.container.clone();
                        match poll_scan(&mut client, active, &events) {
                            Ok(None) => {}
                            Ok(Some(ScanTerminal::Completed {
                                snapshot_id,
                                total,
                            })) => {
                                match collect_pages(&mut client, &container, &snapshot_id, total, &events)
                                {
                                    Ok(entries) => {
                                        cache = Some((container.clone(), entries.clone()));
                                        let count = entries.len();
                                        emit_event(
                                            &events,
                                            BridgeEvent::Scan {
                                                container: container.clone(),
                                                update: ScanUpdate::Completed { entries },
                                            },
                                        );
                                        eprintln!(
                                            "whisky-bridge: scan of {container} loaded {count} entries"
                                        );
                                        scan = None;
                                    }
                                    Err(CallFailure::Remote(reason)) => {
                                        emit_event(
                                            &events,
                                            BridgeEvent::Scan {
                                                container,
                                                update: ScanUpdate::Failed {
                                                    status: JobStatus::Failed,
                                                    reason,
                                                },
                                            },
                                        );
                                        scan = None;
                                    }
                                    Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                                }
                            }
                            Ok(Some(ScanTerminal::Failed { status, reason })) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Scan {
                                        container,
                                        update: ScanUpdate::Failed { status, reason },
                                    },
                                );
                                scan = None;
                            }
                            Err(CallFailure::Remote(reason)) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Scan {
                                        container,
                                        update: ScanUpdate::Failed {
                                            status: JobStatus::Failed,
                                            reason,
                                        },
                                    },
                                );
                                scan = None;
                            }
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                    if let Some(active) = create.as_mut() {
                        match poll_create(&mut client, active, &events) {
                            Ok(None) => {}
                            Ok(Some(CreateTerminal::Completed { path, name })) => {
                                match fetch_containers(&mut client) {
                                    Ok(containers) => {
                                        cache = None;
                                        log_container_names(&containers);
                                        emit_event(
                                            &events,
                                            BridgeEvent::BottleCreate {
                                                update: BottleCreateUpdate::Completed {
                                                    path,
                                                    name,
                                                    containers,
                                                },
                                            },
                                        );
                                        create = None;
                                    }
                                    Err(CallFailure::Remote(reason)) => {
                                        emit_event(
                                            &events,
                                            BridgeEvent::BottleCreate {
                                                update: BottleCreateUpdate::Failed {
                                                    status: JobStatus::Failed,
                                                    reason: format!(
                                                        "Bottle created but catalogue refresh failed: {reason}"
                                                    ),
                                                },
                                            },
                                        );
                                        create = None;
                                    }
                                    Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                                }
                            }
                            Ok(Some(CreateTerminal::Failed { status, reason })) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::BottleCreate {
                                        update: BottleCreateUpdate::Failed { status, reason },
                                    },
                                );
                                create = None;
                            }
                            Err(CallFailure::Remote(reason)) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::BottleCreate {
                                        update: BottleCreateUpdate::Failed {
                                            status: JobStatus::Failed,
                                            reason,
                                        },
                                    },
                                );
                                create = None;
                            }
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                    if let Some(active) = tricks.as_mut() {
                        match poll_winetricks(&mut client, active, &events) {
                            Ok(None) => {}
                            Ok(Some(WinetricksTerminal::Completed(result))) => {
                                let current = match load_installed_winetricks(
                                    &mut client,
                                    &active.container,
                                ) {
                                    Ok(current) => current.verbs,
                                    Err(_) => result.installed.clone(),
                                };
                                emit_event(
                                    &events,
                                    BridgeEvent::WinetricksInstall {
                                        container: active.container.clone(),
                                        update: winetricks::InstallUpdate::Completed {
                                            installed: current,
                                            succeeded: result.succeeded,
                                            failed: result.failed,
                                        },
                                    },
                                );
                                tricks = None;
                            }
                            Ok(Some(WinetricksTerminal::Failed { status, reason })) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::WinetricksInstall {
                                        container: active.container.clone(),
                                        update: winetricks::InstallUpdate::Failed { status, reason },
                                    },
                                );
                                tricks = None;
                            }
                            Err(CallFailure::Remote(reason)) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::WinetricksInstall {
                                        container: active.container.clone(),
                                        update: winetricks::InstallUpdate::Failed {
                                            status: JobStatus::Failed,
                                            reason,
                                        },
                                    },
                                );
                                tricks = None;
                            }
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                    if let Some(active) = program_run.as_mut() {
                        match poll_program_run(&mut client, active) {
                            Ok(ProgramRunPoll::Pending) => {}
                            Ok(ProgramRunPoll::Finished) => program_run = None,
                            Ok(ProgramRunPoll::Failed(reason)) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::ProgramRunFailed {
                                        name: active.name.clone(),
                                        reason,
                                    },
                                );
                                program_run = None;
                            }
                            Err(CallFailure::Remote(reason)) => {
                                eprintln!("whisky-bridge: programs.run poll failed: {reason}");
                                program_run = None;
                            }
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                    if let Some(active) = bottle_op.as_mut() {
                        match poll_bottle_operation(&mut client, active) {
                            Ok(None) => {}
                            Ok(Some(BottleOperationTerminal::Completed { path, name })) => {
                                let operation = active.operation;
                                let container = active.container.clone();
                                emit_event(
                                    &events,
                                    BridgeEvent::BottleOperation {
                                        operation,
                                        container,
                                        update: BottleOperationUpdate::Completed {
                                            path,
                                            name,
                                        },
                                    },
                                );
                                bottle_op = None;
                                if operation.refreshes_catalogue() {
                                    cache = None;
                                    match fetch_containers(&mut client) {
                                        Ok(containers) => {
                                            log_container_names(&containers);
                                            emit_event(
                                                &events,
                                                BridgeEvent::ContainersRefreshed(containers),
                                            );
                                        }
                                        Err(CallFailure::Remote(reason)) => {
                                            emit_event(&events, BridgeEvent::ActionFailed { reason });
                                        }
                                        Err(CallFailure::Session(reason)) => {
                                            reconnect = Some(reason)
                                        }
                                    }
                                }
                            }
                            Ok(Some(BottleOperationTerminal::Failed { reason })) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::BottleOperation {
                                        operation: active.operation,
                                        container: active.container.clone(),
                                        update: BottleOperationUpdate::Failed { reason },
                                    },
                                );
                                bottle_op = None;
                            }
                            Err(CallFailure::Remote(reason)) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::BottleOperation {
                                        operation: active.operation,
                                        container: active.container.clone(),
                                        update: BottleOperationUpdate::Failed { reason },
                                    },
                                );
                                bottle_op = None;
                            }
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                    if let Some(active) = diagnostic.as_mut() {
                        match poll_diagnostic(&mut client, active) {
                            Ok(None) => {}
                            Ok(Some(terminal)) => {
                                let kind = active.kind;
                                let container = active.container.clone();
                                let update = match terminal {
                                    DiagnosticTerminal::Report(report) => {
                                        DiagnosticUpdate::Report { report }
                                    }
                                    DiagnosticTerminal::Exported(path) => {
                                        DiagnosticUpdate::Exported { path }
                                    }
                                    DiagnosticTerminal::Audio(result) => {
                                        DiagnosticUpdate::Audio { result }
                                    }
                                    DiagnosticTerminal::Checks(results) => {
                                        DiagnosticUpdate::Checks { results }
                                    }
                                    DiagnosticTerminal::Failed(reason) => {
                                        DiagnosticUpdate::Failed { reason }
                                    }
                                };
                                emit_event(
                                    &events,
                                    BridgeEvent::Diagnostics {
                                        kind,
                                        container,
                                        update,
                                    },
                                );
                                diagnostic = None;
                            }
                            Err(CallFailure::Remote(reason)) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Diagnostics {
                                        kind: active.kind,
                                        container: active.container.clone(),
                                        update: DiagnosticUpdate::Failed { reason },
                                    },
                                );
                                diagnostic = None;
                            }
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                    if let Some(active) = setup.as_mut() {
                        match poll_setup(&mut client, active, &events) {
                            Ok(None) => {}
                            Ok(Some(SetupTerminal::Completed { version })) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Setup {
                                        update: SetupUpdate::Installed { version },
                                    },
                                );
                                setup = None;
                            }
                            Ok(Some(SetupTerminal::RosettaCompleted)) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Setup {
                                        update: SetupUpdate::RosettaInstalled,
                                    },
                                );
                                setup = None;
                            }
                            Ok(Some(SetupTerminal::Failed(reason))) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Setup {
                                        update: SetupUpdate::Failed { reason },
                                    },
                                );
                                setup = None;
                            }
                            Err(CallFailure::Remote(reason)) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Setup {
                                        update: SetupUpdate::Failed { reason },
                                    },
                                );
                                setup = None;
                            }
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                    if let Some(active) = update_check.as_mut() {
                        match poll_update_check(&mut client, active) {
                            Ok(Some(UpdateCheckTerminal::Available { local, remote })) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Setup {
                                        update: SetupUpdate::WineUpdate { local, remote },
                                    },
                                );
                                update_check = None;
                            }
                            Ok(Some(UpdateCheckTerminal::Current)) => {
                                update_check = None;
                            }
                            Ok(Some(UpdateCheckTerminal::Failed(reason))) => {
                                // A failed check is not worth a surface; the
                                // next launch tries again.
                                eprintln!("whisky-bridge: WhiskyWine update check failed: {reason}");
                                update_check = None;
                            }
                            Ok(None) => {}
                            Err(CallFailure::Remote(reason)) => {
                                eprintln!("whisky-bridge: WhiskyWine update check failed: {reason}");
                                update_check = None;
                            }
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                    if let Some(active) = metadata_sync.as_mut() {
                        match poll_metadata_sync(&mut client, active) {
                            Ok((None, entry)) => {
                                if let Some(entry) = entry {
                                    emit_event(
                                        &events,
                                        BridgeEvent::Metadata {
                                            update: MetadataUpdate::EntrySynced {
                                                container: active.container.clone(),
                                                entry,
                                            },
                                        },
                                    );
                                }
                            }
                            Ok((Some(MetadataSyncTerminal::Completed { matched, failed }), _)) => {
                                cache = None;
                                emit_event(
                                    &events,
                                    BridgeEvent::Metadata {
                                        update: MetadataUpdate::Synced {
                                            container: active.container.clone(),
                                            matched,
                                            failed,
                                            automatic: active.automatic,
                                        },
                                    },
                                );
                                metadata_sync = None;
                            }
                            Ok((Some(MetadataSyncTerminal::Failed(reason)), _)) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Metadata {
                                        update: MetadataUpdate::Failed { reason },
                                    },
                                );
                                metadata_sync = None;
                            }
                            Err(CallFailure::Remote(reason)) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Metadata {
                                        update: MetadataUpdate::Failed { reason },
                                    },
                                );
                                metadata_sync = None;
                            }
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                    if let Some(active) = metadata_search.as_mut() {
                        match poll_metadata_search(&mut client, active) {
                            Ok(None) => {}
                            Ok(Some(MetadataSearchTerminal::Completed(results))) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Metadata {
                                        update: MetadataUpdate::Results {
                                            container: active.container.clone(),
                                            entry_id: active.entry_id.clone(),
                                            results,
                                        },
                                    },
                                );
                                metadata_search = None;
                            }
                            Ok(Some(MetadataSearchTerminal::Failed(reason))) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Metadata {
                                        update: MetadataUpdate::Failed { reason },
                                    },
                                );
                                metadata_search = None;
                            }
                            Err(CallFailure::Remote(reason)) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Metadata {
                                        update: MetadataUpdate::Failed { reason },
                                    },
                                );
                                metadata_search = None;
                            }
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                }
                Some(Command::Shutdown) => {
                    client.close();
                    emit(&events, BridgeStatus::Stopped);
                    return;
                }
                Some(Command::ShutdownApplication) => {
                    let _ = client.shutdown(true);
                    emit(&events, BridgeStatus::Stopped);
                    return;
                }
                Some(Command::Retry) => {
                    client.close();
                    attempt = 0;
                    continue 'session;
                }
                Some(Command::SetActive(active)) => {
                    foreground = active;
                    // Returning to the foreground polls at once so the first
                    // frame after activation is not stale by up to a cadence.
                    if active && let Some(session) = live.as_mut() {
                        session.due = Instant::now();
                    }
                }
                Some(Command::LoadEntries(container)) => {
                    if let Some((cached, entries)) = &cache
                        && *cached == container
                    {
                        emit_event(
                            &events,
                            BridgeEvent::Entries {
                                container,
                                entries: entries.clone(),
                            },
                        );
                        continue;
                    }
                    cache = None;
                    match fetch_entries(&mut client, &container) {
                        Ok(entries) => {
                            cache = Some((container.clone(), entries.clone()));
                            emit_event(
                                &events,
                                BridgeEvent::Entries { container, entries },
                            );
                        }
                        Err(CallFailure::Remote(reason)) => {
                            emit_event(
                                &events,
                                BridgeEvent::LoadFailed {
                                    container: Some(container),
                                    reason,
                                },
                            );
                        }
                        Err(CallFailure::Session(reason)) => {
                            emit_event(
                                &events,
                                BridgeEvent::LoadFailed {
                                    container: Some(container),
                                    reason: reason.clone(),
                                },
                            );
                            reconnect = Some(reason);
                        }
                    }
                }
                Some(Command::ConfigureRuntime(container)) => {
                    // File-only hosts can select containers and complete lifecycle jobs.
                    if !describe.methods.iter().any(|method| method == "runtime.configure") {
                        continue;
                    }
                    match configure_runtime(&mut client, &container) {
                        Ok(snapshot) => {
                            // Configure is the only wholesale replace: the new
                            // container's entries have nothing in common with
                            // the old bottle's.
                            let session = LiveRuntime::new(&container, &snapshot);
                            emit_event(
                                &events,
                                BridgeEvent::Runtime(RuntimeUpdate::resync(
                                    &container,
                                    snapshot.entries,
                                )),
                            );
                            live = Some(session);
                        }
                        Err(CallFailure::Remote(reason)) => {
                            // Nothing is configured now, so stop polling: the
                            // cards gate their actions on the configured path.
                            live = None;
                            emit_event(
                                &events,
                                BridgeEvent::ConfigureFailed { container, reason },
                            );
                        }
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::Launch {
                    container,
                    entry_id,
                    executable,
                }) => {
                    // `mode` is omitted: the helper defaults to "standard",
                    // and a terminal launch needs the `.terminal` bit.
                    let mut params = json!({ "container": container, "entryID": entry_id });
                    if let Some(executable) = &executable {
                        params["executable"] = json!(executable);
                    }
                    if let Err(failure) = runtime_launch(
                        &mut client,
                        params,
                        &container,
                        &entry_id,
                        executable.as_deref(),
                        &events,
                    ) {
                        match failure {
                            CallFailure::Remote(reason) => {
                                emit_event(&events, BridgeEvent::RuntimeFailed { reason });
                            }
                            CallFailure::Session(reason) => reconnect = Some(reason),
                        }
                    }
                    poll_soon(&mut live);
                }
                Some(Command::DecideClipboard { prompt, decision }) => {
                    let params = prompt.params(decision);
                    if let Err(failure) = runtime_launch(
                        &mut client,
                        params,
                        &prompt.container,
                        &prompt.entry_id,
                        prompt.executable.as_deref(),
                        &events,
                    ) {
                        match failure {
                            CallFailure::Remote(reason) => {
                                emit_event(&events, BridgeEvent::RuntimeFailed { reason });
                            }
                            CallFailure::Session(reason) => reconnect = Some(reason),
                        }
                    }
                    poll_soon(&mut live);
                }
                Some(Command::Cancel { container, entry_id }) => {
                    if let Err(failure) =
                        runtime_control(&mut client, "runtime.cancel", &container, &entry_id)
                    {
                        match failure {
                            CallFailure::Remote(reason) => {
                                emit_event(&events, BridgeEvent::RuntimeFailed { reason });
                            }
                            CallFailure::Session(reason) => reconnect = Some(reason),
                        }
                    }
                    poll_soon(&mut live);
                }
                Some(Command::Stop { container, entry_id }) => {
                    if let Err(failure) =
                        runtime_control(&mut client, "runtime.stop", &container, &entry_id)
                    {
                        match failure {
                            CallFailure::Remote(reason) => {
                                emit_event(&events, BridgeEvent::RuntimeFailed { reason });
                            }
                            CallFailure::Session(reason) => reconnect = Some(reason),
                        }
                    }
                    poll_soon(&mut live);
                }
                Some(Command::SetRating {
                    container,
                    entry_id,
                    rating,
                }) => {
                    let params = json!({
                        "container": container,
                        "entryID": entry_id,
                        "rating": rating,
                    });
                    match client.call("entry.rating", params).map_err(classify) {
                        Ok(value) => match serde_json::from_value::<ActivityDto>(value) {
                            Ok(activity) => emit_event(
                                &events,
                                BridgeEvent::EntryRating {
                                    container,
                                    entry_id,
                                    activity,
                                },
                            ),
                            Err(error) => emit_event(
                                &events,
                                BridgeEvent::EntryFailed {
                                    mutation: EntryMutation::Rating,
                                    container,
                                    entry_id,
                                    reason: format!("invalid activity payload: {error}"),
                                },
                            ),
                        },
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::EntryFailed {
                                mutation: EntryMutation::Rating,
                                container,
                                entry_id,
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::SetHidden {
                    container,
                    entry_id,
                    hidden,
                }) => {
                    let params = json!({
                        "container": container,
                        "entryID": entry_id,
                        "hidden": hidden,
                    });
                    match client.call("entry.hidden", params).map_err(classify) {
                        Ok(value) => match serde_json::from_value::<HiddenReplyDto>(value) {
                            Ok(reply) => emit_event(
                                &events,
                                BridgeEvent::EntryHidden {
                                    container,
                                    entry_id: reply.entry_id,
                                    hidden: reply.hidden,
                                },
                            ),
                            Err(error) => emit_event(
                                &events,
                                BridgeEvent::EntryFailed {
                                    mutation: EntryMutation::Hidden,
                                    container,
                                    entry_id,
                                    reason: format!("invalid visibility payload: {error}"),
                                },
                            ),
                        },
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::EntryFailed {
                                mutation: EntryMutation::Hidden,
                                container,
                                entry_id,
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                #[cfg(target_os = "linux")]
                Some(Command::LoadTerminals) => fetch_terminals(&mut client, &events),
                #[cfg(target_os = "linux")]
                Some(Command::DesktopIntegration { install }) => fetch_desktop(&mut client, &events, install),
                Some(Command::ResolveDesktopOpen { request, id, path }) => {
                    let reply = client.call("system.desktop.resolve", json!({"containerID": id, "path": path})).map_err(classify)
                        .and_then(|value| {
                            let container = value.get("container").and_then(|value| value.as_str());
                            let path = value.get("path").and_then(|value| value.as_str());
                            match (path, container) {
                                (Some(path), Some(container)) => crate::desktop_open::parse(&["--open-file".into(), path.into(), "--container".into(), container.into()])
                                    .map_err(|reason| CallFailure::Remote(reason.into()))?
                                    .ok_or_else(|| CallFailure::Remote("Empty shortcut resolution".into())),
                                _ => Err(CallFailure::Remote("Invalid shortcut resolution".into())),
                            }
                        });
                    let retryable = matches!(&reply, Err(CallFailure::Session(_)));
                    if let Err(CallFailure::Session(reason)) = &reply { reconnect = Some(reason.clone()); }
                    emit_event(&events, BridgeEvent::DesktopResolved { request, result: reply.map_err(CallFailure::into_message), retryable });
                }
                Some(Command::LoadPreferences) => {
                    match load_preferences(&mut client) {
                        Ok((values, schema)) => {
                            emit_event(&events, BridgeEvent::Preferences { values, schema });
                        }
                        // Preferences are a view nicety: a failure keeps the
                        // SwiftUI defaults instead of blanking the library.
                        Err(CallFailure::Remote(reason)) => {
                            eprintln!("whisky-bridge: preferences.read failed: {reason}");
                        }
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::LoadSystemInfo) => {
                    match load_system_info(&mut client) {
                        Ok(info) => emit_event(&events, BridgeEvent::SystemInfo { info }),
                        // The About panel falls back to its built-in copy.
                        Err(CallFailure::Remote(reason)) => {
                            eprintln!("whisky-bridge: system.info failed: {reason}");
                        }
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::SetPreference { key, value }) => {
                    let params = json!({ "key": key, "value": value });
                    match client.call("preferences.set", params).map_err(classify) {
                        Ok(_) => {}
                        Err(CallFailure::Remote(reason)) => {
                            eprintln!("whisky-bridge: preferences.set failed for {key}: {reason}");
                        }
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::LoadConfiguration(container)) => {
                    match load_configuration(&mut client, &container, &describe) {
                        Ok((schema, values)) => emit_event(
                            &events,
                            BridgeEvent::Configuration {
                                container,
                                capabilities: describe.capabilities.clone(),
                                schema,
                                values,
                            },
                        ),
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ConfigurationFailed {
                                container,
                                field: None,
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::SetConfiguration {
                    container,
                    field,
                    value,
                }) => {
                    let params = config::set_payload(&container, &field, &value);
                    match client.call("configuration.set", params).map_err(classify) {
                        Ok(reply) => match decode_values(&reply) {
                            Ok(values) => emit_event(
                                &events,
                                BridgeEvent::ConfigurationSaved {
                                    container,
                                    field,
                                    values,
                                },
                            ),
                            Err(reason) => emit_event(
                                &events,
                                BridgeEvent::ConfigurationFailed {
                                    container,
                                    field: Some(field),
                                    reason,
                                },
                            ),
                        },
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ConfigurationFailed {
                                container,
                                field: Some(field),
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::LoadFolders(container)) => {
                    match load_folders(&mut client, &container) {
                        Ok(folders) => {
                            emit_event(&events, BridgeEvent::Folders { container, folders });
                        }
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::FoldersFailed { container, reason },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::LoadCandidates { container, folder }) => {
                    match load_candidates(&mut client, &container, &folder) {
                        Ok(candidates) => {
                            emit_event(&events, BridgeEvent::Candidates { candidates });
                        }
                        Err(CallFailure::Remote(reason)) => {
                            emit_event(&events, BridgeEvent::RuntimeFailed { reason });
                        }
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::EditFolders { container, edit }) => {
                    let (method, params) = edit.call(&container);
                    match client.call(method, params).map_err(classify) {
                        Ok(reply) => match serde_json::from_value::<FoldersDto>(reply) {
                            Ok(folders) => {
                                emit_event(&events, BridgeEvent::Folders { container, folders });
                            }
                            Err(error) => emit_event(
                                &events,
                                BridgeEvent::FoldersFailed {
                                    container,
                                    reason: format!("invalid folders payload: {error}"),
                                },
                            ),
                        },
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::FoldersFailed { container, reason },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::AddScanRoots { container, paths }) => {
                    match client
                        .call(
                            "folders.addRoots",
                            json!({ "container": container, "paths": paths }),
                        )
                        .map_err(classify)
                    {
                        Ok(reply) => match serde_json::from_value::<FoldersDto>(reply) {
                            Ok(folders) => {
                                emit_event(&events, BridgeEvent::Folders { container, folders });
                            }
                            Err(error) => emit_event(
                                &events,
                                BridgeEvent::FoldersFailed {
                                    container,
                                    reason: format!("invalid folders payload: {error}"),
                                },
                            ),
                        },
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::FoldersFailed { container, reason },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::MoveScanRoot {
                    source,
                    root,
                    target,
                }) => {
                    match client
                        .call(
                            "folders.moveRoot",
                            json!({
                                "container": source,
                                "path": root,
                                "targetContainer": target,
                            }),
                        )
                        .map_err(classify)
                    {
                        Ok(_) => emit_event(
                            &events,
                            BridgeEvent::ScanRootMoved {
                                source,
                                target,
                            },
                        ),
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::FoldersFailed {
                                container: source,
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::LoadEnvironment(container)) => {
                    match load_environment(&mut client, &container) {
                        Ok(values) => {
                            emit_event(&events, BridgeEvent::Environment { container, values });
                        }
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::EnvironmentFailed { container, reason },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::SetEnvironment {
                    container,
                    key,
                    value,
                    replacing,
                }) => {
                    match write_environment(&mut client, &container, &key, value, replacing) {
                        Ok(values) => {
                            emit_event(&events, BridgeEvent::Environment { container, values });
                        }
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::EnvironmentFailed { container, reason },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::LoadPrograms(container)) => {
                    match fetch_programs(&mut client, &container) {
                        Ok(programs) => {
                            emit_event(
                                &events,
                                BridgeEvent::Programs {
                                    container,
                                    programs,
                                    settled: None,
                                },
                            );
                        }
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ProgramsFailed { container, reason },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::SetProgramPinned {
                    container,
                    path,
                    name,
                    pinned,
                }) => {
                    let params = json!({
                        "container": container,
                        "executable": path,
                        "name": name,
                        "pinned": pinned,
                    });
                    let settled = Some((ProgramMutation::Pin, path.clone()));
                    match client.call("programs.pin", params).map_err(classify) {
                        Ok(reply) => match serde_json::from_value::<Vec<ProgramDto>>(reply) {
                            Ok(programs) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Programs {
                                        container,
                                        programs,
                                        settled,
                                    },
                                );
                            }
                            Err(error) => emit_event(
                                &events,
                                BridgeEvent::ProgramFailed {
                                    mutation: ProgramMutation::Pin,
                                    container,
                                    path,
                                    reason: format!("invalid programs payload: {error}"),
                                },
                            ),
                        },
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ProgramFailed {
                                mutation: ProgramMutation::Pin,
                                container,
                                path,
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::SetProgramBlocked {
                    container,
                    path,
                    blocked,
                }) => {
                    let params = json!({
                        "container": container,
                        "executable": path,
                        "blocked": blocked,
                    });
                    let settled = Some((ProgramMutation::Block, path.clone()));
                    match client.call("programs.block", params).map_err(classify) {
                        Ok(reply) => match serde_json::from_value::<Vec<ProgramDto>>(reply) {
                            Ok(programs) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Programs {
                                        container,
                                        programs,
                                        settled,
                                    },
                                );
                            }
                            Err(error) => emit_event(
                                &events,
                                BridgeEvent::ProgramFailed {
                                    mutation: ProgramMutation::Block,
                                    container,
                                    path,
                                    reason: format!("invalid programs payload: {error}"),
                                },
                            ),
                        },
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ProgramFailed {
                                mutation: ProgramMutation::Block,
                                container,
                                path,
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::LoadProcesses(container)) => {
                    match fetch_processes(&mut client, &container) {
                        Ok(processes) => {
                            emit_event(&events, BridgeEvent::Processes { container, processes });
                        }
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ProcessesFailed { container, reason },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::KillProcess { container, pid }) => {
                    let params = json!({ "container": container, "pid": pid });
                    match client.call("processes.kill", params).map_err(classify) {
                        Ok(reply) => match serde_json::from_value::<KillReplyDto>(reply) {
                            Ok(kill) => emit_event(
                                &events,
                                BridgeEvent::ProcessKilled {
                                    container,
                                    pid,
                                    killed: kill.killed,
                                },
                            ),
                            Err(error) => emit_event(
                                &events,
                                BridgeEvent::ProcessKillFailed {
                                    container,
                                    pid,
                                    reason: format!("invalid kill payload: {error}"),
                                },
                            ),
                        },
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ProcessKillFailed {
                                container,
                                pid,
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::KillAllProcesses(container)) => {
                    let params = json!({ "container": container });
                    match client.call("processes.killAll", params).map_err(classify) {
                        Ok(_) => {
                            // Immediately fetch updated processes list
                            match fetch_processes(&mut client, &container) {
                                Ok(processes) => {
                                    emit_event(&events, BridgeEvent::Processes { container, processes });
                                }
                                Err(CallFailure::Remote(reason)) => emit_event(
                                    &events,
                                    BridgeEvent::ProcessesFailed { container, reason },
                                ),
                                Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                            }
                        }
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ProcessesFailed { container, reason },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::StartScan(container)) => {
                    if scan.is_some() {
                        // The sheet disables Scan while a job is live; a second
                        // start must not replace the id the UI cancels by.
                        eprintln!("whisky-bridge: a scan is already running");
                    } else {
                        match start_scan(&mut client, &container) {
                            Ok(job_id) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Scan {
                                        container: container.clone(),
                                        update: ScanUpdate::Started {
                                            job_id: job_id.clone(),
                                        },
                                    },
                                );
                                scan = Some(LiveScan {
                                    container,
                                    job_id,
                                    due: Instant::now() + SCAN_POLL,
                                    last: None,
                                });
                            }
                            Err(CallFailure::Remote(reason)) => emit_event(
                                &events,
                                BridgeEvent::Scan {
                                    container,
                                    update: ScanUpdate::Failed {
                                        status: JobStatus::Failed,
                                        reason,
                                    },
                                },
                            ),
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                }
                Some(Command::CancelScan) => {
                    let cancelled = scan.as_ref().map(|active| active.job_id.clone());
                    match cancelled {
                        Some(job_id) => {
                            match client
                                .call("jobs.cancel", json!({"jobID": job_id}))
                                .map_err(classify)
                            {
                                Ok(_) => {
                                    // Poll on the next tick so the sheet sees
                                    // `cancelling` and then `cancelled`.
                                    if let Some(active) = scan.as_mut() {
                                        active.due = Instant::now();
                                    }
                                }
                                Err(CallFailure::Remote(reason)) => {
                                    let container = scan
                                        .as_ref()
                                        .map(|active| active.container.clone())
                                        .unwrap_or_default();
                                    emit_event(
                                        &events,
                                        BridgeEvent::Scan {
                                            container,
                                            update: ScanUpdate::Failed {
                                                status: JobStatus::Failed,
                                                reason,
                                            },
                                        },
                                    );
                                    scan = None;
                                }
                                Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                            }
                        }
                        // Nothing to cancel: the sheet only offers it while a
                        // job is live.
                        None => eprintln!("whisky-bridge: no scan to cancel"),
                    }
                }
                Some(Command::CreateBottle {
                    name,
                    parent,
                    windows_version,
                }) => {
                    if create.is_some() {
                        eprintln!("whisky-bridge: a bottle create is already running");
                    } else {
                        match start_create(&mut client, &name, &parent, &windows_version) {
                            Ok(job_id) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::BottleCreate {
                                        update: BottleCreateUpdate::Started {
                                            job_id: job_id.clone(),
                                        },
                                    },
                                );
                                create = Some(LiveCreate {
                                    job_id,
                                    due: Instant::now() + SCAN_POLL,
                                    last: None,
                                });
                            }
                            Err(CallFailure::Remote(reason)) => emit_event(
                                &events,
                                BridgeEvent::BottleCreate {
                                    update: BottleCreateUpdate::Failed {
                                        status: JobStatus::Failed,
                                        reason,
                                    },
                                },
                            ),
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                }
                Some(Command::LoadWinetricksCatalog) => {
                    match client.call("winetricks.catalog", json!({})).map_err(classify) {
                        Ok(reply) => match serde_json::from_value::<CatalogDto>(reply) {
                            Ok(catalog) => {
                                emit_event(&events, BridgeEvent::WinetricksCatalog { catalog });
                            }
                            Err(error) => emit_event(
                                &events,
                                BridgeEvent::WinetricksCatalogFailed {
                                    reason: format!("invalid winetricks catalog: {error}"),
                                },
                            ),
                        },
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::WinetricksCatalogFailed { reason },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::LoadInstalledWinetricks(container)) => {
                    match load_installed_winetricks(&mut client, &container) {
                        Ok(installed) => emit_event(
                            &events,
                            BridgeEvent::WinetricksInstalled {
                                container,
                                verbs: installed.verbs,
                            },
                        ),
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::WinetricksInstalledFailed { container, reason },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::InstallWinetricks { container, verbs }) => {
                    if tricks.is_some() {
                        eprintln!("whisky-bridge: a winetricks install is already running");
                    } else {
                        match start_winetricks(&mut client, &container, &verbs) {
                            Ok(job_id) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::WinetricksInstall {
                                        container: container.clone(),
                                        update: winetricks::InstallUpdate::Started {
                                            job_id: job_id.clone(),
                                        },
                                    },
                                );
                                tricks = Some(LiveWinetricks {
                                    container,
                                    job_id,
                                    due: Instant::now() + SCAN_POLL,
                                    last: None,
                                });
                            }
                            Err(CallFailure::Remote(reason)) => emit_event(
                                &events,
                                BridgeEvent::WinetricksInstall {
                                    container,
                                    update: winetricks::InstallUpdate::Failed {
                                        status: JobStatus::Failed,
                                        reason,
                                    },
                                },
                            ),
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                }
                Some(Command::CancelWinetricks) => {
                    match tricks.as_ref().map(|active| active.job_id.clone()) {
                        Some(job_id) => {
                            match client
                                .call("jobs.cancel", json!({"jobID": job_id}))
                                .map_err(classify)
                            {
                                Ok(_) => {
                                    if let Some(active) = tricks.as_mut() {
                                        active.due = Instant::now();
                                    }
                                }
                                Err(CallFailure::Remote(reason)) => {
                                    let container = tricks
                                        .as_ref()
                                        .map(|active| active.container.clone())
                                        .unwrap_or_default();
                                    emit_event(
                                        &events,
                                        BridgeEvent::WinetricksInstall {
                                            container,
                                            update: winetricks::InstallUpdate::Failed {
                                                status: JobStatus::Failed,
                                                reason,
                                            },
                                        },
                                    );
                                    tricks = None;
                                }
                                Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                            }
                        }
                        None => eprintln!("whisky-bridge: no winetricks install to cancel"),
                    }
                }
                Some(Command::LoadProgramSettings { container, executable }) => {
                    match read_program_settings(&mut client, &container, &executable) {
                        Ok(settings) => emit_event(
                            &events,
                            BridgeEvent::ProgramSettings { settings },
                        ),
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ProgramSettingsFailed {
                                container,
                                executable,
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::SaveProgramSettings { container, executable, patch }) => {
                    match write_program_settings(&mut client, &container, &executable, patch) {
                        Ok(settings) => emit_event(
                            &events,
                            BridgeEvent::ProgramSettings { settings },
                        ),
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ProgramSettingsFailed {
                                container,
                                executable,
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::LoadProgramHistory { container, executable }) => {
                    match read_program_history(&mut client, &container, &executable) {
                        Ok(history) => emit_event(
                            &events,
                            BridgeEvent::ProgramHistory {
                                container,
                                executable,
                                history,
                            },
                        ),
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ProgramHistoryFailed {
                                container,
                                executable,
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::DeleteProgramHistory { container, executable, run_id }) => {
                    match delete_program_history(&mut client, &container, &executable, run_id.as_deref()) {
                        Ok(history) => emit_event(
                            &events,
                            BridgeEvent::ProgramHistory {
                                container,
                                executable,
                                history,
                            },
                        ),
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ProgramHistoryFailed {
                                container,
                                executable,
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::CreateProgramShortcut {
                    container,
                    executable,
                    destination,
                }) => {
                    match write_program_shortcut(&mut client, &container, &executable, &destination) {
                        Ok(path) => emit_event(
                            &events,
                            BridgeEvent::ProgramShortcutCreated {
                                container,
                                executable,
                                path,
                            },
                        ),
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ProgramShortcutFailed {
                                container,
                                executable,
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::MoveEntry {
                    source_container,
                    entry_id,
                    target_container,
                }) => {
                    match client
                        .call(
                            "entry.move",
                            json!({
                                "container": source_container,
                                "entryID": entry_id,
                                "targetContainer": target_container,
                            }),
                        )
                        .map_err(classify)
                    {
                        Ok(_) => emit_event(
                            &events,
                            BridgeEvent::EntryMoved {
                                source_container,
                                target_container,
                            },
                        ),
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::EntryMoveFailed {
                                source_container,
                                target_container,
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::RunProgram {
                    container,
                    path,
                    name,
                }) => {
                    if !describe.methods.iter().any(|method| method == "programs.run") {
                        emit_event(&events, BridgeEvent::ActionFailed { reason: "当前主机尚未提供 Windows 程序运行服务".into() });
                        continue;
                    }
                    match client
                        .call(
                            "programs.run",
                            json!({ "container": container, "executable": path }),
                        )
                        .map_err(classify)
                    {
                        Ok(reply) => match serde_json::from_value::<JobStartDto>(reply) {
                            Ok(start) => {
                                let now = Instant::now();
                                program_run = Some(LiveProgramRun {
                                    job_id: start.job_id,
                                    name,
                                    due: now + PROGRAM_RUN_POLL,
                                    deadline: now + PROGRAM_RUN_GRACE,
                                });
                            }
                            Err(error) => emit_event(
                                &events,
                                BridgeEvent::ProgramRunFailed {
                                    name,
                                    reason: format!("invalid run reply: {error}"),
                                },
                            ),
                        },
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ProgramRunFailed { name, reason },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::ReloadLibrary) => {
                    // A refresh must re-read: the cached snapshot predates it.
                    cache = None;
                    match fetch_containers(&mut client) {
                        Ok(containers) => {
                            log_container_names(&containers);
                            emit_event(&events, BridgeEvent::ContainersRefreshed(containers));
                        }
                        Err(CallFailure::Remote(reason)) => {
                            emit_event(&events, BridgeEvent::ActionFailed { reason });
                        }
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::System {
                    container,
                    path,
                    reveal,
                }) => {
                    let method = if reveal { "system.reveal" } else { "system.open" };
                    let mut params = json!({ "container": container });
                    if let Some(path) = path {
                        params["path"] = json!(path);
                    }
                    match client.call(method, params).map_err(classify) {
                        Ok(_) => {}
                        Err(CallFailure::Remote(reason)) => {
                            emit_event(&events, BridgeEvent::ActionFailed { reason });
                        }
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::ChooseFolder(path)) => {
                    match client
                        .call_with_timeout(
                            "system.chooseFolder",
                            json!({ "path": path }),
                            PICKER_TIMEOUT,
                        )
                        .map_err(classify)
                    {
                        Ok(reply) => {
                            let path = reply.get("path").and_then(|value| value.as_str()).map(str::to_owned);
                            emit_event(&events, BridgeEvent::FolderChosen { path });
                        }
                        Err(CallFailure::Remote(reason)) => {
                            emit_event(&events, BridgeEvent::FolderChooseFailed { reason });
                        }
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::ChooseFolders { purpose, path }) => {
                    match client
                        .call_with_timeout(
                            "system.chooseFolders",
                            json!({ "path": path }),
                            PICKER_TIMEOUT,
                        )
                        .map_err(classify)
                    {
                        Ok(reply) => {
                            let paths = reply
                                .get("paths")
                                .and_then(serde_json::Value::as_array)
                                .map(|items| {
                                    items
                                        .iter()
                                        .filter_map(serde_json::Value::as_str)
                                        .map(str::to_owned)
                                        .collect::<Vec<_>>()
                                })
                                .unwrap_or_default();
                            emit_event(&events, BridgeEvent::FoldersChosen { purpose, paths });
                        }
                        Err(CallFailure::Remote(reason)) => {
                            emit_event(&events, BridgeEvent::ActionFailed { reason });
                        }
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::DiscoverContainers { request, root }) => {
                    let params = root.map(|path| json!({ "path": path })).unwrap_or_else(|| json!({}));
                    let result = client.call("workspace.discover", params).map_err(classify)
                        .and_then(|value| serde_json::from_value(value)
                            .map_err(|error| CallFailure::Remote(format!("invalid candidate payload: {error}"))));
                    match result {
                        Ok(candidates) => emit_event(&events, BridgeEvent::ImportCandidates { request, candidates }),
                        Err(error) => {
                            if let CallFailure::Session(reason) = &error { reconnect = Some(reason.clone()); }
                            emit_event(&events, BridgeEvent::ImportCandidatesFailed { request, reason: error.into_message() });
                        }
                    }
                }
                Some(Command::ImportCandidates { request, candidates }) => {
                    let paths = candidates.iter().map(|candidate| candidate.path.clone()).collect();
                    match client.call("workspace.import", json!({ "candidates": candidates })).map_err(classify)
                        .and_then(|value| crate::container_import::import_reply(value, &candidates).map_err(CallFailure::Remote)) {
                        Ok(count) => {
                            emit_event(&events, BridgeEvent::CandidatesImported { request, paths, count });
                            match fetch_containers(&mut client) {
                                Ok(containers) => { cache = None; emit_event(&events, BridgeEvent::ContainersRefreshed(containers)); }
                                Err(error) => {
                                    if let CallFailure::Session(reason) = &error { reconnect = Some(reason.clone()); }
                                    emit_event(&events, BridgeEvent::ImportCandidatesFailed { request,
                                        reason: format!("导入已保存，刷新列表失败：{}", error.into_message()) });
                                }
                            }
                        }
                        Err(error) => {
                            if let CallFailure::Session(reason) = &error { reconnect = Some(reason.clone()); }
                            emit_event(&events, BridgeEvent::ImportCandidatesFailed { request, reason: error.into_message() });
                        }
                    }
                }
                Some(Command::ChoosePath {
                    purpose,
                    mode,
                    path,
                    name,
                    extensions,
                }) => {
                    let mut params = json!({ "purpose": purpose, "mode": mode });
                    if let Some(path) = &path {
                        params["path"] = json!(path);
                    }
                    if let Some(name) = &name {
                        params["name"] = json!(name);
                    }
                    if !extensions.is_empty() {
                        params["extensions"] = json!(extensions);
                    }
                    match client
                        .call_with_timeout("system.choosePath", params, PICKER_TIMEOUT)
                        .map_err(classify)
                    {
                        Ok(reply) => match serde_json::from_value::<PathReplyDto>(reply) {
                            Ok(reply) => {
                                let purpose = if reply.purpose.is_empty() {
                                    purpose
                                } else {
                                    reply.purpose
                                };
                                if purpose == "import-bottle" {
                                    if let Some(path) = reply.path {
                                        match client.call("workspace.import", json!({ "path": path })).map_err(classify) {
                                            Ok(_) => match fetch_containers(&mut client) {
                                                Ok(containers) => {
                                                    cache = None;
                                                    emit_event(&events, BridgeEvent::ContainersRefreshed(containers));
                                                }
                                                Err(CallFailure::Remote(reason)) => emit_event(&events, BridgeEvent::ActionFailed { reason }),
                                                Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                                            },
                                            Err(CallFailure::Remote(reason)) => emit_event(&events, BridgeEvent::ActionFailed { reason }),
                                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                                        }
                                    }
                                } else {
                                emit_event(
                                    &events,
                                    BridgeEvent::PathChosen {
                                        purpose,
                                        path: reply.path,
                                    },
                                );
                                }
                            }
                            Err(error) => emit_event(
                                &events,
                                BridgeEvent::ActionFailed {
                                    reason: format!("invalid path reply: {error}"),
                                },
                            ),
                        },
                        Err(CallFailure::Remote(reason)) => {
                            emit_event(&events, BridgeEvent::ActionFailed { reason });
                        }
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::OpenBottleTool { container, tool }) => {
                    match client
                        .call(
                            "bottle.tools",
                            json!({ "container": container, "tool": tool }),
                        )
                        .map_err(classify)
                    {
                        Ok(_) => emit_event(
                            &events,
                            BridgeEvent::BottleToolOpened { container, tool },
                        ),
                        Err(CallFailure::Remote(reason)) => {
                            emit_event(&events, BridgeEvent::ActionFailed { reason });
                        }
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::BottleOperation {
                    operation,
                    container,
                    name,
                    destination,
                    delete_files,
                }) => {
                    if bottle_op.is_some() {
                        emit_event(
                            &events,
                            BridgeEvent::BottleOperation {
                                operation,
                                container,
                                update: BottleOperationUpdate::Failed {
                                    reason: "另一个容器操作正在进行，请稍后再试".into(),
                                },
                            },
                        );
                    } else {
                        let params = bottle_operation_params(
                            operation,
                            &container,
                            name.as_deref(),
                            destination.as_deref(),
                            delete_files,
                        );
                        match client.call(operation.method(), params).map_err(classify) {
                            Ok(reply) if operation.is_job() => {
                                match serde_json::from_value::<JobStartDto>(reply) {
                                    Ok(start) => {
                                        emit_event(
                                            &events,
                                            BridgeEvent::BottleOperation {
                                                operation,
                                                container: container.clone(),
                                                update: BottleOperationUpdate::Started,
                                            },
                                        );
                                        bottle_op = Some(LiveBottleOperation {
                                            operation,
                                            container,
                                            job_id: start.job_id,
                                            due: Instant::now() + SCAN_POLL,
                                        });
                                    }
                                    Err(error) => emit_event(
                                        &events,
                                        BridgeEvent::BottleOperation {
                                            operation,
                                            container,
                                            update: BottleOperationUpdate::Failed {
                                                reason: format!(
                                                    "invalid bottle operation reply: {error}"
                                                ),
                                            },
                                        },
                                    ),
                                }
                            }
                            Ok(reply) => {
                                let result = serde_json::from_value::<BottleOperationResultDto>(
                                    reply,
                                )
                                .unwrap_or_default();
                                emit_event(
                                    &events,
                                    BridgeEvent::BottleOperation {
                                        operation,
                                        container: container.clone(),
                                        update: BottleOperationUpdate::Completed {
                                            path: result.path,
                                            name: result.name,
                                        },
                                    },
                                );
                                if operation.refreshes_catalogue() {
                                    cache = None;
                                    match fetch_containers(&mut client) {
                                        Ok(containers) => {
                                            log_container_names(&containers);
                                            emit_event(
                                                &events,
                                                BridgeEvent::ContainersRefreshed(containers),
                                            );
                                        }
                                        Err(CallFailure::Remote(reason)) => {
                                            emit_event(&events, BridgeEvent::ActionFailed { reason });
                                        }
                                        Err(CallFailure::Session(reason)) => {
                                            reconnect = Some(reason)
                                        }
                                    }
                                }
                            }
                            Err(CallFailure::Remote(reason)) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::BottleOperation {
                                        operation,
                                        container,
                                        update: BottleOperationUpdate::Failed { reason },
                                    },
                                );
                            }
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                }
                Some(Command::LoadSetupStatus) => {
                    fetch_setup_status(&mut client, &events);
                }
                Some(Command::CheckWineUpdate) => {
                    if update_check.is_none() {
                        match client
                            .call("setup.checkUpdate", json!({}))
                            .map_err(classify)
                        {
                            Ok(reply) => match serde_json::from_value::<JobStartDto>(reply) {
                                Ok(start) => {
                                    update_check = Some(LiveUpdateCheck {
                                        job_id: start.job_id,
                                        due: Instant::now() + SCAN_POLL,
                                    });
                                }
                                Err(error) => emit_event(
                                    &events,
                                    BridgeEvent::Setup {
                                        update: SetupUpdate::Failed {
                                            reason: format!("invalid update-check reply: {error}"),
                                        },
                                    },
                                ),
                            },
                            Err(CallFailure::Remote(reason)) => emit_event(
                                &events,
                                BridgeEvent::Setup {
                                    update: SetupUpdate::Failed { reason },
                                },
                            ),
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                }
                Some(Command::InstallSetup) => {
                    if setup.is_some() {
                        emit_event(
                            &events,
                            BridgeEvent::Setup {
                                update: SetupUpdate::Failed {
                                    reason: "Wine 运行时安装正在进行".into(),
                                },
                            },
                        );
                    } else {
                        match client.call("setup.install", json!({})).map_err(classify) {
                            Ok(reply) => match serde_json::from_value::<JobStartDto>(reply) {
                                Ok(start) => {
                                    emit_event(
                                        &events,
                                        BridgeEvent::Setup {
                                            update: SetupUpdate::Installing {
                                                stage: Some("checking".into()),
                                                progress: None,
                                            },
                                        },
                                    );
                                    setup = Some(LiveSetup {
                                        kind: SetupKind::Runtime,
                                        job_id: start.job_id,
                                        due: Instant::now() + SCAN_POLL,
                                        last_stage: Some("checking".into()),
                                        last_progress: None,
                                    });
                                }
                                Err(error) => emit_event(
                                    &events,
                                    BridgeEvent::Setup {
                                        update: SetupUpdate::Failed {
                                            reason: format!("invalid setup reply: {error}"),
                                        },
                                    },
                                ),
                            },
                            Err(CallFailure::Remote(reason)) => emit_event(
                                &events,
                                BridgeEvent::Setup {
                                    update: SetupUpdate::Failed { reason },
                                },
                            ),
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                }
                Some(Command::InstallRosetta) => {
                    if setup.is_some() {
                        emit_event(
                            &events,
                            BridgeEvent::Setup {
                                update: SetupUpdate::Failed {
                                    reason: "安装任务正在进行".into(),
                                },
                            },
                        );
                    } else {
                        match client
                            .call("setup.installRosetta", json!({}))
                            .map_err(classify)
                        {
                            Ok(reply) => match serde_json::from_value::<JobStartDto>(reply) {
                                Ok(start) => {
                                    emit_event(
                                        &events,
                                        BridgeEvent::Setup {
                                            update: SetupUpdate::Installing {
                                                stage: Some("rosetta".into()),
                                                progress: None,
                                            },
                                        },
                                    );
                                    setup = Some(LiveSetup {
                                        kind: SetupKind::Rosetta,
                                        job_id: start.job_id,
                                        due: Instant::now() + SCAN_POLL,
                                        last_stage: Some("rosetta".into()),
                                        last_progress: None,
                                    });
                                }
                                Err(error) => emit_event(
                                    &events,
                                    BridgeEvent::Setup {
                                        update: SetupUpdate::Failed {
                                            reason: format!("invalid Rosetta reply: {error}"),
                                        },
                                    },
                                ),
                            },
                            Err(CallFailure::Remote(reason)) => emit_event(
                                &events,
                                BridgeEvent::Setup {
                                    update: SetupUpdate::Failed { reason },
                                },
                            ),
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                }
                Some(Command::SyncMetadata {
                    container,
                    sources,
                    automatic,
                }) => {
                    if metadata_sync.is_some() {
                        // A manual request says so; an automatic pass just
                        // waits for the running job to drain the pending set.
                        if !automatic {
                            emit_event(
                                &events,
                                BridgeEvent::Metadata {
                                    update: MetadataUpdate::Failed {
                                        reason: "元数据同步正在进行，请稍后再试".into(),
                                    },
                                },
                            );
                        }
                    } else {
                        match client
                            .call(
                                "metadata.sync",
                                json!({
                                    "container": container,
                                    "sources": sources,
                                    "automatic": automatic,
                                }),
                            )
                            .map_err(classify)
                        {
                            Ok(reply) => match serde_json::from_value::<JobStartDto>(reply) {
                                Ok(start) => {
                                    metadata_sync = Some(LiveMetadataSync {
                                        container,
                                        job_id: start.job_id,
                                        due: Instant::now() + SCAN_POLL,
                                        automatic,
                                        last_entry: None,
                                    });
                                }
                                Err(error) => emit_event(
                                    &events,
                                    BridgeEvent::Metadata {
                                        update: MetadataUpdate::Failed {
                                            reason: format!("invalid sync reply: {error}"),
                                        },
                                    },
                                ),
                            },
                            Err(CallFailure::Remote(reason)) => emit_event(
                                &events,
                                BridgeEvent::Metadata {
                                    update: MetadataUpdate::Failed { reason },
                                },
                            ),
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                }
                Some(Command::SearchMetadata {
                    container,
                    entry_id,
                    query,
                    sources,
                }) => {
                    if metadata_search.is_some() {
                        emit_event(
                            &events,
                            BridgeEvent::Metadata {
                                update: MetadataUpdate::Failed {
                                    reason: "另一次元数据搜索正在进行，请稍后再试".into(),
                                },
                            },
                        );
                    } else {
                        match start_metadata_search(
                            &mut client,
                            &container,
                            &entry_id,
                            &query,
                            &sources,
                            &events,
                        ) {
                            Ok(job) => metadata_search = Some(job),
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                            Err(CallFailure::Remote(_)) => {}
                        }
                    }
                }
                Some(Command::ApplyMetadata {
                    container,
                    entry_id,
                    metadata,
                }) => {
                    // The entry list changed on disk; never serve the stale cache.
                    cache = None;
                    match client
                        .call(
                            "metadata.apply",
                            json!({
                                "container": container,
                                "entryID": entry_id,
                                "metadata": metadata,
                            }),
                        )
                        .map_err(classify)
                    {
                        Ok(_) => emit_event(
                            &events,
                            BridgeEvent::Metadata {
                                update: MetadataUpdate::Applied {
                                    container,
                                    entry_id,
                                },
                            },
                        ),
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::Metadata {
                                update: MetadataUpdate::Failed { reason },
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::ClearMetadata {
                    container,
                    entry_id,
                }) => {
                    // The entry list changed on disk; never serve the stale cache.
                    cache = None;
                    match client
                        .call(
                            "metadata.clear",
                            json!({ "container": container, "entryID": entry_id }),
                        )
                        .map_err(classify)
                    {
                        Ok(_) => emit_event(
                            &events,
                            BridgeEvent::Metadata {
                                update: MetadataUpdate::Applied {
                                    container,
                                    entry_id,
                                },
                            },
                        ),
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::Metadata {
                                update: MetadataUpdate::Failed { reason },
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::ImportMetadataCover {
                    container,
                    entry_id,
                    path,
                }) => {
                    // The entry list changed on disk; never serve the stale cache.
                    cache = None;
                    match client
                        .call(
                            "metadata.cover.import",
                            json!({ "container": container, "entryID": entry_id, "path": path }),
                        )
                        .map_err(classify)
                    {
                        Ok(_) => emit_event(
                            &events,
                            BridgeEvent::Metadata {
                                update: MetadataUpdate::Applied {
                                    container,
                                    entry_id,
                                },
                            },
                        ),
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::Metadata {
                                update: MetadataUpdate::Failed { reason },
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::ResetMetadataCover {
                    container,
                    entry_id,
                }) => {
                    // The entry list changed on disk; never serve the stale cache.
                    cache = None;
                    match client
                        .call(
                            "metadata.cover.reset",
                            json!({ "container": container, "entryID": entry_id }),
                        )
                        .map_err(classify)
                    {
                        Ok(_) => emit_event(
                            &events,
                            BridgeEvent::Metadata {
                                update: MetadataUpdate::Applied {
                                    container,
                                    entry_id,
                                },
                            },
                        ),
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::Metadata {
                                update: MetadataUpdate::Failed { reason },
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::MatchGameConfig {
                    container,
                    entry_id,
                }) => {
                    match client
                        .call(
                            "gameConfig.match",
                            json!({ "container": container, "entryID": entry_id }),
                        )
                        .map_err(classify)
                    {
                        Ok(reply) => match serde_json::from_value::<GameConfigMatchReplyDto>(reply) {
                            Ok(reply) => emit_event(
                                &events,
                                BridgeEvent::Metadata {
                                    update: MetadataUpdate::Matches {
                                        container,
                                        entry_id,
                                        matches: reply.matches,
                                    },
                                },
                            ),
                            Err(error) => emit_event(
                                &events,
                                BridgeEvent::Metadata {
                                    update: MetadataUpdate::MatchesFailed {
                                        container, entry_id, reason: format!("invalid GameDB matches: {error}"),
                                    },
                                },
                            ),
                        },
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::Metadata {
                                update: MetadataUpdate::MatchesFailed { container, entry_id, reason },
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::ApplyGameConfig {
                    container,
                    entry_id,
                    game_id,
                    variant_id,
                }) => {
                    if !describe.methods.iter().any(|method| method == "gameConfig.apply") {
                        emit_event(&events, BridgeEvent::Metadata {
                            update: MetadataUpdate::Failed { reason: "当前会话提供 GameDB 配置参考".into() },
                        });
                        continue;
                    }
                    match client
                        .call(
                            "gameConfig.apply",
                            json!({
                                "container": container,
                                "entryID": entry_id,
                                "gameID": game_id,
                                "variantID": variant_id,
                            }),
                        )
                        .map_err(classify)
                    {
                        Ok(reply) => match serde_json::from_value::<GameConfigApplyReplyDto>(reply) {
                            Ok(reply) => emit_event(
                                &events,
                                BridgeEvent::Metadata {
                                    update: MetadataUpdate::ConfigApplied {
                                        container,
                                        entry_id,
                                        changes: reply.changes,
                                        pending_verbs: reply.pending_verbs,
                                    },
                                },
                            ),
                            Err(error) => emit_event(
                                &events,
                                BridgeEvent::Metadata {
                                    update: MetadataUpdate::Failed {
                                        reason: format!("invalid GameDB result: {error}"),
                                    },
                                },
                            ),
                        },
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::Metadata {
                                update: MetadataUpdate::Failed { reason },
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::RunBottleChecks { container }) => {
                    if diagnostic.is_some() {
                        emit_event(
                            &events,
                            BridgeEvent::ActionFailed {
                                reason: "另一个诊断任务正在进行，请稍后再试".into(),
                            },
                        );
                    } else {
                        match start_diagnostic(
                            &mut client,
                            DiagnosticKind::Checks,
                            "bottle.checks",
                            json!({ "container": container }),
                            &container,
                            &events,
                        ) {
                            Ok(job) => diagnostic = Some(job),
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                            Err(CallFailure::Remote(_)) => {}
                        }
                    }
                }
                Some(Command::LoadDiagnostics { container }) => {
                    if diagnostic.is_some() {
                        emit_event(
                            &events,
                            BridgeEvent::ActionFailed {
                                reason: "另一个诊断任务正在进行，请稍后再试".into(),
                            },
                        );
                    } else {
                        match start_diagnostic(
                            &mut client,
                            DiagnosticKind::Report,
                            "bottle.diagnostics",
                            json!({ "container": container }),
                            &container,
                            &events,
                        ) {
                            Ok(job) => diagnostic = Some(job),
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                            Err(CallFailure::Remote(_)) => {}
                        }
                    }
                }
                Some(Command::ExportDiagnostics {
                    container,
                    destination,
                }) => {
                    if diagnostic.is_some() {
                        emit_event(
                            &events,
                            BridgeEvent::ActionFailed {
                                reason: "另一个诊断任务正在进行，请稍后再试".into(),
                            },
                        );
                    } else {
                        match start_diagnostic(
                            &mut client,
                            DiagnosticKind::Export,
                            "bottle.exportDiagnostics",
                            json!({ "container": container, "destination": destination }),
                            &container,
                            &events,
                        ) {
                            Ok(job) => diagnostic = Some(job),
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                            Err(CallFailure::Remote(_)) => {}
                        }
                    }
                }
                Some(Command::TestAudio { container, beep }) => {
                    if diagnostic.is_some() {
                        emit_event(
                            &events,
                            BridgeEvent::ActionFailed {
                                reason: "另一个诊断任务正在进行，请稍后再试".into(),
                            },
                        );
                    } else {
                        match start_diagnostic(
                            &mut client,
                            DiagnosticKind::Audio,
                            "audio.test",
                            json!({ "container": container, "beep": beep }),
                            &container,
                            &events,
                        ) {
                            Ok(job) => diagnostic = Some(job),
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                            Err(CallFailure::Remote(_)) => {}
                        }
                    }
                }
            }
            if let Some(reason) = reconnect {
                if let Some(active) = scan.take() {
                    emit_event(
                        &events,
                        BridgeEvent::Scan {
                            container: active.container,
                            update: ScanUpdate::Failed {
                                status: JobStatus::Failed,
                                reason: "The bridge session ended; the scan was abandoned".into(),
                            },
                        },
                    );
                }
                if create.take().is_some() {
                    emit_event(
                        &events,
                        BridgeEvent::BottleCreate {
                            update: BottleCreateUpdate::Failed {
                                status: JobStatus::Failed,
                                reason: "The bridge session ended; bottle creation was abandoned"
                                    .into(),
                            },
                        },
                    );
                }
                if let Some(active) = tricks.take() {
                    emit_event(
                        &events,
                        BridgeEvent::WinetricksInstall {
                            container: active.container,
                            update: winetricks::InstallUpdate::Failed {
                                status: JobStatus::Failed,
                                reason: "The bridge session ended; the winetricks install was abandoned"
                                    .into(),
                            },
                        },
                    );
                }
                if let Some(active) = bottle_op.take() {
                    emit_event(
                        &events,
                        BridgeEvent::BottleOperation {
                            operation: active.operation,
                            container: active.container,
                            update: BottleOperationUpdate::Failed {
                                reason: "The bridge session ended; the operation was abandoned"
                                    .into(),
                            },
                        },
                    );
                }
                if let Some(active) = diagnostic.take() {
                    emit_event(
                        &events,
                        BridgeEvent::Diagnostics {
                            kind: active.kind,
                            container: active.container,
                            update: DiagnosticUpdate::Failed {
                                reason: "The bridge session ended; the task was abandoned".into(),
                            },
                        },
                    );
                }
                if metadata_search.take().is_some() {
                    emit_event(
                        &events,
                        BridgeEvent::Metadata {
                            update: MetadataUpdate::Failed {
                                reason: "The bridge session ended; the search was abandoned".into(),
                            },
                        },
                    );
                }
                if metadata_sync.take().is_some() {
                    emit_event(
                        &events,
                        BridgeEvent::Metadata {
                            update: MetadataUpdate::Failed {
                                reason: "The bridge session ended; the sync was abandoned".into(),
                            },
                        },
                    );
                }
                if setup.take().is_some() {
                    emit_event(
                        &events,
                        BridgeEvent::Setup {
                            update: SetupUpdate::Failed {
                                reason: "The bridge session ended; setup was abandoned".into(),
                            },
                        },
                    );
                }
                client.close();
                if fail_and_wait(&events, &commands, &mut attempt, reason, true, &mut foreground)
                {
                    emit(&events, BridgeStatus::Stopped);
                    return;
                }
                continue 'session;
            }
        }
    }
}

/// State the worker keeps for one configured container. Only what the poll
/// schedule needs: the UI owns the entry table.
struct LiveRuntime {
    container: String,
    sequence: String,
    due: Instant,
    /// Consecutive poll failures, for the backoff schedule.
    failures: u32,
    /// Last reported query failures, so they are logged once, not per poll.
    query_failures: BTreeMap<String, String>,
}

impl LiveRuntime {
    fn new(container: &str, snapshot: &RuntimeSnapshotDto) -> Self {
        log_query_failures(&snapshot.query_failures);
        let any_active = snapshot
            .entries
            .iter()
            .any(|entry| RuntimeState::from_wire(&entry.state).is_active());
        Self {
            container: container.to_owned(),
            sequence: snapshot.sequence.clone(),
            due: Instant::now() + poll_interval(any_active),
            failures: 0,
            query_failures: snapshot.query_failures.clone(),
        }
    }
}

fn poll_soon(live: &mut Option<LiveRuntime>) {
    if let Some(session) = live.as_mut() {
        session.due = Instant::now();
    }
}

fn log_query_failures(failures: &BTreeMap<String, String>) {
    for (container, failure) in failures {
        eprintln!("whisky-bridge: runtime query failure for {container}: {failure}");
    }
}

fn configure_runtime(
    client: &mut Client,
    container: &str,
) -> Result<RuntimeSnapshotDto, CallFailure> {
    client
        .call("runtime.configure", json!({ "container": container }))
        .map_err(classify)?;
    // The call already replies with a snapshot; read it back explicitly so the
    // UI always renders a `runtime.snapshot` result.
    fetch_snapshot(client)
}

fn fetch_snapshot(client: &mut Client) -> Result<RuntimeSnapshotDto, CallFailure> {
    let value = client.call("runtime.snapshot", json!({})).map_err(classify)?;
    serde_json::from_value(value)
        .map_err(|error| CallFailure::Remote(format!("invalid runtime snapshot: {error}")))
}

/// Read the cursor. The reply's `snapshot` is current as of the request, so it
/// wins over anything the buffered events carry; the events are still read for
/// launch results and driver failures.
fn poll_runtime(
    client: &mut Client,
    session: &mut LiveRuntime,
    events: &smol::channel::Sender<BridgeEvent>,
) -> Result<(), CallFailure> {
    let value = client
        .call("runtime.events", json!({ "after": session.sequence }))
        .map_err(classify)?;
    let batch: RuntimeEventBatchDto = serde_json::from_value(value)
        .map_err(|error| CallFailure::Remote(format!("invalid runtime events payload: {error}")))?;
    let RuntimeEventBatchDto {
        sequence,
        resync_required,
        events: batch_events,
        snapshot,
    } = batch;
    // A state event carries a whole snapshot; keep the newest as a fallback for
    // a reply that omits `snapshot`.
    let mut latest_state = None;
    for event in batch_events {
        match event.event {
            RuntimeEventPayloadDto::State { value } => latest_state = Some(value),
            RuntimeEventPayloadDto::LaunchResult {
                entry_id,
                status,
                error,
            } => {
                if status == "launched" || status == "terminal" {
                    eprintln!("whisky-bridge: {status} {entry_id}");
                } else {
                    let reason = error
                        .clone()
                        .unwrap_or_else(|| format!("The launch of {entry_id} failed."));
                    eprintln!("whisky-bridge: {reason}");
                    emit_event(events, BridgeEvent::RuntimeFailed { reason });
                }
            }
            RuntimeEventPayloadDto::Failure { message } => {
                eprintln!("whisky-bridge: runtime failure: {message}");
                emit_event(
                    events,
                    BridgeEvent::RuntimeFailed {
                        reason: message.clone(),
                    },
                );
            }
            RuntimeEventPayloadDto::Unknown => {}
        }
    }
    let Some(snapshot) = snapshot.or(latest_state) else {
        return Err(CallFailure::Remote(
            "runtime.events returned no snapshot".into(),
        ));
    };
    if snapshot.query_failures != session.query_failures {
        log_query_failures(&snapshot.query_failures);
        session.query_failures = snapshot.query_failures;
    }
    if !sequence.is_empty() {
        session.sequence = sequence;
    }
    let any_active = snapshot
        .entries
        .iter()
        .any(|entry| RuntimeState::from_wire(&entry.state).is_active());
    session.due = Instant::now() + poll_interval(any_active);
    session.failures = 0;
    // A gap in the ring means the delta set is incomplete, so the frontend must
    // replace its table rather than merge.
    let update = if resync_required {
        RuntimeUpdate::resync(&session.container, snapshot.entries)
    } else {
        RuntimeUpdate::merge(&session.container, snapshot.entries)
    };
    emit_event(events, BridgeEvent::Runtime(update));
    Ok(())
}

/// Helpers for the bottle surfaces. Each returns a domain value or a classified
/// failure so the caller decides between an event and a reconnect.

fn load_configuration(
    client: &mut Client,
    container: &str,
    describe: &DescribeResponse,
) -> Result<(Vec<ConfigField>, BTreeMap<String, serde_json::Value>), CallFailure> {
    let schema = client
        .call(
            "configuration.schema",
            json!({ "container": container, "platform": describe.platform }),
        )
        .map_err(classify)?;
    let fields =
        config::decode_schema(&schema, &describe.platform).map_err(CallFailure::Remote)?;
    let read = client
        .call("configuration.read", json!({ "container": container }))
        .map_err(classify)?;
    let values = config::resolved_values(&fields, &read);
    Ok((fields, values))
}

fn decode_values(reply: &serde_json::Value) -> Result<BTreeMap<String, serde_json::Value>, String> {
    reply
        .as_object()
        .map(|map| {
            map.iter()
                .map(|(key, value)| (key.clone(), value.clone()))
                .collect()
        })
        .ok_or_else(|| "configuration reply is not an object".to_owned())
}

fn load_folders(client: &mut Client, container: &str) -> Result<FoldersDto, CallFailure> {
    let reply = client
        .call("folders.read", json!({ "container": container }))
        .map_err(classify)?;
    serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid folders payload: {error}")))
}

fn load_candidates(
    client: &mut Client,
    container: &str,
    folder: &str,
) -> Result<CandidatesDto, CallFailure> {
    let reply = client
        .call(
            "folders.candidates",
            json!({ "container": container, "path": folder }),
        )
        .map_err(classify)?;
    serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid candidates payload: {error}")))
}

fn load_environment(
    client: &mut Client,
    container: &str,
) -> Result<BTreeMap<String, String>, CallFailure> {
    let reply = client
        .call("environment.read", json!({ "container": container }))
        .map_err(classify)?;
    serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid environment payload: {error}")))
}

fn write_environment(
    client: &mut Client,
    container: &str,
    key: &str,
    value: Option<String>,
    replacing: Option<String>,
) -> Result<BTreeMap<String, String>, CallFailure> {
    // The bridge has no rename: remove the old key, then write the new one.
    if let Some(previous) = replacing.filter(|previous| previous != key) {
        client
            .call(
                "environment.set",
                config::environment_payload(container, &previous, None),
            )
            .map_err(classify)?;
    }
    let reply = client
        .call(
            "environment.set",
            config::environment_payload(container, key, value.as_deref()),
        )
        .map_err(classify)?;
    serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid environment payload: {error}")))
}

fn start_scan(client: &mut Client, container: &str) -> Result<String, CallFailure> {
    let reply = client
        .call("library.scan", json!({ "container": container }))
        .map_err(classify)?;
    let start: JobStartDto = serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid scan reply: {error}")))?;
    Ok(start.job_id)
}

fn bottle_operation_params(
    operation: BottleOperation,
    container: &str,
    name: Option<&str>,
    destination: Option<&str>,
    delete_files: bool,
) -> serde_json::Value {
    match operation {
        BottleOperation::Rename => json!({
            "container": container,
            "name": name.unwrap_or_default(),
        }),
        BottleOperation::Remove => json!({
            "container": container,
            "deleteFiles": delete_files,
            "stopProcesses": true,
        }),
        BottleOperation::Move => json!({
            "container": container,
            "destination": destination.unwrap_or_default(),
        }),
        BottleOperation::Duplicate => json!({
            "container": container,
            "name": name.unwrap_or_default(),
        }),
        BottleOperation::Export => json!({
            "container": container,
            "destination": destination.unwrap_or_default(),
        }),
        BottleOperation::Repair | BottleOperation::CleanCache => {
            json!({ "container": container })
        }
    }
}

fn start_diagnostic(
    client: &mut Client,
    kind: DiagnosticKind,
    method: &str,
    params: serde_json::Value,
    container: &str,
    events: &smol::channel::Sender<BridgeEvent>,
) -> Result<LiveDiagnostic, CallFailure> {
    match client.call(method, params).map_err(classify) {
        Ok(reply) => match serde_json::from_value::<JobStartDto>(reply) {
            Ok(start) => {
                emit_event(
                    events,
                    BridgeEvent::Diagnostics {
                        kind,
                        container: container.to_owned(),
                        update: DiagnosticUpdate::Started,
                    },
                );
                Ok(LiveDiagnostic {
                    kind,
                    container: container.to_owned(),
                    job_id: start.job_id,
                    due: Instant::now() + SCAN_POLL,
                })
            }
            Err(error) => {
                let reason = format!("invalid job reply: {error}");
                emit_event(
                    events,
                    BridgeEvent::Diagnostics {
                        kind,
                        container: container.to_owned(),
                        update: DiagnosticUpdate::Failed {
                            reason: reason.clone(),
                        },
                    },
                );
                Err(CallFailure::Remote(reason))
            }
        },
        Err(CallFailure::Remote(reason)) => {
            emit_event(
                events,
                BridgeEvent::Diagnostics {
                    kind,
                    container: container.to_owned(),
                    update: DiagnosticUpdate::Failed {
                        reason: reason.clone(),
                    },
                },
            );
            Err(CallFailure::Remote(reason))
        }
        Err(CallFailure::Session(reason)) => Err(CallFailure::Session(reason)),
    }
}

fn start_metadata_search(
    client: &mut Client,
    container: &str,
    entry_id: &str,
    query: &str,
    sources: &[String],
    events: &smol::channel::Sender<BridgeEvent>,
) -> Result<LiveMetadataSearch, CallFailure> {
    match client
        .call(
            "metadata.search",
            json!({
                "container": container,
                "entryID": entry_id,
                "query": query,
                "sources": sources,
            }),
        )
        .map_err(classify)
    {
        Ok(reply) => match serde_json::from_value::<JobStartDto>(reply) {
            Ok(start) => {
                emit_event(
                    events,
                    BridgeEvent::Metadata {
                        update: MetadataUpdate::SearchStarted {
                            container: container.to_owned(),
                            entry_id: entry_id.to_owned(),
                        },
                    },
                );
                Ok(LiveMetadataSearch {
                    container: container.to_owned(),
                    entry_id: entry_id.to_owned(),
                    job_id: start.job_id,
                    due: Instant::now() + SCAN_POLL,
                })
            }
            Err(error) => {
                let reason = format!("invalid search reply: {error}");
                emit_event(
                    events,
                    BridgeEvent::Metadata {
                        update: MetadataUpdate::Failed {
                            reason: reason.clone(),
                        },
                    },
                );
                Err(CallFailure::Remote(reason))
            }
        },
        Err(CallFailure::Remote(reason)) => {
            emit_event(
                events,
                BridgeEvent::Metadata {
                    update: MetadataUpdate::Failed {
                        reason: reason.clone(),
                    },
                },
            );
            Err(CallFailure::Remote(reason))
        }
        Err(CallFailure::Session(reason)) => Err(CallFailure::Session(reason)),
    }
}

fn start_create(
    client: &mut Client,
    name: &str,
    parent: &str,
    windows_version: &str,
) -> Result<String, CallFailure> {
    let reply = client
        .call(
            "bottle.create",
            json!({
                "name": name,
                "parent": parent,
                "windowsVersion": windows_version,
            }),
        )
        .map_err(classify)?;
    let start: JobStartDto = serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid create reply: {error}")))?;
    Ok(start.job_id)
}

/// How often `jobs.get` is polled while a scan or create job is queued or running.
const SCAN_POLL: Duration = Duration::from_millis(250);
/// A launched game is only watched for startup failures. After this window the
/// job is left alone; a game may then run for hours.
const PROGRAM_RUN_GRACE: Duration = Duration::from_secs(20);
const PROGRAM_RUN_POLL: Duration = Duration::from_millis(500);

struct LiveProgramRun {
    job_id: String,
    name: String,
    due: Instant,
    deadline: Instant,
}

struct LiveScan {
    container: String,
    job_id: String,
    due: Instant,
    /// Last reported `(status, stage)`, so the sheet is notified on change only.
    last: Option<(JobStatus, Option<String>)>,
}

struct LiveCreate {
    job_id: String,
    due: Instant,
    last: Option<(JobStatus, Option<String>)>,
}

struct LiveWinetricks {
    container: String,
    job_id: String,
    due: Instant,
    /// Last reported `(status, progress)`, so identical polls stay quiet.
    last: Option<(JobStatus, InstallProgress)>,
}

struct LiveBottleOperation {
    operation: BottleOperation,
    container: String,
    job_id: String,
    due: Instant,
}

struct LiveDiagnostic {
    kind: DiagnosticKind,
    container: String,
    job_id: String,
    due: Instant,
}

struct LiveUpdateCheck {
    job_id: String,
    due: Instant,
}

enum UpdateCheckTerminal {
    Available { local: String, remote: String },
    Current,
    Failed(String),
}

/// `setup.checkUpdate`'s result: dotted versions, `remote` is `0.0.0` when
/// no update is available.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct WineUpdateReplyDto {
    update_available: bool,
    remote_version: String,
    #[serde(default)]
    local_version: Option<String>,
}

fn poll_update_check(
    client: &mut Client,
    check: &mut LiveUpdateCheck,
) -> Result<Option<UpdateCheckTerminal>, CallFailure> {
    let reply = client
        .call("jobs.get", json!({ "jobID": check.job_id }))
        .map_err(classify)?;
    let job: JobDto = serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid job payload: {error}")))?;
    let status = JobStatus::from_wire(&job.status)
        .ok_or_else(|| CallFailure::Remote(format!("unknown job status: {}", job.status)))?;
    check.due = Instant::now() + SCAN_POLL;
    match status {
        JobStatus::Completed => {
            let result = job
                .result
                .ok_or_else(|| CallFailure::Remote("update-check job has no result".into()))?;
            let reply: WineUpdateReplyDto = serde_json::from_value(result).map_err(|error| {
                CallFailure::Remote(format!("invalid update-check result: {error}"))
            })?;
            if reply.update_available {
                Ok(Some(UpdateCheckTerminal::Available {
                    local: reply.local_version.unwrap_or_else(|| "0.0.0".into()),
                    remote: reply.remote_version,
                }))
            } else {
                Ok(Some(UpdateCheckTerminal::Current))
            }
        }
        JobStatus::Failed | JobStatus::Cancelled => {
            let reason = job
                .error
                .as_ref()
                .map(BridgeFailureDto::reason)
                .unwrap_or_else(|| "WhiskyWine 更新检查失败".to_owned());
            Ok(Some(UpdateCheckTerminal::Failed(reason)))
        }
        JobStatus::Queued | JobStatus::Running | JobStatus::Cancelling => Ok(None),
    }
}

struct LiveMetadataSearch {
    container: String,
    entry_id: String,
    job_id: String,
    due: Instant,
}

struct LiveMetadataSync {
    container: String,
    job_id: String,
    due: Instant,
    /// `automatic` runs only touch pending entries and finish silently.
    automatic: bool,
    /// Last `entryID` already pushed to the UI, so a poll only forwards a
    /// matched card once.
    last_entry: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum SetupKind {
    Runtime,
    Rosetta,
}

struct LiveSetup {
    kind: SetupKind,
    job_id: String,
    due: Instant,
    last_stage: Option<String>,
    last_progress: Option<(u64, u64)>,
}

enum SetupTerminal {
    Completed { version: Option<String> },
    RosettaCompleted,
    Failed(String),
}

/// Refresh desktop state only through a method advertised by this session.
fn fetch_desktop(client: &mut Client, events: &smol::channel::Sender<BridgeEvent>, install: bool) {
    let method = if install {
        "system.desktop.install"
    } else {
        "system.desktop.status"
    };
    if !client
        .capabilities()
        .methods
        .iter()
        .any(|advertised| advertised == method)
    {
        emit_event(
            events,
            BridgeEvent::HostDesktop {
                install,
                result: Err("桌面集成服务接入后可配置".into()),
            },
        );
        return;
    }
    let result = std::env::current_exe()
        .map_err(|error| error.to_string())
        .and_then(|launcher| {
            client
                .call(method, json!({ "launcher": launcher }))
                .map_err(|error| error.to_string())
        })
        .and_then(|value| serde_json::from_value(value).map_err(|error| error.to_string()));
    emit_event(events, BridgeEvent::HostDesktop { install, result });
}

fn fetch_terminals(client: &mut Client, events: &smol::channel::Sender<BridgeEvent>) {
    if !client
        .capabilities()
        .methods
        .iter()
        .any(|method| method == "system.terminals")
    {
        emit_event(
            events,
            BridgeEvent::HostTerminals {
                result: Err("终端发现服务接入后可选择".into()),
            },
        );
        return;
    }
    let result = client
        .call("system.terminals", json!({}))
        .map_err(|error| error.to_string())
        .and_then(|value| serde_json::from_value(value).map_err(|error| error.to_string()));
    emit_event(events, BridgeEvent::HostTerminals { result });
}

fn fetch_setup_status(client: &mut Client, events: &smol::channel::Sender<BridgeEvent>) {
    if !client
        .capabilities()
        .methods
        .iter()
        .any(|method| method == "setup.status")
    {
        return;
    }
    let Ok(reply) = client.call("setup.status", json!({})) else {
        return;
    };
    let Ok(status) = serde_json::from_value::<SetupStatusDto>(reply) else {
        return;
    };
    emit_event(
        events,
        BridgeEvent::Setup {
            update: SetupUpdate::Status {
                installed: status.installed,
                version: status.version,
                rosetta_installed: status.rosetta_installed,
                apple_silicon: status.apple_silicon,
            },
        },
    );
}

fn poll_setup(
    client: &mut Client,
    setup: &mut LiveSetup,
    events: &smol::channel::Sender<BridgeEvent>,
) -> Result<Option<SetupTerminal>, CallFailure> {
    let reply = client
        .call("jobs.get", json!({ "jobID": setup.job_id }))
        .map_err(classify)?;
    let job: JobDto = serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid job payload: {error}")))?;
    let status = JobStatus::from_wire(&job.status)
        .ok_or_else(|| CallFailure::Remote(format!("unknown job status: {}", job.status)))?;
    let stage = job.stage().map(str::to_owned);
    let progress = job
        .progress
        .get("received")
        .and_then(serde_json::Value::as_u64)
        .zip(job.progress.get("total").and_then(serde_json::Value::as_u64));
    if setup.last_stage != stage || setup.last_progress != progress {
        emit_event(
            events,
            BridgeEvent::Setup {
                update: SetupUpdate::Installing {
                    stage: stage.clone(),
                    progress,
                },
            },
        );
        setup.last_stage = stage;
        setup.last_progress = progress;
    }
    setup.due = Instant::now() + SCAN_POLL;
    match status {
        JobStatus::Completed => {
            let result = job
                .result
                .ok_or_else(|| CallFailure::Remote("setup job has no result".into()))?;
            match setup.kind {
                SetupKind::Runtime => {
                    let status: SetupStatusDto =
                        serde_json::from_value(result).map_err(|error| {
                            CallFailure::Remote(format!("invalid setup result: {error}"))
                        })?;
                    Ok(Some(SetupTerminal::Completed {
                        version: status.version,
                    }))
                }
                SetupKind::Rosetta => Ok(Some(SetupTerminal::RosettaCompleted)),
            }
        }
        JobStatus::Failed | JobStatus::Cancelled => {
            let reason = job
                .error
                .as_ref()
                .map(BridgeFailureDto::reason)
                .unwrap_or_else(|| {
                    if status == JobStatus::Cancelled {
                        "安装已取消".to_owned()
                    } else {
                        "Wine 运行时安装失败".to_owned()
                    }
                });
            Ok(Some(SetupTerminal::Failed(reason)))
        }
        JobStatus::Queued | JobStatus::Running | JobStatus::Cancelling => Ok(None),
    }
}

enum MetadataSyncTerminal {
    Completed { matched: u64, failed: u64 },
    Failed(String),
}

fn poll_metadata_sync(
    client: &mut Client,
    sync: &mut LiveMetadataSync,
) -> Result<(Option<MetadataSyncTerminal>, Option<EntryDto>), CallFailure> {
    let reply = client
        .call("jobs.get", json!({ "jobID": sync.job_id }))
        .map_err(classify)?;
    let job: JobDto = serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid job payload: {error}")))?;
    let status = JobStatus::from_wire(&job.status)
        .ok_or_else(|| CallFailure::Remote(format!("unknown job status: {}", job.status)))?;
    sync.due = Instant::now() + SCAN_POLL;
    match status {
        JobStatus::Completed => {
            let result = job
                .result
                .ok_or_else(|| CallFailure::Remote("sync job has no result".into()))?;
            let reply: MetadataSyncReplyDto = serde_json::from_value(result).map_err(|error| {
                CallFailure::Remote(format!("invalid metadata sync result: {error}"))
            })?;
            Ok((
                Some(MetadataSyncTerminal::Completed {
                    matched: reply.matched,
                    failed: reply.failed,
                }),
                None,
            ))
        }
        JobStatus::Failed | JobStatus::Cancelled => {
            let reason = job
                .error
                .as_ref()
                .map(BridgeFailureDto::reason)
                .unwrap_or_else(|| {
                    if status == JobStatus::Cancelled {
                        "同步已取消".to_owned()
                    } else {
                        "元数据同步失败".to_owned()
                    }
                });
            Ok((Some(MetadataSyncTerminal::Failed(reason)), None))
        }
        JobStatus::Queued | JobStatus::Running | JobStatus::Cancelling => {
            // Each matched entry appears in the progress payload exactly
            // once; forward it so the grid updates card by card.
            let entry = job
                .progress
                .get("entryID")
                .and_then(serde_json::Value::as_str)
                .filter(|id| sync.last_entry.as_deref() != Some(*id))
                .and_then(|id| {
                    sync.last_entry = Some(id.to_owned());
                    job.progress.get("entry")
                })
                .and_then(|value| serde_json::from_value::<EntryDto>(value.clone()).ok());
            Ok((None, entry))
        }
    }
}

enum MetadataSearchTerminal {
    Completed(Vec<MetadataSearchGroupDto>),
    Failed(String),
}

fn poll_metadata_search(
    client: &mut Client,
    search: &mut LiveMetadataSearch,
) -> Result<Option<MetadataSearchTerminal>, CallFailure> {
    let reply = client
        .call("jobs.get", json!({ "jobID": search.job_id }))
        .map_err(classify)?;
    let job: JobDto = serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid job payload: {error}")))?;
    let status = JobStatus::from_wire(&job.status)
        .ok_or_else(|| CallFailure::Remote(format!("unknown job status: {}", job.status)))?;
    search.due = Instant::now() + SCAN_POLL;
    match status {
        JobStatus::Completed => {
            let result = job
                .result
                .ok_or_else(|| CallFailure::Remote("search job has no result".into()))?;
            let reply: MetadataSearchReplyDto = serde_json::from_value(result).map_err(|error| {
                CallFailure::Remote(format!("invalid metadata results: {error}"))
            })?;
            Ok(Some(MetadataSearchTerminal::Completed(reply.results)))
        }
        JobStatus::Failed | JobStatus::Cancelled => {
            let reason = job
                .error
                .as_ref()
                .map(BridgeFailureDto::reason)
                .unwrap_or_else(|| {
                    if status == JobStatus::Cancelled {
                        "搜索已取消".to_owned()
                    } else {
                        "元数据搜索失败".to_owned()
                    }
                });
            Ok(Some(MetadataSearchTerminal::Failed(reason)))
        }
        JobStatus::Queued | JobStatus::Running | JobStatus::Cancelling => Ok(None),
    }
}

enum DiagnosticTerminal {
    Report(String),
    Exported(String),
    Audio(AudioResultDto),
    Checks(Vec<crate::bridge::dto::TroubleshootingCheckDto>),
    Failed(String),
}

fn poll_diagnostic(
    client: &mut Client,
    diagnostic: &mut LiveDiagnostic,
) -> Result<Option<DiagnosticTerminal>, CallFailure> {
    let reply = client
        .call("jobs.get", json!({ "jobID": diagnostic.job_id }))
        .map_err(classify)?;
    let job: JobDto = serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid job payload: {error}")))?;
    let status = JobStatus::from_wire(&job.status)
        .ok_or_else(|| CallFailure::Remote(format!("unknown job status: {}", job.status)))?;
    diagnostic.due = Instant::now() + SCAN_POLL;
    match status {
        JobStatus::Completed => {
            let result = job
                .result
                .ok_or_else(|| CallFailure::Remote("completed job has no result".into()))?;
            match diagnostic.kind {
                DiagnosticKind::Report => {
                    let report: DiagnosticsReportDto = serde_json::from_value(result)
                        .map_err(|error| {
                            CallFailure::Remote(format!("invalid diagnostics report: {error}"))
                        })?;
                    Ok(Some(DiagnosticTerminal::Report(report.report)))
                }
                DiagnosticKind::Export => {
                    let result: BottleOperationResultDto = serde_json::from_value(result)
                        .map_err(|error| {
                            CallFailure::Remote(format!("invalid diagnostics export: {error}"))
                        })?;
                    result
                        .path
                        .map(|path| Some(DiagnosticTerminal::Exported(path)))
                        .ok_or_else(|| {
                            CallFailure::Remote("diagnostics export has no path".into())
                        })
                }
                DiagnosticKind::Audio => {
                    let result: AudioResultDto = serde_json::from_value(result).map_err(|error| {
                        CallFailure::Remote(format!("invalid audio result: {error}"))
                    })?;
                    Ok(Some(DiagnosticTerminal::Audio(result)))
                }
                DiagnosticKind::Checks => {
                    let reply: ChecksReplyDto = serde_json::from_value(result).map_err(|error| {
                        CallFailure::Remote(format!("invalid checks result: {error}"))
                    })?;
                    Ok(Some(DiagnosticTerminal::Checks(reply.checks)))
                }
            }
        }
        JobStatus::Failed | JobStatus::Cancelled => {
            let reason = job
                .error
                .as_ref()
                .map(BridgeFailureDto::reason)
                .unwrap_or_else(|| {
                    if status == JobStatus::Cancelled {
                        "操作已取消".to_owned()
                    } else {
                        "诊断任务失败".to_owned()
                    }
                });
            Ok(Some(DiagnosticTerminal::Failed(reason)))
        }
        JobStatus::Queued | JobStatus::Running | JobStatus::Cancelling => Ok(None),
    }
}

enum BottleOperationTerminal {
    Completed {
        path: Option<String>,
        name: Option<String>,
    },
    Failed {
        reason: String,
    },
}

fn poll_bottle_operation(
    client: &mut Client,
    operation: &mut LiveBottleOperation,
) -> Result<Option<BottleOperationTerminal>, CallFailure> {
    let reply = client
        .call("jobs.get", json!({ "jobID": operation.job_id }))
        .map_err(classify)?;
    let job: JobDto = serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid job payload: {error}")))?;
    let status = JobStatus::from_wire(&job.status)
        .ok_or_else(|| CallFailure::Remote(format!("unknown job status: {}", job.status)))?;
    operation.due = Instant::now() + SCAN_POLL;
    match status {
        JobStatus::Completed => {
            let result = job
                .result
                .map(|value| serde_json::from_value::<BottleOperationResultDto>(value))
                .transpose()
                .map_err(|error| {
                    CallFailure::Remote(format!("invalid bottle operation result: {error}"))
                })?
                .unwrap_or_default();
            Ok(Some(BottleOperationTerminal::Completed {
                path: result.path,
                name: result.name,
            }))
        }
        JobStatus::Failed | JobStatus::Cancelled => {
            let reason = job
                .error
                .as_ref()
                .map(BridgeFailureDto::reason)
                .unwrap_or_else(|| {
                    if status == JobStatus::Cancelled {
                        "操作已取消".to_owned()
                    } else {
                        "容器操作失败".to_owned()
                    }
                });
            Ok(Some(BottleOperationTerminal::Failed { reason }))
        }
        JobStatus::Queued | JobStatus::Running | JobStatus::Cancelling => Ok(None),
    }
}

enum WinetricksTerminal {
    Completed(InstallResultDto),
    Failed { status: JobStatus, reason: String },
}

fn read_program_settings(
    client: &mut Client,
    container: &str,
    executable: &str,
) -> Result<ProgramSettingsDto, CallFailure> {
    let reply = client
        .call(
            "programs.settings.read",
            json!({ "container": container, "executable": executable }),
        )
        .map_err(classify)?;
    serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid program settings: {error}")))
}

fn write_program_settings(
    client: &mut Client,
    container: &str,
    executable: &str,
    patch: serde_json::Value,
) -> Result<ProgramSettingsDto, CallFailure> {
    let reply = client
        .call(
            "programs.settings.set",
            json!({ "container": container, "executable": executable, "patch": patch }),
        )
        .map_err(classify)?;
    serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid program settings: {error}")))
}

fn read_program_history(
    client: &mut Client,
    container: &str,
    executable: &str,
) -> Result<HistoryDto, CallFailure> {
    let reply = client
        .call(
            "programs.history.read",
            json!({ "container": container, "executable": executable }),
        )
        .map_err(classify)?;
    serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid program history: {error}")))
}

fn delete_program_history(
    client: &mut Client,
    container: &str,
    executable: &str,
    run_id: Option<&str>,
) -> Result<HistoryDto, CallFailure> {
    let mut params = json!({ "container": container, "executable": executable });
    if let Some(run_id) = run_id {
        params["runID"] = json!(run_id);
    }
    let reply = client
        .call("programs.history.delete", params)
        .map_err(classify)?;
    serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid program history: {error}")))
}

fn write_program_shortcut(
    client: &mut Client,
    container: &str,
    executable: &str,
    destination: &str,
) -> Result<String, CallFailure> {
    let params = json!({ "container": container, "executable": executable, "destination": destination });
    #[cfg(target_os = "linux")]
    let params = {
        let mut params = params;
        params["launcher"] = json!(std::env::current_exe().map_err(|error| CallFailure::Remote(error.to_string()))?);
        params
    };
    let reply = client
        .call(
            "programs.shortcut.create",
            params,
        )
        .map_err(classify)?;
    reply
        .get("path")
        .and_then(serde_json::Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| CallFailure::Remote("shortcut reply has no path".into()))
}

fn start_winetricks(
    client: &mut Client,
    container: &str,
    verbs: &[String],
) -> Result<String, CallFailure> {
    let reply = client
        .call(
            "winetricks.install",
            json!({ "container": container, "verbs": verbs }),
        )
        .map_err(classify)?;
    let start: JobStartDto = serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid winetricks reply: {error}")))?;
    Ok(start.job_id)
}

fn load_installed_winetricks(
    client: &mut Client,
    container: &str,
) -> Result<InstalledDto, CallFailure> {
    // The helper may run `winetricks list-installed`, which has its own 30 s
    // bound. The default 5 s call timeout would kill the session before that
    // read can fall back to the log parser.
    let reply = client
        .call_with_timeout(
            "winetricks.installed",
            json!({ "container": container }),
            Duration::from_secs(45),
        )
        .map_err(classify)?;
    serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid installed verbs reply: {error}")))
}

fn poll_winetricks(
    client: &mut Client,
    active: &mut LiveWinetricks,
    events: &smol::channel::Sender<BridgeEvent>,
) -> Result<Option<WinetricksTerminal>, CallFailure> {
    let reply = client
        .call("jobs.get", json!({ "jobID": active.job_id }))
        .map_err(classify)?;
    let job: JobDto = serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid job payload: {error}")))?;
    let status = JobStatus::from_wire(&job.status).ok_or_else(|| {
        CallFailure::Remote(format!("unknown job status: {}", job.status))
    })?;
    let progress = InstallProgress::from_value(&job.progress);
    if active.last.as_ref() != Some(&(status, progress.clone())) {
        emit_event(
            events,
            BridgeEvent::WinetricksInstall {
                container: active.container.clone(),
                update: winetricks::InstallUpdate::Progress {
                    status,
                    progress: progress.clone(),
                },
            },
        );
        active.last = Some((status, progress));
    }
    active.due = Instant::now() + SCAN_POLL;
    match status {
        JobStatus::Completed => {
            let result = job
                .result
                .ok_or_else(|| CallFailure::Remote("completed install has no result".into()))?;
            let result: InstallResultDto = serde_json::from_value(result).map_err(|error| {
                CallFailure::Remote(format!("invalid winetricks result: {error}"))
            })?;
            Ok(Some(WinetricksTerminal::Completed(result)))
        }
        JobStatus::Failed | JobStatus::Cancelled => {
            let reason = job
                .error
                .as_ref()
                .map(|error| {
                    // The helper distinguishes a broken prefix from a plain
                    // winetricks failure; turn it into the repair action the
                    // SwiftUI alert offers.
                    if error.code == "prefix_invalid" {
                        "容器前缀不完整或已损坏，请先在容器页执行「修复容器」，然后重试"
                            .to_owned()
                    } else {
                        error.reason()
                    }
                })
                .unwrap_or_else(|| match status {
                    JobStatus::Cancelled => "已取消".to_owned(),
                    _ => "安装失败".to_owned(),
                });
            Ok(Some(WinetricksTerminal::Failed { status, reason }))
        }
        JobStatus::Queued | JobStatus::Running | JobStatus::Cancelling => Ok(None),
    }
}

enum CreateTerminal {
    Completed { path: String, name: String },
    Failed { status: JobStatus, reason: String },
}

fn poll_create(
    client: &mut Client,
    create: &mut LiveCreate,
    events: &smol::channel::Sender<BridgeEvent>,
) -> Result<Option<CreateTerminal>, CallFailure> {
    let reply = client
        .call("jobs.get", json!({ "jobID": create.job_id }))
        .map_err(classify)?;
    let job: JobDto = serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid job payload: {error}")))?;
    let status = JobStatus::from_wire(&job.status).ok_or_else(|| {
        CallFailure::Remote(format!("unknown job status: {}", job.status))
    })?;
    let stage = job.stage().map(str::to_owned);
    if create.last.as_ref() != Some(&(status, stage.clone())) {
        emit_event(
            events,
            BridgeEvent::BottleCreate {
                update: BottleCreateUpdate::Progress {
                    status,
                    stage: stage.clone(),
                },
            },
        );
        create.last = Some((status, stage));
    }
    create.due = Instant::now() + SCAN_POLL;
    match status {
        JobStatus::Completed => {
            let result = job
                .result
                .ok_or_else(|| CallFailure::Remote("completed create has no result".into()))?;
            let result: BottleCreatedDto = serde_json::from_value(result)
                .map_err(|error| CallFailure::Remote(format!("invalid create result: {error}")))?;
            Ok(Some(CreateTerminal::Completed {
                path: result.path,
                name: result.name,
            }))
        }
        JobStatus::Failed | JobStatus::Cancelled => {
            let reason = job
                .error
                .as_ref()
                .map(BridgeFailureDto::reason)
                .unwrap_or_else(|| {
                    crate::create_bottle::progress_label(status, None).to_owned()
                });
            Ok(Some(CreateTerminal::Failed { status, reason }))
        }
        JobStatus::Queued | JobStatus::Running | JobStatus::Cancelling => Ok(None),
    }
}

enum ScanTerminal {
    Completed { snapshot_id: String, total: u64 },
    Failed { status: JobStatus, reason: String },
}

enum ProgramRunPoll {
    Pending,
    /// Started (or already exited) successfully; stop watching.
    Finished,
    Failed(String),
}

/// Watch a launched file only until the startup grace expires. After that the
/// job is left alone so a long-running game costs no polls.
fn poll_program_run(
    client: &mut Client,
    run: &mut LiveProgramRun,
) -> Result<ProgramRunPoll, CallFailure> {
    if Instant::now() >= run.deadline {
        return Ok(ProgramRunPoll::Finished);
    }
    let reply = client
        .call("jobs.get", json!({ "jobID": run.job_id }))
        .map_err(classify)?;
    let job: JobDto = serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid job payload: {error}")))?;
    run.due = Instant::now() + PROGRAM_RUN_POLL;
    match job.status.as_str() {
        "failed" | "cancelled" => Ok(ProgramRunPoll::Failed(
            job.error
                .as_ref()
                .map(BridgeFailureDto::reason)
                .unwrap_or_else(|| job.status),
        )),
        "completed" => Ok(ProgramRunPoll::Finished),
        "queued" | "running" | "cancelling" => Ok(ProgramRunPoll::Pending),
        other => Err(CallFailure::Remote(format!("unknown job status: {other}"))),
    }
}

fn poll_scan(
    client: &mut Client,
    scan: &mut LiveScan,
    events: &smol::channel::Sender<BridgeEvent>,
) -> Result<Option<ScanTerminal>, CallFailure> {
    let reply = client
        .call("jobs.get", json!({ "jobID": scan.job_id }))
        .map_err(classify)?;
    let job: JobDto = serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid job payload: {error}")))?;
    let status = JobStatus::from_wire(&job.status).ok_or_else(|| {
        CallFailure::Remote(format!("unknown job status: {}", job.status))
    })?;
    let stage = job.stage().map(str::to_owned);
    if scan.last.as_ref() != Some(&(status, stage.clone())) {
        emit_event(
            events,
            BridgeEvent::Scan {
                container: scan.container.clone(),
                update: ScanUpdate::Progress {
                    status,
                    stage: stage.clone(),
                    loaded: None,
                    total: None,
                },
            },
        );
        scan.last = Some((status, stage));
    }
    scan.due = Instant::now() + SCAN_POLL;
    match status {
        JobStatus::Completed => {
            let result = job
                .result
                .ok_or_else(|| CallFailure::Remote("completed scan has no result".into()))?;
            let result: ScanResultDto = serde_json::from_value(result)
                .map_err(|error| CallFailure::Remote(format!("invalid scan result: {error}")))?;
            Ok(Some(ScanTerminal::Completed {
                snapshot_id: result.snapshot_id,
                total: result.total,
            }))
        }
        JobStatus::Failed | JobStatus::Cancelled => {
            let reason = job
                .error
                .as_ref()
                .map(BridgeFailureDto::reason)
                .unwrap_or_else(|| status.label().to_owned());
            Ok(Some(ScanTerminal::Failed { status, reason }))
        }
        JobStatus::Queued | JobStatus::Running | JobStatus::Cancelling => Ok(None),
    }
}

/// Walk `library.page` from offset 0 until `nextOffset` is null.
fn collect_pages(
    client: &mut Client,
    container: &str,
    snapshot_id: &str,
    total: u64,
    events: &smol::channel::Sender<BridgeEvent>,
) -> Result<Vec<EntryDto>, CallFailure> {
    let mut accumulator = PageAccumulator::start(total);
    loop {
        let reply = client
            .call(
                "library.page",
                scan::page_payload(snapshot_id, accumulator.offset, config::PAGE_LIMIT),
            )
            .map_err(classify)?;
        let page: LibraryPageDto = serde_json::from_value(reply)
            .map_err(|error| CallFailure::Remote(format!("invalid library page: {error}")))?;
        let next = accumulator.apply(&page).map_err(CallFailure::Remote)?;
        // One event per ten pages keeps the channel quiet on a large catalogue
        // without leaving the sheet frozen.
        if accumulator.loaded() % (config::PAGE_LIMIT as usize * 10) == 0
            || next.is_none()
        {
            emit_event(
                events,
                BridgeEvent::Scan {
                    container: container.to_owned(),
                    update: ScanUpdate::Progress {
                        status: JobStatus::Running,
                        stage: Some("paging".into()),
                        loaded: Some(accumulator.loaded()),
                        total: Some(accumulator.total),
                    },
                },
            );
        }
        if next.is_none() {
            return Ok(accumulator.into_entries());
        }
    }
}

fn runtime_launch(
    client: &mut Client,
    params: serde_json::Value,
    container: &str,
    entry_id: &str,
    executable: Option<&str>,
    events: &smol::channel::Sender<BridgeEvent>,
) -> Result<(), CallFailure> {
    let value = client.call("runtime.launch", params).map_err(classify)?;
    let reply: LaunchReplyDto = serde_json::from_value(value)
        .map_err(|error| CallFailure::Remote(format!("invalid launch payload: {error}")))?;
    match interpret_launch_reply(container, entry_id, executable, reply) {
        LaunchOutcome::Accepted => Ok(()),
        LaunchOutcome::Prompt(prompt) => {
            emit_event(events, BridgeEvent::ClipboardPrompt(prompt));
            Ok(())
        }
        LaunchOutcome::Rejected => Err(CallFailure::Remote(format!(
            "The helper did not accept the launch of {entry_id}."
        ))),
    }
}

fn runtime_control(
    client: &mut Client,
    method: &str,
    container: &str,
    entry_id: &str,
) -> Result<(), CallFailure> {
    let value = client
        .call(method, json!({ "container": container, "entryID": entry_id }))
        .map_err(classify)?;
    let accepted = value
        .get("accepted")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    if !accepted {
        return Err(CallFailure::Remote(format!(
            "{method} was not accepted for {entry_id}"
        )));
    }
    Ok(())
}

/// Surface a failure, then wait for the next automatic or manual attempt.
/// Returns true when the worker must stop.
fn fail_and_wait(
    events: &smol::channel::Sender<BridgeEvent>,
    commands: &CommandReceiver<Command>,
    attempt: &mut u32,
    reason: String,
    retryable: bool,
    foreground: &mut bool,
) -> bool {
    emit(
        events,
        BridgeStatus::Failed {
            reason,
            retryable,
        },
    );
    match wait(commands, backoff_delay(*attempt), foreground) {
        Wake::Stop => true,
        Wake::Retry => {
            *attempt = 0;
            false
        }
        Wake::Timeout => {
            *attempt = attempt.saturating_add(1);
            false
        }
    }
}

fn wait(commands: &CommandReceiver<Command>, delay: Duration, foreground: &mut bool) -> Wake {
    let deadline = Instant::now() + delay;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match commands.recv_timeout(remaining) {
            Ok(Command::Retry) => return Wake::Retry,
            Ok(Command::Shutdown) | Ok(Command::ShutdownApplication) | Err(RecvTimeoutError::Disconnected) => {
                return Wake::Stop;
            }
            // Activation is the only command that outlives the session.
            Ok(Command::SetActive(active)) => *foreground = active,
            // Reads and runtime intents queued for the failed session are
            // dropped; the catalogue event after reconnecting makes the UI
            // issue fresh requests.
            Ok(_) => {}
            Err(RecvTimeoutError::Timeout) => return Wake::Timeout,
        }
    }
}

fn emit(events: &smol::channel::Sender<BridgeEvent>, status: BridgeStatus) {
    let _ = events.send_blocking(BridgeEvent::Status(status));
}

fn emit_event(events: &smol::channel::Sender<BridgeEvent>, event: BridgeEvent) {
    let _ = events.send_blocking(event);
}

/// A remote error leaves the session usable; anything else ends it.
enum CallFailure {
    Remote(String),
    Session(String),
}

impl CallFailure {
    fn into_message(self) -> String {
        match self {
            Self::Remote(message) | Self::Session(message) => message,
        }
    }
}

fn classify(error: whisky_bridge::Error) -> CallFailure {
    match error {
        whisky_bridge::Error::Remote(error) => {
            CallFailure::Remote(format!("{}: {}", error.code, error.message))
        }
        other => CallFailure::Session(other.to_string()),
    }
}

/// Recovery is a retained helper job so each IPC call remains bounded while
/// a large interrupted copy or removal is cleaned before catalogues load.
fn recover_workspace(client: &mut Client) -> Result<(), CallFailure> {
    if !client
        .capabilities()
        .methods
        .iter()
        .any(|method| method == "workspace.recover")
    {
        return Ok(());
    }
    loop {
        let start = client
            .call("workspace.recover", json!({}))
            .map_err(classify)?;
        let Some(id) = start.get("jobID").and_then(serde_json::Value::as_str) else {
            return Ok(());
        };
        loop {
            let value = client
                .call("jobs.get", json!({ "jobID": id }))
                .map_err(classify)?;
            let job: JobDto = serde_json::from_value(value).map_err(|error| {
                CallFailure::Remote(format!("invalid recovery payload: {error}"))
            })?;
            match JobStatus::from_wire(&job.status) {
                Some(JobStatus::Completed) => return Ok(()),
                Some(JobStatus::Failed)
                    if job.error.as_ref().is_some_and(|error| error.code == "busy") =>
                {
                    break
                }
                Some(JobStatus::Failed | JobStatus::Cancelled) => {
                    return Err(CallFailure::Remote(
                        job.error
                            .as_ref()
                            .map(BridgeFailureDto::reason)
                            .unwrap_or_else(|| {
                                "Workspace recovery failed; inspect its retained journal".into()
                            }),
                    ));
                }
                Some(JobStatus::Queued | JobStatus::Running | JobStatus::Cancelling) => {}
                None => {
                    return Err(CallFailure::Remote(format!(
                        "unknown recovery status: {}",
                        job.status
                    )))
                }
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

fn fetch_containers(client: &mut Client) -> Result<ContainerList, CallFailure> {
    recover_workspace(client)?;
    let value = client
        .call("workspace.containers", json!({}))
        .map_err(classify)?;
    serde_json::from_value(value)
        .map_err(|error| CallFailure::Remote(format!("invalid container payload: {error}")))
}

fn fetch_entries(client: &mut Client, container: &str) -> Result<EntryList, CallFailure> {
    let value = client
        .call("library.entries", json!({ "container": container }))
        .map_err(classify)?;
    serde_json::from_value(value)
        .map_err(|error| CallFailure::Remote(format!("invalid library payload: {error}")))
}

fn fetch_programs(client: &mut Client, container: &str) -> Result<Vec<ProgramDto>, CallFailure> {
    let value = client
        .call("programs.list", json!({ "container": container }))
        .map_err(classify)?;
    serde_json::from_value(value)
        .map_err(|error| CallFailure::Remote(format!("invalid programs payload: {error}")))
}

fn fetch_processes(client: &mut Client, container: &str) -> Result<Vec<ProcessDto>, CallFailure> {
    let value = client
        .call("processes.list", json!({ "container": container }))
        .map_err(classify)?;
    serde_json::from_value(value)
        .map_err(|error| CallFailure::Remote(format!("invalid processes payload: {error}")))
}

/// Read the schema and the stored values in one worker slot. `preferences.read`
/// returns every key the helper knows, so the request carries no filter; the
/// `keys` array is still sent for forward compatibility.
fn load_preferences(
    client: &mut Client,
) -> Result<(serde_json::Value, PreferencesSchemaDto), CallFailure> {
    let schema = client
        .call("preferences.schema", json!({}))
        .map_err(classify)?;
    let schema: PreferencesSchemaDto = serde_json::from_value(schema)
        .map_err(|error| CallFailure::Remote(format!("invalid preferences schema: {error}")))?;
    let keys = schema.keys().map(str::to_owned).collect::<Vec<_>>();
    let values = client
        .call("preferences.read", json!({ "keys": keys }))
        .map_err(classify)?;
    if !values.is_object() {
        return Err(CallFailure::Remote(
            "preferences.read did not return an object".into(),
        ));
    }
    Ok((values, schema))
}

fn load_system_info(client: &mut Client) -> Result<SystemInfoDto, CallFailure> {
    let value = client
        .call("system.info", json!({}))
        .map_err(classify)?;
    serde_json::from_value(value)
        .map_err(|error| CallFailure::Remote(format!("invalid system info payload: {error}")))
}

fn log_container_names(containers: &[Container]) {    let names = containers
        .iter()
        .map(|container| container.name.as_str())
        .collect::<Vec<_>>()
        .join(", ");
    eprintln!(
        "whisky-bridge: {} container(s): {}",
        containers.len(),
        if names.is_empty() { "(none)" } else { &names }
    );
}

/// Capped exponential backoff: 500 ms, 1 s, 2 s, 4 s, then 8 s.
pub(crate) fn backoff_delay(attempt: u32) -> Duration {
    let exponent = attempt.min(4);
    let millis = BACKOFF_MIN_MS.saturating_mul(1_u64 << exponent);
    Duration::from_millis(millis.min(BACKOFF_MAX_MS))
}

/// Arguments passed to every helper spawn.
///
/// On macOS Wine host effects (`bottle.create`, configuration side effects,
/// process kill) require `--enable-wine`. Opt out with `WHISKY_BRIDGE_NO_WINE=1`.
fn helper_arguments() -> Vec<String> {
    #[cfg(target_os = "macos")]
    {
        let disabled = std::env::var_os("WHISKY_BRIDGE_NO_WINE").is_some_and(|value| {
            value == "1" || value.eq_ignore_ascii_case("true")
        });
        if !disabled {
            return vec!["--enable-wine".into()];
        }
    }
    Vec::new()
}

/// Resolve the helper in the documented order. Every candidate is checked with
/// `is_file`; no failure path panics.
pub(crate) fn locate_helper() -> Result<PathBuf, String> {
    if let Some(raw) = std::env::var_os("WHISKY_BRIDGE_HELPER") {
        let path = PathBuf::from(raw);
        if !path.is_absolute() {
            return Err(format!(
                "WHISKY_BRIDGE_HELPER must be an absolute path: {}",
                path.display()
            ));
        }
        if path.is_file() {
            return Ok(path);
        }
        return Err(format!(
            "WHISKY_BRIDGE_HELPER does not name a file: {}",
            path.display()
        ));
    }
    if let Ok(executable) = std::env::current_exe()
        && let Some(directory) = executable.parent()
    {
        let candidates = [
            directory.join(HELPER_PRODUCT),
            directory.join(format!("Contents/Resources/{HELPER_PRODUCT}")),
            directory
                .parent()
                .map(|contents| contents.join(format!("Resources/{HELPER_PRODUCT}")))
                .unwrap_or_default(),
        ];
        for candidate in candidates {
            if candidate.is_absolute() && candidate.is_file() {
                return Ok(candidate);
            }
        }
    }
    if let Some(root) = repository_root() {
        for profile in ["release", "debug"] {
            let candidate = root
                .join("WhiskyBridge/.build")
                .join(profile)
                .join(HELPER_PRODUCT);
            if candidate.is_file() {
                return Ok(candidate);
            }
        }
    }
    Err(format!(
        "whisky-bridge helper not found. Set WHISKY_BRIDGE_HELPER to an absolute path, \
         or build it with `swift build --package-path WhiskyBridge -c release`."
    ))
}

/// Walk up from this crate until the directory that contains the Swift package.
fn repository_root() -> Option<PathBuf> {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .find(|directory| directory.join("WhiskyBridge/Package.swift").is_file())
        .map(Path::to_path_buf)
}

/// `--print-bridge-status`: connect, validate, print the describe payload, and
/// report success through the process exit code.
pub(crate) fn print_status() -> i32 {
    let helper = match locate_helper() {
        Ok(helper) => helper,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            return 1;
        }
    };
    eprintln!("whisky-bridge: helper {}", helper.display());
    let mut client = match Client::spawn(&helper, &helper_arguments(), CALL_TIMEOUT) {
        Ok(client) => client,
        Err(error) => {
            eprintln!("whisky-bridge: handshake failed: {error}");
            return 1;
        }
    };
    let describe = DescribeResponse::from_capabilities(client.capabilities());
    let missing = describe.missing_required_methods();
    if !missing.is_empty() {
        eprintln!(
            "whisky-bridge: handshake is missing required method(s): {}",
            missing.join(", ")
        );
        client.close();
        return 1;
    }
    match serde_json::to_string_pretty(&describe) {
        Ok(payload) => println!("{payload}"),
        Err(error) => {
            eprintln!("whisky-bridge: cannot encode the describe payload: {error}");
            client.close();
            return 1;
        }
    }
    match fetch_containers(&mut client) {
        Ok(containers) => log_container_names(&containers),
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    }
    let _ = client.shutdown(false);
    0
}

/// `--print-runtime`: connect, check the runtime allow-list, read one
/// `runtime.snapshot`, and print it as JSON. Safe with no game running: the
/// payload only reports the configured entries and the event cursor.
pub(crate) fn print_runtime() -> i32 {
    let helper = match locate_helper() {
        Ok(helper) => helper,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            return 1;
        }
    };
    eprintln!("whisky-bridge: helper {}", helper.display());
    let mut client = match Client::spawn(&helper, &helper_arguments(), CALL_TIMEOUT) {
        Ok(client) => client,
        Err(error) => {
            eprintln!("whisky-bridge: handshake failed: {error}");
            return 1;
        }
    };
    let describe = DescribeResponse::from_capabilities(client.capabilities());
    let missing = describe.missing_methods(RUNTIME_METHODS);
    if !missing.is_empty() {
        eprintln!(
            "whisky-bridge: helper does not advertise runtime method(s): {}",
            missing.join(", ")
        );
        client.close();
        return 1;
    }
    let payload = match client.call("runtime.snapshot", json!({})) {
        Ok(payload) => payload,
        Err(error) => {
            eprintln!(
                "whisky-bridge: runtime.snapshot failed: {}",
                classify(error).into_message()
            );
            client.close();
            return 1;
        }
    };
    let snapshot: RuntimeSnapshotDto = match serde_json::from_value(payload.clone()) {
        Ok(snapshot) => snapshot,
        Err(error) => {
            eprintln!("whisky-bridge: invalid runtime snapshot: {error}");
            client.close();
            return 1;
        }
    };
    eprintln!(
        "whisky-bridge: runtime sequence {}, {} entry(ies), {} query failure(s)",
        snapshot.sequence,
        snapshot.entries.len(),
        snapshot.query_failures.len()
    );
    for entry in &snapshot.entries {
        eprintln!(
            "whisky-bridge:   {} state={} capabilities={}",
            entry.id, entry.state, entry.capabilities
        );
    }
    for (container, failure) in &snapshot.query_failures {
        eprintln!("whisky-bridge:   {container}: {failure}");
    }
    match serde_json::to_string_pretty(&payload) {
        Ok(rendered) => println!("{rendered}"),
        Err(error) => {
            eprintln!("whisky-bridge: cannot encode the runtime snapshot: {error}");
            client.close();
            return 1;
        }
    }
    let _ = client.shutdown(false);
    0
}

/// How often `--runtime-watch` reads the cursor. Deliberately faster than the
/// app's cadence so a short observation window shows something.
const WATCH_INTERVAL: Duration = Duration::from_millis(500);

/// `--runtime-watch --seconds N [--bottle <name-or-path>]`: configure one
/// bottle, poll `runtime.events`, and print each entry's state when it changes.
///
/// Observation only. Nothing here calls `runtime.launch`, so no game and no
/// Steam client can start; the command exists to prove the cursor moves and the
/// snapshot shape matches what the UI stores.
pub(crate) fn watch_runtime(bottle: Option<&str>, seconds: u64) -> i32 {
    let helper = match locate_helper() {
        Ok(helper) => helper,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            return 1;
        }
    };
    eprintln!("whisky-bridge: helper {}", helper.display());
    let mut client = match Client::spawn(&helper, &helper_arguments(), CALL_TIMEOUT) {
        Ok(client) => client,
        Err(error) => {
            eprintln!("whisky-bridge: handshake failed: {error}");
            return 1;
        }
    };
    let describe = DescribeResponse::from_capabilities(client.capabilities());
    let missing = describe.missing_methods(RUNTIME_SESSION_METHODS);
    if !missing.is_empty() {
        eprintln!(
            "whisky-bridge: helper does not advertise runtime method(s): {}",
            missing.join(", ")
        );
        client.close();
        return 1;
    }
    let containers = match fetch_containers(&mut client) {
        Ok(containers) => containers,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let container = match pick_container(&containers, bottle) {
        Ok(container) => container,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            client.close();
            return 1;
        }
    };
    eprintln!(
        "whisky-bridge: watching {} for {seconds}s (observation only; no game is launched)",
        container.name
    );
    let snapshot = match configure_runtime(&mut client, &container.path) {
        Ok(snapshot) => snapshot,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let mut previous = BTreeMap::new();
    let mut changes = print_watch_delta(&snapshot, &mut previous);
    let mut cursor = snapshot.sequence.clone();
    let deadline = Instant::now() + Duration::from_secs(seconds);
    let mut polls = 0_u32;
    while Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(Instant::now());
        std::thread::sleep(remaining.min(WATCH_INTERVAL));
        if Instant::now() >= deadline {
            break;
        }
        match watch_poll(&mut client, &mut cursor) {
            Ok((snapshot, resync)) => {
                if resync {
                    eprintln!("whisky-bridge: resync required; state replaced");
                }
                changes += print_watch_delta(&snapshot, &mut previous);
            }
            Err(failure) => {
                // A failed poll must not end the watch; the next tick retries.
                eprintln!("whisky-bridge: poll failed: {}", failure.into_message());
            }
        }
        polls += 1;
    }
    println!(
        "runtime: {polls} poll(s), {changes} state change(s), sequence {cursor}"
    );
    let _ = client.shutdown(false);
    0
}

fn pick_container<'a>(
    containers: &'a [Container],
    selector: Option<&str>,
) -> Result<&'a Container, String> {
    match selector {
        Some(selector) => containers
            .iter()
            .find(|container| container.name == selector || container.path == selector)
            .ok_or_else(|| format!("no container named or located at {selector}")),
        None => containers
            .iter()
            .find(|container| container.available)
            .ok_or_else(|| "no available container to watch".to_owned()),
    }
}

fn watch_poll(
    client: &mut Client,
    cursor: &mut String,
) -> Result<(RuntimeSnapshotDto, bool), CallFailure> {
    let value = client
        .call("runtime.events", json!({ "after": cursor }))
        .map_err(classify)?;
    let batch: RuntimeEventBatchDto = serde_json::from_value(value)
        .map_err(|error| CallFailure::Remote(format!("invalid runtime events payload: {error}")))?;
    if !batch.sequence.is_empty() {
        *cursor = batch.sequence;
    }
    let snapshot = batch.snapshot.ok_or_else(|| {
        CallFailure::Remote("runtime.events returned no snapshot".to_owned())
    })?;
    Ok((snapshot, batch.resync_required))
}

/// Print only what changed since the previous snapshot, one line per entry.
fn print_watch_delta(
    snapshot: &RuntimeSnapshotDto,
    previous: &mut BTreeMap<String, String>,
) -> u32 {
    let mut changes = 0;
    let mut current = BTreeMap::new();
    for entry in &snapshot.entries {
        current.insert(entry.id.clone(), entry.state.clone());
        if previous.get(&entry.id) != Some(&entry.state) {
            println!("runtime: entry {} state={}", entry.id, entry.state);
            changes += 1;
        }
    }
    for id in previous.keys() {
        if !current.contains_key(id) {
            println!("runtime: entry {id} removed");
            changes += 1;
        }
    }
    println!(
        "runtime: sequence {} · {} entry(ies)",
        snapshot.sequence,
        snapshot.entries.len()
    );
    for (container, failure) in &snapshot.query_failures {
        println!("runtime: query failure {container}: {failure}");
    }
    *previous = current;
    changes
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LibrarySummary {
    containers: Vec<BottleSummary>,
    /// Present with `--all`: the merged view the Library page renders.
    #[serde(skip_serializing_if = "Option::is_none")]
    all: Option<AllBottlesSummary>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AllBottlesSummary {
    /// Every entry across every bottle, before display de-duplication.
    total: usize,
    per_bottle: Vec<PerBottleCount>,
}

#[derive(Serialize)]
struct PerBottleCount {
    name: String,
    entries: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BottleSummary {
    path: String,
    name: String,
    available: bool,
    entry_count: usize,
    /// First five entry names, so a headless run shows what the grid will show.
    sample: Vec<String>,
}

/// `--print-library [--bottle <name-or-path>] [--all]`: read-only, no window.
/// Prints containers and their entry counts as JSON; failures go to stderr.
/// `all` merges every bottle and adds the total plus per-bottle counts.
pub(crate) fn print_library(bottle: Option<&str>, all: bool) -> i32 {
    let helper = match locate_helper() {
        Ok(helper) => helper,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            return 1;
        }
    };
    eprintln!("whisky-bridge: helper {}", helper.display());
    let mut client = match Client::spawn(&helper, &helper_arguments(), CALL_TIMEOUT) {
        Ok(client) => client,
        Err(error) => {
            eprintln!("whisky-bridge: handshake failed: {error}");
            return 1;
        }
    };
    let describe = DescribeResponse::from_capabilities(client.capabilities());
    let missing = describe.missing_required_methods();
    if !missing.is_empty() {
        eprintln!(
            "whisky-bridge: handshake is missing required method(s): {}",
            missing.join(", ")
        );
        client.close();
        return 1;
    }
    let mut containers = match fetch_containers(&mut client) {
        Ok(containers) => containers,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    if let Some(selector) = bottle.filter(|_| !all) {
        let matched: Vec<_> = containers
            .into_iter()
            .filter(|container| container.name == selector || container.path == selector)
            .collect();
        if matched.is_empty() {
            eprintln!("whisky-bridge: no container named or located at {selector}");
            client.close();
            return 1;
        }
        containers = matched;
    }
    let mut summaries = Vec::with_capacity(containers.len());
    for container in containers {
        let entries = if container.available {
            match fetch_entries(&mut client, &container.path) {
                Ok(entries) => entries,
                Err(failure) => {
                    eprintln!(
                        "whisky-bridge: library.entries failed for {}: {}",
                        container.name,
                        failure.into_message()
                    );
                    client.close();
                    return 1;
                }
            }
        } else {
            Vec::new()
        };
        summaries.push(BottleSummary {
            path: container.path,
            name: container.name,
            available: container.available,
            entry_count: entries.len(),
            sample: entries
                .iter()
                .take(5)
                .map(|entry| entry.name.clone())
                .collect(),
        });
    }
    let summary = LibrarySummary {
        all: all.then(|| AllBottlesSummary {
            total: summaries.iter().map(|bottle| bottle.entry_count).sum(),
            per_bottle: summaries
                .iter()
                .map(|bottle| PerBottleCount {
                    name: bottle.name.clone(),
                    entries: bottle.entry_count,
                })
                .collect(),
        }),
        containers: summaries,
    };
    match serde_json::to_string_pretty(&summary) {
        Ok(payload) => println!("{payload}"),
        Err(error) => {
            eprintln!("whisky-bridge: cannot encode the library summary: {error}");
            client.close();
            return 1;
        }
    }
    let _ = client.shutdown(false);
    0
}

/// `--print-config [--bottle <name-or-path>]`: read the schema and the stored
/// values, then print the field count, the kind histogram and three samples as
/// JSON. Read-only: it never calls `configuration.set` or a scan.
pub(crate) fn print_config(bottle: Option<&str>) -> i32 {
    let helper = match locate_helper() {
        Ok(helper) => helper,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            return 1;
        }
    };
    eprintln!("whisky-bridge: helper {}", helper.display());
    let mut client = match Client::spawn(&helper, &helper_arguments(), CALL_TIMEOUT) {
        Ok(client) => client,
        Err(error) => {
            eprintln!("whisky-bridge: handshake failed: {error}");
            return 1;
        }
    };
    let describe = DescribeResponse::from_capabilities(client.capabilities());
    let missing = describe.missing_methods(&["configuration.schema", "configuration.read"]);
    if !missing.is_empty() {
        eprintln!(
            "whisky-bridge: helper does not advertise configuration method(s): {}",
            missing.join(", ")
        );
        client.close();
        return 1;
    }
    let containers = match fetch_containers(&mut client) {
        Ok(containers) => containers,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let container = match pick_container(&containers, bottle) {
        Ok(container) => container,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            client.close();
            return 1;
        }
    };
    let (fields, values) = match load_configuration(&mut client, &container.path, &describe) {
        Ok(configuration) => configuration,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let sections: Vec<serde_json::Value> = config::group_sections(&fields)
        .into_iter()
        .map(|section| {
            json!({
                "id": section.spec.id,
                "title": section.spec.title,
                "fields": section.fields.len(),
            })
        })
        .collect();
    let samples: Vec<serde_json::Value> = fields
        .iter()
        .take(3)
        .map(|field| {
            json!({
                "id": field.id,
                "title": field.title,
                "titleKey": field.title_key,
                "kind": field.kind.name(),
                "default": field.default,
                "value": values.get(&field.id).cloned().unwrap_or(serde_json::Value::Null),
                "requires": field.requires,
            })
        })
        .collect();
    let report = json!({
        "bottle": container.name,
        "container": container.path,
        "platform": describe.platform,
        "fieldCount": fields.len(),
        "kinds": config::kind_histogram(&fields),
        "sections": sections,
        "disabledFields": fields
            .iter()
            .filter(|field| !field.enabled(&describe.capabilities))
            .map(|field| field.id.clone())
            .collect::<Vec<_>>(),
        "samples": samples,
    });
    match serde_json::to_string_pretty(&report) {
        Ok(payload) => println!("{payload}"),
        Err(error) => {
            eprintln!("whisky-bridge: cannot encode the configuration report: {error}");
            client.close();
            return 1;
        }
    }
    eprintln!(
        "whisky-bridge: {} field(s), {} section(s)",
        fields.len(),
        config::group_sections(&fields).len()
    );
    let _ = client.shutdown(false);
    0
}

/// `--print-folders [--bottle <name-or-path>]`: roots with their assignment,
/// exclusion and executable, plus every list the helper stores. Read-only.
pub(crate) fn print_folders(bottle: Option<&str>) -> i32 {
    let helper = match locate_helper() {
        Ok(helper) => helper,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            return 1;
        }
    };
    eprintln!("whisky-bridge: helper {}", helper.display());
    let mut client = match Client::spawn(&helper, &helper_arguments(), CALL_TIMEOUT) {
        Ok(client) => client,
        Err(error) => {
            eprintln!("whisky-bridge: handshake failed: {error}");
            return 1;
        }
    };
    let describe = DescribeResponse::from_capabilities(client.capabilities());
    let missing = describe.missing_methods(&["folders.read"]);
    if !missing.is_empty() {
        eprintln!(
            "whisky-bridge: helper does not advertise folder method(s): {}",
            missing.join(", ")
        );
        client.close();
        return 1;
    }
    let containers = match fetch_containers(&mut client) {
        Ok(containers) => containers,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let container = match pick_container(&containers, bottle) {
        Ok(container) => container,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            client.close();
            return 1;
        }
    };
    let folders = match load_folders(&mut client, &container.path) {
        Ok(folders) => folders,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let roots: Vec<serde_json::Value> = folders
        .roots
        .iter()
        .map(|root| {
            json!({
                "path": root,
                "assigned": folders.is_assigned(root),
                "excluded": folders.is_excluded(root),
                "executable": folders.executable_for(root),
            })
        })
        .collect();
    let report = json!({
        "bottle": container.name,
        "container": container.path,
        "automaticMetadata": folders.automatic_metadata,
        "rootCount": folders.roots.len(),
        "roots": roots,
        "assignedFolders": folders.assigned_folders,
        "excludedFolders": folders.excluded_folders,
        "executables": folders.executables,
        "knownFolderCount": folders.known_folders.len(),
    });
    match serde_json::to_string_pretty(&report) {
        Ok(payload) => println!("{payload}"),
        Err(error) => {
            eprintln!("whisky-bridge: cannot encode the folders report: {error}");
            client.close();
            return 1;
        }
    }
    eprintln!(
        "whisky-bridge: {} root(s), {} assigned, {} excluded",
        folders.roots.len(),
        folders.assigned_folders.len(),
        folders.excluded_folders.len()
    );
    let _ = client.shutdown(false);
    0
}

/// `--print-winetricks [--bottle <name-or-path>]`: the bundled catalog
/// categories and one bottle's installed verbs. Read-only.
pub(crate) fn print_winetricks(bottle: Option<&str>) -> i32 {
    let helper = match locate_helper() {
        Ok(helper) => helper,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            return 1;
        }
    };
    eprintln!("whisky-bridge: helper {}", helper.display());
    let mut client = match Client::spawn(&helper, &helper_arguments(), CALL_TIMEOUT) {
        Ok(client) => client,
        Err(error) => {
            eprintln!("whisky-bridge: handshake failed: {error}");
            return 1;
        }
    };
    let describe = DescribeResponse::from_capabilities(client.capabilities());
    let missing = describe.missing_methods(&["winetricks.catalog", "winetricks.installed"]);
    if !missing.is_empty() {
        eprintln!(
            "whisky-bridge: helper does not advertise winetricks method(s): {}",
            missing.join(", ")
        );
        client.close();
        return 1;
    }
    let containers = match fetch_containers(&mut client) {
        Ok(containers) => containers,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let container = match pick_container(&containers, bottle) {
        Ok(container) => container,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            client.close();
            return 1;
        }
    };
    let catalog = match client.call("winetricks.catalog", json!({})).map_err(classify) {
        Ok(reply) => match serde_json::from_value::<CatalogDto>(reply) {
            Ok(catalog) => catalog,
            Err(error) => {
                eprintln!("whisky-bridge: invalid winetricks catalog: {error}");
                client.close();
                return 1;
            }
        },
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let installed = match load_installed_winetricks(&mut client, &container.path) {
        Ok(installed) => installed,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let categories: Vec<serde_json::Value> = catalog
        .categories
        .iter()
        .map(|category| {
            json!({
                "id": category.id,
                "verbs": category.verbs.len(),
                "sample": category.verbs.iter().take(3).map(|verb| &verb.name).collect::<Vec<_>>(),
            })
        })
        .collect();
    let report = json!({
        "bottle": container.name,
        "container": container.path,
        "catalog": {
            "categories": categories,
            "verbCount": catalog.verb_count(),
        },
        "installed": installed.verbs,
        "installedFromCache": installed.from_cache,
    });
    match serde_json::to_string_pretty(&report) {
        Ok(payload) => println!("{payload}"),
        Err(error) => {
            eprintln!("whisky-bridge: cannot encode the winetricks report: {error}");
            client.close();
            return 1;
        }
    }
    eprintln!(
        "whisky-bridge: {} categories, {} verbs, {} installed",
        catalog.categories.len(),
        catalog.verb_count(),
        installed.verbs.len()
    );
    let _ = client.shutdown(false);
    0
}

/// `--print-programs [--bottle <name-or-path>]`: the bottle's installed
/// programs with their pin/block state, as counts plus a five-row sample.
/// Read-only: it never calls `programs.pin` or `programs.block`.
pub(crate) fn print_programs(bottle: Option<&str>) -> i32 {
    let helper = match locate_helper() {
        Ok(helper) => helper,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            return 1;
        }
    };
    eprintln!("whisky-bridge: helper {}", helper.display());
    let mut client = match Client::spawn(&helper, &helper_arguments(), CALL_TIMEOUT) {
        Ok(client) => client,
        Err(error) => {
            eprintln!("whisky-bridge: handshake failed: {error}");
            return 1;
        }
    };
    let describe = DescribeResponse::from_capabilities(client.capabilities());
    let missing = describe.missing_methods(&["programs.list"]);
    if !missing.is_empty() {
        eprintln!(
            "whisky-bridge: helper does not advertise program method(s): {}",
            missing.join(", ")
        );
        client.close();
        return 1;
    }
    let containers = match fetch_containers(&mut client) {
        Ok(containers) => containers,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let container = match pick_container(&containers, bottle) {
        Ok(container) => container,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            client.close();
            return 1;
        }
    };
    let programs = match fetch_programs(&mut client, &container.path) {
        Ok(programs) => programs,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let sample: Vec<serde_json::Value> = programs
        .iter()
        .take(5)
        .map(|program| {
            json!({
                "name": program.name,
                "path": program.path,
                "pinned": program.pinned,
                "blocked": program.blocked,
                "available": program.available,
            })
        })
        .collect();
    let report = json!({
        "bottle": container.name,
        "container": container.path,
        "programCount": programs.len(),
        "pinnedCount": programs.iter().filter(|program| program.pinned).count(),
        "blockedCount": programs.iter().filter(|program| program.blocked).count(),
        "sample": sample,
    });
    match serde_json::to_string_pretty(&report) {
        Ok(payload) => println!("{payload}"),
        Err(error) => {
            eprintln!("whisky-bridge: cannot encode the programs report: {error}");
            client.close();
            return 1;
        }
    }
    eprintln!(
        "whisky-bridge: {} program(s), {} pinned, {} blocked",
        programs.len(),
        programs.iter().filter(|program| program.pinned).count(),
        programs.iter().filter(|program| program.blocked).count()
    );
    let _ = client.shutdown(false);
    0
}

/// A PID that cannot name a real Wine process: the kill probe must never
/// signal anything, so it picks `Int32::MAX` and only reads the reply.
const BOGUS_PID: i64 = 2_147_483_647;

/// `--print-processes [--bottle <name-or-path>]`: one `processes.list`
/// snapshot plus a `processes.kill` probe against [`BOGUS_PID`]. Observation
/// only: no game is launched and nothing real is ever signalled. An empty
/// list is a legitimate answer and still exits 0.
pub(crate) fn print_processes(bottle: Option<&str>) -> i32 {
    let helper = match locate_helper() {
        Ok(helper) => helper,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            return 1;
        }
    };
    eprintln!("whisky-bridge: helper {}", helper.display());
    let mut client = match Client::spawn(&helper, &helper_arguments(), CALL_TIMEOUT) {
        Ok(client) => client,
        Err(error) => {
            eprintln!("whisky-bridge: handshake failed: {error}");
            return 1;
        }
    };
    let describe = DescribeResponse::from_capabilities(client.capabilities());
    let missing = describe.missing_methods(&["processes.list", "processes.kill"]);
    if !missing.is_empty() {
        eprintln!(
            "whisky-bridge: helper does not advertise process method(s): {}",
            missing.join(", ")
        );
        client.close();
        return 1;
    }
    let containers = match fetch_containers(&mut client) {
        Ok(containers) => containers,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let container = match pick_container(&containers, bottle) {
        Ok(container) => container,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            client.close();
            return 1;
        }
    };
    let processes = match fetch_processes(&mut client, &container.path) {
        Ok(processes) => processes,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let sample: Vec<serde_json::Value> = processes
        .iter()
        .take(5)
        .map(|process| {
            json!({
                "pid": process.pid,
                "name": process.name,
                "memory": process.memory,
                "kind": process.kind,
                "source": process.source,
                "startedAt": process.started_at,
                "macosPid": process.macos_pid,
            })
        })
        .collect();
    // The kill probe: a PID no process can hold. `killed: false` is the only
    // honest answer and proves the reply path without signalling anything.
    let probe = match client.call(
        "processes.kill",
        json!({ "container": container.path, "pid": BOGUS_PID }),
    ) {
        Ok(reply) => serde_json::from_value::<KillReplyDto>(reply)
            .map(|kill| json!({ "pid": BOGUS_PID, "killed": kill.killed }))
            .unwrap_or_else(|error| json!({ "pid": BOGUS_PID, "error": error.to_string() })),
        Err(error) => json!({ "pid": BOGUS_PID, "error": classify(error).into_message() }),
    };
    let report = json!({
        "bottle": container.name,
        "container": container.path,
        "processCount": processes.len(),
        "sample": sample,
        "killProbe": probe,
    });
    match serde_json::to_string_pretty(&report) {
        Ok(payload) => println!("{payload}"),
        Err(error) => {
            eprintln!("whisky-bridge: cannot encode the processes report: {error}");
            client.close();
            return 1;
        }
    }
    eprintln!(
        "whisky-bridge: {} process(es); kill probe on bogus pid {}",
        processes.len(),
        BOGUS_PID
    );
    let _ = client.shutdown(false);
    0
}

/// Capability bits of `LibraryRuntimeCapabilities` (`LibraryRuntime.swift`),
/// decoded so the report shows what the button gate will actually see.
fn decode_capabilities(bits: i64) -> Vec<&'static str> {
    const BITS: [(i64, &str); 4] = [
        (1 << 0, "launch"),
        (1 << 1, "cancelLaunch"),
        (1 << 2, "stop"),
        (1 << 3, "terminal"),
    ];
    BITS.iter()
        .filter(|(bit, _)| bits & bit != 0)
        .map(|(_, name)| *name)
        .collect()
}

/// `--diagnose-launch --bottle <name-or-path> [--entry <substring>]`:
/// observation only. Configures one bottle and reports, per matched entry,
/// the id the UI would send as `entryID`, the id `runtime.snapshot` carries,
/// the derived `PrimaryAction`, and both helper-side gates (`configured` and
/// the `.launch` capability). Nothing here calls `runtime.launch`, so no game
/// and no Steam client can start.
pub(crate) fn diagnose_launch(bottle: Option<&str>, entry: Option<&str>) -> i32 {
    let helper = match locate_helper() {
        Ok(helper) => helper,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            return 1;
        }
    };
    eprintln!("whisky-bridge: helper {}", helper.display());
    let mut client = match Client::spawn(&helper, &helper_arguments(), CALL_TIMEOUT) {
        Ok(client) => client,
        Err(error) => {
            eprintln!("whisky-bridge: handshake failed: {error}");
            return 1;
        }
    };
    let describe = DescribeResponse::from_capabilities(client.capabilities());
    let missing = describe.missing_methods(RUNTIME_SESSION_METHODS);
    if !missing.is_empty() {
        eprintln!(
            "whisky-bridge: helper does not advertise runtime method(s): {}",
            missing.join(", ")
        );
        client.close();
        return 1;
    }
    let containers = match fetch_containers(&mut client) {
        Ok(containers) => containers,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let container = match pick_container(&containers, bottle) {
        Ok(container) => container,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            client.close();
            return 1;
        }
    };
    // The UI's `game.id` is `EntryRecord.id` from `library.entries`; the
    // runtime table and the helper's `configured` gate are keyed by the same
    // `LibraryEntry.id`. Both reads are shown so a divergence is visible.
    let library = match fetch_entries(&mut client, &container.path) {
        Ok(entries) => entries,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    eprintln!(
        "whisky-bridge: configuring {} (observation only; no game is launched)",
        container.name
    );
    let snapshot = match configure_runtime(&mut client, &container.path) {
        Ok(snapshot) => snapshot,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let by_id: BTreeMap<&str, &RuntimeEntryDto> = snapshot
        .entries
        .iter()
        .map(|entry| (entry.id.as_str(), entry))
        .collect();
    let needle = entry.map(str::to_lowercase);
    let mut reports = Vec::new();
    for record in &library {
        let matches = needle.as_ref().is_none_or(|needle| {
            record.name.to_lowercase().contains(needle.as_str())
                || record.id.to_lowercase().contains(needle.as_str())
        });
        if !matches {
            continue;
        }
        // The UI sends this id as `entryID`; the helper resolves the entry by
        // scanning `workspace.entries` and matching `$0.id == entryID`.
        let ui_entry_id = record.id.as_str();
        let runtime = by_id.get(ui_entry_id).copied();
        let state = runtime.map(|entry| entry.state.clone());
        let capabilities = runtime.map(|entry| entry.capabilities).unwrap_or(0);
        let has_launch = capabilities & CAP_LAUNCH != 0;
        // Mirrors `WhiskyApp::primary_action`: a runtime table row wins, and
        // an entry the helper never listed falls back to the optimistic Play.
        let action = match runtime {
            Some(entry) => {
                let state = RuntimeState::from_wire(&entry.state);
                let action = primary_action_for(state, entry.capabilities);
                json!({
                    "label": action.label,
                    "action": action.action.map(|action| match action {
                        RuntimeAction::Launch => "launch",
                        RuntimeAction::Cancel => "cancel",
                        RuntimeAction::Stop => "stop",
                    }),
                    "enabled": action.enabled,
                    "busy": action.busy,
                    "derivedFrom": "runtimeState",
                })
            }
            None => json!({
                "label": "Play",
                "action": "launch",
                "enabled": true,
                "busy": false,
                "derivedFrom": "optimistic",
            }),
        };
        reports.push(json!({
            "name": record.name,
            "uiEntryID": ui_entry_id,
            "runtimeEntryID": runtime.map(|entry| entry.id.as_str()),
            "idMatches": runtime.is_some(),
            "state": state,
            "capabilities": capabilities,
            "capabilitiesDecoded": decode_capabilities(capabilities),
            "configuredGate": runtime.is_some(),
            "hasLaunchCapability": has_launch,
            "primaryAction": action,
            "executable": record.executable,
            "needsExecutable": record.needs_executable,
        }));
    }
    let report = json!({
        "bottle": container.name,
        "container": container.path,
        "libraryTotal": library.len(),
        "snapshotTotal": snapshot.entries.len(),
        "sequence": snapshot.sequence,
        "queryFailures": snapshot.query_failures,
        "matched": reports,
    });
    match serde_json::to_string_pretty(&report) {
        Ok(payload) => println!("{payload}"),
        Err(error) => {
            eprintln!("whisky-bridge: cannot encode the launch report: {error}");
            client.close();
            return 1;
        }
    }
    eprintln!(
        "whisky-bridge: {} library entr(ies), {} runtime entr(ies), {} matched",
        library.len(),
        snapshot.entries.len(),
        reports.len()
    );
    let _ = client.shutdown(false);
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_grows_and_stays_bounded() {
        let schedule = (0..12).map(backoff_delay).collect::<Vec<_>>();
        assert!(schedule[0] >= Duration::from_millis(250));
        assert!(schedule.iter().all(|delay| *delay <= Duration::from_millis(8_000)));
        assert!(schedule.windows(2).all(|pair| pair[0] <= pair[1]));
        assert_eq!(schedule.last(), Some(&Duration::from_millis(8_000)));
    }

    /// `configuration.read` and the `configuration.set` readback reply with the
    /// whole file's values object. `decode_values` is the seam both the
    /// saved-path merge and the rejection rollback read through, so the shape
    /// is pinned here: a flat field→value map, and nothing else.
    #[test]
    fn configuration_readback_decodes_into_the_value_map() {
        let reply = json!({
            "windowsVersion": "win11",
            "avxEnabled": true,
            "customResolutionWidth": 2560,
            "pinnedDeviceName": ""
        });
        let values = decode_values(&reply).expect("values");
        assert_eq!(values.len(), 4);
        assert_eq!(values["windowsVersion"], json!("win11"));
        assert_eq!(values["avxEnabled"], json!(true));
        assert_eq!(values["customResolutionWidth"], json!(2560));
        assert_eq!(values["pinnedDeviceName"], json!(""));
        // A non-object reply is a protocol error, never an empty map: an
        // empty map would silently roll every field back to its default.
        let error = decode_values(&json!([1, 2])).unwrap_err();
        assert!(error.contains("not an object"), "{error}");
    }
}
