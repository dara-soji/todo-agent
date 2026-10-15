import Foundation

/// Names made distinct for a model to choose among: repeats are numbered "Name (2)", "Name (3)".
func uniqueLabels(_ names: [String]) -> [String] {
    var seen: [String: Int] = [:]
    return names.map { name in
        seen[name, default: 0] += 1
        return seen[name]! == 1 ? name : "\(name) (\(seen[name]!))"
    }
}
