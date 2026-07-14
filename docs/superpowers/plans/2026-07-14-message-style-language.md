# Message Style Language (Vietnamese Support) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Language setting (English / Tiếng Việt) so every message style's thinking/tool/waiting phrases can render in Vietnamese — original, playful phrasing per style, not literal translations.

**Architecture:** A second, parallel phrase catalog. `MessageStylesVi.swift` mirrors `MessageStyles.swift` (same 7 ids, same order) with a full Vietnamese catalog. `MessageStyles.style(id:language:)` is a new total-lookup overload that dispatches to either catalog. `SettingsStore` persists the chosen `Language` the same way it already persists `DisplayStyle` (raw-string-backed computed property), and `messageStyle` folds `language` into its existing lookup. `MenuBarText`, `ThinkingVerbs`/`VerbCycler`, the hook binary, session-file format, and the popover are untouched — they already consume a fully-resolved `MessageStyle` and don't care which language produced it.

**Tech Stack:** Swift 6.0 toolchain in `.swiftLanguageMode(.v5)`, SwiftPM (no Xcode — CLT-only machine), macOS 14+, swift-testing pinned `exact: "0.12.0"`.

**Spec:** `docs/superpowers/specs/2026-07-14-message-style-language-design.md` (commit `5153a0e`).

## Global Constraints

- swift-testing is pinned `exact: "0.12.0"` — use ONLY `@Test`, `@Suite`, `#expect`, `#require`. No other swift-testing API (no traits, no parameterized `arguments:`, no `withKnownIssue`).
- Every Vietnamese phrase (thinking, tool, waiting) for the 6 themed styles (everything but `classic`) is exactly 2–4 whitespace-separated words — tighter than the English catalog's 3–4, tuned for menu bar width. `classic` is exempt, same precedent as English Classic.
- Transcribe every Vietnamese phrase from this plan byte-exactly (they are already finalized and reviewed) — do not "improve," reorder, or re-translate them.
- Language and Message style are independent axes: 7 styles × 2 languages = 14 combinations, all reachable through `MessageStyles.style(id:language:)`.
- Default `language` is `.english` — existing installs see byte-identical menu bar output with no migration.
- Style picker names ("Classic", "RPG", "Gardening", "Dumb", "Sci-Fi", "Cooking", "Pirate") never change with Language — only the phrase content does.
- Untouched files/behavior: `Sources/StatusBarCore/Display/MenuBarText.swift`, `Sources/StatusBarCore/Display/ThinkingVerbs.swift` (incl. `VerbCycler`), hook binary (`Sources/ClaudeStatusHook/`), `SessionReducer`, session-file format, `SessionsSection.swift` (popover keeps canonical English text).
- All code, comments, tests, and commit messages are in English (Vietnamese only appears inside string literals in `MessageStylesVi.swift` and its tests). Commit subjects imperative, ≤72 chars.
- Work on branch `feat/message-style-language` (exists; base `main` @ `bab9326`; spec committed at `5153a0e`). Never push to main/master, never force-push.
- Test command: `swift test` from the repo root `/Users/ser/scatola/jobs/projects/claude-status-bar-macos`. Full suite (143 tests pre-existing on this branch) must pass at the end of every task.
- Regression guarantee: with default settings (`language == .english`), menu bar output is unchanged from before this feature. This is verified by the existing `Tests/StatusBarCoreTests/MessageStylesTests.swift` regression test, which this plan does not touch — its continuing to pass (as part of the full `swift test` run) is the proof.
- The shell's working directory may reset between commands — prefix every command with `cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && `.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `Sources/StatusBarCore/Settings/Language.swift` | **Create** (Task 1) | `Language` enum (`english`/`vietnamese`) |
| `Sources/StatusBarCore/Display/MessageStylesVi.swift` | **Create** (Task 1) | Vietnamese phrase catalog, parallel to `MessageStyles.swift` |
| `Sources/StatusBarCore/Display/MessageStyles.swift` | Modify (Task 1) | New `style(id:language:)` overload; existing `style(id:)` and 7 English styles unchanged |
| `Tests/StatusBarCoreTests/MessageStylesViTests.swift` | **Create** (Task 1) | Catalog invariants, parity, and dispatch tests |
| `Sources/StatusBarCore/Settings/SettingsStore.swift` | Modify (Task 2) | Persisted `languageRaw` + computed `language`; `messageStyle` folds in `language` |
| `Tests/StatusBarCoreTests/SettingsStoreTests.swift` | Modify (Task 2) | Persistence + fallback tests for `language` |
| `Sources/ClaudeStatusBar/SettingsView.swift` | Modify (Task 3) | "Language" picker in GeneralTab, next to "Message style" |

