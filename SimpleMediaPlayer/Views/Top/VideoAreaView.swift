import AVFoundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct VideoAreaView: View {
    let player: PlayerViewModel
    @State private var isFullScreenPresented = false
    @State private var showsControls = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    @State private var fullScreenPresenter = VideoFullScreenPresenter()
    #endif

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            PlayerLayerView(player: player.videoService.player)
                .padding(.vertical, 18)
                .contentShape(Rectangle())
                .gesture(videoTapGesture)
                .modifier(VideoPlaybackAccessibility(player: player))

            HStack {
                Button {
                    player.showVideoArea = false
                } label: {
                    Label("Back to List", systemImage: "chevron.left")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Button {
                    presentFullScreen()
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(14)
            .opacity(showsControls ? 1 : 0)
            .allowsHitTesting(showsControls)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: showsControls)
        }
        .onAppear {
            showsControls = true
        }
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                showsControls = true
            case .ended:
                showsControls = false
            }
        }
        #else
        .onHover { hovering in
            showsControls = hovering
        }
        #endif
        #if !os(macOS)
        .fullScreenCover(isPresented: $isFullScreenPresented) {
            FullScreenVideoView(player: player)
        }
        #endif
    }

    private var videoTapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                presentFullScreen()
            }
            .exclusively(
                before: TapGesture()
                    .onEnded {
                        player.togglePlayPause()
                    }
            )
    }

    private func presentFullScreen() {
        #if os(macOS)
        fullScreenPresenter.present(player: player)
        #else
        isFullScreenPresented = true
        #endif
    }
}

private struct FullScreenVideoView: View {
    let player: PlayerViewModel
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            PlayerLayerView(player: player.videoService.player)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .gesture(videoTapGesture)
                .modifier(VideoPlaybackAccessibility(player: player))

            Button {
                close()
            } label: {
                Label("Close", systemImage: "xmark")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(18)
        }
    }

    private var videoTapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                close()
            }
            .exclusively(
                before: TapGesture()
                    .onEnded {
                        player.togglePlayPause()
                    }
            )
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}

private struct VideoPlaybackAccessibility: ViewModifier {
    let player: PlayerViewModel

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Video")
            .accessibilityValue(player.isPlaying ? Text("Playing") : Text("Paused"))
            .accessibilityHint("Activate to play or pause")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                player.togglePlayPause()
            }
    }
}

#if os(macOS)
@MainActor
private final class VideoFullScreenPresenter {
    private var window: NSWindow?

    func present(player: PlayerViewModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let window = NSWindow(
            contentRect: screenFrame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = player.currentItem?.title ?? L10n.string("Video")
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: FullScreenVideoView(player: player) { [weak self] in
                self?.dismiss()
            }
        )
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
        self.window = window
    }

    func dismiss() {
        window?.close()
        window = nil
    }
}
#endif

#if os(macOS)
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerHostingView {
        let view = PlayerHostingView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerHostingView, context: Context) {
        nsView.playerLayer.player = player
    }
}

final class PlayerHostingView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
#else
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostingView {
        let view = PlayerHostingView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerHostingView, context: Context) {
        uiView.playerLayer.player = player
    }
}

final class PlayerHostingView: UIView {
    let playerLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
#endif
