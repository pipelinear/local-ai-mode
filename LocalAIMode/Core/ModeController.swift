import AppKit
import Combine

/// Orchestrates AI Mode ON/OFF. All transitions are serialized on the main actor through `ModeStateMachine`,
/// and every irreversible step is journaled *before* it happens so a crash can be recovered.
@MainActor
final class ModeController: ObservableObject {
    // Services
    let settings: SettingsManager
    let apps: ApplicationManager
    let workspace: WorkspaceManager
    let ollama: OllamaService
    let monitor: MemoryMonitor
    let performance: PerformanceManager
    let store: SessionStore

    // State
    @Published private(set) var machine = ModeStateMachine()
    @Published private(set) var log: [ActivityEvent] = []
    @Published var selectedPIDs: Set<pid_t> = []
    @Published private(set) var stillRunning: [AppSnapshotEntry] = []
    @Published private(set) var lastRestoreReport: RestoreReport?
    @Published private(set) var recovery: RecoveryAssessment = .clean
    @Published private(set) var journal: SessionJournal?
    @Published private(set) var stepDetail: String?
    @Published var transientNotice: String?

    var state: ModeState { machine.state }

    private var transitionTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var tickCount = 0

    init(settings providedSettings: SettingsManager? = nil,
         store: SessionStore = SessionStore(),
         startMonitoring: Bool = true) {
        let settings = providedSettings ?? SettingsManager()
        self.settings = settings
        self.store = store
        self.apps = ApplicationManager()
        self.workspace = WorkspaceManager()
        self.ollama = OllamaService(baseURL: settings.settings.ollamaBaseURL)
        self.monitor = MemoryMonitor()
        self.performance = PerformanceManager()

        apps.policyProvider = { [weak settings] in
            ExclusionPolicy(ownBundleIdentifier: Bundle.main.bundleIdentifier,
                            ownPID: ProcessInfo.processInfo.processIdentifier,
                            userExcludedBundleIDs: Set(settings?.settings.userExcludedBundleIDs ?? []),
                            includeMenuBarApps: settings?.settings.includeMenuBarApps ?? false,
                            ollamaHostPIDs: ApplicationManager.ollamaHostPIDs())
        }

        // Re-evaluate exclusions and Ollama endpoint when settings change.
        settings.$settings
            .removeDuplicates()
            .sink { [weak self] s in
                guard let self else { return }
                self.ollama.configure(baseURL: s.ollamaBaseURL)
                DispatchQueue.main.async { self.apps.refresh() }
            }
            .store(in: &cancellables)

        // Forward nested changes so views observing the controller update.
        [apps.objectWillChange, ollama.objectWillChange, monitor.objectWillChange, performance.objectWillChange]
            .forEach { $0.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables) }

