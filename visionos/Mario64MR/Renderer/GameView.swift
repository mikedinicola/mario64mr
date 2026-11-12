import MetalKit
import SwiftUI

/// The game drawn into a flat view, 16:9 like the 60 fps build's window
struct GameView: UIViewRepresentable {
    let renderer: GameRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        renderer.configure(view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}
}
