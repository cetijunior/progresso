import SwiftUI

/// The one place UI chrome colors live. Views read `@Environment(\.colorScheme)`
/// and build a `Theme` from it instead of scattering `scheme == .light`
/// ternaries — change a value here and every surface follows.
///
/// Light mode is a warm "paper" look: off-white board, slightly darker
/// columns, pure-white cards lifted by a hairline border + soft shadow.
/// Dark mode defers to the system's semantic colors.
struct Theme {
    let scheme: ColorScheme
    var isLight: Bool { scheme == .light }

    // MARK: Board surfaces

    /// The canvas behind the columns (also used behind the page-tab strip
    /// so the strip reads as part of the board, not a separate bar).
    var boardBackground: Color {
        isLight ? Color(red: 0.956, green: 0.949, blue: 0.933)
                : Color(nsColor: .windowBackgroundColor)
    }

    var columnFill: Color {
        isLight ? Color(red: 0.912, green: 0.904, blue: 0.884)
                : Color(nsColor: .underPageBackgroundColor)
    }

    var columnBorder: Color {
        isLight ? Color.black.opacity(0.06) : .clear
    }

    /// Hairline under the page-tab strip separating it from the columns.
    var hairline: Color {
        isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.08)
    }

    // MARK: Cards

    var cardFill: Color {
        isLight ? .white : Color(nsColor: .controlBackgroundColor)
    }

    /// nil = no border (dark mode relies on contrast, not strokes).
    var cardBorder: Color? {
        isLight ? Color.black.opacity(0.07) : nil
    }

    func cardShadow(hovering: Bool) -> Color {
        .black.opacity(isLight ? (hovering ? 0.14 : 0.07)
                               : (hovering ? 0.22 : 0.10))
    }

    // MARK: Sheet accents (dashboard stat tiles etc.)

    /// Stat tiles sit on a plain sheet background — in light they get the
    /// board's paper tone + hairline so they don't wash out white-on-white.
    var tileFill: Color {
        isLight ? Color(red: 0.956, green: 0.949, blue: 0.933)
                : Color(nsColor: .controlBackgroundColor)
    }

    var tileBorder: Color {
        isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.06)
    }
}

/// Left-aligned flow layout: chips wrap to the next line instead of
/// stretching the row past the card's edge (which is what happened when a
/// paid amount, contract, assignee, AND due date all showed at once).
struct WrapChips: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0; y += rowHeight + lineSpacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: maxWidth == .infinity ? widest : maxWidth,
                      height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + lineSpacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