Note: `Sources/ClaudeStatusBar/` is the executable target — SwiftPM test targets cannot import it, so the `SettingsView` change is verified by `swift build` + the full core suite, not by new unit tests (same convention as the original message-styles feature, `docs/superpowers/plans/2026-07-11-message-styles.md` Task 6).

---

### Task 1: Vietnamese catalog + language dispatch

**Files:**
- Create: `Sources/StatusBarCore/Settings/Language.swift`
- Create: `Sources/StatusBarCore/Display/MessageStylesVi.swift`
- Modify: `Sources/StatusBarCore/Display/MessageStyles.swift:21-25`
- Test: `Tests/StatusBarCoreTests/MessageStylesViTests.swift` (create)

**Interfaces:**
- Consumes: existing `MessageStyle` struct, `MessageStyles.all`, `MessageStyles.style(id:)` (all unchanged).
- Produces: `public enum Language: String, CaseIterable, Sendable { case english, vietnamese }`; `enum MessageStylesVi { static let all: [MessageStyle]; static func style(id: String) -> MessageStyle }`; `public static func MessageStyles.style(id: String, language: Language) -> MessageStyle`. Task 2 relies on the `Language` type (cases `.english`/`.vietnamese`, `rawValue` "english"/"vietnamese") and on `MessageStyles.style(id:language:)` existing with exactly this signature.

- [ ] **Step 1: Write the failing tests**

Create `Tests/StatusBarCoreTests/MessageStylesViTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && swift test --filter MessageStylesViTests`
Expected: BUILD FAILURE — `cannot find 'MessageStylesVi' in scope` / `cannot find type 'Language' in scope`.

- [ ] **Step 3: Create the `Language` enum**

Create `Sources/StatusBarCore/Settings/Language.swift`:

```swift
import Foundation

/// Language affects only message-style menu bar phrases (thinking/tool/
/// waiting text) — Settings UI labels, style picker names, and the popover
/// stay English regardless of this setting.
public enum Language: String, CaseIterable, Sendable {
    case english, vietnamese
}
```

- [ ] **Step 4: Create the Vietnamese catalog**

Create `Sources/StatusBarCore/Display/MessageStylesVi.swift`:

