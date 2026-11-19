import SwiftUI
import AppKit

private struct DonationMethod: Identifiable {
    let id: String
    let name: String
    let detail: String
    let tint: Color
    let code: NSImage?

    init(_ id: String, name: String, detail: String, tint: Color) {
        self.id = id
        self.name = name
        self.detail = detail
        self.tint = tint
        code = Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "Donation")
            .flatMap { NSImage(contentsOf: $0) }
    }

    private static let yuanAmount = 6.66.formatted(.currency(code: "CNY"))

    static let all = [
        DonationMethod("venmo", name: "Venmo", detail: "@weetom", tint: Color(red: 0.14, green: 0.49, blue: 0.72)),
        DonationMethod("alipay", name: tr("支付宝"), detail: yuanAmount, tint: Color(red: 0.09, green: 0.47, blue: 1)),
        DonationMethod("wechat-pay", name: tr("微信支付"), detail: yuanAmount, tint: Color(red: 0.02, green: 0.68, blue: 0.41))
    ]
}

struct DonationView: View {
    private static let repositoryURL = URL(string: "https://github.com/WeeTom/redmagic-monitor-control")!
    private let gap: CGFloat = 10
    private let padding: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            paymentMethods
            Link(destination: Self.repositoryURL) {
                HStack(spacing: 5) {
                    Text(verbatim: "GitHub")
                    Image(systemName: "arrow.up.right").accessibilityHidden(true)
                }
            }
            .buttonStyle(.bordered)
            .help(tr("在浏览器中查看项目源码"))
            .accessibilityLabel(tr("在 GitHub 查看源码"))
            .padding(.bottom, padding)
        }
    }

    private var paymentMethods: some View {
        GeometryReader { area in
            let count = CGFloat(DonationMethod.all.count)
            let available = area.size.height - 2 * padding - (count - 1) * gap
            let side = min(184, max(144, floor(available / count - 2 * padding)))
            ViewThatFits(in: .vertical) {
                rows(side: side).fixedSize(horizontal: false, vertical: true)
                ScrollView(.vertical) { rows(side: side) }
                    .scrollIndicators(.never)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func rows(side: CGFloat) -> some View {
        VStack(spacing: gap) {
            ForEach(DonationMethod.all) { method in
                HStack(spacing: 10) {
                    Capsule().fill(method.tint).frame(width: 3, height: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(method.name).font(.headline)
                        Text(verbatim: method.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Group {
                        if let code = method.code {
                            Image(nsImage: code).resizable().scaledToFit()
                        } else {
                            Text(tr("二维码暂不可用")).foregroundStyle(.black)
                        }
                    }
                    .frame(width: side, height: side)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(tr("%@收款二维码", method.name))
                }
                .padding(padding)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, PanelLayout.margin)
        .padding(.vertical, padding)
    }
}
