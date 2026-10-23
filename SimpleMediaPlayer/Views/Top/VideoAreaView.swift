import AVFoundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct VideoAreaView: View {
    let player: PlayerViewModel
    var showsBackToListButton = true
    var presentVideoFullScreen: (() -> Void)?
    @Environment(\.usesTouchControls) private var usesTouchControls
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
                if showsBackToListButton {
                    Button {
                        player.showVideoArea = false
                    } label: {
                        Label("Back to List", systemImage: "chevron.left")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()

                Button {
                    presentFullScreen()
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: usesTouchControls ? 44 : nil)
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
        guard player.isVideoMode, player.currentItem?.isVideo == true else { return }
        if let presentVideoFullScreen {
            presentVideoFullScreen()
        } else {
            isFullScreenPresented = true
        }
        #endif
    }
}

struct FullScreenVideoView: View {
    let player: PlayerViewModel
    var onClose: (() -> Void)?
    @Environment(\.usesTouchControls) private var usesTouchControls
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            fullScreenVideo
                .contentShape(Rectangle())
                .gesture(videoTapGesture)

            #if os(iOS)
            fullScreenControls
            #else
            closeButton.padding(18)
            #endif
        }
    }

    #if os(iOS)
    private var fullScreenControls: some View {
        GeometryReader { proxy in
            let frame = FullScreenVideoLayout.controlsFrame(
                in: CGRect(origin: .zero, size: proxy.size),
                activeDivisionFrames: DeckReservedRegions.activeDivisionFrames(in: proxy)
            )
            DeckSafeControlsOverlay {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { playbackButton; closeButton }
                    VStack(alignment: .trailing, spacing: 12) { playbackButton; closeButton }
                }
                .padding(18)
            }
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
        }
    }
    #endif

    @ViewBuilder private var fullScreenVideo: some View {
        #if os(iOS)
        GeometryReader { proxy in
            let frame = FullScreenVideoLayout.videoFrame(
                in: CGRect(origin: .zero, size: proxy.size),
                activeDivisionFrames: DeckReservedRegions.activeDivisionFrames(in: proxy)
            )
            PlayerLayerView(player: player.videoService.player)
                .frame(width: frame.width, height: frame.height)
                .modifier(VideoPlaybackAccessibility(player: player))
                #if DEBUG
                .modifier(DuoPanelRegionDiagnostics(regionID: "fullScreenVideo"))
                #endif
                .offset(x: frame.minX, y: frame.minY)
        }
        .ignoresSafeArea()
        #else
        PlayerLayerView(player: player.videoService.player)
            .ignoresSafeArea()
            .modifier(VideoPlaybackAccessibility(player: player))
        #endif
    }

    private var closeButton: some View {
        Button {
            close()
        } label: {
            Label("Close", systemImage: "xmark")
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .frame(minWidth: usesTouchControls ? 44 : nil, minHeight: usesTouchControls ? 44 : nil)
        .accessibilityIdentifier("videoFullScreenCloseButton")
    }

    #if os(iOS)
    private var playbackButton: some View {
        Button { player.togglePlayPause() } label: {
            Label(player.canPause ? L10n.string("Pause") : L10n.string("Play"),
                  systemImage: player.canPause ? "pause.fill" : "play.fill")
                .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(!player.isVideoMode)
        .accessibilityIdentifier("videoFullScreenPlayPauseButton")
    }
    #endif

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
