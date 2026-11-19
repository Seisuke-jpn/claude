import SwiftUI

/// 右側のペン道具パレット
struct ToolPalette: View {
    @ObservedObject var ink: InkModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                ForEach(InkModel.palette.indices, id: \.self) { index in
                    Button { ink.colorIndex = index } label: {
                        Circle()
                            .fill(Color(uiColor: InkModel.palette[index]))
                            .frame(width: 30, height: 30)
                            .overlay(
                                Circle().strokeBorder(Color.white, lineWidth: ink.colorIndex == index ? 3 : 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Divider().frame(width: 44)

                ForEach(InkModel.widths.indices, id: \.self) { index in
                    Button { ink.widthLevel = index } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(ink.widthLevel == index ? Color.white.opacity(0.25) : Color.clear)
                                .frame(width: 48, height: 34)
                            Capsule()
                                .fill(Color.white)
                                .frame(width: 28, height: CGFloat(2 + index * 4))
                        }
                    }
                    .buttonStyle(.plain)
                }

                Divider().frame(width: 44)

                PaletteButton(title: "戻す", systemImage: "arrow.uturn.backward") { ink.undo() }
                    .disabled(!ink.canUndo)
                PaletteButton(title: "全消去", systemImage: "trash") { ink.clear() }
                    .disabled(ink.isEmpty)

                Divider().frame(width: 44)

                PaletteToggle(title: "指で描く", systemImage: "hand.draw", isOn: $ink.allowFinger)
                PaletteToggle(title: "再生で消す", systemImage: "play.circle", isOn: $ink.clearOnPlay)

                if let delay = ink.lastTouchDelayMs {
                    VStack(spacing: 2) {
                        Text("入力の遅れ")
                        Text("\(delay)ms")
                            .monospacedDigit()
                            .foregroundStyle(delay > 30 ? Color.orange : Color.green)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 78)
        .background(.ultraThinMaterial)
    }
}

private struct PaletteButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(width: 64, height: 46)
        }
    }
}

private struct PaletteToggle: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(width: 64, height: 46)
            .foregroundStyle(isOn ? Color.yellow : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isOn ? Color.yellow.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}
