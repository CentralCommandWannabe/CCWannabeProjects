/**
 * Reusable ocean water columns for linked underwater Z-levels.
 *
 * Map authors can place /turf/open/openspace/ocean_column anywhere above
 * regular Oshan seabed. No particular station name or map trait is required.
 * The open-space turf renders the levels below via normal multi-Z transparency.
 *
 * Water visuals are shared by plane offset. Only columns next to reachable dry
 * floor turfs are actively processed as infinite ocean sources for flooding.
 *
 * This first version provides neutral-buoyancy swimming. Pressure,
 * decompression, oxygen consumption, and more realistic buoyancy are future work.
 */

// A per-client looping underwater bed; 993 is not one of MonkeStation's
// existing named sound channels. We deliberately leave CHANNEL_BUZZ alone.
#define CHANNEL_OCEAN_RUMBLE 993

/// Determine whether a turf is part of the permanent open ocean.
///
/// This is based on what the tile IS, not on whether a water column happens
/// to be directly above it. The seabed stays submerged beneath overhangs,
/// hull floors, caves, or other solid geometry.
///
/// The /area/ocean fallback also lets mappers use a custom open-floor turf
/// for an underwater environment without requiring a special ambience area.
/// Do not use an ocean area for a dry, sealed room. Dynamic flooding inside
/// sealed compartments is a separate system and is intentionally excluded.
/proc/is_swimmable_ocean_turf(turf/check_turf)
	if(!istype(check_turf))
		return FALSE
	if(istype(check_turf, /turf/open/openspace/ocean_column))
		return TRUE
	if(isoceanturf(check_turf))
		return TRUE
	// Non-column open-space is not automatically water: this includes
	// dry openings within the submarine, which will need flood detection.
	if(!isopenturf(check_turf) || isopenspaceturf(check_turf))
		return FALSE
	return istype(get_area(check_turf), /area/ocean)

/turf/open/openspace/ocean_column
	name = "open ocean"
	desc = "An open column of deep water. You can swim upwards or downwards."
	planetary_atmos = TRUE
	initial_gas_mix = OSHAN_DEFAULT_ATMOS
	baseturfs = /turf/open/openspace/ocean_column

	/// One shared visual per multiz rendering offset, not one atom per tile.
	var/static/list/column_visuals_by_offset = list()
	var/static/list/water_reagents = list(/datum/reagent/water = 10)

	/// Shared with Oshan seabed movement, so we do not allocate a sound list per step.
	var/static/list/swimming_sounds = list(
		'sound/effects/water_wade1.ogg',
		'sound/effects/water_wade2.ogg',
		'sound/effects/water_wade3.ogg',
		'sound/effects/water_wade4.ogg'
	)

	/// Cardinal directions with a reachable, non-ocean, non-open-space floor.
	var/list/open_turfs = list()

/turf/open/openspace/ocean_column/LateInitialize(mapload_arg)
	. = ..()

	var/plane_offset = GET_Z_PLANE_OFFSET(z)
	var/offset_key = "[plane_offset]"
	var/obj/effect/abstract/ocean_overlay/water_visual = column_visuals_by_offset[offset_key]
	if(!water_visual)
		water_visual = new(null, water_reagents)
		SET_PLANE_W_SCALAR(water_visual, AREA_PLANE, plane_offset)
		column_visuals_by_offset[offset_key] = water_visual
	vis_contents += water_visual
	light_color = water_visual.color

	if(!atmos_adjacent_turfs)
		immediate_calculate_adjacent_turfs()
	RegisterSignal(src, COMSIG_TURF_CALCULATED_ADJACENT_ATMOS, PROC_REF(rebuild_adjacent))
	rebuild_adjacent()

/turf/open/openspace/ocean_column/Destroy()
	UnregisterSignal(src, COMSIG_TURF_CALCULATED_ADJACENT_ATMOS)
	SSliquids.active_ocean_columns -= src
	return ..()

