import SwiftUI

struct LEDBezelPlate<Content: View>: View {
    let corner: LEDPanelCorner
    let side: LEDPanelSide
    let palette: BottomPanelPalette
    private let content: (ConcentricRectangle) -> Content

    init(
        corner: LEDPanelCorner,
        side: LEDPanelSide,
        palette: BottomPanelPalette,
        @ViewBuilder content: @escaping (ConcentricRectangle) -> Content
    ) {
        self.corner = corner
        self.side = side
        self.palette = palette
        self.content = content
    }

    var body: some View {
        let bezelShape = corner.cornerStyles(side: side).shape

        content(corner.cornerStyles(side: side, inset: 1).shape)
            .padding(.top, 2)
            .padding(.horizontal, 1)
            .padding(.bottom, 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                bezelShape
                    .fill(palette.displayBezelFill)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(palette.displayBezelTopLine)
                            .frame(height: 1)
                    }
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(palette.displayBezelInnerShadow)
                            .frame(height: 3)
                            .padding(.top, 2)
                    }
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(palette.displayBezelBottomLine)
                            .frame(height: 1)
                    }
                    .clipShape(bezelShape)
            )
            .clipShape(bezelShape)
    }
}
