import Foundation
import Testing
@testable import StatusBarCore

private let canonicalLabels = ["Editing", "Running", "Reading", "Searching",
                               "Browsing", "Delegating", "Working"]

private func wordCount(_ phrase: String) -> Int {
    phrase.split(whereSeparator: \.isWhitespace).count
}

@Suite struct MessageStylesViTests {
    @Test func lineupMatchesEnglishIdsAndOrder() {
        #expect(MessageStylesVi.all.map(\.id) == MessageStyles.all.map(\.id))
    }

    @Test func idsAreUnique() {
        #expect(Set(MessageStylesVi.all.map(\.id)).count == MessageStylesVi.all.count)
    }

    @Test func everyStyleCoversAllCanonicalLabels() {
        for style in MessageStylesVi.all {
            #expect(Set(style.tool.keys) == Set(canonicalLabels), "\(style.id)")
            #expect(!style.thinking.isEmpty, "\(style.id)")
            #expect(!style.waiting.isEmpty, "\(style.id)")
        }
    }

    @Test func themedThinkingPoolsHaveTwelveUniquePhrases() {
        for style in MessageStylesVi.all where style.id != "classic" {
            #expect(style.thinking.count == 12, "\(style.id)")
            #expect(Set(style.thinking).count == 12, "\(style.id)")
        }
    }

    @Test func classicHasTwentyEightUniquePhrases() {
        let classic = MessageStylesVi.style(id: "classic")
        #expect(classic.thinking.count == 28)
        #expect(Set(classic.thinking).count == 28)
    }

    @Test func themedPhrasesAreTwoToFourWords() {
        for style in MessageStylesVi.all where style.id != "classic" {
            for phrase in style.thinking {
                #expect((2...4).contains(wordCount(phrase)), "\(style.id): \(phrase)")
            }
            for phrase in style.tool.values {
                #expect((2...4).contains(wordCount(phrase)), "\(style.id): \(phrase)")
            }
            #expect((2...4).contains(wordCount(style.waiting)), "\(style.id): \(style.waiting)")
        }
    }

    @Test func unknownIdFallsBackToVietnameseClassic() {
        #expect(MessageStylesVi.style(id: "nope").id == "classic")
        #expect(MessageStylesVi.style(id: "nope").waiting == "Đang chờ bạn")
    }

    @Test func languageDispatchMatchesEachCatalog() {
        for id in MessageStyles.all.map(\.id) {
            let english = MessageStyles.style(id: id, language: .english)
            #expect(english.thinking == MessageStyles.style(id: id).thinking)
            #expect(english.tool == MessageStyles.style(id: id).tool)
            #expect(english.waiting == MessageStyles.style(id: id).waiting)

            let vietnamese = MessageStyles.style(id: id, language: .vietnamese)
            #expect(vietnamese.thinking == MessageStylesVi.style(id: id).thinking)
            #expect(vietnamese.tool == MessageStylesVi.style(id: id).tool)
            #expect(vietnamese.waiting == MessageStylesVi.style(id: id).waiting)
        }
    }
}