```swift
import Foundation

/// Vietnamese phrase catalog, structurally parallel to `MessageStyles.swift`:
/// same 7 ids, same order. Phrases are original, not translations — see
/// the design doc's Style catalog section for the authored set.
enum MessageStylesVi {
    static let all: [MessageStyle] = [
        classic, rpg, gardening, dumb, scifi, cooking, pirate,
    ]

    /// Total lookup: unknown id falls back to Vietnamese classic, not the
    /// English one, so language stays consistent.
    static func style(id: String) -> MessageStyle {
        all.first { $0.id == id } ?? classic
    }

    static let classic = MessageStyle(
        id: "classic", name: "Classic",
        thinking: [
            "Nghiền ngẫm", "Ủ mưu", "Vò đầu", "Nung nấu", "Nhâm nhi ý", "Gỡ rối", "Cân đo",
            "Phác thảo", "Mơ mộng", "Mày mò", "Ngâm ý", "Trăn trở", "Ấp ủ", "Lẩm bẩm",
            "Chắt lọc", "Cân nhắc", "Ấp trứng", "Sáng tác", "Vặn óc", "Nặn óc", "Đun sôi ý",
            "Dò dẫm", "Lắp ráp ý", "Tính toán", "Nhen nhóm", "Ngẫm nghĩ", "Xào nấu ý",
            "Ướp ý tưởng",
        ],
        tool: [
            "Editing": "Đang sửa", "Running": "Đang chạy", "Reading": "Đang đọc",
            "Searching": "Đang tìm", "Browsing": "Đang lướt", "Delegating": "Đang giao việc",
            "Working": "Đang làm",
        ],
        waiting: "Đang chờ bạn")

    static let rpg = MessageStyle(
        id: "rpg", name: "RPG",
        thinking: [
            "Múa kiếm chơi", "Cày cấp độ", "Săn boss trùm", "Đọc thần chú", "Mở rương báu",
            "Hú gọi đồng bọn", "Đào mỏ EXP", "Ngáo phép thuật", "Né đòn chí mạng",
            "Buff máu cả team", "Vái trời khấn Phật", "Combo chưa ra chiêu",
        ],
        tool: [
            "Editing": "Rèn kiếm mới", "Running": "Phang chiêu cái đùng",
            "Reading": "Ngâm cứu sách phép", "Searching": "Lục lọi hang động",
            "Browsing": "Dạo quanh bản đồ", "Delegating": "Sai vặt đồng bọn",
            "Working": "Cày như trâu",
        ],
        waiting: "Đang chờ lệnh sếp")

    static let gardening = MessageStyle(
        id: "gardening", name: "Gardening",
        thinking: [
            "Nhổ cỏ đầu óc", "Ngửi hoa hồng", "Bắt sâu trong đầu", "Tưới cây ý tưởng",
            "Ươm mầm non", "Bón phân cho não", "Ngắm lá vàng rơi", "Hóng nắng thư giãn",
            "Tỉa cành lung tung", "Đào đất trồng cây", "Ngắt hoa hái quả",
            "Trốn nắng trong vườn",
        ],
        tool: [
            "Editing": "Tỉa cành lẹ tay", "Running": "Xới đất ầm ầm",
            "Reading": "Đọc túi hạt giống", "Searching": "Săn lùng cỏ dại",
            "Browsing": "Dạo một vòng vườn", "Delegating": "Sai yêu tinh vườn",
            "Working": "Cắm mặt làm vườn",
        ],
        waiting: "Rau chín rồi đó")

    static let dumb = MessageStyle(
        id: "dumb", name: "Dumb",
        thinking: [
            "Não đang load", "Đơ 5 giây", "Ủa cái gì", "Chưa nghĩ ra gì", "Đầu óc trên mây",
            "Nạp thêm IQ", "Não cá vàng", "Bấm nút restart não", "Có ai không đó",
            "Lú thiệt sự", "Đứng hình chấm cơm", "Suy nghĩ hộ cái",
        ],
        tool: [
            "Editing": "Gõ chữ loạn xạ", "Running": "Bấm nút to đùng", "Reading": "Ngó lơ ngơ",
            "Searching": "Tìm hoài chưa thấy", "Browsing": "Lướt web vô định",
            "Delegating": "Nhờ đứa khác làm", "Working": "Làm được tí gì",
        ],
        waiting: "Tới lượt bạn đó")

    static let scifi = MessageStyle(
        id: "scifi", name: "Sci-Fi",
        thinking: [
            "Dò sóng lạ", "Sạc pin photon", "Tính giờ warp", "Du hành xuyên không",
            "Giải mã tín hiệu", "Canh giờ đổ bộ", "Buôn chuyện với AI", "Ngắm sao băng bay",
            "Vá lỗ đen", "Dò UFO ngoài kia", "Nạp nhiên liệu warp", "Chỉnh ăng-ten dò sóng",
        ],
        tool: [
            "Editing": "Vá lại con chip", "Running": "Nổ máy tăng tốc",
            "Reading": "Dò dữ liệu cũ", "Searching": "Quét khắp ngân hà",
            "Browsing": "Dò kênh liên lạc", "Delegating": "Điều robot đi làm",
            "Working": "Chạy full công suất",
        ],
        waiting: "Chờ lệnh chỉ huy")

    static let cooking = MessageStyle(
        id: "cooking", name: "Cooking",
        thinking: [
            "Nêm cho vừa", "Lật bánh lẹ", "Múa dao đầu bếp", "Canh lửa liu riu",
            "Nếm thử chút xíu", "Ướp cho ngấm vị", "Đảo đều tay nào", "Hầm cho mềm nhừ",
            "Trộn đều gia vị", "Canh nồi sôi trào", "Bào vỏ thái lát", "Nướng cho vàng đều",
        ],
        tool: [
            "Editing": "Bày món lên đĩa", "Running": "Bật bếp lửa to",
            "Reading": "Đọc công thức nấu", "Searching": "Sục sạo tủ lạnh",
            "Browsing": "Dạo chợ mua đồ", "Delegating": "Gọi phụ bếp ra",
            "Working": "Đứng bếp cả ngày",
        ],
        waiting: "Lên món rồi đó")

    static let pirate = MessageStyle(
        id: "pirate", name: "Pirate",
        thinking: [
            "Dò kho báu", "Buộc dây neo", "Nghe lỏm tin đồn", "Ngắm sao định hướng",
            "Mài lưỡi đao cong", "Đếm vàng trong rương", "Nhìn xa trông biển",
            "Nói chuyện với vẹt", "Cột chặt nút dây", "Vượt qua bão to", "Dò tìm đảo giấu",
            "Lau ống nhòm sáng",
        ],
        tool: [
            "Editing": "Vá lại cánh buồm", "Running": "Khai hỏa đại bác",
            "Reading": "Nghiên cứu bản đồ", "Searching": "Đào bới tìm vàng",
            "Browsing": "Dò xét chân trời", "Delegating": "Hô hào cả đoàn",
            "Working": "Cọ sàn tàu",
        ],
        waiting: "Chờ lệnh thuyền trưởng")
}
```

