import SwiftUI

/// Discrete brightness HUD: segmented progress bar where each segment
/// corresponds to one 1/16 brightness step (16 segments total).
struct BrightnessHUDView: View {
    let brightness: Double

    private let segmentCount = 16

    private var normalizedBrightness: Double {
        min(max(brightness, 0), 1)
    }

    private var activeSegments: Int {
        Int((normalizedBrightness * Double(segmentCount)).rounded())
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 23, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)

            HStack(spacing: 3) {
                ForEach(0..<segmentCount, id: \.self) { index in
                    Capsule()
                        .fill(
                            index < activeSegments
                                ? Color.primary
                                : Color.secondary.opacity(0.25)
                        )
                        .frame(width: 5, height: 24)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: activeSegments)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 13)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            Color.primary.opacity(0.08),
                            lineWidth: 0.7
                        )
                }
        }
        .shadow(
            color: .black.opacity(0.12),
            radius: 20,
            x: 0,
            y: 8
        )
        .fixedSize()
    }
}


struct BrightnessHUDModifier: ViewModifier {

    @Binding var brightness: Double?
    @State private var trigger = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                VStack {
                    Spacer()
                    if let value = brightness {
                        BrightnessHUDView(brightness: value)
                            .transition(
                                .opacity.combined(with: .scale(scale: 0.95))
                            )
                            .zIndex(50)
                            .padding(.bottom, 24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
            .onChange(of: brightness) { newValue in
                guard newValue != nil else { return }
                trigger += 1
            }
            .task(id: trigger) {
                guard brightness != nil else { return }
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }

                withAnimation(.easeIn(duration: 0.25)) {
                    brightness = nil
                }
            }
    }
}

extension View {
    func brightnessHUD(_ brightness: Binding<Double?>) -> some View {
        modifier(BrightnessHUDModifier(brightness: brightness))
    }
}

#Preview("Light") {
    BrightnessHUDView(brightness: 0.4)
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    BrightnessHUDView(brightness: 0.5)
        .preferredColorScheme(.dark)
}
