//
//  EmulatorController.swift — one place that owns the emulated machine.
//
//  Purpose : Setting up, starting, driving and stopping the Amiga. The EMU panel asks
//            it to do things; it owns the machine, the command bridge and the panel
//            state, and nothing else in the app has to know how any of that works.
//  Inputs  : requests from the EMU panel — set up, launch, move a control, type a line.
//  Outputs : a running machine, commands delivered into it, and frames on a channel.
//  Connects: FSUAEHost, AmigaCommandBridge, ScalaTitlerPanel, Engine, EmuBrowserView.
//  Extend  : a second program is a second `TitlerProgram` and its own panel type. This
//            controller should not grow a branch per program — the dialect handles
//            that, and it already does.
//
//  ── WHY THE CONTROLLER AND NOT THE VIEW OWNS THE PANEL STATE ────────────────────
//
//  Because the state outlives the view and can be driven from elsewhere. A fader here
//  can be moved by a mouse, by a MIDI CC, by an LFO or by a sweep on the beat, and all
//  four have to arrive at the same place and produce the same command. If the view held
//  the values, MIDI would have to reach into the view to move them.
//

import AppKit
import VideoboyCore

/// Owns the emulated machine and everything that talks to it.
final class EmulatorController {

    /// Where the machine's workspace lives.
    ///
    /// Outside the repo and outside the app bundle, in the person's own Application
    /// Support: it holds paths to their media and a copy of their disc, neither of
    /// which belongs in version control or in a signed bundle. Deleting this folder
    /// undoes everything the setup did.
    static let workspace = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Videoboy/amiga")

    private var sharedDrawer: URL { Self.workspace.appendingPathComponent("VB") }
    private var systemDrive: URL { Self.workspace.appendingPathComponent("System") }
    private var statesDirectory: URL { Self.workspace.appendingPathComponent("states") }

