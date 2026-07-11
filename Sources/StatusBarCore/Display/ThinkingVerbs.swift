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

/// Uniform random verb picker that never repeats the previous verb.
public struct VerbCycler {
    let rng: () -> Double
    var previousIndex: Int?

    public init(rng: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.rng = rng
    }

    public mutating func next() -> String {
        let verbs = ThinkingVerbs.all
        // Draw from the pool minus the previous pick, then map back to full indices.
        let poolSize = previousIndex == nil ? verbs.count : verbs.count - 1
        var index = min(Int(rng() * Double(poolSize)), poolSize - 1)
        if let previous = previousIndex, index >= previous { index += 1 }
        previousIndex = index
        return verbs[index]
    }
}
