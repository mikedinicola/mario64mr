import CompositorServices
import GameController
import SwiftUI

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
        .onAppear {
            if renderer == nil, let device = game.device {
                renderer = GameRenderer(device: device, frames: game.output)
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-room") { Task { await openRoom() } }
            #endif
        }
    }

    /// The game moves from this window into the room; when you leave the room (the Digital Crown), this window
    /// comes back
    private func openRoom() async {
        guard case .opened = await openImmersiveSpace(id: Self.roomSpace) else { return }
        let openWindow = openWindow
        game.room.onClose = { DispatchQueue.main.async { openWindow(id: Self.flatWindow) } }
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
