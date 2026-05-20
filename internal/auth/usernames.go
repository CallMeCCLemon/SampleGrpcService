package auth

import (
	"fmt"
	"math/rand/v2"
)

var adjectives = []string{
	"Amber", "Ancient", "Arctic", "Ashen", "Blazing", "Blighted", "Bold", "Brave",
	"Bronze", "Calm", "Clever", "Cloudy", "Cobalt", "Cosmic", "Crimson", "Crystal",
	"Dark", "Dawn", "Deft", "Dire", "Dusk", "Dusty", "Elder", "Ember", "Endless",
	"Fallen", "Fierce", "Feral", "Frosty", "Gilded", "Grim", "Hollow", "Honored",
	"Icy", "Infernal", "Jagged", "Jade", "Keen", "Lofty", "Lost", "Lunar", "Lurking",
	"Marbled", "Misty", "Molten", "Mystic", "Noble", "Nether", "Obsidian", "Ominous",
	"Pale", "Phantom", "Primal", "Rapid", "Raging", "Runed", "Scarlet", "Shadowed",
	"Silent", "Silver", "Sly", "Solar", "Spectral", "Stern", "Stony", "Stormy",
	"Swift", "Toxic", "Twilight", "Unyielding", "Veiled", "Vengeful", "Void",
	"Wicked", "Wild", "Withered", "Wrathful",
}

var nouns = []string{
	"Adder", "Anvil", "Archer", "Asp", "Axe", "Basilisk", "Bear", "Blade",
	"Blaze", "Boar", "Bolt", "Bulwark", "Claw", "Cobra", "Condor", "Crag",
	"Drake", "Drifter", "Duelist", "Eagle", "Ember", "Falcon", "Fang", "Forge",
	"Fox", "Gale", "Gargoyle", "Ghost", "Golem", "Guardian", "Hawk", "Helm",
	"Hound", "Hunter", "Hydra", "Iron", "Jackal", "Knight", "Lance", "Lynx",
	"Mantle", "Marauder", "Monk", "Ogre", "Oracle", "Panther", "Pike", "Ranger",
	"Raven", "Reaver", "Rogue", "Sage", "Sentry", "Serpent", "Shade", "Shield",
	"Skull", "Slayer", "Specter", "Spike", "Spirit", "Stalker", "Storm", "Striker",
	"Tempest", "Thorn", "Tiger", "Titan", "Toad", "Tracker", "Troll", "Viper",
	"Void", "Warden", "Warlock", "Wasp", "Wolf", "Wyrm",
}

// GenerateUsername returns a random adjective+noun+number username, e.g. "StormyFalcon42".
// The number is in the range 10–999 to keep it short but varied.
func GenerateUsername() string {
	adj := adjectives[rand.IntN(len(adjectives))]
	noun := nouns[rand.IntN(len(nouns))]
	num := rand.IntN(990) + 10 // 10–999
	return fmt.Sprintf("%s%s%d", adj, noun, num)
}
