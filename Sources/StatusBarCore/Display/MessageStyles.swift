import Foundation

/// A themed set of menu bar phrases. `thinking` feeds `VerbCycler`;
/// `tool` maps the hook's canonical labels (Editing, Running, Reading,
/// Searching, Browsing, Delegating, Working) to themed phrases — unknown
/// labels render unthemed via `tool[label] ?? label`; `waiting` replaces
/// "Waiting for you". The popover keeps canonical text by design.
public struct MessageStyle: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let thinking: [String]
    public let tool: [String: String]
    public let waiting: String
}

public enum MessageStyles {
    public static let all: [MessageStyle] = [
        classic, rpg, gardening, dumb, scifi, cooking, pirate, harrypotter,
    ]

    /// Total lookup: an id persisted by a future version (or corrupted)
    /// must never crash the app — fall back to Classic, never write back.
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
        id: "classic", name: "Classic",
        thinking: ThinkingVerbs.all,
        tool: ["Editing": "Editing", "Running": "Running", "Reading": "Reading",
               "Searching": "Searching", "Browsing": "Browsing",
               "Delegating": "Delegating", "Working": "Working"],
        waiting: "Waiting for you")

    static let rpg = MessageStyle(
        id: "rpg", name: "RPG",
        thinking: ["Consulting the oracle", "Rolling for wisdom",
                   "Diving into the dungeon", "Brewing mana potions",
                   "Facing the final boss", "Reading the prophecy",
                   "Charging the spell", "Plotting the quest",
                   "Leveling up wisdom", "Casting a fireball",
                   "Gathering party buffs", "Looting the boss chest"],
        tool: ["Editing": "Forging the blade", "Running": "Casting the spell",
               "Reading": "Reading the scrolls", "Searching": "Scouting the dungeon",
               "Browsing": "Charting distant lands", "Delegating": "Summoning the party",
               "Working": "Grinding the XP"],
        waiting: "Awaiting your command")

    static let gardening = MessageStyle(
        id: "gardening", name: "Gardening",
        thinking: ["Watering the seedlings", "Sprouting new ideas",
                   "Composting stray thoughts", "Sowing fresh seeds",
                   "Sniffing the roses", "Grafting wild branches",
                   "Mulching the beds", "Deadheading the flowers",
                   "Repotting big ideas", "Trimming the hedges",
                   "Feeding the roots", "Harvesting the tomatoes"],
        tool: ["Editing": "Pruning the branches", "Running": "Turning the soil",
               "Reading": "Reading seed packets", "Searching": "Hunting for weeds",
               "Browsing": "Visiting the nursery", "Delegating": "Hiring garden gnomes",
               "Working": "Tending the garden"],
        waiting: "Ripe for picking")

    static let dumb = MessageStyle(
        id: "dumb", name: "Dumb",
        thinking: ["Making think happen", "Doing brain stuff",
                   "Going full goblin mode", "Loading smart thoughts",
                   "Doom scrolling for answers", "Thinking really hard",
                   "Consulting inner monologue", "Staring at ceiling",
                   "Rebooting the noggin", "Being delulu on purpose",
                   "Cooking hot takes", "Giving major NPC energy"],
        tool: ["Editing": "Typing many words", "Running": "Hoping this works",
               "Reading": "Reading without understanding", "Searching": "Finding the thing",
               "Browsing": "Surfing the webs", "Delegating": "Making friends work",
               "Working": "Doing the thing"],
        waiting: "Your turn buddy")

    static let scifi = MessageStyle(
        id: "scifi", name: "Sci-Fi",
        thinking: ["Computing warp trajectories", "Consulting ship AI",
                   "Charting an unknown planet", "Charging photon banks",
                   "Mapping wormhole routes", "Decoding alien signals",
                   "Aligning the antenna", "Simulating first contact",
                   "Cooling the reactor", "Plotting orbital burns",
                   "Syncing quantum clocks", "Docking with the station"],
        tool: ["Editing": "Rewiring the core", "Running": "Firing the thrusters",
               "Reading": "Scanning data banks", "Searching": "Probing deep space",
               "Browsing": "Hailing distant stations", "Delegating": "Deploying drone fleet",
               "Working": "Running ship diagnostics"],
        waiting: "Awaiting your orders")

    static let cooking = MessageStyle(
        id: "cooking", name: "Cooking",
        thinking: ["Whipping dalgona coffee", "Folding baked feta pasta",
                   "Assembling birria tacos", "Stacking a smash burger",
                   "Skewering candied tanghulu", "Building a butter board",
                   "Drizzling hot honey", "Charring corn ribs",
                   "Blending a matcha latte", "Frying Nashville hot chicken",
                   "Rolling sushi burritos", "Air-frying literally everything"],
        tool: ["Editing": "Garnishing with microgreens", "Running": "Cranking the wok",
               "Reading": "Scrolling recipe videos", "Searching": "Hunting rare ingredients",
               "Browsing": "Scrolling foodie TikTok", "Delegating": "Texting the delivery guy",
               "Working": "Meal-prepping for Sunday"],
        waiting: "Stomach's officially growling")

    static let pirate = MessageStyle(
        id: "pirate", name: "Pirate",
        thinking: ["Consulting Jack's compass", "Summoning the Kraken",
                   "Bargaining with Davy Jones", "Drinking questionable rum",
                   "Touching cursed Aztec gold", "Hoisting the black colours",
                   "Whistling for the Pearl", "Consulting the Pirate Code",
                   "Sailing past Isla Muerta", "Dodging the Flying Dutchman",
                   "Parleying with the crew", "Being the worst pirate"],
        tool: ["Editing": "Caulking the hull", "Running": "Unleashing the cannons",
               "Reading": "Reading Jones' logbook", "Searching": "Hunting cursed treasure",
               "Browsing": "Squinting through the spyglass", "Delegating": "Rallying the cursed crew",
               "Working": "Swabbing under full moon"],
        waiting: "Compass points to you")

    static let harrypotter = MessageStyle(
        id: "harrypotter", name: "Harry Potter",
        thinking: ["Casting Wingardium Leviosa", "Casting Expecto Patronum",
                   "Whispering Alohomora softly", "Practicing Protego shields",
                   "Casting silent Legilimens", "Muttering old Riddikulus",
                   "Trying Finite Incantatem", "Casting Petrificus Totalus",
                   "Whispering quiet Muffliato", "Casting gentle Rictusempra",
                   "Casting quick Stupefy", "Conjuring birds with Avis"],
        tool: ["Editing": "Casting Reparo swiftly", "Running": "Casting Avada Kedavra",
               "Reading": "Casting Revelio slowly", "Searching": "Casting Accio spell",
               "Browsing": "Casting Point Me", "Delegating": "Sending owl post",
               "Working": "Casting Scourgify daily"],
        waiting: "Awaiting your next spell")
}
