import SwiftUI

struct VisualizerHostView: View {
    let player: PlayerViewModel
    let palette: LEDDisplayPalette
    let reduceMotionOverride: Bool?
    @AppStorage("ledVisualizerID") private var visualizerID = "spectrum.stereo"
    @AppStorage(AppSettingsKey.visualizerResponseMode)
    private var responseModeRaw = AppSettingsDefault.visualizerResponseMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let registry = VisualizerRegistry.shared

    init(player: PlayerViewModel, palette: LEDDisplayPalette, reduceMotionOverride: Bool? = nil) {
        self.player = player
        self.palette = palette
        self.reduceMotionOverride = reduceMotionOverride
    }
    private var style: LEDStyle {
        LEDStyle(palette: palette)
    }

    var body: some View {
        let visualizer = registry.visualizer(for: visualizerID)
        let responseMode = VisualizerResponseMode(rawValue: responseModeRaw) ?? .normal
        let reduceMotion = reduceMotionOverride ?? self.reduceMotion

        visualizationContent(visualizer: visualizer, responseMode: responseMode, reduceMotion: reduceMotion)
        .contentShape(Rectangle())
        .onTapGesture {
            visualizerID = registry.next(after: visualizerID).id
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio Visualizer")
        .accessibilityValue(Text(visualizer.displayName))
        .accessibilityHidden(registry.visualizers.count <= 1)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            visualizerID = registry.next(after: visualizerID).id
        }
        .contextMenu {
            ForEach(registry.visualizers, id: \.id) { item in
                Button(item.displayName) {
                    visualizerID = item.id
                }
            }
        }
        .onAppear {
            player.setVisualizerBandCount(visualizer.requiredBandCount)
            player.setVisualizerResponseMode(responseMode)
        }
        .onChange(of: visualizerID) { _, newValue in
            player.setVisualizerBandCount(registry.visualizer(for: newValue).requiredBandCount)
        }
        .onChange(of: responseModeRaw) { _, newValue in
            player.setVisualizerResponseMode(VisualizerResponseMode(rawValue: newValue) ?? .normal)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: visualizerID)
    }

    func visualizationContent(
        visualizer: any LEDVisualizer, responseMode: VisualizerResponseMode, reduceMotion: Bool
    ) -> some View {
        Group {
            if reduceMotion {
                Canvas { context, size in
                    draw(visualizer: visualizer, context: context, size: size, frame: .silent(), reduceMotion: true)
                }
            } else {
                // Read only the idle flag here. Canvas reads per-frame values while drawing,
                // so analysis frames do not invalidate the enclosing view.
                TimelineView(.animation(
                    minimumInterval: 1.0 / responseMode.framesPerSecond,
                    paused: player.isVisualizerIdle
                )) { _ in
                    Canvas { context, size in
                        draw(
                            visualizer: visualizer, context: context, size: size,
                            frame: player.audioFrame, reduceMotion: false
                        )
                    }
                }
                .modifier(VisualizationConsumer(player: player))
            }
        }
    }

    private func draw(
        visualizer: any LEDVisualizer,
        context: GraphicsContext,
        size: CGSize,
        frame: AudioFrameData,
        reduceMotion: Bool
    ) {
        var drawingContext = context
        visualizer.draw(
            in: &drawingContext,
            size: size,
            frame: frame,
            style: style,
            spectrumFrameRate: reduceMotion ? 0 : player.spectrumFrameRate,
            isEqualizerActive: player.equalizer.isEnabled
        )
    }
}

/// Keeps spectrum analysis running while the modified view, which draws `audioFrame`, is on screen.
struct VisualizationConsumer: ViewModifier {
    let player: PlayerViewModel
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { player.addVisualizationConsumer(id) }
            .onDisappear { player.removeVisualizationConsumer(id) }
    }
}
