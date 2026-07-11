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
        classic, rpg, gardening, dumb, scifi, cooking, pirate,
    ]

    /// Total lookup: an id persisted by a future version (or corrupted)
    /// must never crash the app — fall back to Classic, never write back.
    public static func style(id: String) -> MessageStyle {
        all.first { $0.id == id } ?? classic
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
                   "Studying ancient runes", "Brewing mana potions",
                   "Sharpening the sword", "Reading the prophecy",
                   "Charging the spell", "Plotting the quest",
                   "Leveling up wisdom", "Taming wild ideas",
                   "Gathering party buffs", "Deciphering old glyphs"],
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
                   "Mulching the beds", "Sunning the sprouts",
                   "Repotting big ideas", "Trimming the hedges",
                   "Feeding the roots", "Warming the greenhouse"],
        tool: ["Editing": "Pruning the branches", "Running": "Turning the soil",
               "Reading": "Reading seed packets", "Searching": "Hunting for weeds",
               "Browsing": "Visiting the nursery", "Delegating": "Hiring garden gnomes",
               "Working": "Tending the garden"],
        waiting: "Ripe for picking")

    static let dumb = MessageStyle(
        id: "dumb", name: "Dumb",
        thinking: ["Making think happen", "Doing brain stuff",
                   "Vibing real hard", "Loading smart thoughts",
                   "Buffering big brain", "Thinking really hard",
                   "Consulting inner monologue", "Staring at ceiling",
                   "Rebooting the noggin", "Doing a ponder",
                   "Cooking hot takes", "Charging brain cells"],
        tool: ["Editing": "Typing many words", "Running": "Pressing big button",
               "Reading": "Looking at stuff", "Searching": "Finding the thing",
               "Browsing": "Surfing the webs", "Delegating": "Making friends work",
               "Working": "Doing the thing"],
        waiting: "Your turn buddy")

    static let scifi = MessageStyle(
        id: "scifi", name: "Sci-Fi",
        thinking: ["Computing warp trajectories", "Consulting ship AI",
                   "Calibrating the sensors", "Charging photon banks",
                   "Mapping wormhole routes", "Decoding alien signals",
                   "Aligning the antenna", "Simulating first contact",
                   "Cooling the reactor", "Plotting orbital burns",
                   "Syncing quantum clocks", "Scanning nebula clouds"],
        tool: ["Editing": "Rewiring the core", "Running": "Firing the thrusters",
               "Reading": "Scanning data banks", "Searching": "Probing deep space",
               "Browsing": "Hailing distant stations", "Delegating": "Deploying drone fleet",
               "Working": "Running ship diagnostics"],
        waiting: "Awaiting your orders")

    static let cooking = MessageStyle(
        id: "cooking", name: "Cooking",
        thinking: ["Tasting the broth", "Whisking fresh ideas",
                   "Reducing the sauce", "Proofing the dough",
                   "Caramelizing the onions", "Seasoning to taste",
                   "Simmering the stock", "Kneading raw thoughts",
                   "Toasting the spices", "Resting the roast",
                   "Glazing the tart", "Julienning the details"],
        tool: ["Editing": "Plating the dish", "Running": "Firing the stove",
               "Reading": "Reading the recipe", "Searching": "Raiding the pantry",
               "Browsing": "Shopping the market", "Delegating": "Calling sous chefs",
               "Working": "Prepping the ingredients"],
        waiting: "Order up, chef")

    static let pirate = MessageStyle(
        id: "pirate", name: "Pirate",
        thinking: ["Plotting the course", "Reading the stars",
                   "Studying the charts", "Counting gold doubloons",
                   "Eyeing the horizon", "Trimming the mainsail",
                   "Whispering to parrots", "Sniffing for treasure",
                   "Tying sailor knots", "Weathering the storm",
                   "Charting hidden coves", "Polishing the spyglass"],
        tool: ["Editing": "Patching the sails", "Running": "Firing the cannons",
               "Reading": "Studying the map", "Searching": "Digging for treasure",
               "Browsing": "Scanning the horizon", "Delegating": "Rallying the crew",
               "Working": "Swabbing the deck"],
        waiting: "Cap'n needs orders")
}
