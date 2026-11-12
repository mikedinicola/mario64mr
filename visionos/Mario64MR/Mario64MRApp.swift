import GameController
import SwiftUI

@main
struct Mario64MRApp: App {
    @State private var game = GameHost()

    var body: some Scene {
        WindowGroup {
            GameWindow(game: game)
                .onAppear { game.start() }
        }
        .defaultSize(width: 1280, height: 760)
    }
}

/// Phase 1: the game in a flat window, played with a gamepad (or a keyboard)
struct GameWindow: View {
    let game: GameHost
    @State private var renderer: GameRenderer?

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
        }
    }

    private var statusLine: String {
        switch game.status {
        case .starting: "Starting…"
        case .failed: "Stopped"
        case .running: "Game frame \(game.frames) · stage \(game.stage) · \(game.batches) draws · audio \(game.queuedAudio)"
        }
    }
}
