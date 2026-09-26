import SwiftUI

struct VisualizerHostView: View {
    let player: PlayerViewModel
    let palette: LEDDisplayPalette
    @AppStorage("ledVisualizerID") private var visualizerID = "spectrum.stereo"
    @AppStorage(AppSettingsKey.visualizerResponseMode)
    private var responseModeRaw = AppSettingsDefault.visualizerResponseMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let registry = VisualizerRegistry.shared
    private var style: LEDStyle {
        LEDStyle(palette: palette)
    }

    var body: some View {
        let visualizer = registry.visualizer(for: visualizerID)
        let responseMode = VisualizerResponseMode(rawValue: responseModeRaw) ?? .normal

        Group {
            if reduceMotion {
                Canvas { context, size in
                    draw(
                        visualizer: visualizer,
                        context: context,
                        size: size,
                        frame: .silent()
                    )
                }
            } else {
                TimelineView(.animation(
                    minimumInterval: 1.0 / responseMode.framesPerSecond,
                    paused: player.isPlaying == false && player.audioFrame.isSilent
                )) { _ in
                    Canvas { context, size in
                        draw(
                            visualizer: visualizer,
                            context: context,
                            size: size,
                            frame: player.audioFrame
                        )
                    }
                }
            }
        }
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

    private func draw(
        visualizer: any LEDVisualizer,
        context: GraphicsContext,
        size: CGSize,
        frame: AudioFrameData
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
