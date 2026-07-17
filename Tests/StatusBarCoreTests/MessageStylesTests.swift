import Foundation
import Testing
@testable import StatusBarCore

private let canonicalLabels = ["Editing", "Running", "Reading", "Searching",
                               "Browsing", "Delegating", "Working"]

private func wordCount(_ phrase: String) -> Int {
    phrase.split(whereSeparator: \.isWhitespace).count
}

@Suite struct MessageStyleCatalogTests {
    @Test func lineupIsTenStylesClassicThenDumbFirst() {
        #expect(MessageStyles.all.map(\.id)
                == ["classic", "dumb", "rpg", "gardening", "cooking", "pirate",
                    "harrypotter", "office", "design", "dev"])
    }

    @Test func idsAreUnique() {
        #expect(Set(MessageStyles.all.map(\.id)).count == MessageStyles.all.count)
    }

    @Test func everyStyleCoversAllCanonicalLabels() {
        for style in MessageStyles.all {
            #expect(Set(style.tool.keys) == Set(canonicalLabels), "\(style.id)")
            #expect(!style.thinking.isEmpty, "\(style.id)")
            #expect(!style.waiting.isEmpty, "\(style.id)")
        }
    }

    @Test func themedThinkingPoolsHaveTwelveUniquePhrases() {
        for style in MessageStyles.all where style.id != "classic" {
            #expect(style.thinking.count == 12, "\(style.id)")
            #expect(Set(style.thinking).count == 12, "\(style.id)")
        }
    }

    @Test func themedPhrasesAreThreeToFourWords() {
        for style in MessageStyles.all where style.id != "classic" {
            for phrase in style.thinking {
                #expect((3...4).contains(wordCount(phrase)), "\(style.id): \(phrase)")
            }
            for phrase in style.tool.values {
                #expect((3...4).contains(wordCount(phrase)), "\(style.id): \(phrase)")
            }
            #expect((3...4).contains(wordCount(style.waiting)), "\(style.id): \(style.waiting)")
        }
    }

    @Test func classicPreservesTodayExactly() {
        let classic = MessageStyles.style(id: "classic")
        #expect(classic.thinking == ThinkingVerbs.all)
        for label in canonicalLabels {
            #expect(classic.tool[label] == label)
        }
        #expect(classic.waiting == "Waiting for you")
    }

    @Test func unknownIdFallsBackToClassic() {
        #expect(MessageStyles.style(id: "nope").id == "classic")
        #expect(MessageStyles.style(id: "").id == "classic")
        #expect(MessageStyles.style(id: "pirate").id == "pirate")
    }
}
