import SwiftUI

// MARK: - 顶栏、侧列与底栏

extension WallPreview {
    /// 编号胶囊，点开输入编号跳转。
    func numberPill(_ i: Int) -> some View {
        Button {
            jumpText = ""
            jumpLayout = layoutSize
            jumping = true
        } label: {
            Text("\(i + 1) / \(walls.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.primary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassBackground(in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(i + 1) 张，共 \(walls.count) 张")
        .accessibilityHint("输入编号跳转")
    }

    /// 顶栏。关闭和撤销在左、编号跟在后面；宽屏照系统相册把分享和整理操作放顶部右边一排；
    /// 右边一列的时候顶部只剩编号，按钮都在列里（见 sideButtons）。
    /// 编号以前是 `.overlay` 挂在整条顶栏正中间，Duo 内屏竖放右边那组按钮一宽（分享 + 三个图标的胶囊 + 删除
    /// 约 260pt）就顶到编号右缘上了（v0.3.168 用户反馈「跳转按钮和编号重叠」）。现在编号是这一行里的
    /// 普通一项，右边靠 Spacer 撑开，不会再叠；窄屏（普通 iPhone）还是要居中，用两个 Spacer 夹住。
    var topBar: some View {
        HStack(spacing: 8) {
            if !sideColumn {
                circleButton("xmark", label: "关闭", size: topButtonSize) { dismiss() }
                if let undo = session.undoName { undoButton(undo, size: topButtonSize) }
            }
            if sideColumn || !wide {
                Spacer(minLength: 8)
                if let index { numberPill(index) }
                Spacer(minLength: 8)
            } else {
                if let index { numberPill(index) }
                Spacer(minLength: 8)
                if let wall { topActions(wall) }
            }
        }
        .padding(.leading, 20)
        // Duo 内屏竖放：系统相册把按钮行和右上角的时间、信号放在同一行（v0.3.167）；
        // 有灵动岛实时活动时状态栏会往左扩展，按系统报的遮挡区动态让开。
        .padding(.trailing, topRowBesideStatusBar ? statusBarTrailing : 20)
        // 铺满全屏后 padding 是从屏幕边缘算的，安全区得自己加：竖屏状态栏 / 灵动岛下面再留 8，
        // 横屏（安全区几乎为 0）离上边缘至少 28，不然编号贴着屏幕边。
        // Duo 内屏竖放例外：状态栏本来就占着顶上一整行（安全区 82），按钮行要跟它并排、不能落到下面
        // （21 让 38 高的按钮中心落在 40，量系统相册同一行的按钮中心就是 40，见 topBarTopPadding）。
        .padding(.top, topBarTopPadding)
        .padding(.bottom, 8)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { topBarBottom = $0 }
    }

    /// 顶栏这一排的按钮直径。Duo 内屏竖放那种和状态栏并排的排法，系统相册用 38（量过），
    /// 一直用 44 会比状态栏那一行明显大一号（v0.3.168 用户反馈「按钮大小还是不对」）。
    private var topButtonSize: CGFloat { topRowBesideStatusBar ? 38 : 44 }
    /// 整理操作那块胶囊的高度，跟着圆钮一起收。
    private var topPillSize: CGFloat { topRowBesideStatusBar ? 42 : 48 }

    /// 顶栏离上边缘多远。右边一列时顶部只剩编号：
    /// 横放时状态栏在右上角竖着排（内屏）或者根本不显示（外屏），编号照系统相册那条日期卡贴顶放 28；
    /// 竖放时状态栏是竖着排在右上角的，编号比它再往下一点（用户嫌贴着屏幕边，v0.3.168 从 28 提到 40）。
    private var topBarTopPadding: CGFloat {
        // 21 让 38 高的按钮中心落在 40，和系统相册那一行、状态栏（安全区 82 的一半）同一个高度
        if topRowBesideStatusBar { return 21 }
        if sideColumn {
            if layoutSize.width > layoutSize.height { return 28 }
            return max(windowSafe.top + 12, 40)
        }
        let occ = duoInnerPortrait ? (topRightOcclusion.bottom ?? 0) : 0
        return max(windowSafe.top + 8, occ + 8, 28)
    }

    /// Duo 内屏竖放的屏形：宽屏竖放、宽度不到 iPad 那档（Duo 内屏竖放 669×951，iPad mini 竖放 744 宽）。
    /// 以前按窗口顶安全区 > 60 认，真机上读到的值和模拟器不一样，按钮行掉到状态栏下面去了（v0.3.168）。
    private var duoInnerPortrait: Bool {
        wide && !sideColumn && layoutSize.height > layoutSize.width && layoutSize.width < 700
    }

    /// 内屏竖放与状态栏并排时，顶栏右边需要留出的距离（屏右缘到删除按钮右缘）。
    /// 平常状态栏占约 111pt、固定留 140pt；灵动岛有实时活动（如导航、媒体）时遮挡区往左扩，
    /// 按系统报的遮挡宽度再加一点留白，避免最右侧的删除按钮被时间和灵动岛挡住。
    private var statusBarTrailing: CGFloat {
        max(140, topRightOcclusion.topWidth + 8)
    }

    /// 顶部那一排按钮要不要和状态栏并排：Duo 内屏竖放，且让开状态栏和灵动岛后还放得下整排按钮。
    /// 若灵动岛展开得很宽导致放不下，自动退回落到状态栏下方（按钮不和编号挤在一起，也不被遮挡）。
    private var topRowBesideStatusBar: Bool {
        guard duoInnerPortrait else { return false }
        // 左边距 20 + 关闭 38 + (撤销 46) + 编号 ~96 + 间距 8 + 右侧操作组 224 ≈ 386（有撤销 432）
        let needed: CGFloat = session.undoName == nil ? 400 : 444
        return layoutSize.width - statusBarTrailing >= needed
    }

    private func undoButton(_ name: String, size: CGFloat = 44) -> some View {
        circleButton("arrow.uturn.backward", label: "撤销移出 \(name)", size: size) {
            Task {
                if let n = await session.undoRemove(), walls.contains(where: { $0.name == n }) { go(to: n) }
            }
        }
        .disabled(session.acting != nil || (!session.offline && session.state?.running == true))
    }

    /// 宽屏竖屏时顶栏右边这一组（照系统相册）：分享、一块玻璃里三个整理操作、红色的删除。
    private func topActions(_ w: Wallpaper) -> some View {
        HStack(spacing: 8) {
            ShareOriginalButton(session: session, wall: w, glass: true, size: topButtonSize)
            actionPill(w, size: topPillSize)
            if w.canDeleteOriginal {
                actionCircle(.delete, w, size: topButtonSize)
                    .deleteOriginalDialog(session: session, wall: $confirmDelete)
            }
        }
    }

    /// 那一竖列（照系统相册）：撤销、关闭、分享各自一颗，中间一列整理操作，最下面删除。
    /// 放摄像头那一侧（见 columnOnRight）。竖放时整列垂直居中，避开右上角竖排的状态栏
    /// （Duo 外屏竖放时那排时间和 Wi‑Fi 竖着排在右边，一直画到 150pt 左右）；横放时状态栏在顶部横排，
    /// 整列跟着贴顶，起点和编号胶囊、状态栏同一行。
    /// **横放时还要避开前置摄像头**（v0.3.166）：整页 `ignoresSafeArea` 铺满，系统不会替我们让开，
    /// 摄像头在左上角时关闭按钮正好压在挖孔上、点不到。摄像头在这一侧的上半部分时，
    /// 整列从它的下沿（+8）开始；在下半部分（右下角）时不冲突，照常贴顶。
    /// 普通 iPhone 横放屏幕高 380 以下时才用小一号（圆钮 38、胶囊里 42、间距 6）。
    func sideButtons(_ w: Wallpaper) -> some View {
        let tight = tightColumn
        let landscape = layoutSize.width > layoutSize.height
        let button: CGFloat = tight ? 38 : 44
        let pill: CGFloat = tight ? 42 : 48
        let camNearTop = cameraFrame != .zero && cameraFrame.midY < layoutSize.height / 2
        // 只有外屏 / 手机这种小屏才可能让摄像头压到这一列上（Duo 外屏横放时挖孔在角上，和列同一条竖线）。
        // 摄像头压在列上才让开，而且只在列位于左侧时检查：Duo 外屏横放「圆角朝下」那一向摄像头在左上角，
        // 跟这一列同一条竖线（v0.3.166 用户反馈关闭按钮点不到就是这一向）；另一向摄像头在右下角，不冲突。
        // Duo 内屏横放不走这条路：那块挖孔和右上角的状态栏是同一块，见下面的 tallScreen。
        let camOnColumn = !columnOnRight && cameraFrame != .zero && cameraFrame.minX < 60
        // 内屏横放：系统相册保留右上角那块状态栏（时间、电量、信号竖着排），按钮列紧贴着它下面开始——
        // 那块就是前置摄像头的遮挡区（模拟器上量到 951 宽的屏上到 y 124.5），系统相册第一颗按钮顶边
        // 也是 124。外屏、手机横放：状态栏不显示，贴顶 28，摄像头压在同一侧时往下让开。
        let tallScreen = layoutSize.height >= 640
        let camOnColumnSide = cameraFrame != .zero
            && (columnOnRight ? cameraFrame.midX > layoutSize.width / 2 : cameraFrame.midX < layoutSize.width / 2)
        // 竖放：状态栏竖着排在右上角，整列放在它下面那段里居中。量不到遮挡区（iOS 27.1 以前）时按
        // 外屏竖放状态栏的高度留（模拟器量到 174）。以前整屏居中，列一高（有撤销按钮）或者灵动岛里有实时活动，
        // 关闭按钮就落到电量图标下面、点不到（v0.4.18 用户反馈）。
        let statusBottom = topRightOcclusion.bottom ?? 174
        let topInset: CGFloat = landscape
            ? (tallScreen
                ? (camNearTop && camOnColumnSide ? cameraFrame.maxY : max(windowSafe.top + button, 28))
                : (camNearTop && camOnColumn ? max(cameraFrame.maxY + 8, 28) : max(windowSafe.top + 8, 28)))
            : max(statusBottom + 12, windowSafe.top + 8, 28)
        // 竖放：状态栏下面那段里，上下两个 Spacer 夹住、垂直居中；横放：上面不留、下面用 Spacer 撑开，贴顶。
        // 不用 `.frame(maxHeight: .infinity, alignment: .top)`：overlay 里给的高度提案不一定是整屏，
        // 横向那一版对齐偶尔没生效、整列被顶到中间偏下（v0.3.168 内屏横放踩过）。
        return VStack(spacing: 0) {
            if !landscape { Spacer(minLength: 0) }
            VStack(spacing: tight ? 6 : 8) {
                if let undo = session.undoName { undoButton(undo, size: button) }
                circleButton("xmark", label: "关闭", size: button) { dismiss() }
                ShareOriginalButton(session: session, wall: w, glass: true, size: button)
                actionPill(w, vertical: true, size: pill)
                if w.canDeleteOriginal {
                    actionCircle(.delete, w, size: button)
                        .deleteOriginalDialog(session: session, wall: $confirmDelete)
                }
            }
            .padding(.top, landscape ? topInset : 0)
            Spacer(minLength: 0)
        }
        // 竖放时上面让开状态栏（topInset），底部让开小横条；用 padding，别用 Color.clear 占位：
        // 它横向会撑满，整列就跑到屏幕中间了
        .padding(.top, landscape ? 0 : topInset)
        .padding(.bottom, landscape ? 0 : max(24, windowSafe.bottom + 12))
        .frame(maxHeight: .infinity)
        // 离屏幕边 24：和状态栏同一条竖线（对着系统相册量的：外屏竖放 457 宽时按钮中心 408.5、
        // 时间也在这条线上；内屏横放 951 宽时按钮中心 903）。列里最宽的是胶囊 48，所以 951−24−24=903。
        // 以前给 20 整列偏右、给 26/32 又偏左 2~6pt
        .padding(columnOnRight ? .trailing : .leading, 24)
    }

    /// 圆形的玻璃按钮（关闭、撤销、分享）。
    private func circleButton(_ icon: String, label: String, size: CGFloat = 44,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 20, weight: .semibold))
                .glassCircle(size: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// 操作图标（不带玻璃）：存到相册正在下载时换成一个转圈。
    private func actionIcon(_ kind: WallActionKind, _ w: Wallpaper) -> some View {
        Group {
            if kind == .save, session.saving == w.name {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: kind.icon).font(.system(size: 20, weight: .semibold))
            }
        }
        .foregroundStyle(kind.isDestructive ? Color.red : Color.primary)
    }

