# Message Styles — Design

**Date:** 2026-07-11
**Status:** Approved pending user spec review
**Repo:** claude-status-bar-macos (base: main @ 5db72a4, v1 merged)

## Goal

Let the user pick a themed "message style" for the menu bar activity text.
Each style rewrites what the bar says while Claude works — thinking phrases,
tool-activity phrases, and the waiting text — as short English phrases
(3–4 words each). The picker lives in Settings → General.

## Background (current pipeline)

- **Thinking** — `ThinkingVerbs.all` (28 single-word verbs) cycled by
  `VerbCycler` (uniform random, never repeats the previous pick); rendered
  as `Verb… · 12s`.
- **Tool** — the hook binary maps tool names to canonical labels via
  `ToolLabels.label(for:)` (`Editing`, `Running`, `Reading`, `Searching`,
  `Browsing`, `Delegating`; unknown tools pass through capitalized;
  missing tool name → `Working`) and **bakes the label string into the
  session file**. The app renders `Label · 12s`.
- **Waiting** — fixed `"Waiting for you"`.
- The popover (`SessionsSection`) renders its own canonical state text,
  independent of the menu bar.

## Decisions (from brainstorming)

1. **Scope: full theme.** A style rewrites all three groups: thinking pool,
   tool labels, waiting text.
2. **"Dump" example = Dumb** — intentionally goofy meme style.
3. **Lineup: 7 styles** — Classic (default, preserves today's behavior
   exactly) + RPG, Gardening, Dumb, Sci-Fi, Cooking, Pirate.
4. **Approach: display-time theming.** The app maps canonical labels to
   themed phrases at render time. Hook binary, session-file format, and
   popover are untouched — no version-skew risk with already-installed
   hooks, and style changes apply instantly to running sessions.

## Architecture

New file `Sources/StatusBarCore/Display/MessageStyles.swift`:

```swift
public struct MessageStyle: Identifiable, Sendable {
    public let id: String              // "classic", "rpg", ...
    public let name: String            // Picker display: "Classic", "RPG", ...
    public let thinking: [String]      // phrase pool for state .thinking
    public let tool: [String: String]  // canonical label -> themed phrase;
                                       // keys: Editing, Running, Reading,
                                       // Searching, Browsing, Delegating, Working
    public let waiting: String
}

public enum MessageStyles {
    public static let all: [MessageStyle]              // classic first
    public static func style(id: String) -> MessageStyle  // unknown id -> classic
}
```

Touched components (no other new files):

- **`ThinkingVerbs.swift`** — `ThinkingVerbs.all` stays as-is (public API,
  referenced by tests); it becomes the `thinking` pool of the `classic`
  style. `VerbCycler` keeps its name but generalizes:
  `mutating func next(from phrases: [String]) -> String` plus
  `mutating func reset()`. Internal guard: if the remembered previous index
  no longer fits the given pool (pool changed size), treat it as nil —
  never index out of bounds. No-repeat rule unchanged.
- **`MenuBarText.model(...)`** — gains a `style: MessageStyle` parameter.
  `.tool` case: `style.tool[label] ?? label` (unknown pass-through labels
  like `WebFetch` render unthemed). `.waiting` case: `style.waiting`.
  The pre-picked `verb` parameter stays and is used verbatim for
  `.thinking`. Formats unchanged: `Phrase… · 12s` / `Phrase · 12s`.
- **`SettingsStore`** — new persisted property `messageStyleId: String`
  (UserDefaults key `messageStyleId`, default `"classic"`) + computed
  `messageStyle: MessageStyle` via `MessageStyles.style(id:)`.
- **`AppState`** — `currentVerb` is drawn from the active style's
  `thinking` pool (`verbCycler.next(from: settings.messageStyle.thinking)`);
  new method `rerollThinkingPhrase()` resets the cycler and re-picks
  `currentVerb` so a style switch updates the bar immediately.
- **`SettingsView` (GeneralTab)** — gains `let appState: AppState`; new
  `Picker("Message style", selection: $settings.messageStyleId)` listing
  `MessageStyles.all` (`Text(style.name).tag(style.id)`), placed below
  "Display style", with `.onChange(of: settings.messageStyleId)` calling
  `appState.rerollThinkingPhrase()`.

Untouched: hook binary, `SessionReducer`, session-file format,
`SessionsSection` (popover), `StatusIcon`.

## Style catalog

All phrases are original (clean-room — nothing sourced from the KDE repo),
English, and exactly 3–4 words for themed styles. Classic keeps today's
single-word verbs and canonical labels, exempt from the word-count rule.

### Classic (id `classic`, default)

- **thinking:** `ThinkingVerbs.all` (the existing 28 verbs, unchanged)
- **tool:** identity map — `Editing: "Editing"`, `Running: "Running"`,
  `Reading: "Reading"`, `Searching: "Searching"`, `Browsing: "Browsing"`,
  `Delegating: "Delegating"`, `Working: "Working"`
- **waiting:** `Waiting for you`

### RPG (id `rpg`)

- **thinking (12):** Consulting the oracle · Rolling for wisdom ·
  Studying ancient runes · Brewing mana potions · Sharpening the sword ·
  Reading the prophecy · Charging the spell · Plotting the quest ·
  Leveling up wisdom · Taming wild ideas · Gathering party buffs ·
  Deciphering old glyphs
- **tool:** Editing: `Forging the blade` · Running: `Casting the spell` ·
  Reading: `Reading the scrolls` · Searching: `Scouting the dungeon` ·
  Browsing: `Charting distant lands` · Delegating: `Summoning the party` ·
  Working: `Grinding the XP`
- **waiting:** `Awaiting your command`

### Gardening (id `gardening`)