    /// Where Amiberry writes its save states.
    ///
    /// Its own folder rather than ours: the emulator's GUI writes there and cannot be
    /// told otherwise from a config we regenerate on every launch, so the honest thing
    /// is to look where it actually puts them.
    private var amiberryStatesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Amiberry/SaveStates")
    }

    /// The saved state for this machine, from wherever the emulator put it.
    var saveState: AmigaSaveState {
        let ours = AmigaSaveState(directory: statesDirectory)
        if ours.exists { return ours }
        return AmigaSaveState(directory: amiberryStatesDirectory)
    }

    /// What to tell someone who wants to make one.
    ///
    /// ── WHY THIS IS A DIALOGUE AND NOT A BUTTON THAT JUST DOES IT ───────────────
    ///
    /// Saving a state means telling the EMULATOR to save, and the emulator is a
    /// separate application. Driving its menu from here would need Accessibility
    /// permission to send events to another process — a large thing to ask so that one
    /// button can avoid explaining itself once.
    ///
    /// It is also genuinely a one-time manual step, and the thing that makes it work is
    /// the part only a person can judge: getting the machine to exactly the page you
    /// want to start from.
    static let saveStateInstructions = """
        Get the machine to the point you want to start from every time: software         loaded, the script open, sitting on the page you will title from.

        Then, in the emulator's own window, press F12 to open its menu, choose         Savestates, and save to a slot.

        Videoboy watches for the file. Once it exists, this button becomes LOAD STATE         and every start lands there in about a second instead of booting from cold.
        """

    /// Whether the next start restores the saved state instead of booting cold.
    ///
    /// Defaults to TRUE once a state exists, because that is invariably what someone
    /// wants: the reason to save a state is not to have one, it is to stop waiting for
    /// a cold boot.
    var restoresSavedState: Bool = true

    /// The program being driven. One for now; the second is a menu.
    let program: TitlerProgram

    /// The translation layer — 0...1 in, real script lines out.
    let panel = ScalaTitlerPanel()

    private(set) var host: FSUAEHost
    private(set) var bridge: AmigaCommandBridge?

    /// Called on the main thread whenever anything the panel shows has changed.
    var onStateChanged: (() -> Void)?

    /// Called when frames start arriving, so the graph can be pointed at them.
    var onMachineReady: ((EmulatorHost) -> Void)?

    init(program: TitlerProgram = TitlerLibrary.programs.first { $0.name == "Scala MM300" }!) {
        self.program = program
        self.host = FSUAEHost(workspace: Self.workspace)
        host.onStateChanged = { [weak self] in self?.onStateChanged?() }
        // A drive built in a previous session still has its assets; rescanning at
        // launch means the choice controls work without pressing SET UP again.
        loadTitlerAssets()
    }

    /// Fills the panel's choice lists from an already-installed drive.
    private func loadTitlerAssets() {
        let installer = AmigaSystemInstaller(destination: systemDrive)
        guard installer.isInstalled else { return }
        let volume = findDisc().flatMap { try? DiscImage(path: $0).existingMountPoint() }?
            .lastPathComponent ?? "Workbench"
        let assets = installer.titlerAssets(volumeName: volume)
        panel.backdrops = assets.backdrops
        panel.pageNames = assets.pageNames
        panel.setBrush(file: assets.symbols.first)
    }

    // MARK: - What the panel shows

    /// Whether a machine has been assembled and can be started.
    var isSetUp: Bool {
        // EITHER config: the host picks the emulator, so a machine is set up when the
        // file that emulator wants exists.
        [ "videoboy-amiga.uae", "videoboy-amiga.fs-uae" ].contains {
            FileManager.default.fileExists(
                atPath: Self.workspace.appendingPathComponent($0).path)
        }
    }

    var isRunning: Bool { host.isReady }

    /// Whether the listener inside the machine is answering.
    var linkState: AmigaLinkState { bridge?.state ?? .idle }

    /// What the listener last said about itself, read from the shared drawer.
    ///
    /// The machine writes this; we only read it. Two different facts come back — that
    /// the listener is alive, and whether the program's script port is open — and
    /// telling those apart is most of diagnosing this link. "Nothing is happening"
    /// means something quite different in each case.
    var machineStatus: String? {
        let status = sharedDrawer.appendingPathComponent("ack/link.status")
        guard let text = try? String(contentsOf: status, encoding: .isoLatin1) else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: " · ")
    }

    /// One line describing where things stand, for the panel's status row.
    var summary: String {
        if let reason = host.unavailableReason { return reason }
        if !isSetUp { return "Not set up yet — press SET UP." }
        if !isRunning { return "Ready. Press START." }
        if let status = machineStatus { return "Running · \(status)" }
        return "Running · waiting for the machine to answer"
    }

    // MARK: - Doing things

    /// Assembles a machine from a disc. Long, so it reports progress and runs off the
    /// main thread.
    func setUp(progress: @escaping (String) -> Void, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            func report(_ text: String) { DispatchQueue.main.async { progress(text) } }
            func finish(_ error: String?) {
                DispatchQueue.main.async {
                    completion(error)
                    self.onStateChanged?()
                }
            }

            guard FSUAEInstallation.isInstalled() else {
                return finish(FSUAEInstallation.installationHint)
            }
            guard let disc = self.findDisc() else {
                return finish("No Amiga disc image found in ~/Desktop or ~/Downloads. "
                    + "Put the .iso in one of those, or mount it first.")
            }

            do {
                report("mounting \(disc.lastPathComponent)")
                let mounted = try DiscImage(path: disc).mount()

                let installer = AmigaSystemInstaller(destination: self.systemDrive)
                if !installer.isInstalled {
                    report("copying the system from \(mounted.lastPathComponent)")
                    let result = try installer.install(from: mounted) { drawer in
                        report("copying \(drawer)")
                    }
                    report(result.summary)
                }

                // What the panel can actually offer, read off the drive we just built.
                let assets = installer.titlerAssets(volumeName: mounted.lastPathComponent)
                DispatchQueue.main.async {
                    self.panel.backdrops = assets.backdrops
                    self.panel.pageNames = assets.pageNames
                    self.panel.setBrush(file: assets.symbols.first)
                }
                report("\(assets.backdrops.count) backgrounds, \(assets.pageNames.count) pages")

                report("writing the machine configuration")
                try FileManager.default.createDirectory(
                    at: self.statesDirectory, withIntermediateDirectories: true)
                self.writeConfiguration(volumeName: mounted.lastPathComponent)

                finish(nil)
            } catch {
                finish(error.localizedDescription)
            }
        }
    }

    /// Starts the machine and opens the command link.
    ///
    /// Rewrites the configuration first, because whether to restore the saved state is
    /// decided at launch and lives in that file. Cheap — it is a few lines of text —
    /// and it means the button and the machine can never disagree about it.
    @discardableResult
    func start() -> Bool {
        writeConfiguration()
        guard host.boot(program) else { return false }

        do {
            let transport = try SharedDrawerTransport(root: sharedDrawer)
            let bridge = AmigaCommandBridge(transport: transport)
            bridge.onStateChanged = { [weak self] _ in self?.onStateChanged?() }
            bridge.start()
            self.bridge = bridge
        } catch {
            Log.error(.titler, "could not open the command link: \(error.localizedDescription)")
        }

        onMachineReady?(host)
        onStateChanged?()
        return true
    }

    /// Rewrites BOTH machine configurations from the current choices.
    ///
    /// Both, every time, because which emulator is present is not this function's
    /// business — the host picks, and it picks Amiberry when it is there. Writing one
    /// and discovering later that the other was needed is how a setup silently points
    /// at a stale file.
    private func writeConfiguration(volumeName: String? = nil) {
        let firmware = FSUAEInstallation.firmware(kickstartPath: kickstartPath())
        let volume = volumeName
            ?? findDisc().flatMap { try? DiscImage(path: $0).existingMountPoint() }?
                .lastPathComponent
            ?? "Workbench"

        var fsuae = FSUAEConfiguration(
            program: program, firmware: firmware,
            sharedDrawer: sharedDrawer, systemDrive: systemDrive)
        fsuae.systemVolumeName = volume
        fsuae.saveStatesDirectory = statesDirectory
        fsuae.loadsSavedState = restoresSavedState && saveState.exists
        try? fsuae.write(to: Self.workspace)

        let amiberry = AmiberryConfiguration(
            program: program, firmware: firmware,
            sharedDrawer: sharedDrawer, systemDrive: systemDrive,
            systemVolumeName: volume,
            // Only when one exists AND the operator wants it: a config pointing at a
            // state file that is not there is a machine that will not start at all.
            stateFile: (restoresSavedState && saveState.exists)
                ? saveState.files.first
                : nil)
        try? amiberry.write(to: Self.workspace)
    }

    func stop() {
        bridge?.stop()
        bridge = nil
        host.shutdown()
        onStateChanged?()
    }

    /// Brings the emulator's own window forward, so the machine can be used directly.
    func showMachine() {
        host.bringToFront()
    }

    /// Sends the whole panel, so the machine and the faders agree.
    ///
    /// A freshly started machine has no idea what the controls are showing. Without
    /// this the first fader moved is the only thing that matches, and everything else
    /// silently disagrees until it happens to be touched.
    func synchronise() {
        bridge?.sendImmediately(panel.fullState())
    }

    // MARK: - Driving it

    /// Moves one control and sends whatever that produces.
    ///
    /// The single path from a 0...1 value to the machine. A mouse, a MIDI CC, an LFO
    /// and a beat-synced sweep all arrive here, which is what makes all four behave
    /// identically.
    func move(_ function: TitlerFunction, to value: Double) {
        let commands = panel.set(function, to: value)
        guard !commands.isEmpty else { return }
        bridge?.send(commands)
    }

    /// Sends commands produced elsewhere — by the graph node, for automation and MIDI.
    ///
    /// Through the same bridge as a fader move, so a knob and a mouse are
    /// indistinguishable by the time they reach the machine.
    func send(_ commands: [TitlerCommand]) {
        guard !commands.isEmpty else { return }
        bridge?.send(commands)
    }

    /// Sets the line of text being titled.
    func setText(_ text: String) {
        bridge?.send(panel.setText(text))
    }

    /// What a control currently reads, in the software's own units.
    func readout(for function: TitlerFunction) -> String {
        panel.readout(for: function)
    }

    /// Why a control cannot do anything yet, or nil.
    func unavailableReason(for function: TitlerFunction) -> String? {
        panel.unavailableReason(for: function)
    }

    // MARK: - Finding things

    /// A disc image, in the two places a person actually leaves one.
    ///
    /// Desktop and Downloads. Sweeping the whole home directory would be slow,
    /// surprising, and would find things that are none of this app's business.
    private func findDisc() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for place in ["Desktop", "Downloads"] {
            let directory = home.appendingPathComponent(place)
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
            if let hit = contents.first(where: {
                let name = $0.lastPathComponent.lowercased()
                return (name.hasSuffix(".iso") || name.hasSuffix(".cue"))
                    && (name.contains("amiga") || name.contains("cucd") || name.contains("scala"))
            }) { return hit }
        }
        return nil
    }

    /// A Kickstart ROM, if the person has put one where FS-UAE keeps them.
    ///
    /// Looked for in ONE place and never fetched. A Kickstart is copyrighted; this app
    /// uses one if its owner has supplied it and boots on AROS if not.
    private func kickstartPath() -> String? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/FS-UAE/Kickstarts")
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.first { $0.pathExtension.lowercased() == "rom" }?.path
    }
}
