import CompositorServices
import GameController
import SwiftUI
import UniformTypeIdentifiers

@main
struct Mario64MRApp: App {
    @State private var game = GameHost()

    var body: some Scene {
        WindowGroup(id: GameWindow.flatWindow) {
            GameWindow(game: game)
                .onAppear { game.start() }
        }
        .defaultSize(width: 1280, height: 760)

        ImmersiveSpace(id: GameWindow.roomSpace) {
            CompositorLayer(configuration: RoomLayerConfiguration()) { layer in
                ImmersiveRenderer.start(layer, host: game)
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

/// The game in a flat window, played with a gamepad (or a keyboard), and the button that opens it into the room
struct GameWindow: View {
    static let roomSpace = "Room", flatWindow = "Flat"
    let game: GameHost
    @State private var renderer: GameRenderer?
    @State private var packs = TexturePacks()
    @State private var showingPacks = false
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let renderer {
                    GameView(renderer: renderer)
                }
                if case .failed(let message) = game.status {
                    Text(message).foregroundStyle(.red).padding()
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            HStack {
                Button("Open a window into the game") { Task { await openRoom() } }
                Button("Texture packs") { showingPacks = true }
                Text(statusLine).monospacedDigit()
                Spacer()
                Text(game.hasGamePad ? "Gamepad connected" : "No gamepad: pair one, or use a keyboard "
                     + "(WASD, Space = A, Shift = B, Z, Return = Start, arrows = C)")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        // Without this visionOS takes the pad for window navigation (A taps, d-pad and sticks move focus) and
        // only Menu reaches GameController
        .handlesGameControllerEvents(matching: .gamepad)
        .sheet(isPresented: $showingPacks) { TexturePacksView(packs: packs) }
        .onAppear {
            if renderer == nil, let device = game.device {
                renderer = GameRenderer(device: device, frames: game.output)
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-room") { Task { await openRoom() } }
            // (-importPack <path>: imports it, and shows the texture packs)
            let arguments = ProcessInfo.processInfo.arguments
            if let i = arguments.firstIndex(of: "-importPack"), i + 1 < arguments.count {
                packs.add(URL(fileURLWithPath: arguments[i + 1]))
                showingPacks = true
            }
            #endif
        }
    }

    /// The game moves from this window into the room. The Digital Crown steps back out: from a diorama to the
    /// window in the room (visionOS closes the room either way, so it opens again at once), and from the window in
    /// the room to this one
    private func openRoom() async {
        guard case .opened = await openImmersiveSpace(id: Self.roomSpace) else { return }
        let (openWindow, openImmersiveSpace, room) = (openWindow, openImmersiveSpace, game.room)
        room.onClose = {
            Task { @MainActor in
                if room.current.reopenWidth != nil {
                    if case .opened = await openImmersiveSpace(id: Self.roomSpace) { return }
                    room.update { $0.reopenWidth = nil }
                }
                openWindow(id: Self.flatWindow)
            }
        }
        dismissWindow(id: Self.flatWindow)
    }

    private var statusLine: String {
        switch game.status {
        case .starting: "Starting…"
        case .failed: "Stopped"
        case .running: "Game frame \(game.frames) · stage \(game.stage) · \(game.batches) draws · audio \(game.queuedAudio)"
        }
    }
}

/// Your texture packs: import one (a zip or a folder, from the Files app), turn them on and off, remove them. The
/// game uses them from its next start.
struct TexturePacksView: View {
    let packs: TexturePacks
    @State private var choosing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if packs.packs.isEmpty {
                        Text("None yet. Import a texture pack for sm64ex: a .zip, or a folder, with a gfx folder in it.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(packs.packs) { pack in
                        HStack {
                            Toggle(isOn: Binding(get: { pack.enabled }, set: { packs.setEnabled(pack, $0) })) {
                                VStack(alignment: .leading) {
                                    Text(pack.name)
                                    Text(ByteCountFormatter.string(fromByteCount: pack.bytes, countStyle: .file))
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            Button(role: .destructive) { packs.remove(pack) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove \(pack.name)")
                        }
                    }
                } footer: {
                    Text("Over the game's own textures, in this order: where two packs have the same texture, the "
                         + "lower one wins. The title screen's face uses them too; Mario out in your room keeps "
                         + "the ROM's.")
                }
                if let problem = packs.problem {
                    Section { Text(problem).foregroundStyle(.red) }
                }
                if packs.changed {
                    Section {
                        Text("The game uses your texture packs from when it next starts.")
                        Button("Quit Mario 64 MR now") { exit(0) }
                    } footer: {
                        Text("Then open it again from the Home View. Your game is saved as you play, and the "
                             + "options as you change them.")
                    }
                }
            }
            .navigationTitle("Texture packs")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if packs.importing {
                        ProgressView()
                    } else {
                        Button("Import", systemImage: "plus") { choosing = true }
                    }
                }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.zip, .folder]) { result in
                switch result {
                case .success(let url): packs.add(url)
                case .failure(let error): packs.problem = error.localizedDescription
                }
            }
            .onAppear { packs.reload() }
        }
        .frame(minWidth: 560, minHeight: 480)
    }
}
