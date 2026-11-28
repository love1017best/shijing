import SwiftUI

/// 幻灯片模式的液态玻璃浮层组件（右上角状态胶囊、左下角时钟与文件名卡片、底部宽/紧凑控制条）。
extension SlideshowView {
    // MARK: - 右上角状态与页码胶囊

    var statusPill: some View {
        let topInsets = topPillInsets
        return VStack {
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: playing ? "play.fill" : "pause.fill")
                        .font(.caption2)
                    Text("\(playing ? "播放中" : "已暂停") · \(currentIndex + 1) / \(max(activeList.count, 1))")
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassBackground(in: Capsule(), tint: .black.opacity(0.28))
            }
            .padding(.leading, max(20, windowSafe.left + 20, occlusion.topLeftWidth + 12))
            .padding(.trailing, topInsets.trailing)
            .padding(.top, topInsets.top)
            Spacer()
        }
    }

    // MARK: - 液态玻璃时钟与文件名卡片

    var infoCard: some View {
        Button {
            openCurrentForOrganize()
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ctx.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                            .font(.system(size: isWide ? 36 : 30, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
                            .lineLimit(1)
                        Text(SlideshowLogic.dateText(ctx.date))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.84))
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    HStack(spacing: 5) {
                        Text(SlideshowLogic.displayTitle(currentWall?.name ?? current))
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .frame(maxWidth: isWide ? 280 : 260, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .glassBackground(in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                             tint: .black.opacity(0.28), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看并整理当前壁纸：\(currentWall?.name ?? current)")
    }

    // MARK: - 液态玻璃控制条

    var wideControlBar: some View {
        HStack(spacing: 4) {
            playbackButtons
            barDivider
            optionButtons
            barDivider
            organizeButton
            closeButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassBackground(in: Capsule(), tint: .black.opacity(0.32))
        .fixedSize(horizontal: true, vertical: false)
    }

    var compactControlBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                optionButtons
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassBackground(in: Capsule(), tint: .black.opacity(0.3))
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 6) {
                playbackButtons
                barDivider
                organizeButton
                closeButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassBackground(in: Capsule(), tint: .black.opacity(0.34))
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var playbackButtons: some View {
        barIconButton("backward.fill", label: "上一张") {
            Task { await step(-1) }
            pokeHUD()
        }
        barIconButton(playing ? "pause.fill" : "play.fill", label: playing ? "暂停" : "播放", active: playing) {
            playing.toggle()
            pokeHUD()
        }
        barIconButton("forward.fill", label: "下一张") {
            Task { await step(1) }
            pokeHUD()
        }
    }

    @ViewBuilder
    private var optionButtons: some View {
        Button {
            cycleInterval()
            pokeHUD()
        } label: {
            Text(SlideshowLogic.intervalLabel(intervalSec))
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(.white.opacity(0.94))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("切图间隔：\(SlideshowLogic.intervalLabel(intervalSec))")

        barIconButton("shuffle", label: "随机播放", active: shuffle) {
            shuffle.toggle()
            rebuildOrderIfNeeded(keeping: current)
            pokeHUD()
        }
        barIconButton(shouldFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                      label: shouldFill ? "改为完整显示" : "改为铺满屏幕", active: shouldFill) {
            toggleFit()
            pokeHUD()
        }
        barIconButton("clock", label: showInfo ? "隐藏时钟与文件名" : "显示时钟与文件名", active: showInfo) {
            withAnimation(.easeInOut(duration: 0.2)) { showInfo.toggle() }
            pokeHUD()
        }
        barIconButton(keepAwake ? "sun.max.fill" : "sun.max",
                      label: keepAwake ? "关闭防息屏" : "开启防息屏", active: keepAwake) {
            keepAwake.toggle()
            pokeHUD()
        }
    }

    private var organizeButton: some View {
        Button {
            openCurrentForOrganize()
        } label: {
            Text("整理")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(.white.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("跳转到当前图片的大图预览进行整理")
    }

    private var closeButton: some View {
        barIconButton("xmark", label: "退出幻灯片") {
            dismiss()
        }
    }

    private func barIconButton(_ systemName: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(active ? 1 : 0.85))
                .frame(width: 34, height: 34)
                .background(active ? .white.opacity(0.22) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var barDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.2))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 2)
    }
}
