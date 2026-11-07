import SwiftUI

/// The outer stroke of the ARNA logo: an open triangle without a base, drawn from the left foot over the apex.
public struct ARNAChevron: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

/// The ARNA mark used as a progress indicator: a faint chevron track and a stroke that grows along it.
public struct ARNAProgressMark: View {
    public var progress: Double
    public var tint: Color
    public var track: Color
    public var lineWidth: CGFloat

    public init(progress: Double, tint: Color, track: Color, lineWidth: CGFloat = 10) {
        self.progress = progress
        self.tint = tint
        self.track = track
        self.lineWidth = lineWidth
    }

    private var clamped: Double { min(1, max(0, progress)) }

    public var body: some View {
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        ZStack {
            ARNAChevron()
                .stroke(track, style: style)
            ARNAChevron()
                .trim(from: 0, to: clamped)
                .stroke(tint, style: style)
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: clamped)
        }
        .padding(lineWidth / 2)
        .accessibilityElement()
        .accessibilityLabel("Прогресс")
        .accessibilityValue("\(Int((clamped * 100).rounded())) %")
    }
}

/// The lilac accent of the ARNA logo, for places without the app's design system.
public enum ARNABrand {
    public static let lilac = Color(red: 0.78, green: 0.70, blue: 0.96)
    public static let violet = Color(red: 0.42, green: 0.31, blue: 0.85)
}
