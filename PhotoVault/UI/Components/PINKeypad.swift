import SwiftUI

/// iPhoneのパスコード画面に近い丸表示です。ログインとPIN設定で同じ見た目を共有します。
struct PINIndicatorView: View {
    let digitCount: Int
    let tint: Color
    var maximumDigits = 6

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<maximumDigits, id: \.self) { index in
                Circle()
                    .fill(index < digitCount ? tint : Color.secondary.opacity(0.20))
                    .frame(width: 13, height: 13)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("パスコード \(digitCount)桁入力済み")
        .padding(.vertical, 2)
    }
}

/// 数字の追加・1桁削除・最大6桁への制限を一元化したPINキーパッドです。
struct NumericPINKeypad: View {
    @Binding private var value: String
    private let tint: Color
    private let isDisabled: Bool
    private let leadingSystemImage: String?
    private let leadingAccessibilityLabel: String?
    private let onLeadingAction: (() -> Void)?
    private let onValueChange: (String) -> Void
    private let keyDiameter: CGFloat
    private let rowSpacing: CGFloat
    private let columnSpacing: CGFloat

    init(
        value: Binding<String>,
        tint: Color,
        isDisabled: Bool = false,
        leadingSystemImage: String? = nil,
        leadingAccessibilityLabel: String? = nil,
        onLeadingAction: (() -> Void)? = nil,
        keyDiameter: CGFloat = 68,
        rowSpacing: CGFloat = 12,
        columnSpacing: CGFloat = 18,
        onValueChange: @escaping (String) -> Void = { _ in }
    ) {
        _value = value
        self.tint = tint
        self.isDisabled = isDisabled
        self.leadingSystemImage = leadingSystemImage
        self.leadingAccessibilityLabel = leadingAccessibilityLabel
        self.onLeadingAction = onLeadingAction
        self.keyDiameter = keyDiameter
        self.rowSpacing = rowSpacing
        self.columnSpacing = columnSpacing
        self.onValueChange = onValueChange
    }

    var body: some View {
        VStack(spacing: rowSpacing) {
            numberRow(["1", "2", "3"])
            numberRow(["4", "5", "6"])
            numberRow(["7", "8", "9"])

            HStack(spacing: columnSpacing) {
                leadingKey
                numberButton("0")
                deleteKey
            }
        }
    }

    private func numberRow(_ numbers: [String]) -> some View {
        HStack(spacing: columnSpacing) {
            ForEach(numbers, id: \.self) { number in
                numberButton(number)
            }
        }
    }

    private func numberButton(_ number: String) -> some View {
        Button {
            guard value.count < 6 else { return }
            value.append(number)
            onValueChange(value)
        } label: {
            Text(number)
                .font(.system(size: keyDiameter * 0.41, weight: .regular, design: .rounded))
                .foregroundStyle(.primary)
                .frame(width: keyDiameter, height: keyDiameter)
                .background(.secondary.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || value.count >= 6)
        .accessibilityLabel("数字\(number)")
    }

    @ViewBuilder
    private var leadingKey: some View {
        if let leadingSystemImage, let onLeadingAction {
            Button(action: onLeadingAction) {
                Image(systemName: leadingSystemImage)
                    .font(.system(size: keyDiameter * 0.40))
                    .foregroundStyle(tint)
                    .frame(width: keyDiameter, height: keyDiameter)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityLabel(leadingAccessibilityLabel ?? "追加操作")
        } else {
            // 左下を空けることで、iPhoneのパスコード配列と同じ位置に0を置きます。
            Color.clear
                .frame(width: keyDiameter, height: keyDiameter)
                .accessibilityHidden(true)
        }
    }

    private var deleteKey: some View {
        Button {
            guard !value.isEmpty else { return }
            value.removeLast()
            onValueChange(value)
        } label: {
            Image(systemName: "delete.left")
                .font(.system(size: keyDiameter * 0.37))
                .foregroundStyle(.primary)
                .frame(width: keyDiameter, height: keyDiameter)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || value.isEmpty)
        .accessibilityLabel("1桁削除")
    }
}
