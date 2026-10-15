import Foundation

extension Assistant {
    /// Dara's "Not this": fixes Now for the current window at once, and offers to make it stick.
    /// Nothing is learned unless Dara then chooses Always.
    public func correctNow(_ correction: Correction) throws {
        guard let window = now.window else { throw Failure.noWindow }
        if case let .project(id) = correction, projectsByID[id]?.status != .active {
            throw Failure.unknownProject(id)
        }
        self.correction = (window, correction)
        switch correction {
        case let .project(id):
            // No offer when there's no key to match on, or the Project already has it.
            if let matcher = fitting.suggestedMatcher(for: window), projectsByID[id]?.matchers.contains(matcher) == false {
                offer = .alwaysMatch(matcher, id)
            } else {
                offer = nil
            }
        case .neutral:
            offer = .alwaysNeutral(fitting.suggestedNeutral(for: window))
        case .none:
            offer = nil
        }
        resolve(now.visit)
    }

    /// Always: adds the offered Matcher to its Project, or makes the offered app or site Neutral.
    @discardableResult
    public func acceptOffer() throws -> Outcome {
        guard let offer else { throw Failure.noOffer }
        self.offer = nil
        switch offer {
        case let .alwaysMatch(matcher, project): return try addMatcher(matcher, to: project)
        case let .alwaysNeutral(key): return try markNeutral(key)
        }
    }

    /// Just this once: the correction stands for this window, and nothing is kept.
    public func dismissOffer() {
        offer = nil
    }

    /// "Treat <app/site> as Neutral" for the current window, or nil when it is already Neutral.
    public var neutralSuggestion: NeutralKey? {
        guard let window = now.window, now.neutral == nil else { return nil }
        return fitting.suggestedNeutral(for: window)
    }

    /// Makes an app or site Neutral from now on.
    @discardableResult
    public func markNeutral(_ key: NeutralKey, by startedBy: StartedBy = .dara) throws -> Outcome {
        guard !(NeutralKey.defaults + neutrals).contains(key) else { throw Failure.alreadyNeutral(key) }
        let label = switch key {
        case let .app(bundleID): bundleID
        case let .site(site): site
        }
        return try perform(.markNeutral, "Treated \(label) as Neutral", by: startedBy,
                           writing: Change(neutrals: neutrals + [key]))
    }
}
