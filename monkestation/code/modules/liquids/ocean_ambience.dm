/**
 * Optional ocean-specific distant ambience, using MonkeStation's SSambience.
 * Map these /area subtypes to play occasional underwater sound effects.
 * Continuous underwater rumble is instead tied to the swimming status effect,
 * so that it reliably stops when the swimmer enters a dry compartment.
 *
 * SOUND ASSETS: The referenced OGGs are deliberately NOT bundled. See
 * README_MANUAL.md to acquire CC0 originals from Freesound before compiling.
 */

/area/ocean/ambient
	// The continuous bed is handled separately; don't use the ship engine loop.
	ambient_buzz = null
	ambientsounds = list(
		'sound/ambience/ocean/ocean_bubbles.ogg',
		'sound/ambience/ocean/ocean_creak.ogg',
		'sound/ambience/ocean/ocean_strange.ogg',
	)
	min_ambience_cooldown = 55 SECONDS
	max_ambience_cooldown = 100 SECONDS
	forced_ambience = FALSE

/area/ocean/ambient/play_ambience(mob/M, sound/override_sound, volume)
	return ..(M, override_sound, 18)

/area/ocean/dark/ambient
	ambient_buzz = null
	ambientsounds = list(
		'sound/ambience/ocean/ocean_bubbles.ogg',
		'sound/ambience/ocean/ocean_creak.ogg',
		'sound/ambience/ocean/ocean_strange.ogg',
	)
	min_ambience_cooldown = 55 SECONDS
	max_ambience_cooldown = 100 SECONDS
	forced_ambience = FALSE

/area/ocean/dark/ambient/play_ambience(mob/M, sound/override_sound, volume)
	return ..(M, override_sound, 18)