- [ ] **Step 5: Add the `style(id:language:)` overload**

In `Sources/StatusBarCore/Display/MessageStyles.swift`, after the existing `style(id:)` method (lines 21–25), insert:

```swift
    /// Total lookup across both language catalogs. English delegates to the
    /// existing `style(id:)`; Vietnamese delegates to `MessageStylesVi`.
    public static func style(id: String, language: Language) -> MessageStyle {
        switch language {
        case .english: return style(id: id)
        case .vietnamese: return MessageStylesVi.style(id: id)
        }
    }
```

so the enum reads (unchanged parts elided):

```swift
public enum MessageStyles {
    public static let all: [MessageStyle] = [
        classic, rpg, gardening, dumb, scifi, cooking, pirate,
    ]

    public static func style(id: String) -> MessageStyle {
        all.first { $0.id == id } ?? classic
    }

    /// Total lookup across both language catalogs. English delegates to the
    /// existing `style(id:)`; Vietnamese delegates to `MessageStylesVi`.
    public static func style(id: String, language: Language) -> MessageStyle {
        switch language {
        case .english: return style(id: id)
        case .vietnamese: return MessageStylesVi.style(id: id)
        }
    }

    static let classic = MessageStyle(
        ...
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && swift test --filter MessageStylesViTests`
Expected: PASS — 8 tests.

Then run the full suite: `cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && swift test`
Expected: PASS — 151 tests (143 existing + 8 new).

- [ ] **Step 7: Commit**

```bash
cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && git add Sources/StatusBarCore/Settings/Language.swift Sources/StatusBarCore/Display/MessageStylesVi.swift Sources/StatusBarCore/Display/MessageStyles.swift Tests/StatusBarCoreTests/MessageStylesViTests.swift && git commit -m "feat: add Vietnamese message-style catalog and language dispatch"
```

