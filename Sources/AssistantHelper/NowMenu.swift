import AppKit
import AssistantCore

/// "Not this ▸" and "Treat <app/site> as Neutral" under Now. A correction fixes Now at once; only
/// the Always that follows keeps anything.
@MainActor
final class NowMenu: NSObject {
    private let assistant: Assistant
    var onChange: () -> Void = {}

    init(assistant: Assistant) {
        self.assistant = assistant
    }

    func items() -> [NSMenuItem] {
        guard let window = assistant.now.window, !window.isExcluded else { return [] }
        var items = [notThisItem()]
        if let key = assistant.neutralToOffer {
            let treat = NSMenuItem(
                title: "Treat \(key.label(in: assistant.now.window)) as Neutral",
                action: #selector(markNeutral(_:)), keyEquivalent: "")
            treat.target = self
            treat.representedObject = NeutralBox(key: key)
            items.append(treat)
        }
        return items
    }

    private func notThisItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Not this", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for project in assistant.projects where project.status == .active && project.id != assistant.now.project {
            menu.addItem(choice(project.name, .project(project.id)))
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        menu.addItem(choice("Neutral", .neutral))
        menu.addItem(choice("None", .none))
        item.submenu = menu
        return item
    }

    private final class CorrectionBox: NSObject {
        let correction: Correction
        init(correction: Correction) { self.correction = correction }
    }

    private final class NeutralBox: NSObject {
        let key: NeutralKey
        init(key: NeutralKey) { self.key = key }
    }

    private func choice(_ title: String, _ correction: Correction) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(correct(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = CorrectionBox(correction: correction)
        return item
    }

    @objc private func correct(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CorrectionBox else { return }
        Attempt.run("Couldn't correct Now", then: onChange) { try assistant.correctNow(box.correction) }
    }

    @objc private func markNeutral(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? NeutralBox else { return }
        Attempt.run("Couldn't make it Neutral", then: onChange) { try assistant.markNeutral(box.key) }
    }
}
