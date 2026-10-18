import SwiftUI

/// Fighting-game hit spark. About 0.7s: a white core, expanding rings,
/// a few sparks, and a gold 「暴击」 that scales in and fades.
struct CritFlashView: View {
    let token: UUID
    /// Target display scale. Stroke width is in points, divided by scale,
    /// so the ring stays about two physical pixels on Retina and non-Retina.
    let contentsScale: CGFloat

    @State private var pop = false
    @State private var fade = false

    var body: some View {
        ZStack {
            core
            rings
            slashes
            particles
            label
        }
        .frame(width: ScreenGeometry.effectSize.width, height: ScreenGeometry.effectSize.height)
        .background(Color.clear)
        .allowsHitTesting(false)
        .id(token)
        .onAppear(perform: start)
    }

    private var hairline: CGFloat {
        max(1, 2 / max(contentsScale, 1))
    }

    private var core: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 16, height: 16)
            .scaleEffect(pop ? 2.4 : 0.2)
            .opacity(pop ? 0 : 1)
            .blur(radius: 0.4)
            .animation(.easeOut(duration: 0.16), value: pop)
    }

    private var rings: some View {
        ForEach(0..<3, id: \.self) { index in
            Circle()
                .stroke(ringColor(index), lineWidth: hairline + CGFloat(index == 0 ? 1 : 0))
                .frame(width: 34, height: 34)
                .scaleEffect(pop ? 1.2 + CGFloat(index) * 0.7 : 0.12)
                .opacity(pop ? 0 : 0.92)
                .animation(.easeOut(duration: 0.62).delay(Double(index) * 0.045), value: pop)
        }
    }

    private var slashes: some View {
        ZStack {
            slash(angle: -32, width: 132)
            slash(angle: 24, width: 96)
        }
        .opacity(fade ? 0 : 1)
        .animation(.easeIn(duration: 0.22).delay(0.36), value: fade)
    }

    private func slash(angle: Double, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(Color.white.opacity(0.92))
            .frame(width: pop ? width : 10, height: 3)
            .rotationEffect(.degrees(angle))
            .animation(.easeOut(duration: 0.18), value: pop)
    }

    private var particles: some View {
        ForEach(0..<8, id: \.self) { index in
            Circle()
                .fill(index.isMultiple(of: 2)
                      ? Color(red: 1, green: 0.84, blue: 0.28)
                      : Color.white)
                .frame(width: index.isMultiple(of: 3) ? 6 : 4, height: index.isMultiple(of: 3) ? 6 : 4)
                .offset(particleOffset(index))
                .opacity(pop ? 0 : 1)
                .animation(.easeOut(duration: 0.5).delay(0.02), value: pop)
        }
    }

    private var label: some View {
        VStack(spacing: -2) {
            Text("CRIT")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .tracking(4)
                .foregroundStyle(Color(red: 1, green: 0.36, blue: 0.18))
            Text("暴击")
                .font(.system(size: 46, weight: .black, design: .rounded))
                .italic()
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 1, green: 0.98, blue: 0.90),
                            Color(red: 1, green: 0.78, blue: 0.12),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .shadow(color: .black.opacity(0.72), radius: 2, y: 1)
        .shadow(color: Color(red: 1, green: 0.42, blue: 0.05).opacity(0.85), radius: pop ? 14 : 0)
        .scaleEffect(pop ? (fade ? 1.08 : 1) : 0.28)
        .opacity(pop ? (fade ? 0 : 1) : 0)
        .offset(y: fade ? -14 : 0)
        .animation(.spring(response: 0.24, dampingFraction: 0.56), value: pop)
        .animation(.easeIn(duration: 0.24).delay(0.38), value: fade)
    }

    private func ringColor(_ index: Int) -> Color {
        switch index {
        case 0: return Color(red: 1, green: 0.86, blue: 0.35)
        case 1: return Color.white.opacity(0.9)
        default: return Color(red: 1, green: 0.42, blue: 0.18)
        }
    }

    private func particleOffset(_ index: Int) -> CGSize {
        let angle = (Double(index) / 8.0) * Double.pi * 2 + 0.35
        let radius: CGFloat = pop ? 86 : 6
        return CGSize(width: CGFloat(cos(angle)) * radius, height: CGFloat(sin(angle)) * radius)
    }

    private func start() {
        pop = false
        fade = false
        DispatchQueue.main.async {
            pop = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
                fade = true
            }
        }
    }
}
