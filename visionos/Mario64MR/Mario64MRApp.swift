import SwiftUI

@main
struct Mario64MRApp: App {
    @State private var game = GameHost()

    var body: some Scene {
        WindowGroup {
            StatusView(game: game)
                .onAppear { game.start() }
        }
        .defaultSize(width: 640, height: 400)
    }
}

/// Phase 0: the game runs and plays its sound; this shows that it does.
struct StatusView: View {
    let game: GameHost

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mario 64 MR").font(.largeTitle)
            switch game.status {
            case .starting: Text("Starting…")
            case .running: Text("Running").foregroundStyle(.green)
            case .failed(let message): Text(message).foregroundStyle(.red)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("Libraries"); Text(game.libraries) }
                GridRow { Text("Game frames"); Text("\(game.frames)").monospacedDigit() }
                GridRow { Text("Stage"); Text("\(game.stage)").monospacedDigit() }
                GridRow { Text("Batches"); Text("\(game.batches)").monospacedDigit() }
                GridRow { Text("Audio queued"); Text("\(game.queuedAudio) frames").monospacedDigit() }
            }
            .font(.callout)
            Text("Nothing is drawn yet: you should hear the title screen. A paired gamepad's Start begins the game.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(32)
    }
}
