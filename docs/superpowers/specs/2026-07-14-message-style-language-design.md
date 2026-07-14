# Message Style Language (Vietnamese Support) — Design

**Date:** 2026-07-14
**Status:** Approved pending user spec review
**Repo:** claude-status-bar-macos (base: main @ bab9326)

## Goal

Add a Language setting (English / Tiếng Việt) so every message style's menu
bar phrases (thinking pool, tool phrases, waiting text) can render in
Vietnamese instead of English. Vietnamese phrases are **not** literal
translations — each style gets its own original, playful Vietnamese phrases
matching that style's theme and tone, the same way the English catalog was
written clean-room per style rather than derived from a shared template.

## Background

See `2026-07-11-message-styles-design.md` for the existing message-style
pipeline (`MessageStyle`, `MessageStyles`, `MenuBarText.model(...)`,
`SettingsStore.messageStyle`, the GeneralTab picker). That design explicitly
scoped localization out. This spec adds it, narrowly.

## Decisions (from brainstorming)

1. **Scope: message-style phrases only.** Language affects `thinking`,
   `tool`, and `waiting` text on the menu bar. Everything else — Settings UI
   labels, the style names in the picker ("Classic", "RPG", "Pirate", ...),
   the popover (`SessionsSection`), the hook binary, session-file format —
   stays English regardless of the Language setting.
2. **Classic gets a Vietnamese variant too.** Not just the 6 themed styles —
   all 7 styles have a Vietnamese catalog, so switching Language is
   consistent no matter which style is selected.
3. **Architecture: separate catalog file.** A new file
   `MessageStylesVi.swift` holds a full Vietnamese catalog, structurally
   parallel to `MessageStyles.swift` (same 7 ids, same order).
   `MessageStyles.swift` is untouched. `MessageStyles.style(id:language:)`
   selects which catalog to read from.
4. **Style picker names stay English.** The Picker labels ("Classic", "RPG",
   "Gardening", "Dumb", "Sci-Fi", "Cooking", "Pirate") do not change when
   Language = Vietnamese — only the phrase content they produce does.
5. **Tone: shorter and funnier than a first draft.** Iterated during
   brainstorming: original samples were trimmed for menu-bar width and
   pushed toward more comedic phrasing (the "Dumb" style's energy was
   explicitly called out as the right target register for the others too).

## Architecture

New file `Sources/StatusBarCore/Settings/Language.swift`:

```swift
public enum Language: String, CaseIterable, Sendable {
    case english, vietnamese
}
```

`Sources/StatusBarCore/Display/MessageStyles.swift` (touched — new overload
added, existing `style(id:)` and all 7 English style definitions unchanged):

```swift
public enum MessageStyles {
    public static let all: [MessageStyle]                 // unchanged
    public static func style(id: String) -> MessageStyle   // unchanged

    /// Total lookup across both language catalogs. English delegates to the
    /// existing `style(id:)`; Vietnamese delegates to `MessageStylesVi`.
    public static func style(id: String, language: Language) -> MessageStyle {
        switch language {
        case .english: return style(id: id)
        case .vietnamese: return MessageStylesVi.style(id: id)
        }
    }
}
```

New file `Sources/StatusBarCore/Display/MessageStylesVi.swift`, structurally
mirroring `MessageStyles.swift`:

```swift
enum MessageStylesVi {
    static let all: [MessageStyle] = [
        classic, rpg, gardening, dumb, scifi, cooking, pirate,
    ]

    /// Total lookup: unknown id falls back to Classic — the Vietnamese
    /// Classic, not the English one, so language stays consistent.
    static func style(id: String) -> MessageStyle {
        all.first { $0.id == id } ?? classic
    }

    // 7 static MessageStyle values, same ids/order as MessageStyles.swift,
    // Vietnamese thinking/tool/waiting content (see Style catalog below).
}
```

`MessageStyle` itself is unchanged — same struct, same shape, reused as-is
for both catalogs.

Touched components:

- **`SettingsStore`** — new persisted property `languageRaw: String` (key
  `"languageRaw"`, default `Language.english.rawValue`) + computed
  `language: Language` via `Language(rawValue:) ?? .english` (same bridge
  pattern as `displayStyleRaw`/`displayStyle`). `messageStyle` changes from
  `MessageStyles.style(id: messageStyleId)` to
  `MessageStyles.style(id: messageStyleId, language: language)`.
- **`SettingsView` (GeneralTab)** — new `Picker("Language", selection:
  $settings.language)` with two options (`Text("English").tag(.english)`,
  `Text("Tiếng Việt").tag(.vietnamese)`), placed next to "Message style".
  `.onChange(of: settings.language)` calls `appState.rerollThinkingPhrase()`
  — same instant-feedback mechanism the style picker already uses.

