import SwiftUI
import TamagotchiCore

/// A comic speech bubble with a little tail pointing at whoever speaks.
struct SpeechBubbleView: View {
    let text: String
    /// Which side the tail is on: the bottom in the scene (speaker below), the top under the menu bar.
    var tailEdge: VerticalEdge = .bottom
    /// Horizontal offset of the tail from the bubble's centre.
    var tailOffset: CGFloat = 0
    var opaque = false

    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false

    var body: some View {
        let shape = BubbleShape(tailEdge: tailEdge, tailOffset: tailOffset)
        Text(text)
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(colorScheme == .dark ? Color.white : Color(hex: 0x3A2E35))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: 170)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .padding(tailEdge == .bottom ? .bottom : .top, BubbleShape.tailHeight)
            .background {
                shape.fill(colorScheme == .dark ? Color(hex: 0x3B3540).opacity(opaque ? 1 : 0.97) : Color.white.opacity(opaque ? 1 : 0.97))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                shape.stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
            .scaleEffect(appeared ? 1 : 0.4, anchor: UnitPoint(x: 0.5 + tailOffset / 200, y: tailEdge == .bottom ? 1 : 0))
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(.spring(duration: 0.38, bounce: 0.45)) { appeared = true }
            }
            .accessibilityLabel(text)
    }
}

struct BubbleShape: Shape {
    static let tailHeight: CGFloat = 6
    var tailEdge: VerticalEdge
    var tailOffset: CGFloat

    func path(in rect: CGRect) -> Path {
        let tail = Self.tailHeight
        let body = tailEdge == .bottom
            ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - tail)
            : CGRect(x: rect.minX, y: rect.minY + tail, width: rect.width, height: rect.height - tail)
        var path = Path(roundedRect: body, cornerRadius: min(11, body.height / 2), style: .continuous)
        let x = min(max(rect.midX + tailOffset, body.minX + 12), body.maxX - 12)
        var spike = Path()
        if tailEdge == .bottom {
            spike.move(to: CGPoint(x: x - 5, y: body.maxY - 0.5))
            spike.addQuadCurve(to: CGPoint(x: x + 1, y: rect.maxY), control: CGPoint(x: x - 1, y: body.maxY + 2))
            spike.addQuadCurve(to: CGPoint(x: x + 5, y: body.maxY - 0.5), control: CGPoint(x: x + 2, y: body.maxY + 1))
        } else {
            spike.move(to: CGPoint(x: x - 5, y: body.minY + 0.5))
            spike.addQuadCurve(to: CGPoint(x: x + 1, y: rect.minY), control: CGPoint(x: x - 1, y: body.minY - 2))
            spike.addQuadCurve(to: CGPoint(x: x + 5, y: body.minY + 0.5), control: CGPoint(x: x + 2, y: body.minY - 1))
        }
        spike.closeSubpath()
        path.addPath(spike)
        return path
    }
}

/// The bubble over the popover scene, above whoever speaks.
struct SceneSpeechOverlay: View {
    let world: CompanionWorld
    let layout: SceneLayout

    var body: some View {
        if let bubble = world.speech, bubble.speaker == .pet || world.companionPresent,
           bubble.speaker == .companion || !world.adventureActive {
            let frame = bubble.speaker == .pet ? layout.petFrame : layout.companionFrame
            let anchorX = frame.midX
            let clampedX = min(max(anchorX, 96), layout.size.width - 96)
            Color.clear
                .frame(width: 1, height: 1)
                .overlay(alignment: .bottom) {
                    SpeechBubbleView(text: bubble.text, tailEdge: .bottom, tailOffset: anchorX - clampedX)
                        .fixedSize()
                        .id(bubble.id)
                }
                .position(x: clampedX, y: max(40, frame.minY + (bubble.speaker == .pet ? 4 : -4)))
                .allowsHitTesting(false)
        }
    }
}