- **thinking (12):** Watering the seedlings · Sprouting new ideas ·
  Composting stray thoughts · Sowing fresh seeds · Sniffing the roses ·
  Grafting wild branches · Mulching the beds · Sunning the sprouts ·
  Repotting big ideas · Trimming the hedges · Feeding the roots ·
  Warming the greenhouse
- **tool:** Editing: `Pruning the branches` · Running: `Turning the soil` ·
  Reading: `Reading seed packets` · Searching: `Hunting for weeds` ·
  Browsing: `Visiting the nursery` · Delegating: `Hiring garden gnomes` ·
  Working: `Tending the garden`
- **waiting:** `Ripe for picking`

### Dumb (id `dumb`)

- **thinking (12):** Making think happen · Doing brain stuff ·
  Vibing real hard · Loading smart thoughts · Buffering big brain ·
  Thinking really hard · Consulting inner monologue · Staring at ceiling ·
  Rebooting the noggin · Doing a ponder · Cooking hot takes ·
  Charging brain cells
- **tool:** Editing: `Typing many words` · Running: `Pressing big button` ·
  Reading: `Looking at stuff` · Searching: `Finding the thing` ·
  Browsing: `Surfing the webs` · Delegating: `Making friends work` ·
  Working: `Doing the thing`
- **waiting:** `Your turn buddy`

### Sci-Fi (id `scifi`)

- **thinking (12):** Computing warp trajectories · Consulting ship AI ·
  Calibrating the sensors · Charging photon banks · Mapping wormhole routes ·
  Decoding alien signals · Aligning the antenna · Simulating first contact ·
  Cooling the reactor · Plotting orbital burns · Syncing quantum clocks ·
  Scanning nebula clouds
- **tool:** Editing: `Rewiring the core` · Running: `Firing the thrusters` ·
  Reading: `Scanning data banks` · Searching: `Probing deep space` ·
  Browsing: `Hailing distant stations` · Delegating: `Deploying drone fleet` ·
  Working: `Running ship diagnostics`
- **waiting:** `Awaiting your orders`

### Cooking (id `cooking`)

- **thinking (12):** Tasting the broth · Whisking fresh ideas ·
  Reducing the sauce · Proofing the dough · Caramelizing the onions ·
  Seasoning to taste · Simmering the stock · Kneading raw thoughts ·
  Toasting the spices · Resting the roast · Glazing the tart ·
  Julienning the details
- **tool:** Editing: `Plating the dish` · Running: `Firing the stove` ·
  Reading: `Reading the recipe` · Searching: `Raiding the pantry` ·
  Browsing: `Shopping the market` · Delegating: `Calling sous chefs` ·
  Working: `Prepping the ingredients`
- **waiting:** `Order up, chef`

### Pirate (id `pirate`)

- **thinking (12):** Plotting the course · Reading the stars ·
  Studying the charts · Counting gold doubloons · Eyeing the horizon ·
  Trimming the mainsail · Whispering to parrots · Sniffing for treasure ·
  Tying sailor knots · Weathering the storm · Charting hidden coves ·
  Polishing the spyglass
- **tool:** Editing: `Patching the sails` · Running: `Firing the cannons` ·
  Reading: `Studying the map` · Searching: `Digging for treasure` ·
  Browsing: `Scanning the horizon` · Delegating: `Rallying the crew` ·
  Working: `Swabbing the deck`
- **waiting:** `Cap'n needs orders`

## Behavior

- Style switch takes effect immediately: the picker's `onChange` re-rolls
  the thinking phrase, so a bar currently in `.thinking` re-renders with
  the new style at once; tool/waiting text re-themes on the next render
  tick (≤1 s, the existing TimelineView cadence).
- Persisted `messageStyleId` not matching any style (e.g. a style removed
  in a future version) silently falls back to Classic — never crashes,
  never writes back.
- Thinking phrases keep cycling on each idle/tool → thinking transition,
  never repeating the immediately previous phrase (existing rule).
- The popover intentionally keeps canonical text (`Thinking`, `Editing`,
  `Waiting for you`) — it is the functional detail view; the theme lives
  only in the menu bar.

## Error handling

- `MessageStyles.style(id:)` total: any unknown id returns Classic.
- `style.tool[label] ?? label` guarantees a printable label for tools the
  map does not know (capitalized raw tool names from the hook fallback).
- `VerbCycler.next(from:)` guards a stale previous index against the given
  pool's size — safe across pools of different lengths.

## Testing (swift-testing 0.12.0 API: `@Test`/`@Suite`/`#expect`/`#require`)

- **Catalog invariants** — for every style in `MessageStyles.all`: all 7
  tool keys present, non-empty thinking pool, non-empty waiting; for every
  themed style (all except `classic`): every thinking/tool/waiting phrase
  is 3–4 whitespace-separated words; ids unique; `classic` is first.
- **Registry fallback** — `style(id: "nope")` returns classic;
  `style(id: "pirate")` returns pirate.
- **MenuBarText theming** — known label maps to themed phrase; unknown
  label (`WebFetch`) passes through; waiting state renders `style.waiting`;
  elapsed-time formats unchanged.
- **Cycler** — no immediate repeat within a pool; switching to a smaller
  pool never indexes out of bounds; `reset()` clears the no-repeat memory.
- **SettingsStore** — `messageStyleId` persists and reloads; missing key
  defaults to `"classic"`; unknown persisted id resolves to Classic via
  `messageStyle`.
- **Regression** — with default settings, menu bar output is byte-identical
  to today: verbs drawn from `ThinkingVerbs.all`, tool state renders
  `Editing · 12s`, waiting renders `Waiting for you`.

## Out of scope

- Theming the popover or the Clawd icon set per style.
- User-defined/custom styles, per-style icons, localization.
- Any hook binary or session-file format change.
