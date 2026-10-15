import Foundation

extension Assistant {
    /// Dara's "Not this": fixes Now for the current window at once, and offers to make it stick.
    /// Nothing is learned unless Dara then chooses Always.
    public func correctNow(_ correction: Correction) throws {
        guard let window = now.window else { throw Failure.noWindow }
        guard !window.isExcluded else { throw Failure.windowExcluded }
        if case let .project(id) = correction, projectsByID[id]?.status != .active {
            throw Failure.unknownProject(id)
        }
        // Saying a guessed window is something else forgets the guess for that window.
        if now.match?.basis == .guess, correction != .project(now.match!.project), let key = guessKey(for: window) {
            guessCache[key] = .some(nil)
        }
        self.correction = (window, correction)
        switch correction {
        case let .project(id):
            // Nothing to offer when the window shows no URL or path to match on, or the Project has it already.
            if let matcher = fitting.proposedMatcher(for: window), projectsByID[id]?.matchers.contains(matcher) == false {
                offer = .alwaysMatch(matcher, id)
            } else {
                offer = nil
            }
        case .neutral:
            offer = isNeutral(window) ? nil : .alwaysNeutral(fitting.proposedNeutral(for: window))
        case .none:
            offer = nil
        }
        resolve(now.visit)
    }

    /// Always: adds the offered Matcher to its Project, or makes the offered app or site Neutral.
    /// The correction then gives way to what was kept. If keeping fails, the offer stays.
    @discardableResult
    public func acceptOffer() throws -> Outcome {
        guard let offer else { throw Failure.noOffer }
        let outcome = switch offer {
        case let .alwaysMatch(matcher, project): try addMatcher(matcher, to: project)
        case let .alwaysNeutral(key): try markNeutral(key)
        }
        self.offer = nil
        correction = nil
        resolve(now.visit)
        return outcome
    }

    /// Just this once: the correction stands for this window, and nothing is kept.
    public func dismissOffer() {
        offer = nil
    }

    /// The app or site "Treat as Neutral" would add for the current window, or nil when it is
    /// Neutral already.
    public var neutralToOffer: NeutralKey? {
        guard let window = now.window, !isNeutral(window) else { return nil }
        return fitting.proposedNeutral(for: window)
    }

    /// Makes an app or site Neutral from now on.
    @discardableResult
    public func markNeutral(_ key: NeutralKey, by startedBy: StartedBy = .dara) throws -> Outcome {
        guard !(NeutralKey.defaults + neutrals).contains(key) else { throw Failure.alreadyNeutral(key) }
        return try perform(.markNeutral, "Treated \(key.label(in: now.window)) as Neutral", by: startedBy,
                           writing: changingSettings { $0.neutrals.append(key) })
    }

    /// The "Always …?" waiting after a correction, as a Decision.
    var offerDecision: [Decision] {
        offer.map { [.offer($0)] } ?? []
    }
}
