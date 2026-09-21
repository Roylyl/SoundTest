// Native surfaces and version fallbacks adapted from ASRtest/GlassStyle.swift.
import SwiftUI

struct SoundBackdrop: View {
    var body: some View { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() }
}
extension View {
    @ViewBuilder func soundGlass() -> some View {
        if #available(iOS 26, *) { glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24)) }
        else { background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24)) }
    }
    @ViewBuilder func soundButton(prominent: Bool = false) -> some View {
        if #available(iOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}
func timeText(_ value: Double) -> String { String(format: "%.2f s", value) }
func msText(_ value: Double) -> String { String(format: "%.1f ms", value) }
func scoreText(_ value: Double?) -> String { value.map { String(format: "%.4f", $0) } ?? "未返回 / 标签不支持" }