Untouched: `MenuBarText.model(...)` (already takes a fully-resolved
`MessageStyle`, doesn't care which language produced it), `ThinkingVerbs.swift`,
`VerbCycler`, hook binary, session-file format, popover.

## Style catalog (Vietnamese)

Length rule for the 6 themed styles: **2–4 space-separated words**, applied
to every `thinking`/`tool`/`waiting` phrase, tuned for menu bar width
(tighter than the English rule of 3–4, since a first draft ran long).
**Classic is exempt** from this rule, same precedent as English Classic —
its phrases are meant to be short single/double-word verbs, not themed
2–4 word phrases.

Tone: playful and a little goofy across every style — not literal
translations of the English catalog. Classic is the one exception that
leans literal for its `tool` map (it's the plain/default baseline, mirroring
English Classic's identity map), but its `thinking` pool is still original
short phrases, not word-for-word translations of `ThinkingVerbs.all`.

### Classic (id `classic`)

- **thinking (28):** Nghiền ngẫm · Ủ mưu · Vò đầu · Nung nấu · Nhâm nhi ý ·
  Gỡ rối · Cân đo · Phác thảo · Mơ mộng · Mày mò · Ngâm ý · Trăn trở ·
  Ấp ủ · Lẩm bẩm · Chắt lọc · Cân nhắc · Ấp trứng · Sáng tác · Vặn óc ·
  Nặn óc · Đun sôi ý · Dò dẫm · Lắp ráp ý · Tính toán · Nhen nhóm ·
  Ngẫm nghĩ · Xào nấu ý · Ướp ý tưởng
- **tool:** Editing: `Đang sửa` · Running: `Đang chạy` · Reading: `Đang đọc` ·
  Searching: `Đang tìm` · Browsing: `Đang lướt` · Delegating: `Đang giao việc` ·
  Working: `Đang làm`
- **waiting:** `Đang chờ bạn`

### RPG (id `rpg`)

- **thinking (12):** Múa kiếm chơi · Cày cấp độ · Săn boss trùm ·
  Đọc thần chú · Mở rương báu · Hú gọi đồng bọn · Đào mỏ EXP ·
  Ngáo phép thuật · Né đòn chí mạng · Buff máu cả team ·
  Vái trời khấn Phật · Combo chưa ra chiêu
- **tool:** Editing: `Rèn kiếm mới` · Running: `Phang chiêu cái đùng` ·
  Reading: `Ngâm cứu sách phép` · Searching: `Lục lọi hang động` ·
  Browsing: `Dạo quanh bản đồ` · Delegating: `Sai vặt đồng bọn` ·
  Working: `Cày như trâu`
- **waiting:** `Đang chờ lệnh sếp`

### Gardening (id `gardening`)

- **thinking (12):** Nhổ cỏ đầu óc · Ngửi hoa hồng · Bắt sâu trong đầu ·
  Tưới cây ý tưởng · Ươm mầm non · Bón phân cho não · Ngắm lá vàng rơi ·
  Hóng nắng thư giãn · Tỉa cành lung tung · Đào đất trồng cây ·
  Ngắt hoa hái quả · Trốn nắng trong vườn
- **tool:** Editing: `Tỉa cành lẹ tay` · Running: `Xới đất ầm ầm` ·
  Reading: `Đọc túi hạt giống` · Searching: `Săn lùng cỏ dại` ·
  Browsing: `Dạo một vòng vườn` · Delegating: `Sai yêu tinh vườn` ·
  Working: `Cắm mặt làm vườn`
- **waiting:** `Rau chín rồi đó`

### Dumb (id `dumb`)

- **thinking (12):** Não đang load · Đơ 5 giây · Ủa cái gì ·
  Chưa nghĩ ra gì · Đầu óc trên mây · Nạp thêm IQ · Não cá vàng ·
  Bấm nút restart não · Có ai không đó · Lú thiệt sự ·
  Đứng hình chấm cơm · Suy nghĩ hộ cái
- **tool:** Editing: `Gõ chữ loạn xạ` · Running: `Bấm nút to đùng` ·
  Reading: `Ngó lơ ngơ` · Searching: `Tìm hoài chưa thấy` ·
  Browsing: `Lướt web vô định` · Delegating: `Nhờ đứa khác làm` ·
  Working: `Làm được tí gì`
- **waiting:** `Tới lượt bạn đó`

### Sci-Fi (id `scifi`)

- **thinking (12):** Dò sóng lạ · Sạc pin photon · Tính giờ warp ·
  Du hành xuyên không · Giải mã tín hiệu · Canh giờ đổ bộ ·
  Buôn chuyện với AI · Ngắm sao băng bay · Vá lỗ đen ·
  Dò UFO ngoài kia · Nạp nhiên liệu warp · Chỉnh ăng-ten dò sóng
- **tool:** Editing: `Vá lại con chip` · Running: `Nổ máy tăng tốc` ·
  Reading: `Dò dữ liệu cũ` · Searching: `Quét khắp ngân hà` ·
  Browsing: `Dò kênh liên lạc` · Delegating: `Điều robot đi làm` ·
  Working: `Chạy full công suất`
- **waiting:** `Chờ lệnh chỉ huy`

### Cooking (id `cooking`)

- **thinking (12):** Nêm cho vừa · Lật bánh lẹ · Múa dao đầu bếp ·
  Canh lửa liu riu · Nếm thử chút xíu · Ướp cho ngấm vị ·
  Đảo đều tay nào · Hầm cho mềm nhừ · Trộn đều gia vị ·
  Canh nồi sôi trào · Bào vỏ thái lát · Nướng cho vàng đều
- **tool:** Editing: `Bày món lên đĩa` · Running: `Bật bếp lửa to` ·
  Reading: `Đọc công thức nấu` · Searching: `Sục sạo tủ lạnh` ·
  Browsing: `Dạo chợ mua đồ` · Delegating: `Gọi phụ bếp ra` ·
  Working: `Đứng bếp cả ngày`
- **waiting:** `Lên món rồi đó`

### Pirate (id `pirate`)

- **thinking (12):** Dò kho báu · Buộc dây neo · Nghe lỏm tin đồn ·
  Ngắm sao định hướng · Mài lưỡi đao cong · Đếm vàng trong rương ·
  Nhìn xa trông biển · Nói chuyện với vẹt · Cột chặt nút dây ·
  Vượt qua bão to · Dò tìm đảo giấu · Lau ống nhòm sáng
- **tool:** Editing: `Vá lại cánh buồm` · Running: `Khai hỏa đại bác` ·
  Reading: `Nghiên cứu bản đồ` · Searching: `Đào bới tìm vàng` ·
  Browsing: `Dò xét chân trời` · Delegating: `Hô hào cả đoàn` ·
  Working: `Cọ sàn tàu`
- **waiting:** `Chờ lệnh thuyền trưởng`

## Behavior

- Language and Message style are independent axes — 7 styles × 2 languages
  = 14 combinations. Changing either re-picks phrases immediately via
  `appState.rerollThinkingPhrase()` (thinking text updates at once; tool/
  waiting text re-themes on the next render tick, ≤1 s, same as a style
  switch today).
- Default `language` is `.english` — existing installs see byte-identical
  behavior with no migration.
- The popover, style picker names, and rest of Settings UI never change
  language — only the three menu-bar phrase groups do.

## Error handling

- `MessageStyles.style(id:language:)` is total: `.english` delegates to the
  existing total `style(id:)` (unknown id → English Classic); `.vietnamese`
  delegates to `MessageStylesVi.style(id:)` (unknown id → Vietnamese
  Classic). Neither path can crash or produce a missing style.
- `SettingsStore.language`: an unrecognized persisted `languageRaw` (e.g.
  from a downgrade or manual defaults edit) falls back to `.english` via
  the `Language(rawValue:) ?? .english` bridge — never crashes, never
  writes the fallback back to defaults (same convention as `displayStyle`).

## Testing (swift-testing 0.12.0 API: `@Test`/`@Suite`/`#expect`/`#require`)

- **New `MessageStylesViTests.swift`:**
  - Parity: `MessageStylesVi.all` has exactly the same 7 ids, in the same
    order, as `MessageStyles.all`.
  - Catalog invariants: every Vietnamese style covers all 7 canonical tool
    keys; non-empty thinking pool; non-empty waiting.
  - Themed styles (all except classic): 12 unique thinking phrases, and
    every thinking/tool/waiting phrase is 2–4 whitespace-separated words
    (same shape as the English invariant test, tighter range).
  - Classic has 28 unique thinking phrases (word count unconstrained, same
    exemption as English Classic).
  - Registry fallback: `MessageStylesVi.style(id: "nope")` returns
    Vietnamese classic.
  - `MessageStyles.style(id:language:)`: `.english` matches
    `MessageStyles.style(id:)` exactly for every id; `.vietnamese` matches
    `MessageStylesVi.style(id:)` exactly for every id.
- **`SettingsStoreTests` additions:** `language`/`languageRaw` persist and
  reload correctly; missing key defaults to `.english`; an unrecognized
  persisted value resolves to `.english` via `language` (never crashes);
  `messageStyle` reflects both `messageStyleId` and `language`.
- **Regression:** with default settings (`language == .english`), menu bar
  output is unchanged from before this feature — verified by the existing
  `MessageStylesTests.swift` regression test, which this feature doesn't
  touch.

## Out of scope

- Localizing the popover (`SessionsSection`), style picker names, or any
  other Settings UI text.
- A general i18n/localization framework (`.lproj`, `Localizable.strings`,
  `String(localized:)`) — this is a narrow, self-contained two-catalog
  switch, not app-wide localization infrastructure.
- Any hook binary or session-file format change.
- Additional languages beyond English/Vietnamese (the `Language` enum can
  grow later, but nothing here designs for a third case).