---

### Task 2: Persist Language choice in SettingsStore

**Files:**
- Modify: `Sources/StatusBarCore/Settings/SettingsStore.swift`
- Test: `Tests/StatusBarCoreTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: `Language` enum, `MessageStyles.style(id:language:)` (Task 1).
- Produces: `SettingsStore.languageRaw: String` (persisted, UserDefaults key `"languageRaw"`, default `Language.english.rawValue`) and computed `SettingsStore.language: Language` (get via `Language(rawValue:) ?? .english`, set writes `languageRaw`). `messageStyle` now reads `MessageStyles.style(id: messageStyleId, language: language)`. Task 3 relies on the `$settings.language` binding (requires `language` to be a stored-or-computed property on an `@Observable` class, which it is).

- [ ] **Step 1: Write the failing tests**

Add to the `SettingsStoreTests` suite in `Tests/StatusBarCoreTests/SettingsStoreTests.swift` (inside the suite, after `unknownMessageStyleIdResolvesToClassicWithoutWriteBack`):

```swift
    @Test func languageDefaultsToEnglish() {
        let store = SettingsStore(defaults: makeDefaults())
        #expect(store.languageRaw == "english")
        #expect(store.language == .english)
    }

    @Test func languagePersistsAcrossInstances() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.language = .vietnamese
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.languageRaw == "vietnamese")
        #expect(reloaded.language == .vietnamese)
    }

    @Test func unknownLanguageRawFallsBackToEnglishWithoutWriteBack() {
        let defaults = makeDefaults()
        defaults.set("klingon", forKey: "languageRaw")
        let store = SettingsStore(defaults: defaults)
        #expect(store.language == .english)
        // The raw value is preserved — never rewritten to "english".
        #expect(store.languageRaw == "klingon")
        #expect(defaults.string(forKey: "languageRaw") == "klingon")
    }

    @Test func messageStyleReflectsLanguage() {
        let store = SettingsStore(defaults: makeDefaults())
        store.messageStyleId = "pirate"
        #expect(store.messageStyle.waiting == "Cap'n needs orders")
        store.language = .vietnamese
        #expect(store.messageStyle.waiting == "Chờ lệnh thuyền trưởng")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && swift test --filter SettingsStoreTests`
Expected: BUILD FAILURE — `value of type 'SettingsStore' has no member 'languageRaw'` / `has no member 'language'`.

- [ ] **Step 3: Write the implementation**

In `Sources/StatusBarCore/Settings/SettingsStore.swift`, after the `messageStyleId` property (lines 31–33), add:

```swift
    public var languageRaw: String {
        didSet { defaults.set(languageRaw, forKey: "languageRaw") }
    }
```

After the `displayStyle` computed property (lines 56–59), before the `messageStyle` computed property, add:

```swift
    /// Total: an unrecognized persisted value falls back to English (never
    /// crashes, never writes the fallback back to defaults).
    public var language: Language {
        get { Language(rawValue: languageRaw) ?? .english }
        set { languageRaw = newValue.rawValue }
    }
```

Change the existing `messageStyle` computed property (lines 63–65) from:

```swift
    public var messageStyle: MessageStyle {
        MessageStyles.style(id: messageStyleId)
    }
```

to:

```swift
    public var messageStyle: MessageStyle {
        MessageStyles.style(id: messageStyleId, language: language)
    }
```

In `init`, after the `messageStyleId = defaults.string(forKey: "messageStyleId") ?? "classic"` line (line 76), add:

```swift
        languageRaw = defaults.string(forKey: "languageRaw") ?? Language.english.rawValue
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && swift test`
Expected: PASS — 155 tests (151 + 4 new).

- [ ] **Step 5: Commit**

```bash
cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && git add Sources/StatusBarCore/Settings/SettingsStore.swift Tests/StatusBarCoreTests/SettingsStoreTests.swift && git commit -m "feat: persist language setting in SettingsStore"
```

---

### Task 3: Language picker in Settings

**Files:**
- Modify: `Sources/ClaudeStatusBar/SettingsView.swift:56-66`

**Interfaces:**
- Consumes: `Language` enum (Task 1); `$settings.language` (Task 2); `AppState.rerollThinkingPhrase()` (existing, unchanged — it already re-picks from `settings.messageStyle.thinking`, which now itself accounts for `language`).
- Produces: nothing consumed by later tasks (final task).

Note: `SettingsView` lives in the executable target, which the test target cannot import — verification for this task is `swift build` + the full core suite staying green, plus a manual check (same convention as `docs/superpowers/plans/2026-07-11-message-styles.md` Task 6).

- [ ] **Step 1: Write the implementation**

In `Sources/ClaudeStatusBar/SettingsView.swift`, inside `GeneralTab`'s `Form`, insert a new picker immediately after the existing "Message style" picker's `.onChange` block (i.e. after line 66, before the "Usage poll interval" picker):

```swift
            Picker("Language", selection: $settings.language) {
                Text("English").tag(Language.english)
                Text("Tiếng Việt").tag(Language.vietnamese)
            }
            .onChange(of: settings.language) {
                // Same instant-feedback mechanism as the style picker: a bar
                // currently in .thinking re-renders now; tool/waiting text
                // re-themes on the next elapsed tick (≤1 s).
                appState.rerollThinkingPhrase()
            }
```

So the relevant section of `GeneralTab.body` reads:

```swift
            Picker("Message style", selection: $settings.messageStyleId) {
                ForEach(MessageStyles.all) { style in
                    Text(style.name).tag(style.id)
                }
            }
            .onChange(of: settings.messageStyleId) {
                appState.rerollThinkingPhrase()
            }
            Picker("Language", selection: $settings.language) {
                Text("English").tag(Language.english)
                Text("Tiếng Việt").tag(Language.vietnamese)
            }
            .onChange(of: settings.language) {
                appState.rerollThinkingPhrase()
            }
            Picker("Usage poll interval", selection: $settings.pollMinutes) {
```

- [ ] **Step 2: Verify the build and suite**

Run: `cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && swift build && swift test`
Expected: build succeeds; 155 tests PASS.

- [ ] **Step 3: Manual verification**

Run: `cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && swift run ClaudeStatusBar`
Open Settings → General. Confirm:
- A "Language" picker appears next to "Message style", with options "English" and "Tiếng Việt".
- Switching Language to "Tiếng Việt" while "Pirate" is the selected Message style changes the bar's `.thinking` text immediately to one of the Vietnamese pirate phrases (e.g. "Dò kho báu").
- Switching Message style while Language is "Tiếng Việt" stays in Vietnamese (e.g. switching to "Cooking" shows "Nêm cho vừa" or similar, not English).
- Switching Language back to "English" restores English phrases.
Quit the app (`Ctrl+C` in the terminal) when done.

- [ ] **Step 4: Commit**

```bash
cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && git add Sources/ClaudeStatusBar/SettingsView.swift && git commit -m "feat: add Language picker to Settings General tab"
```

---

## Verification (whole feature)

- `swift test` — 155 tests pass, including the untouched `MessageStylesTests.swift` regression test (proves default-English output is byte-identical to before this feature).
- `bash scripts/hook-integration-test.sh` — checks pass (hook untouched; this proves it).
- `git diff main --stat` touches ONLY: `Language.swift` (new), `MessageStylesVi.swift` (new), `MessageStylesViTests.swift` (new), `MessageStyles.swift`, `SettingsStore.swift`, `SettingsStoreTests.swift`, `SettingsView.swift`, plus `docs/superpowers/`. Anything else (hook, `MenuBarText`, `ThinkingVerbs`, `SessionsSection`, `StatusIcon`) is a defect.
- Manual (from Task 3 Step 3): Language and Message style behave as independent axes; default install still renders English.
