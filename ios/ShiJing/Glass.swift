import SwiftUI

/// 悬浮控件的底：iOS 26 起用系统的液态玻璃，更早的系统退回毛玻璃。
/// App 里浮在图片 / 内容上面的块（预览的按钮和文件名、缩略图条、提示、多选操作条……）都用它，
/// 别各写一份 `.background(.ultraThinMaterial, ...)`。
extension View {
    @ViewBuilder
    func glassBackground<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    /// 深色图上的深色玻璃：浅色玻璃在暗图上会发灰，这种地方用 tint 压一下（iOS 26 才有）
    @ViewBuilder
    func glassBackground<S: InsettableShape>(in shape: S, tint: Color, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect((interactive ? Glass.regular.interactive() : .regular).tint(tint), in: shape)
        } else {
            background(tint.opacity(0.55), in: shape).background(.ultraThinMaterial, in: shape)
        }
    }
}