    /// 单独一颗圆的整理操作（右上角那一排、竖屏右边的删除）。
    private func actionCircle(_ kind: WallActionKind, _ w: Wallpaper, size: CGFloat = 44) -> some View {
        let enabled = kind.isEnabled(session, w)
        return Button(role: kind.isDestructive ? .destructive : nil) {
            kind.perform(session, w, confirmDelete: $confirmDelete)
        } label: {
            actionIcon(kind, w)
                .glassCircle(size: size)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(kind == .save && session.saving == w.name ? "正在下载" : kind.barTitle)
        .accessibilityHint(kind.hint)
    }

    func bottomBar(_ w: Wallpaper) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 把手：上滑 / 点它显示、收起文件名（VoiceOver 用户没法靠滑动）
            Button {
                withAnimation(.spring(duration: 0.35)) { showsInfo.toggle() }
            } label: {
                Capsule().fill(.secondary).frame(width: 36, height: 5)
                    .frame(maxWidth: .infinity).padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsInfo ? "收起文件名" : "显示文件名")

            // 缩略图条撑满整行，当前那张对齐屏幕正中（内屏侧边的传感器区会让这条变窄，不能用它自己的正中）；
            // 宽屏横放时右边让开按钮那一列（直接缩窄这条，加 padding 挡不住滚动内容画到屏幕边上），
            // 条按自己的正中（照系统相册）
            FilmStrip(session: session, current: current, screenMidX: sideColumn ? nil : screenMidX,
                      inset: sideColumn ? 84 : 0, insetOnRight: columnOnRight) { go(to: $0) }
                .padding(.horizontal, -20)

            if showsInfo {
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.name).font(.subheadline.bold()).lineLimit(1).truncationMode(.middle)
                    Text(sourceCaption(w))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassBackground(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if session.state?.running == true {
                Label("正在更换壁纸，等更换完成后再整理", systemImage: "hourglass")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if !wide && !sideColumn { actionRow(w) } // 宽屏的按钮在顶栏，右边一列时在右列里
        }
        .padding(.horizontal, 20).padding(.top, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { bottomBarTop = $0 }
    }

    private func sourceCaption(_ w: Wallpaper) -> String {
        if !w.hasSource {
            return "原图：无记录（由旧版本更换），无法删除，只能移出"
        }
        if w.isSampleOnly {
            return "原图：\(w.source ?? "")（仅采样目录，不可删除原图）"
        }
        return "原图：\(w.source ?? "")"
    }

    /// 窄屏底部这一排（照系统相册的 iPhone 版）：左边分享，中间一块玻璃里排三个整理操作，右边红色的删除。
    /// 不可删除原图时右侧用同宽透明占位，让中间的玻璃胶囊继续居中。不写文字，只说给 VoiceOver 听。
    private func actionRow(_ w: Wallpaper) -> some View {
        HStack(spacing: 0) {
            ShareOriginalButton(session: session, wall: w, glass: true, size: 44)
            Spacer(minLength: 12)
            actionPill(w)
            Spacer(minLength: 12)
            if w.canDeleteOriginal {
                actionCircle(.delete, w)
                    .deleteOriginalDialog(session: session, wall: $confirmDelete)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .frame(height: 52)
    }

    /// 存到相册、移出、不再选它三颗共用一层玻璃（相册里也是几个图标装在一个胶囊里）。
    /// `vertical`：宽屏横放时右边那一列是竖着的。
    private func actionPill(_ w: Wallpaper, vertical: Bool = false, size: CGFloat = 50) -> some View {
        let kinds = Self.pillKinds.filter { !$0.needsSource || w.hasSource }
        return Group {
            if vertical {
                VStack(spacing: 0) { contents(kinds, w, size: size) }.padding(.vertical, 3)
            } else {
                HStack(spacing: 0) { contents(kinds, w, size: size) }.padding(.horizontal, 3)
            }
        }
        .glassBackground(in: Capsule(), interactive: true)
    }

    private func contents(_ kinds: [WallActionKind], _ w: Wallpaper, size: CGFloat) -> some View {
        ForEach(kinds, id: \.self) { kind in pillButton(kind, w, size: size) }
    }

    private static let pillKinds: [WallActionKind] = [.save, .remove, .exclude]

    private func pillButton(_ kind: WallActionKind, _ w: Wallpaper, size: CGFloat) -> some View {
        let enabled = kind.isEnabled(session, w)
        return Button {
            kind.perform(session, w, confirmDelete: $confirmDelete)
        } label: {
            actionIcon(kind, w)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(kind == .save && session.saving == w.name ? "正在下载" : kind.barTitle)
        .accessibilityHint(kind.hint)
    }
}