/turf/open/openspace/ocean_column/Entered(atom/movable/arrived, atom/old_loc, list/atom/old_locs)
	// Apply FLOATING before normal open-space Entered() can start a fall.
	if(isliving(arrived))
		var/mob/living/swimmer = arrived
		if(!swimmer.incorporeal_move)
			swimmer.apply_status_effect(/datum/status_effect/ocean_swimming)
			if(!swimmer.has_status_effect(/datum/status_effect/ocean_affected))
				swimmer.apply_status_effect(/datum/status_effect/ocean_affected)

			// One splash on entering water from dry ground, then Oshan's
			// usual 30% water movement sounds while swimming through columns.
			if(isturf(old_loc) && !is_swimmable_ocean_turf(old_loc))
				playsound(src, 'sound/effects/splash_loud.ogg', 50, FALSE)
			else if(prob(30))
				playsound(src, pick(swimming_sounds), 50, FALSE)
	return ..()


// On a multiz ocean map, a seabed tile is swimmable when its tile above is
// ocean_column. Reactivate swimming when walking out from below a hull onto
// exposed seabed. The column's Entered() cannot handle this case, because
// Page Up is blocked until the FLOATING movement trait has been restored.
// Existing Oshan seabeds without an ocean_column above are unaffected.
/turf/open/floor/plating/ocean/Entered(atom/movable/arrived, atom/old_loc, list/atom/old_locs)
	. = ..()
	if(!isliving(arrived) || !is_swimmable_ocean_turf(src))
		return
	var/mob/living/swimmer = arrived
	if(swimmer.incorporeal_move || swimmer.has_status_effect(/datum/status_effect/ocean_swimming))
		return
	swimmer.apply_status_effect(/datum/status_effect/ocean_swimming)

/turf/open/openspace/ocean_column/proc/rebuild_adjacent()
	SIGNAL_HANDLER
	open_turfs.len = 0
	for(var/direction in GLOB.cardinals)
		var/turf/adjacent = get_step(src, direction)
		if(!isopenturf(adjacent) || isopenspaceturf(adjacent) || isoceanturf(adjacent))
			continue
		if(!TURFS_CAN_SHARE(src, adjacent))
			continue
		open_turfs += direction

	if(length(open_turfs))
		SSliquids.active_ocean_columns |= src
	else
		SSliquids.active_ocean_columns -= src

/turf/open/openspace/ocean_column/proc/process_turf()
	for(var/direction in open_turfs)
		var/turf/adjacent = get_step(src, direction)
		if(!isopenturf(adjacent) || isopenspaceturf(adjacent) || isoceanturf(adjacent) || !TURFS_CAN_SHARE(src, adjacent))
			open_turfs -= direction
			continue
		adjacent.add_liquid_list(water_reagents, FALSE, T20C)
	if(!length(open_turfs))
		SSliquids.active_ocean_columns -= src

// Existing Goon bubble sprite, emitted economically as BYOND particles.
// No new DMI or additional per-tile processing is required.
/particles/ocean_swimming_bubbles
	icon = 'goon/icons/effects/particles.dmi'
	icon_state = "bubble"
	width = 32
	height = 48
	count = 7
	spawning = 0.65
	lifespan = 2.5 SECONDS
	fade = 0.7 SECONDS
	color = "#a8e4ffb8"
	position = generator(GEN_VECTOR, list(-3, 7, 0), list(3, 12, 0), NORMAL_RAND)
	velocity = generator(GEN_VECTOR, list(-0.15, 0.45, 0), list(0.15, 0.7, 0), NORMAL_RAND)
	gravity = list(0, 0.25, 0)
	scale = generator(GEN_VECTOR, list(0.35, 0.35), list(0.6, 0.6), NORMAL_RAND)

/// Swimming is automatically enabled by the turf, not by a specific station.
/datum/status_effect/ocean_swimming
	id = "ocean_swimming"
	duration = STATUS_EFFECT_PERMANENT
	alert_type = null

	/// The client hearing the local ocean drone; needed to silence it on exit.
	var/client/ocean_sound_client
	var/ocean_sound_volume = 0

/datum/status_effect/ocean_swimming/on_apply()
	if(!is_swimmable_ocean_turf(get_turf(owner)))
		return FALSE
	ADD_TRAIT(owner, TRAIT_MOVE_FLOATING, "ocean_swimming")
	owner.add_movespeed_modifier(/datum/movespeed_modifier/ocean_swimming)
	RegisterSignal(owner, COMSIG_MOVABLE_MOVED, PROC_REF(check_swimming_location))
	RegisterSignal(owner, COMSIG_LIVING_Z_IMPACT, PROC_REF(prevent_underwater_impact))
	// Use the standard breathing hook instead of redefining a core carbon proc.
	// This permits oxygen internals while preventing ambient ocean gas inhalation.
	if(iscarbon(owner))
		RegisterSignal(owner, COMSIG_CARBON_ATTEMPT_BREATHE, PROC_REF(prevent_ocean_breathing))
	// Particles follow the swimming mob and are automatically cleaned up
	// when this status effect is deleted by the base status effect code.
	particle_effect = new(owner, /particles/ocean_swimming_bubbles)
	update_ocean_sound()
	return TRUE

