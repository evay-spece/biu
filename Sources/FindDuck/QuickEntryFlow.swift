import SwiftUI

enum FindDuckHighlight {
    static let soft = Color(red: 0.34, green: 0.55, blue: 0.94).opacity(0.16)
    static let selected = soft
    static let hover = Color.primary.opacity(0.065)
}

struct QuickEntryFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width: bounds.width, subviews: subviews)
        for (view, frame) in zip(subviews, layout.frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = CGSize(width: min(width, ideal.width), height: ideal.height)
            if x > 0, x + size.width > width {
                y += height + spacing
                x = 0
                height = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            height = max(height, size.height)
            widest = max(widest, x + size.width)
            x += size.width + spacing
        }
        let rowHeights = Dictionary(grouping: frames, by: { $0.minY }).mapValues { $0.map(\.height).max() ?? 0 }
        for index in frames.indices {
            frames[index].origin.y += ((rowHeights[frames[index].minY] ?? frames[index].height) - frames[index].height) / 2
        }
        return (CGSize(width: width.isFinite ? width : widest, height: y + height), frames)
    }
}
