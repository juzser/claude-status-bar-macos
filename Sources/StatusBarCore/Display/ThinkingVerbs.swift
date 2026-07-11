import Foundation

public enum ThinkingVerbs {
    public static let all = [
        "Brewing", "Pondering", "Scheming", "Musing", "Percolating", "Ruminating",
        "Noodling", "Cogitating", "Marinating", "Simmering", "Untangling", "Weighing",
        "Sketching", "Plotting", "Dreaming", "Tinkering", "Digesting", "Mulling",
        "Hatching", "Stewing", "Whirring", "Conjuring", "Assembling", "Distilling",
        "Deliberating", "Incubating", "Composing", "Calibrating",
    ]
}

/// Uniform random phrase picker that never repeats the previous pick.
/// Pool-agnostic: the caller passes the pool each draw, so switching
/// message styles mid-flight is safe. Precondition: `phrases` is non-empty
/// (guaranteed by the MessageStyles catalog invariant tests).
public struct VerbCycler {
    let rng: () -> Double
    var previousIndex: Int?

    public init(rng: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.rng = rng
    }

    public mutating func next(from phrases: [String]) -> String {
        // A remembered index may come from a different (larger) pool; and in
        // a one-phrase pool the no-repeat rule is unsatisfiable. Forget it.
        if let previous = previousIndex, previous >= phrases.count || phrases.count == 1 {
            previousIndex = nil
        }
        // Draw from the pool minus the previous pick, then map back to full indices.
        let poolSize = previousIndex == nil ? phrases.count : phrases.count - 1
        var index = min(Int(rng() * Double(poolSize)), poolSize - 1)
        if let previous = previousIndex, index >= previous { index += 1 }
        previousIndex = index
        return phrases[index]
    }

    public mutating func reset() {
        previousIndex = nil
    }
}
