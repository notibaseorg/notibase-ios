/**
 * Drawing an in-app message, in UIKit and nothing else.
 *
 * Every block becomes a real view, built by hand. No xib, no storyboard,
 * no image library, and no WKWebView — which is the whole reason a message
 * is a block document rather than the HTML somebody typed into a console.
 * There is no path here by which message copy becomes code running inside
 * a customer's app.
 *
 * The decisions — which message, whether it may be shown, how often — are
 * in NotibaseInApp.swift, which has no UIKit in it and is compiled and
 * exercised on Linux. This file only draws, and compiles to nothing where
 * UIKit does not exist.
 */
import Foundation

#if canImport(UIKit) && !os(watchOS)
import UIKit

/// NSObject because the tap targets below are `@objc` selectors, and a
/// selector needs a class the Objective-C runtime can see.
@available(iOS 13.0, *)
final class NotibaseInAppView: NSObject {

    /// The window this message owns. Released when it closes.
    private var window: UIWindow?
    private let rule: InAppRule
    private let onAction: (InAppAction) -> Void
    private let onDismiss: () -> Void

    init(
        rule: InAppRule,
        onAction: @escaping (InAppAction) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.rule = rule
        self.onAction = onAction
        self.onDismiss = onDismiss
        super.init()
    }

    /**
     * Show it over everything.
     *
     * A window of its own rather than a presented view controller: an app
     * that is already presenting something would refuse the presentation,
     * and a message that silently does not appear because the person had a
     * sheet open is worse than one that covers it.
     */
    func show(in scene: UIWindowScene) {
        let host = UIViewController()
        host.view.backgroundColor = UIColor.black.withAlphaComponent(0.45)

        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        // Just under the system alert level: above the app, below anything
        // the OS itself needs to put on screen.
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 1)
        window.backgroundColor = .clear
        self.window = window

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = NotibaseInAppView.colour(rule.style.bg) ?? .white
        card.layer.cornerRadius = rule.layout == "full" ? 0 : CGFloat(rule.style.radius)
        card.clipsToBounds = true

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        if rule.dismissible {
            let close = UIButton(type: .system)
            close.setTitle("✕", for: .normal)
            close.setTitleColor(UIColor(white: 0.6, alpha: 1), for: .normal)
            close.titleLabel?.font = .systemFont(ofSize: 20)
            close.accessibilityLabel = "Close"
            close.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
            let row = UIStackView(arrangedSubviews: [UIView(), close])
            row.axis = .horizontal
            stack.addArrangedSubview(row)
        }

        for block in rule.blocks {
            switch block {
            case let .text(text, size, bold, align, color):
                let label = UILabel()
                label.text = text
                label.numberOfLines = 0
                label.font = bold
                    ? .boldSystemFont(ofSize: CGFloat(size))
                    : .systemFont(ofSize: CGFloat(size))
                label.textColor = NotibaseInAppView.colour(color) ?? UIColor(white: 0.07, alpha: 1)
                label.textAlignment = align == "left" ? .left : (align == "right" ? .right : .center)
                stack.addArrangedSubview(label)

            case let .image(url, alt, height):
                let view = UIImageView()
                view.contentMode = .scaleAspectFill
                view.clipsToBounds = true
                view.layer.cornerRadius = 6
                view.isAccessibilityElement = true
                view.accessibilityLabel = alt
                if let height = height {
                    view.heightAnchor.constraint(equalToConstant: CGFloat(height)).isActive = true
                }
                stack.addArrangedSubview(view)
                NotibaseInAppView.loadImage(url, into: view)

            case let .spacer(height):
                let gap = UIView()
                gap.heightAnchor.constraint(equalToConstant: CGFloat(height)).isActive = true
                stack.addArrangedSubview(gap)

            case let .button(label, action, bg, color, radius):
                let button = InAppButton(type: .system)
                button.action = action
                button.setTitle(label, for: .normal)
                button.setTitleColor(NotibaseInAppView.colour(color) ?? .white, for: .normal)
                button.titleLabel?.font = .boldSystemFont(ofSize: 15)
                button.backgroundColor = NotibaseInAppView.colour(bg) ?? UIColor(white: 0.07, alpha: 1)
                button.layer.cornerRadius = CGFloat(radius)
                button.heightAnchor.constraint(equalToConstant: 46).isActive = true
                button.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)
                stack.addArrangedSubview(button)
            }
        }

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        card.addSubview(scroll)
        host.view.addSubview(card)

        let pad = CGFloat(rule.style.padding)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: card.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: pad),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -pad),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -pad),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -pad * 2),
        ])

        let guide = host.view.safeAreaLayoutGuide
        let full = rule.layout == "full"
        let margin: CGFloat = full ? 0 : 16
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: margin),
            card.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -margin),
        ])
        if full {
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: guide.topAnchor),
                card.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            ])
        } else {
            card.heightAnchor.constraint(lessThanOrEqualTo: guide.heightAnchor, multiplier: 0.88)
                .isActive = true
            switch rule.layout {
            case "top":
                card.topAnchor.constraint(equalTo: guide.topAnchor, constant: margin).isActive = true
            case "bottom":
                card.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -margin).isActive = true
            default:
                card.centerYAnchor.constraint(equalTo: guide.centerYAnchor).isActive = true
            }
        }

        if rule.dismissible {
            let tap = UITapGestureRecognizer(target: self, action: #selector(scrimTapped(_:)))
            host.view.addGestureRecognizer(tap)
        }

        window.makeKeyAndVisible()
    }

    @objc private func scrimTapped(_ gesture: UITapGestureRecognizer) {
        // Only a tap outside the card closes it. Tapping the message itself
        // is not a request to dismiss the message.
        guard let host = window?.rootViewController?.view else { return }
        let point = gesture.location(in: host)
        for sub in host.subviews where sub.frame.contains(point) { return }
        dismissTapped()
    }

    @objc private func dismissTapped() {
        close()
        onDismiss()
    }

    @objc private func buttonTapped(_ sender: UIButton) {
        guard let button = sender as? InAppButton, let action = button.action else { return }
        onAction(action)
        // Every press closes it. A message left standing behind a
        // permission dialog is one the person has to dismiss twice, and
        // nobody reads it the second time.
        close()
    }

    private func close() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }

    /// A button that remembers what it was configured to do.
    private final class InAppButton: UIButton {
        var action: InAppAction?
    }

    /**
     * Fetch and set one image, off the main thread.
     *
     * Deliberately unclever: no cache, no placeholder, no transformations.
     * A message shows one image and the alternative is a dependency this
     * SDK is built to avoid. A fetch that fails leaves the space empty
     * rather than failing the message — the words are the message, the
     * picture is decoration.
     */
    private static func loadImage(_ url: String, into view: UIImageView) {
        guard let parsed = URL(string: url) else { return }
        var req = URLRequest(url: parsed)
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async { view.image = image }
        }.resume()
    }

    /// `#rgb`, `#rrggbb` or `#rrggbbaa` from the console; nil for anything else.
    static func colour(_ value: String?) -> UIColor? {
        guard var hex = value, hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6 || hex.count == 8, let n = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let r = Double((n >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((n >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((n >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(n & 0xFF) / 255 : 1
        return UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }
}
#endif