        guard startMonitoring else { return }
        monitor.onTick = { [weak self] in self?.tick() }
        monitor.start()
        apps.refresh()
        Task { await ollama.refresh(includeInstalled: true, measureFootprint: true) }
    }

    // MARK: Logging

    func record(_ message: String, _ kind: ActivityEvent.Kind = .info) {
        log.insert(ActivityEvent(kind: kind, message: message), at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }
    }

    private func setStep(_ step: ActivationStep) {
        machine.handle(.activationStep(step))
        stepDetail = nil
        record(step.rawValue)
    }

    private func setStep(_ step: DeactivationStep) {
        machine.handle(.deactivationStep(step))
        stepDetail = nil
        record(step.rawValue)
    }

    private func rejectBusy(_ action: String) {
        let message = "\(action) ignored: \(state.title) is still in progress."
        transientNotice = message
        record(message, .warning)
    }

    // MARK: Periodic checks

    private func tick() {
        tickCount += 1
        let active = state == .active
        // Poll Ollama every tick while AI Mode is on (detects user quitting Ollama / model eviction);
        // otherwise only while the dashboard is visible, and at a lower rate.
        guard active || (monitor.isDashboardVisible && tickCount % 3 == 0) else { return }
        Task {
            await ollama.refresh(measureFootprint: monitor.isDashboardVisible || active)
            if monitor.isDashboardVisible { apps.refreshMemory() }
            if active { checkModelHealth() }
        }
    }

    private func checkModelHealth() {
        guard case .loaded(let model) = ollama.modelStatus else { return }
        if !ollama.isReachable {
            ollama.modelStatus = .lost(model: model, reason: "Ollama stopped running")
            record("Ollama is no longer reachable — it may have been quit.", .warning)
        } else if !ollama.runningModels.contains(where: { $0.name == model || $0.model == model }) {
            ollama.modelStatus = .lost(model: model, reason: "Model was unloaded by Ollama")
            record("\(model) is no longer loaded in Ollama.", .warning)
        }
    }

    // MARK: Launch / recovery

    func assessRecoveryAtLaunch() {
        recovery = RecoveryAssessment.assess(store: store)
        switch recovery {
        case .clean:
            break
        case .corrupt:
            store.quarantineCorruptJournal()
            record("A damaged session journal was found and set aside.", .warning)
            recovery = .clean
        case .interrupted(let j):
            journal = j
            machine.handle(.recoveryDetected)
            record("An AI Mode session from \(j.startedAt.formatted(date: .abbreviated, time: .shortened)) did not finish.", .warning)
        case .restorePending(let j):
            journal = j
            record("Your workspace from the last AI Mode session has not been restored yet.", .info)
        }
    }

    func dismissRecovery() {
        guard machine.handle(.recoveryDismissed) else { return }
        record("Recovery dismissed. The snapshot is kept for Emergency Restore.")
        // Keep the journal's snapshot reachable via Emergency Restore, then clear the session.
        store.endSession()
        journal = nil
        recovery = .clean
    }

    // MARK: Activation

    /// Step 0: compute the list of apps to close and (optionally) ask for confirmation.
    func requestActivation() {
        guard machine.handle(.requestActivation) else { return rejectBusy("Enable AI Mode") }
        prepareSelection()
        if !settings.settings.confirmBeforeClosing { confirmActivation() }
    }

    /// From the recovery screen: close what is open again and reload the model, keeping the original snapshot.
    func resumeAIMode() {
        guard machine.handle(.resumeRequested) else { return rejectBusy("Resume AI Mode") }
        prepareSelection()
    }

    private func prepareSelection() {
        apps.refresh()
        apps.refreshMemory()
        selectedPIDs = Set(apps.appsToClose.map(\.pid))
        Task { await ollama.refresh(includeInstalled: true) }
    }

    func cancelActivation() {
        guard machine.handle(.cancel) else { return }
        record("AI Mode activation cancelled.")
    }

    func confirmActivation() {
        let resuming = machine.isResuming
        guard machine.handle(.confirm) else { return rejectBusy("Enable AI Mode") }
        let chosen = apps.apps.filter { selectedPIDs.contains($0.pid) && $0.decision.willClose }
        transitionTask = Task { [weak self] in
            await self?.runActivation(closing: chosen, resuming: resuming)
        }
    }

    private func runActivation(closing chosen: [RunningAppInfo], resuming: Bool) async {
        let s = settings.settings
        stillRunning = []
        lastRestoreReport = nil

        // 1. Snapshot (never overwrites an existing session)
        record(ActivationStep.savingSnapshot.rawValue)
        let before = monitor.captureNow()
        monitor.beforeSample = before
        monitor.afterSample = nil
        monitor.addMarker("AI Mode on")

        let snapshot = await workspace.captureSnapshot(apps: chosen, captureDocuments: s.captureDocumentsWithAccessibility,
                                                       captureBrowserTabs: s.captureBrowserTabs) { [weak self] in self?.stepDetail = $0 }
        do {
            if resuming, store.loadJournal() != nil {
                // Append newly opened apps to the original snapshot instead of replacing it.
                journal = try store.update { j in
                    let known = Set(j.snapshot.applications.map(\.id))
                    let offset = (j.snapshot.applications.map(\.launchOrder).max() ?? 0) + 1
                    for (i, var e) in snapshot.applications.enumerated() where !known.contains(e.id) {
                        e.launchOrder = offset + i
                        j.snapshot.applications.append(e)
                    }
                    for i in j.snapshot.applications.indices {
                        if let fresh = snapshot.applications.first(where: { $0.id == j.snapshot.applications[i].id }) {
                            j.snapshot.applications[i].processIdentifier = fresh.processIdentifier
                        }
                    }
                    j.phase = .activating
                    j.requestedModel = s.selectedModel
                }
            } else {
                var j = try store.beginSession(snapshot: snapshot, model: s.selectedModel)
                j = try store.update { $0.memoryBefore = before }
                journal = j
            }
        } catch {
            record("Could not save the workspace snapshot: \(error.localizedDescription). Nothing was closed.", .error)
            machine.handle(.activationAborted)
            return
        }
        recovery = .clean
        record("Saved snapshot of \(snapshot.applications.count) app(s).", .success)

        // 2. Close applications gracefully
        setStep(.closingApps)
        let toClose = snapshot.applications
        if !toClose.isEmpty {
            let outcome = await apps.terminateGracefully(toClose, timeout: s.gracefulQuitTimeout) { [weak self] in
                self?.stepDetail = $0
            }
            markClosed(outcome.closed.map(\.id))
            stillRunning = outcome.stillRunning
            record("Closed \(outcome.closed.count) app(s).", .success)
            if !outcome.stillRunning.isEmpty {
                record("\(outcome.stillRunning.count) app(s) did not quit (they may be waiting for you to save): "
                       + outcome.stillRunning.map(\.name).joined(separator: ", "), .warning)
            }
        }

        // 3. Performance settings
        setStep(.optimizingPerformance)
        await applyPerformanceSettings(s)

        // 4. Ollama
        setStep(.startingOllama)
        var ollamaOK = false
        do {
            let started = try await ollama.ensureRunning(settings: s)
            if started {
                journal = try? store.update { $0.ollamaStartedByAIMode = true }
                record("Started Ollama.", .success)
            } else {
                record("Ollama \(ollama.version ?? "") is running.", .success)
            }
            ollamaOK = true
        } catch {
            record(error.localizedDescription, .error)
            if let model = s.selectedModel { ollama.modelStatus = .failed(model: model, message: error.localizedDescription) }
        }

        // 5. Load model (cancellable independently of the activation)
        if ollamaOK {
            if let model = s.selectedModel, !model.isEmpty {
                setStep(.loadingModel)
                stepDetail = "Loading \(model) — large models can take a minute"
                await startLoad(model: model, settings: s).value
            } else {
                record("No model selected — choose one in the Ollama panel and press Load.", .warning)
            }
        }

        // 6. Verify & finish
        setStep(.verifying)
        await ollama.refresh(includeInstalled: false, measureFootprint: true)
        journal = try? store.update { $0.phase = .active }
        apps.isTrackingLaunches = true
        machine.handle(.activationFinished)
        stepDetail = nil
        record("AI Performance Mode is on.", .success)

        // Measure the effect once things have settled.
        try? await Task.sleep(for: .seconds(4))
        if state == .active { monitor.afterSample = monitor.captureNow() }
    }

    private func applyPerformanceSettings(_ s: AppSettings) async {
        performance.beginPerformanceActivity(preventIdleSleep: s.preventIdleSleep)
        if s.preventIdleSleep { record("Idle sleep prevented while AI Mode is on.") }

        guard s.disableLowPowerMode, performance.isLowPowerModeEnabled else {
            if performance.isLowPowerModeEnabled {
                record("Low Power Mode is on (disabling it is turned off in Settings).", .warning)
            }
            return
        }
        let alreadyRecorded = journal?.changedSettings.powerModesChanged == true
        let original = alreadyRecorded ? (journal?.changedSettings.originalPowerModes ?? []) : await performance.currentPowerModes()
        if original.isEmpty {
            record("Low Power Mode is on, but its pmset setting could not be read; left unchanged.", .warning)
            return
        }
        // Journal the original values *before* changing anything.
        if !alreadyRecorded {
            journal = try? store.update { $0.changedSettings.originalPowerModes = original }
        }
        stepDetail = "Waiting for administrator authorization to turn off Low Power Mode"
        do {
            if try await performance.disableLowPowerMode(original: original) {
                journal = try? store.update { $0.changedSettings.powerModesChanged = true }
                record("Low Power Mode turned off.", .success)
            }
        } catch {
            record(error.localizedDescription, .warning)
        }
    }

    @discardableResult
    private func startLoad(model: String, settings s: AppSettings) -> Task<Void, Never> {
        loadTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.ollama.loadModel(model, settings: s)
                let gpu = Int((loaded.gpuFraction * 100).rounded())
                self.record("\(model) loaded — Ollama reports \(ByteFormat.string(UInt64(loaded.size))) (\(gpu)% GPU).", .success)
            } catch is CancellationError {
                self.record("Model load cancelled.", .warning)
            } catch {
                self.record("Model failed to load: \(error.localizedDescription)", .error)
            }
        }
        loadTask = task
        return task
    }

    /// Load or reload the selected model while AI Mode is on (or anytime from the Ollama panel).
    func loadSelectedModel() {
        guard !state.isTransitioning || state == .activating(.loadingModel) else { return rejectBusy("Load model") }
        guard let model = settings.settings.selectedModel else {
            record("Select a model first.", .warning); return
        }
        let s = settings.settings
        Task {
            do {
                let started = try await ollama.ensureRunning(settings: s)
                if started, journal != nil { journal = try? store.update { $0.ollamaStartedByAIMode = true } }
                startLoad(model: model, settings: s)
            } catch {
                record(error.localizedDescription, .error)
                ollama.modelStatus = .failed(model: model, message: error.localizedDescription)
            }
        }
    }

    func cancelModelLoad() {
        loadTask?.cancel()
    }

    func unloadAllModels() {
        guard !state.isTransitioning else { return rejectBusy("Unload") }
        Task {
            let remaining = await ollama.unloadAll(timeout: settings.settings.unloadTimeout)
            if remaining.isEmpty { record("All models unloaded.", .success) }
            else { record("Still loaded: \(remaining.joined(separator: ", "))", .warning) }
        }
    }

    // MARK: Apps that did not quit

    private func markClosed(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        journal = try? store.update { j in
            for i in j.snapshot.applications.indices where set.contains(j.snapshot.applications[i].id) {
                j.snapshot.applications[i].wasClosedByAIMode = true
            }
        }
    }

    func waitLonger(for entry: AppSnapshotEntry) {
        apps.requestQuit(pid: entry.processIdentifier)
        Task {
            let remaining = await apps.waitForTermination(pids: [entry.processIdentifier], timeout: 30)
            if remaining.isEmpty {
                stillRunning.removeAll { $0.id == entry.id }
                markClosed([entry.id])
                record("\(entry.name) quit.", .success)
            } else {
                record("\(entry.name) is still running.", .warning)
            }
        }
    }

    func keepOpen(_ entry: AppSnapshotEntry) {
        stillRunning.removeAll { $0.id == entry.id }
        record("\(entry.name) will stay open.")
    }

    /// Only reachable after an explicit, warned confirmation in the UI.
    func forceQuit(_ entry: AppSnapshotEntry) {
        Task {
            if await apps.forceQuit(pid: entry.processIdentifier) {
                stillRunning.removeAll { $0.id == entry.id }
                markClosed([entry.id])
                record("Force quit \(entry.name). Unsaved changes in it were lost.", .warning)
            } else {
                record("Could not force quit \(entry.name).", .error)
            }
        }
    }

    func quitLaunchedApp(_ app: RunningAppInfo) {
        apps.requestQuit(pid: app.pid)
        record("Asked \(app.name) to quit.")
    }

    // MARK: Deactivation

    func requestDeactivation() {
        guard let j = journal ?? store.loadJournal() else {
            // No journal (should not happen) — still allow returning to normal safely.
            guard machine.handle(.requestDeactivation) else { return rejectBusy("Disable AI Mode") }
            transitionTask = Task { [weak self] in await self?.runDeactivation(journal: nil) }
            return
        }
        guard machine.handle(.requestDeactivation) else { return rejectBusy("Disable AI Mode") }
        transitionTask = Task { [weak self] in await self?.runDeactivation(journal: j) }
    }

    /// Also used by "Restore Previous Workspace" after a crash.
    private func runDeactivation(journal j: SessionJournal?) async {
        let s = settings.settings
        loadTask?.cancel()
        apps.isTrackingLaunches = false
        if j != nil { journal = try? store.update { $0.phase = .deactivating } }

        // 1. Unload — Ollama completes in-flight requests before releasing a model.
        setStep(.unloadingModels)
        await ollama.refresh()
        if ollama.isReachable {
            let remaining = await ollama.unloadAll(timeout: s.unloadTimeout)
            if remaining.isEmpty { record("Models unloaded and memory released by Ollama.", .success) }
            else { record("Still loaded after \(Int(s.unloadTimeout)) s: \(remaining.joined(separator: ", ")).", .warning) }
        } else {
            ollama.modelStatus = .idle
            record("Ollama is not running; nothing to unload.")
        }

        // 2. Ollama process
        if !s.keepOllamaRunningAfterExit {
            setStep(.stoppingOllama)
            record(await ollama.launcher.stop())
        }

        // 3. Settings
        setStep(.restoringSettings)
        performance.endPerformanceActivity()
        if let changed = j?.changedSettings, changed.powerModesChanged {
            do {
                try await performance.restorePowerModes(changed.originalPowerModes)
                journal = try? store.update { $0.changedSettings.powerModesChanged = false }
                record("Power settings restored.", .success)
            } catch {
                record("Power settings were not restored: \(error.localizedDescription). You can change Low Power Mode in System Settings › Battery.", .warning)
            }
        }

        // 4. Apps
        if let j {
            if s.restoreAppsAutomatically {
                setStep(.restoringApps)
                let snapshot = store.loadJournal()?.snapshot ?? j.snapshot
                await restore(snapshot: snapshot)
                store.endSession()
                journal = nil
            } else {
                journal = try? store.update { $0.phase = .restorePending }
                if let pending = journal { recovery = .restorePending(pending) }
                record("Apps were not reopened (automatic restore is off). Use Restore Workspace when ready.")
            }
        }

        apps.clearLaunchedDuringAIMode()
        stillRunning = []
        monitor.addMarker("AI Mode off")
        machine.handle(.deactivationFinished)
        if case .restorePending = recovery {} else { recovery = .clean }
        stepDetail = nil
        record("Back to Normal Mode.", .success)
        await ollama.refresh(measureFootprint: true)
    }

    private func restore(snapshot: WorkspaceSnapshot) async {
        let report = await workspace.restore(snapshot: snapshot) { [weak self] in self?.stepDetail = $0 }
        lastRestoreReport = report
        record(report.summary, report.failures.isEmpty ? .success : .warning)
        for failure in report.failures { record("\(failure.appName): \(failure.reason)", .warning) }
        if !report.relocated.isEmpty { record("Found moved apps: \(report.relocated.joined(separator: ", "))") }
        apps.refresh()
    }

    /// Restores a pending workspace (automatic restore off) without touching mode state.
    func restorePendingWorkspace() {
        guard !state.isTransitioning else { return rejectBusy("Restore Workspace") }
        guard let j = store.loadJournal(), j.phase == .restorePending else { return }
        Task {
            await restore(snapshot: j.snapshot)
            store.endSession()
            journal = nil
            recovery = .clean
        }
    }

    /// From the recovery screen: run the full OFF sequence using the journal from the interrupted session.
    func restorePreviousWorkspace() {
        requestDeactivation()
    }

    /// Settings › Emergency Workspace Restore. Reopens apps from the current journal or the last finished session,
    /// and restores power settings if the journal says they were changed. Does not unload models or change mode.
    func emergencyRestore() {
        guard !state.isTransitioning else { return rejectBusy("Emergency Restore") }
        let j = store.loadJournal()
        guard let snapshot = j?.snapshot ?? store.loadLastSnapshot() else {
            record("No saved workspace snapshot was found.", .warning)
            return
        }
        record("Emergency restore started.", .warning)
        Task {
            if let changed = j?.changedSettings, changed.powerModesChanged {
                do {
                    try await performance.restorePowerModes(changed.originalPowerModes)
                    journal = try? store.update { $0.changedSettings.powerModesChanged = false }
                } catch { record(error.localizedDescription, .warning) }
            }
            await restore(snapshot: snapshot)
        }
    }

    var hasEmergencySnapshot: Bool { store.loadJournal() != nil || store.loadLastSnapshot() != nil }

    // MARK: Toggle

    func toggle() {
        switch state {
        case .normal: requestActivation()
        case .active: requestDeactivation()
        case .recoveryNeeded: break
        default: rejectBusy(state.isAIModeOn ? "Disable AI Mode" : "Enable AI Mode")
        }
    }
}