/datum/status_effect/ocean_swimming/proc/check_swimming_location(datum/source)
	SIGNAL_HANDLER
	if(!is_swimmable_ocean_turf(get_turf(owner)))
		qdel(src)
		return
	update_ocean_sound()

/datum/status_effect/ocean_swimming/tick()
	if(!is_swimmable_ocean_turf(get_turf(owner)))
		qdel(src)
		return
	// Handles a client logging in, disconnecting, or switching bodies.
	update_ocean_sound()

/// Play the continuous low-volume water bed for this client alone. It is
/// separate from the area ambience and existing ship hum (CHANNEL_BUZZ).
/datum/status_effect/ocean_swimming/proc/update_ocean_sound()
	var/client/current_client = owner?.client
	if(ocean_sound_client && ocean_sound_client != current_client)
		SEND_SOUND(ocean_sound_client, sound(null, repeat = FALSE, wait = FALSE, channel = CHANNEL_OCEAN_RUMBLE))
		ocean_sound_client = null
		ocean_sound_volume = 0
	if(!current_client)
		return

	var/new_volume = calculate_mixed_volume(current_client, 17, CHANNEL_BUZZ)
	if(ocean_sound_client == current_client && ocean_sound_volume == new_volume)
		return

	if(new_volume <= 0)
		SEND_SOUND(current_client, sound(null, repeat = FALSE, wait = FALSE, channel = CHANNEL_OCEAN_RUMBLE))
	else if(ocean_sound_client == current_client && ocean_sound_volume > 0)
		// Respect live White Noise/master mixer adjustments without restarting the loop.
		var/sound/updated_sound = sound(null, channel = CHANNEL_OCEAN_RUMBLE, volume = new_volume)
		updated_sound.status = SOUND_UPDATE
		SEND_SOUND(current_client, updated_sound)
	else
		SEND_SOUND(current_client, sound('sound/ambience/ocean/ocean_rumble.ogg', repeat = TRUE, wait = FALSE, volume = new_volume, channel = CHANNEL_OCEAN_RUMBLE))
	ocean_sound_client = current_client
	ocean_sound_volume = new_volume

/// The ocean is water even though the Oshan tiles have an atmospheric gas mix.
/// In the water, unprotected carbon mobs must hold their breath and suffocate.
/// Active, valid oxygen internals remain handled by vanilla carbon breathing.
/datum/status_effect/ocean_swimming/proc/prevent_ocean_breathing(mob/living/carbon/source, seconds_per_tick, times_fired)
	SIGNAL_HANDLER
	if(!is_swimmable_ocean_turf(get_turf(source)))
		return NONE
	if((source.internal || source.external) && !source.invalid_internals())
		return NONE
	return BREATHE_SKIP_BREATH

/datum/status_effect/ocean_swimming/proc/prevent_underwater_impact(mob/living/source, levels, turf/landing_turf)
	SIGNAL_HANDLER
	if(is_swimmable_ocean_turf(landing_turf))
		return NO_Z_IMPACT_DAMAGE

/datum/status_effect/ocean_swimming/on_remove()
	if(ocean_sound_client)
		SEND_SOUND(ocean_sound_client, sound(null, repeat = FALSE, wait = FALSE, channel = CHANNEL_OCEAN_RUMBLE))
		ocean_sound_client = null
		ocean_sound_volume = 0
	UnregisterSignal(owner, list(COMSIG_MOVABLE_MOVED, COMSIG_LIVING_Z_IMPACT, COMSIG_CARBON_ATTEMPT_BREATHE))
	REMOVE_TRAIT(owner, TRAIT_MOVE_FLOATING, "ocean_swimming")
	owner.remove_movespeed_modifier(/datum/movespeed_modifier/ocean_swimming)
	return ..()

/datum/movespeed_modifier/ocean_swimming
	multiplicative_slowdown = 0.6

#undef CHANNEL_OCEAN_RUMBLE
