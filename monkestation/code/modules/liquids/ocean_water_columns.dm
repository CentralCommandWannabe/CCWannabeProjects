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
 * Phase 1 flooding covers SIDE HULL BREACHES ONLY. Vertical flooding,
 * dynamic interior diving, pressure, pumps, and air pockets are future work.
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
    // Treat an ordinary open Z-hole directly above ocean as water-exposed.
    if(isopenspaceturf(check_turf))
        var/turf/below = GET_TURF_BELOW(check_turf)
        if(below && (isoceanturf(below) || istype(below, /turf/open/openspace/ocean_column)))
            return TRUE
    if(isoceanturf(check_turf))
        return TRUE
    // Non-column open-space is not automatically water: this includes
    // dry openings within the submarine, which will need flood detection.
    if(!isopenturf(check_turf) || isopenspaceturf(check_turf))
        return FALSE
    return istype(get_area(check_turf), /area/ocean)

/// True only in water, not in a dry open-space tile that merely permits a diver
/// to return through a vertical opening. The two concepts must stay separate:
/// keeping FLOATING is a movement exception, not proof that a room is flooded.
/// When the compartment system gains physical water levels, this predicate can
/// also consult its flooded-room state without changing movement rules.
/proc/is_submerged_ocean_turf(turf/check_turf)
    if(!istype(check_turf))
        return FALSE
    if(isopenspaceturf(check_turf) && !istype(check_turf, /turf/open/openspace/ocean_column))
        return ocean_water_is_flooded_shaft(check_turf)
    return ocean_water_is_swimmable_environment(check_turf)

// A direct ocean opening needs a faint depth cue even when no nearby room
// has yet been discovered. This is O(1) local geometry, not a region scan.
// Existing native multiz transparency remains authoritative.
/turf/open/openspace/LateInitialize(mapload_arg)
    . = ..()
    // Ocean columns already render native ocean through vis_contents.
    // Only ordinary holes need the additional depth cue.
    if(!istype(src, /turf/open/openspace/ocean_column) && ocean_water_vertical_shaft_exposed(src))
        if(!locate(/obj/effect/ocean_water_shaft) in src)
            new /obj/effect/ocean_water_shaft(src)

/turf/open/openspace/ocean_column
    name = "open ocean"
    desc = "An open column of deep water. You can swim upwards or downwards."
    planetary_atmos = TRUE
    initial_gas_mix = OSHAN_DEFAULT_ATMOS
    baseturfs = /turf/open/openspace/ocean_column

    /// One shared visual per multiz rendering offset, not one atom per tile.
    var/static/list/column_visuals_by_offset = list()
    var/static/list/water_reagents = list(/datum/reagent/water = 10)

    // Real reagent volume injected into a dry compartment per open side edge,
    // per ocean processing interval (~2.5 seconds at default subsystem timing).
    // Tune this for gameplay; it is not a physical liters/second measure.
    var/static/list/breach_ingress_reagents = list(/datum/reagent/water = 450)

    // Stop adding water once the adjacent liquid group's average depth is at
    // full-tile saturation (the default liquid threshold is ~390 units/tile).
    // Leave some headroom for liquid redistribution before the next subsystem pass.
    var/static/breach_saturation_limit = 440

    /// Shared with Oshan seabed movement, so we do not allocate a sound list per step.
    var/static/list/swimming_sounds = list(
        'sound/effects/water_wade1.ogg',
        'sound/effects/water_wade2.ogg',
        'sound/effects/water_wade3.ogg',
        'sound/effects/water_wade4.ogg'
    )

    /// Cardinal directions with a reachable, non-ocean, non-open-space floor.
    var/list/open_turfs = list()

    // Watch just the boundary tiles, not the whole ocean each tick. When a hull
    // wall is replaced by an open turf (or vice versa), update the inlet list.
    var/list/watched_boundary_turfs = list()

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

    // Ocean columns are an infinite reservoir, not members of the finite indoor
    // liquid groups. Prevent room water from flowing back into these turfs.
    ADD_TRAIT(src, TRAIT_BLOCK_LIQUID_SPREAD, "ocean_water_column")

    if(!atmos_adjacent_turfs)
        immediate_calculate_adjacent_turfs()
    RegisterSignal(src, COMSIG_TURF_CALCULATED_ADJACENT_ATMOS, PROC_REF(rebuild_adjacent))
    rebuild_adjacent()

/turf/open/openspace/ocean_column/Destroy()
    UnregisterSignal(src, COMSIG_TURF_CALCULATED_ADJACENT_ATMOS)
    for(var/turf/boundary as anything in watched_boundary_turfs)
        UnregisterSignal(boundary, COMSIG_TURF_CHANGE)
    watched_boundary_turfs.Cut()
    SSliquids.active_ocean_columns -= src
    REMOVE_TRAIT(src, TRAIT_BLOCK_LIQUID_SPREAD, "ocean_water_column")
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
    // These are at most four neighboring turfs. No full Z-level scan.
    for(var/turf/boundary as anything in watched_boundary_turfs)
        UnregisterSignal(boundary, COMSIG_TURF_CHANGE)
    watched_boundary_turfs.Cut()
    open_turfs.len = 0

    for(var/direction in GLOB.cardinals)
        var/turf/adjacent = get_step(src, direction)
        if(!adjacent)
            continue

        // Look for *changes* to hull walls/floors. Flooding starts when the
        // wall is turned into an actual passable floor; no custom map marker.
        if(!is_swimmable_ocean_turf(adjacent) && !isopenspaceturf(adjacent))
            watched_boundary_turfs += adjacent
            RegisterSignal(adjacent, COMSIG_TURF_CHANGE, PROC_REF(on_boundary_changed))

        if(!isopenturf(adjacent) || isopenspaceturf(adjacent) || is_swimmable_ocean_turf(adjacent))
            continue
        if(!TURFS_CAN_SHARE(src, adjacent))
            continue
        open_turfs += direction

    // Stage B2 handles interior compartments using bounded abstract WU.
    // Do not run the older turf-liquid ingress into these same rooms: that
    // would create two independent water simulations for a single breach.
    var/list/legacy_open_edges = list()
    for(var/direction in open_turfs)
        var/turf/adjacent = get_step(src, direction)
        var/datum/ocean_water_registered_compartment/room = GLOB.ocean_water_compartment_registry.turf_to_compartment[adjacent]
        if(room)
            // Room source count is computed at registration or geometry invalidation.
            // Avoid O(room size) rescans for every adjacent ocean column.
            continue
        else
            legacy_open_edges += direction
    open_turfs = legacy_open_edges
    if(length(open_turfs))
        // Stage C3: discovery is asynchronous and bounded; never scan in LateInitialize.
        GLOB.ocean_water_compartment_registry?.enqueue_exterior_neighbors(src)
        SSliquids.active_ocean_columns |= src
    else
        SSliquids.active_ocean_columns -= src

/// Turf replacements preserve their references; a callback after replacement
/// gives us the correct new geometry and recalculates the cached atmos edge.
/turf/open/openspace/ocean_column/proc/on_boundary_changed(turf/changed, path, list/new_baseturfs, flags, list/post_change_callbacks)
    SIGNAL_HANDLER
    post_change_callbacks += CALLBACK(src, PROC_REF(refresh_after_boundary_change))

/turf/open/openspace/ocean_column/proc/refresh_after_boundary_change(turf/new_boundary)
    if(QDELETED(src))
        return
    // This also emits COMSIG_TURF_CALCULATED_ADJACENT_ATMOS, which runs
    // rebuild_adjacent(). No timer, map-wide scan or perpetual retry needed.
    immediate_calculate_adjacent_turfs()
    // Actual geometry edits may discover a newly exposed room. Do not do
    // this inside rebuild_adjacent(), which runs repeatedly during map init.
    if(isopenturf(new_boundary) && !isgroundlessturf(new_boundary) && !is_swimmable_ocean_turf(new_boundary))
        ocean_water_register_exposed_boundary(new_boundary)

/// Called only for ocean columns that currently border a passable opening.
/turf/open/openspace/ocean_column/proc/process_turf()
    for(var/direction in open_turfs)
        var/turf/adjacent = get_step(src, direction)
        if(!isopenturf(adjacent) || isopenspaceturf(adjacent) || is_swimmable_ocean_turf(adjacent) || !TURFS_CAN_SHARE(src, adjacent))
            open_turfs -= direction
            continue

        // New room footprints are owned by Stage B2; don't also inject legacy liquids.
        var/datum/ocean_water_registered_compartment/room = GLOB.ocean_water_compartment_registry.turf_to_compartment[adjacent]
        if(room)
            open_turfs -= direction
            continue
        // Discovery queue owns these floors; do not inject native liquid yet.
        var/datum/ocean_water_compartment_registry/registry = GLOB.ocean_water_compartment_registry
        if(registry.auto_seed_lookup[adjacent] || registry.auto_job?.visited[adjacent])
            continue

        // Infinite ocean source -> finite interior liquid group. The liquid
        // group itself handles spread, room size, visual water height and doors.
        if(adjacent.liquids?.liquid_group?.reagents_per_turf >= breach_saturation_limit)
            continue
        adjacent.add_liquid_list(breach_ingress_reagents, FALSE, T20C)

    if(!length(open_turfs))
        SSliquids.active_ocean_columns -= src


// C4.3: four depth layers inspired by Barotrauma's DrawWaterParticles.
// Rather than putting sharp dots on the full screen, each BYOND particle
// renders a *small texture with multiple soft motes*. Independent near/far
// scaling and velocities suggest parallax with no screen-space starfield.
// Two dim layers occupy visible underwater turfs. Two brighter layers only
// occupy turfs illuminated by MONKESTATION'S NATIVE lighting. They do not
// create their own lights, do raycasting, or override walls.
// C4.5: Barotrauma-style seamless marine snow. These are *texture plates* rather
// than individually spawned particles. No turf scan or server-side particle
// movement per frame. A single plate is a 512x512 tileable texture enlarged
// to 1024 pixels and scrolled exactly one repeat period by BYOND animation.
// The FOV-hidden world plane uses MonkeStation's own sight blocker, instead
// of drawing star-shaped pixels on the HUD. Lighting-sensitive close motes
// remain in the native-light world emitter system below.
/atom/movable/screen/ocean_parallax_plate
    name = "underwater distant sediment"
    icon = 'icons/obj/effects/ocean_parallax.dmi'
    icon_state = "far"
    // Anchor INSIDE the viewport, even on 15x15 clients. The 512px atlas
    // is scaled about its own center and shifted into place via transform.
    // TILE_BOUND prevents oversized screen icons expanding/clipping the map.
    screen_loc = "CENTER,CENTER"
    plane = GAME_PLANE_FOV_HIDDEN
    layer = BELOW_MOB_LAYER
    alpha = 95
    mouse_opacity = MOUSE_OPACITY_TRANSPARENT
    appearance_flags = KEEP_TOGETHER | TILE_BOUND

/atom/movable/screen/ocean_parallax_plate/middle
    icon_state = "middle"
    alpha = 95
    layer = BELOW_MOB_LAYER + 0.01

/atom/movable/screen/ocean_parallax_plate/near
    icon_state = "near"
    alpha = 80
    layer = BELOW_MOB_LAYER + 0.02

/atom/movable/screen/ocean_parallax_plate/fine
    icon_state = "fine"
    alpha = 75
    layer = BELOW_MOB_LAYER + 0.03

/atom/movable/screen/fullscreen/color_vision/ocean_immersion_haze
    color = "#166B87"
    alpha = 18
    mouse_opacity = MOUSE_OPACITY_TRANSPARENT

// Stage C4.4: four independently moving SINGLE-MOTE depths, inspired by
// Barotrauma's four independently scaled/scrolled background texture passes.
// Do not spawn 32x32 multi-mote SHEETS: their bright edges were exposed by
// flashlight movement and they looked like rectangular patches of stars.
// Native BYOND particles are already animated client-side after creation.
/particles/ocean_marine_snow
    icon = 'icons/obj/effects/ocean_atmosphere.dmi'
    icon_state = "far_silt"
    width = 32
    height = 32
    count = 5
    spawning = 0.43
    lifespan = 7 SECONDS
    fade = 2.8 SECONDS
    color = "#80A6B879"
    position = generator(GEN_BOX, list(-12,-12,0), list(12,12,0), NORMAL_RAND)
    velocity = generator(GEN_VECTOR, list(-0.025,-0.025,0), list(0.04,0.028,0), NORMAL_RAND)
    scale = generator(GEN_VECTOR, list(0.44,0.44), list(0.75,0.75), NORMAL_RAND)

/particles/ocean_marine_snow/middle
    icon_state = "mid_silt"
    count = 5
    spawning = 0.58
    lifespan = 6 SECONDS
    fade = 2.4 SECONDS
    color = "#92B6C38B"
    velocity = generator(GEN_VECTOR, list(-0.045,-0.025,0), list(0.055,0.045,0), NORMAL_RAND)
    scale = generator(GEN_VECTOR, list(0.65,0.65), list(1.0,1.0), NORMAL_RAND)

// Lit motes only appear on visibly accessible turfs that native lighting
// actually brightens. We do not create any artificial rays or light sources.
/particles/ocean_marine_snow/illuminated
    icon_state = "lit_silt"
    count = 4
    spawning = 0.72
    lifespan = 4.7 SECONDS
    fade = 1.8 SECONDS
    color = "#B3D6DDAA"
    velocity = generator(GEN_VECTOR, list(-0.065,-0.04,0), list(0.07,0.06,0), NORMAL_RAND)
    scale = generator(GEN_VECTOR, list(0.78,0.78), list(1.15,1.15), NORMAL_RAND)

/particles/ocean_marine_snow/illuminated/foreground
    icon_state = "near_silt"
    count = 3
    spawning = 0.44
    lifespan = 4 SECONDS
    fade = 1.7 SECONDS
    color = "#C6E7E9A8"
    velocity = generator(GEN_VECTOR, list(-0.09,-0.04,0), list(0.12,0.08,0), NORMAL_RAND)
    scale = generator(GEN_VECTOR, list(0.9,0.9), list(1.4,1.4), NORMAL_RAND)

// Native-light and visibility-bound world-space emitters. These DO NOT
// inherit the diver's transform and they are only on visible, wet tiles.
/obj/effect/ocean_marine_snow_tile
    name = "suspended underwater particles"
    icon = null
    density = FALSE
    anchored = TRUE
    mouse_opacity = MOUSE_OPACITY_TRANSPARENT
    plane = GAME_PLANE
    layer = BELOW_MOB_LAYER

/obj/effect/ocean_marine_snow_tile/Initialize(mapload)
    . = ..()
    particles = new /particles/ocean_marine_snow

/obj/effect/ocean_marine_snow_tile/middle
    layer = BELOW_MOB_LAYER + 0.01

/obj/effect/ocean_marine_snow_tile/middle/Initialize(mapload)
    . = ..()
    particles = new /particles/ocean_marine_snow/middle

/obj/effect/ocean_marine_snow_tile/illuminated
    layer = BELOW_MOB_LAYER + 0.02

/obj/effect/ocean_marine_snow_tile/illuminated/Initialize(mapload)
    . = ..()
    particles = new /particles/ocean_marine_snow/illuminated

/obj/effect/ocean_marine_snow_tile/illuminated/foreground
    layer = ABOVE_MOB_LAYER

/obj/effect/ocean_marine_snow_tile/illuminated/foreground/Initialize(mapload)
    . = ..()
    particles = new /particles/ocean_marine_snow/illuminated/foreground

// A stationary, turf-anchored bubble emitter never inherits a character's
// falling/rotation transform or colour; one puff is emitted per pulse and never follows the mob.
/obj/effect/ocean_breathing_bubbles
    icon = null
    density = FALSE
    anchored = TRUE
    mouse_opacity = MOUSE_OPACITY_TRANSPARENT
    plane = GAME_PLANE
    layer = ABOVE_MOB_LAYER

/obj/effect/ocean_breathing_bubbles/Initialize(mapload)
    . = ..()
    // The vanilla Oshan seabed applies its water vis overlay on AREA_PLANE.
    // Put seabed-only bubbles just above it so they remain visible; preserve
    // the original GAME_PLANE treatment throughout ocean columns and rooms.
    if(isoceanturf(get_turf(src)))
        SET_PLANE_EXPLICIT(src, AREA_PLANE, loc)
        layer = ABOVE_MOB_LAYER + 0.1
    particles = new /particles/ocean_swimming_bubbles

// A short burst remains in world space behind the moving swimmer.
/obj/effect/ocean_swim_wake
    icon = null
    density = FALSE
    anchored = TRUE
    mouse_opacity = MOUSE_OPACITY_TRANSPARENT
    plane = GAME_PLANE
    layer = ABOVE_MOB_LAYER

/obj/effect/ocean_swim_wake/Initialize(mapload)
    . = ..()
    if(isoceanturf(get_turf(src)))
        SET_PLANE_EXPLICIT(src, AREA_PLANE, loc)
        layer = ABOVE_MOB_LAYER + 0.11
    particles = new /particles/ocean_swimming_trail

/obj/effect/ocean_swim_wake/proc/set_trailing_direction(direction)
    if(!particles)
        return
    // A one-time world-space burst starts BEHIND the swimmer and drifts
    // directly opposite movement, jetpack-style, not up through the torso.
    var/back_x = 0
    var/back_y = 0
    if(direction & EAST)
        back_x = -13
    else if(direction & WEST)
        back_x = 13
    if(direction & NORTH)
        back_y = -13
    else if(direction & SOUTH)
        back_y = 13
    particles.position = generator(GEN_BOX, list(back_x-3,back_y-3,0), list(back_x+3,back_y+3,0), NORMAL_RAND)
    particles.velocity = generator(GEN_VECTOR, list(back_x*0.05-0.08,back_y*0.05+0.04,0), list(back_x*0.05+0.08,back_y*0.05+0.18,0), NORMAL_RAND)

/particles/ocean_sediment
    icon = 'icons/effects/particles/generic.dmi'
    icon_state = "dot"
    width = 32
    height = 32
    count = 22
    spawning = 2
    lifespan = 1.2 SECONDS
    fade = 0.7 SECONDS
    color = "#7C91949C"
    position = generator(GEN_BOX, list(-12,-12,0), list(12,8,0), NORMAL_RAND)
    velocity = generator(GEN_VECTOR, list(-0.15,-0.04,0), list(0.15,0.06,0), NORMAL_RAND)
    scale = generator(GEN_VECTOR, list(0.18,0.18), list(0.65,0.65), NORMAL_RAND)

// Flow-following trail: much lower density than ordinary breathing bubbles,
// enabled only when an alive swimmer moves. Separate emitter permits instant
// stop on death without delaying the underwater state transition.
/particles/ocean_swimming_trail
    icon = 'goon/icons/effects/particles.dmi'
    icon_state = "bubble"
    width = 32
    height = 48
    count = 5
    spawning = 1.7
    lifespan = 1.55 SECONDS
    fade = 0.7 SECONDS
    color = "#B5EAF3AA"
    position = generator(GEN_BOX, list(-12,-12,0), list(12,12,0), NORMAL_RAND)
    velocity = generator(GEN_VECTOR, list(-0.2,-0.15,0), list(0.2,0.22,0), NORMAL_RAND)
    scale = generator(GEN_VECTOR, list(0.25,0.25), list(0.43,0.43), NORMAL_RAND)

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
    var/next_ocean_sound_check_ds = 0
    var/ocean_sound_recoveries = 0
    /// Slowdown is only active while submerged, never on a dry transition hole.
    var/swimming_slowdown_active = FALSE
    /// Ordinary walking footsteps should never be heard while suspended in water.
    var/swimming_footsteps_muted = FALSE
    var/next_swim_sound_at = 0
    var/atom/movable/screen/fullscreen/color_vision/ocean_immersion_haze/ocean_haze
    var/client/ocean_visual_client
    /// Four client-only tiled depth layers, with no individual mote timers.
    var/list/atom/movable/screen/ocean_parallax_plate/ocean_parallax_plates = list()
    var/atom/movable/plane_master_controller/ocean_refraction_controller
    var/ocean_refraction_enabled = TRUE
    /// Independent A/B switch so refraction and atlas clipping can be isolated.
    var/ocean_parallax_enabled = TRUE
    var/next_parallax_environment_check_at = 0
    /// Avoid dropping four plates on a one-tile obstruction threshold.
    var/parallax_obstructed_checks = 0
    /// Explicitly track Z so old plane-master/screen attachments cannot linger.
    var/last_underwater_visual_z = 0
    /// Avoid recreating screen objects while a cross-Z movement signal runs.
    var/z_transition_refresh_pending = FALSE
    /// Local, world-space motes; no screen-space dots and no mob transforms.
    var/list/obj/effect/ocean_marine_snow_tile/ocean_motes = list()
    var/list/obj/effect/ocean_marine_snow_tile/illuminated/ocean_lit_motes = list()
    /// Last real native-light observation for each claimed lit emitter.
    var/list/ocean_lit_last_seen = list()
    var/next_mote_refresh_at = 0
    var/next_swim_trail_at = 0
    var/list/obj/effect/ocean_swim_wake/ocean_wakes = list()
    // Each puff is born in world space. Never move an existing emitter with
    // the swimmer; doing so dragged live particles/appearances across tiles.
    var/list/obj/effect/ocean_breathing_bubbles/ocean_breath_puffs = list()
    var/next_breath_puff_at = 0
    var/next_sediment_at = 0
    var/last_swim_move_at = 0

/datum/status_effect/ocean_swimming/on_apply()
    if(!ocean_water_is_swimmable_environment(get_turf(owner)))
        return FALSE
    ADD_TRAIT(owner, TRAIT_MOVE_FLOATING, "ocean_swimming")
    RegisterSignal(owner, COMSIG_MOVABLE_MOVED, PROC_REF(check_swimming_location))
    RegisterSignal(owner, COMSIG_MOVABLE_Z_CHANGED, PROC_REF(on_swimmer_z_changed))
    RegisterSignal(owner, COMSIG_LIVING_Z_IMPACT, PROC_REF(prevent_underwater_impact))
    RegisterSignal(owner, COMSIG_LIVING_DEATH, PROC_REF(on_ocean_swimmer_death))
    // Use the standard breathing hook instead of redefining a core carbon proc.
    // This permits oxygen internals while preventing ambient ocean gas inhalation.
    if(iscarbon(owner))
        RegisterSignal(owner, COMSIG_CARBON_ATTEMPT_BREATHE, PROC_REF(prevent_ocean_breathing))
    // FLOATING applies in both water and ocean-facing transition holes. All
    // underwater-only effects are separately controlled by actual immersion.
    refresh_ocean_immersion()
    return TRUE

/datum/status_effect/ocean_swimming/proc/check_swimming_location(datum/source, atom/old_loc, direction, forced)
    SIGNAL_HANDLER
    if(!ocean_water_is_swimmable_environment(get_turf(owner)))
        qdel(src)
        return
    if(!forced)
        last_swim_move_at = world.time
        var/turf/current_swim_turf = get_turf(owner)
        if(owner.stat != DEAD && current_swim_turf && is_submerged_ocean_turf(current_swim_turf) && world.time >= next_swim_trail_at)
            next_swim_trail_at = world.time + 5
            // Spawn on the destination tile, behind the character in pixel
            // space. This also works for actual seabed turfs.
            var/obj/effect/ocean_swim_wake/trail = new(current_swim_turf)
            trail.set_trailing_direction(direction)
            // Track outstanding bursts so death and leaving the water stop
            // ALL swimmer-generated bubbles, even mid-trail.
            for(var/obj/effect/ocean_swim_wake/old_wake as anything in ocean_wakes.Copy())
                if(QDELETED(old_wake))
                    ocean_wakes -= old_wake
            ocean_wakes += trail
            QDEL_IN(trail, 2 SECONDS)
    refresh_ocean_immersion()
    // Light seabed disturbance; never one object per tile or per movement.
    var/turf/current_turf = get_turf(owner)
    if(!forced && owner.stat != DEAD && isoceanturf(current_turf) && world.time >= next_sediment_at)
        next_sediment_at = world.time + 25
        var/obj/effect/abstract/particle_holder/cloud = new(current_turf, /particles/ocean_sediment)
        QDEL_IN(cloud, 2 SECONDS)
    // Swim audio is distinct from metal footsteps, and rate limited.
    // Ocean columns already have their own wading sounds.
    if(owner.stat == DEAD || forced || !is_submerged_ocean_turf(current_turf) || is_swimmable_ocean_turf(current_turf))
        return
    if(world.time >= next_swim_sound_at && prob(35))
        next_swim_sound_at = world.time + 5
        playsound(current_turf, pick('sound/effects/water_wade1.ogg', 'sound/effects/water_wade2.ogg', 'sound/effects/water_wade3.ogg', 'sound/effects/water_wade4.ogg'), 22, TRUE, 0, falloff_distance = 1)

/// Multi-Z travel does not have to emit the same movement signal as horizontal
/// walking. Remove old-Z screen attachments immediately, then allow HUD and
/// plane-master state one tick to settle before rebuilding for the new Z.
/datum/status_effect/ocean_swimming/proc/on_swimmer_z_changed(datum/source, turf/old_turf, turf/new_turf)
    SIGNAL_HANDLER
    if(is_submerged_ocean_turf(old_turf) && is_submerged_ocean_turf(new_turf))
        // Keep screen/plane effects continuous while dropping old-world motes.
        for(var/obj/effect/ocean_marine_snow_tile/p as anything in ocean_motes)
            ocean_water_release_shared_mote(p)
        ocean_motes.Cut()
        for(var/obj/effect/ocean_marine_snow_tile/illuminated/p as anything in ocean_lit_motes)
            ocean_water_release_shared_mote(p)
        ocean_lit_motes.Cut()
        ocean_lit_last_seen.Cut()
        last_underwater_visual_z = new_turf.z
        next_mote_refresh_at = 0
        next_parallax_environment_check_at = 0
    else
        stop_ocean_visuals()
        last_underwater_visual_z = 0
        next_mote_refresh_at = 0
    z_transition_refresh_pending = TRUE
    addtimer(CALLBACK(src, PROC_REF(complete_underwater_z_transition)), 1)

/datum/status_effect/ocean_swimming/proc/complete_underwater_z_transition()
    if(QDELETED(src) || QDELETED(owner))
        return
    z_transition_refresh_pending = FALSE
    refresh_ocean_immersion()

/datum/status_effect/ocean_swimming/proc/on_ocean_swimmer_death(datum/source)
    SIGNAL_HANDLER
    // The body remains in water but can no longer breathe or swim actively.
    for(var/obj/effect/ocean_breathing_bubbles/breath_puff as anything in ocean_breath_puffs)
        if(!QDELETED(breath_puff))
            qdel(breath_puff)
    ocean_breath_puffs.Cut()
    for(var/obj/effect/ocean_swim_wake/trail as anything in ocean_wakes)
        qdel(trail)
    ocean_wakes.Cut()
    if(particle_effect)
        QDEL_NULL(particle_effect)
    stop_ocean_sound()
    stop_ocean_visuals()

/datum/status_effect/ocean_swimming/tick()
    if(!ocean_water_is_swimmable_environment(get_turf(owner)))
        qdel(src)
        return
    // Also handles a client logging in, disconnecting, or switching bodies.
    refresh_ocean_immersion()

/// Maintain the ability to dive back down through a hole without pretending
/// the opening is flooded. This does not touch the permanent FLOATING trait.
/datum/status_effect/ocean_swimming/proc/refresh_ocean_immersion()
    var/is_submerged = is_submerged_ocean_turf(get_turf(owner))
    if(is_submerged && !swimming_footsteps_muted)
        ADD_TRAIT(owner, TRAIT_SILENT_FOOTSTEPS, "ocean_swimming")
        swimming_footsteps_muted = TRUE
    else if(!is_submerged && swimming_footsteps_muted)
        REMOVE_TRAIT(owner, TRAIT_SILENT_FOOTSTEPS, "ocean_swimming")
        swimming_footsteps_muted = FALSE
    if(is_submerged)
        if(!z_transition_refresh_pending)
            update_ocean_visuals()
        if(!swimming_slowdown_active)
            owner.add_movespeed_modifier(/datum/movespeed_modifier/ocean_swimming)
            swimming_slowdown_active = TRUE
        if(owner.stat != DEAD)
            var/turf/at = get_turf(owner)
            if(at && world.time >= next_breath_puff_at)
                next_breath_puff_at = world.time + 18
                // The bubbles belong to this turf after spawning, even if
                // the swimmer moves/rotates/drops to another Z level.
                var/obj/effect/ocean_breathing_bubbles/puff = new(at)
                ocean_breath_puffs += puff
                QDEL_IN(puff, 2 SECONDS)
                for(var/obj/effect/ocean_breathing_bubbles/old_puff as anything in ocean_breath_puffs.Copy())
                    if(QDELETED(old_puff))
                        ocean_breath_puffs -= old_puff
            update_ocean_sound()
        else
            for(var/obj/effect/ocean_breathing_bubbles/breath_puff as anything in ocean_breath_puffs)
                if(!QDELETED(breath_puff))
                    qdel(breath_puff)
            ocean_breath_puffs.Cut()
            stop_ocean_sound()
        return

    // Dry transition opening: no bubble particles, drone, or swimming slowdown.
    stop_ocean_visuals()
    for(var/obj/effect/ocean_breathing_bubbles/breath_puff as anything in ocean_breath_puffs)
        if(!QDELETED(breath_puff))
            qdel(breath_puff)
    ocean_breath_puffs.Cut()
    for(var/obj/effect/ocean_swim_wake/trail as anything in ocean_wakes)
        qdel(trail)
    ocean_wakes.Cut()
    if(particle_effect)
        QDEL_NULL(particle_effect)
    if(swimming_slowdown_active)
        owner.remove_movespeed_modifier(/datum/movespeed_modifier/ocean_swimming)
        swimming_slowdown_active = FALSE
    stop_ocean_sound()

// A single ambient/lit texture-sheet per turf and depth variant, shared by
// all nearby submerged viewers. Each swimming status effect holds one claim;
// the last claim releases it. Prevents brightness stacking with many divers.
GLOBAL_LIST_EMPTY(ocean_water_shared_motes)
GLOBAL_LIST_EMPTY(ocean_water_shared_mote_claims)

/obj/effect/ocean_marine_snow_tile
    var/ocean_shared_cache_key
    var/ocean_shared_variant = 0

/proc/ocean_water_acquire_shared_mote(turf/spot, variant)
    if(!spot)
        return null
    var/cache_key = "[REF(spot)]:[variant]"
    var/obj/effect/ocean_marine_snow_tile/emitter = GLOB.ocean_water_shared_motes[cache_key]
    if(QDELETED(emitter))
        GLOB.ocean_water_shared_motes -= cache_key
        GLOB.ocean_water_shared_mote_claims -= cache_key
        emitter = null
    if(!emitter)
        switch(variant)
            if(2)
                emitter = new /obj/effect/ocean_marine_snow_tile/middle(spot)
            if(3)
                emitter = new /obj/effect/ocean_marine_snow_tile/illuminated(spot)
            if(4)
                emitter = new /obj/effect/ocean_marine_snow_tile/illuminated/foreground(spot)
            else
                emitter = new /obj/effect/ocean_marine_snow_tile(spot)
        emitter.ocean_shared_cache_key = cache_key
        emitter.ocean_shared_variant = variant
        GLOB.ocean_water_shared_motes[cache_key] = emitter
    GLOB.ocean_water_shared_mote_claims[cache_key] = (GLOB.ocean_water_shared_mote_claims[cache_key] || 0) + 1
    return emitter

/proc/ocean_water_release_shared_mote(obj/effect/ocean_marine_snow_tile/emitter)
    if(!emitter)
        return
    var/key = emitter.ocean_shared_cache_key
    if(!key)
        if(!QDELETED(emitter))
            qdel(emitter)
        return
    var/remaining = (GLOB.ocean_water_shared_mote_claims[key] || 0) - 1
    if(remaining > 0)
        GLOB.ocean_water_shared_mote_claims[key] = remaining
        return
    GLOB.ocean_water_shared_mote_claims -= key
    GLOB.ocean_water_shared_motes -= key
    if(!QDELETED(emitter))
        qdel(emitter)

/// Read native lighting corner luminance. This is not a second light engine.
/// The corners are maintained by SSlighting and already account for the
/// station's normal light sources and blockers.
/proc/ocean_water_native_light_strength(turf/open/check_turf)
    if(!check_turf)
        return 0
    // Static corner light and movable flashlight/overlay light have different
    // native representations. Requiring BOTH lighting_object and luminosity
    // discarded legitimate dynamic flashlight light, making lit motes pop.
    var/brightness = max(0, check_turf.dynamic_lumcount)
    if(check_turf.lighting_corner_NE)
        brightness = max(brightness, check_turf.lighting_corner_NE.largest_color_luminosity)
    if(check_turf.lighting_corner_NW)
        brightness = max(brightness, check_turf.lighting_corner_NW.largest_color_luminosity)
    if(check_turf.lighting_corner_SE)
        brightness = max(brightness, check_turf.lighting_corner_SE.largest_color_luminosity)
    if(check_turf.lighting_corner_SW)
        brightness = max(brightness, check_turf.lighting_corner_SW.largest_color_luminosity)
    return brightness

/// Barotrauma uses four independently scrolling water particle TEXTURE layers.
/// BYOND doesn't expose their MonoGame renderer, so use four small textured
/// particle classes distributed on at most 24 visible, underwater turfs.
/// Background flecks are dim; brighter sheets use cached native light levels.
/// A stable deterministic density pattern avoids random reallocation and
/// eliminates camera-relative HUD dots that rendered through walls.
/datum/status_effect/ocean_swimming/proc/update_ocean_visuals()
    var/client/current_client = owner?.client
    var/turf/current_turf = get_turf(owner)
    // Defensive fallback for teleports or custom Z transitions which might
    // not pass through the usual movement callback ordering.
    if(last_underwater_visual_z && last_underwater_visual_z != current_turf?.z)
        next_parallax_environment_check_at = 0
        next_mote_refresh_at = 0
    last_underwater_visual_z = current_turf?.z
    if(ocean_visual_client && ocean_visual_client != current_client)
        stop_ocean_visuals()
    if(!current_client || owner.stat == DEAD)
        stop_ocean_visuals()
        return
    if(!ocean_visual_client)
        ocean_haze = owner.overlay_fullscreen("ocean_immersion_haze", /atom/movable/screen/fullscreen/color_vision/ocean_immersion_haze)
        ocean_visual_client = current_client
    // D1: smooth depth palette; keep the same screen object across submerged Zs.
    if(ocean_haze)
        var/depth = ocean_water_depth_meters(current_turf)
        ocean_haze.alpha = clamp(round(16 + depth * 0.32), 16, 76)
        ocean_haze.color = rgb(clamp(round(22 - depth * 0.12), 4, 22), clamp(round(107 - depth * 0.49), 21, 107), clamp(round(135 - depth * 0.37), 40, 135))
    update_ocean_refraction()
    update_ocean_parallax()
    if(world.time < next_mote_refresh_at)
        return
    next_mote_refresh_at = world.time + 5

    // Use native LOS *and* native lighting. Never draw a huge screen-space
    // starfield through walls. Actual BYOND particles are animated client-side.
    var/list/obj/effect/ocean_marine_snow_tile/new_ambient = list()
    var/list/obj/effect/ocean_marine_snow_tile/illuminated/new_lit = list()
    var/ambient_budget = 24
    var/lit_budget = 20
    var/list/visible_wet_turfs = list()
    for(var/turf/open/spot in view(7, owner))
        if(spot.z != owner.z || !is_submerged_ocean_turf(spot))
            continue
        visible_wet_turfs[spot] = TRUE
        // Deterministic sparse placement keeps emitters stable while moving
        // and avoids regular grid patterns. Each emitter now emits ONE soft mote
        // at a time, not a rectangular sheet of pre-rendered bright flecks.
        var/hashed = (spot.x * 31 + spot.y * 17 + spot.z * 13) % 11
        if(length(new_ambient) < ambient_budget && hashed < 7)
            var/ambient_variant = hashed < 3 ? 1 : 2
            var/obj/effect/ocean_marine_snow_tile/kept = null
            for(var/obj/effect/ocean_marine_snow_tile/previous as anything in ocean_motes)
                if(previous.loc == spot && previous.ocean_shared_variant == ambient_variant && !QDELETED(previous))
                    kept = previous
                    break
            if(!kept)
                kept = ocean_water_acquire_shared_mote(spot, ambient_variant)
            if(kept)
                new_ambient += kept
        if(length(new_lit) < lit_budget && ocean_water_native_light_strength(spot) > 0.10)
            var/lit_variant = hashed % 4 == 0 ? 4 : 3
            var/obj/effect/ocean_marine_snow_tile/illuminated/kept_lit = null
            for(var/obj/effect/ocean_marine_snow_tile/illuminated/previous_lit as anything in ocean_lit_motes)
                if(previous_lit.loc == spot && previous_lit.ocean_shared_variant == lit_variant && !QDELETED(previous_lit))
                    kept_lit = previous_lit
                    break
            if(!kept_lit)
                kept_lit = ocean_water_acquire_shared_mote(spot, lit_variant)
            if(kept_lit)
                new_lit += kept_lit
                ocean_lit_last_seen[kept_lit] = world.time

    // Corner lighting on movable flashlights may briefly lag an animation
    // frame. Preserve existing emitters for 1.5 s only while their turf is
    // still visible and submerged. No through-wall or stale-Z ghost specks.
    for(var/obj/effect/ocean_marine_snow_tile/illuminated/existing as anything in ocean_lit_motes)
        if(existing in new_lit || QDELETED(existing))
            continue
        if(length(new_lit) >= lit_budget)
            break
        if(visible_wet_turfs[existing.loc] && world.time - (ocean_lit_last_seen[existing] || 0) <= 15)
            new_lit += existing

    for(var/obj/effect/ocean_marine_snow_tile/old as anything in ocean_motes)
        if(!(old in new_ambient))
            ocean_water_release_shared_mote(old)
    ocean_motes = new_ambient
    for(var/obj/effect/ocean_marine_snow_tile/illuminated/old_lit as anything in ocean_lit_motes)
        if(!(old_lit in new_lit))
            ocean_lit_last_seen -= old_lit
            ocean_water_release_shared_mote(old_lit)
    ocean_lit_motes = new_lit

// One client-owned wave filter is intentionally applied on MonkeStation's
// existing *game* controller. The HUD and client interface are not distorted.
// A world distortion alternative (gravity pulse) already uses the same
// MonkeStation rendering pipeline. Do not attach filters to individual mobs.
/datum/status_effect/ocean_swimming/proc/update_ocean_refraction()
    var/atom/movable/plane_master_controller/controller = owner?.hud_used?.plane_master_controllers[PLANE_MASTERS_GAME]
    if(!ocean_refraction_enabled || !owner?.client || !controller)
        stop_ocean_refraction()
        return
    if(ocean_refraction_controller && ocean_refraction_controller != controller)
        stop_ocean_refraction()
    if(controller.get_filter("ocean_soft_refraction"))
        ocean_refraction_controller = controller
        return
    // A slightly more discernible but still <= 1px world-space ripple.
    // The previous 0.45px amplitude was often visually indistinguishable.
    controller.add_filter("ocean_soft_refraction", 8, wave_filter(110, 90, 1.25, 0, WAVE_SIDEWAYS))
    ocean_refraction_controller = controller
    var/dm_filter/refraction_filter = controller.get_filter("ocean_soft_refraction")
    if(refraction_filter)
        animate(refraction_filter, offset = 6.28318, time = 8 SECONDS, loop = -1, flags = ANIMATION_PARALLEL)
        animate(offset = 0, time = 0.1)

/datum/status_effect/ocean_swimming/proc/stop_ocean_refraction()
    if(ocean_refraction_controller)
        ocean_refraction_controller.remove_filter("ocean_soft_refraction")
        ocean_refraction_controller = null

// Background texture plates never attempt to light the world. Lit specks are
// owned by existing native-light sampling emitters, keeping lighting occlusion
// authoritative. Disable the plates in cramped interiors to prevent texture
// snow from bleeding into nearby dry rooms through the screen attachment.
/datum/status_effect/ocean_swimming/proc/update_ocean_parallax()
    var/client/C = owner?.client
    if(!C || !ocean_parallax_enabled)
        stop_ocean_parallax()
        return
    if(world.time < next_parallax_environment_check_at)
        return
    next_parallax_environment_check_at = world.time + 10
    var/turf/center = get_turf(owner)
    if(!center || !is_swimmable_ocean_turf(center))
        stop_ocean_parallax()
        return
    // Ocean-only parallax: enclosed flooded rooms instead use the light-aware
    // world motes, without global screen tiles reaching through nearby walls.
    var/nearby_obstructions = 0
    for(var/turf/T in range(3, center))
        if(T.z != center.z)
            continue
        if(T.opacity || isclosedturf(T))
            nearby_obstructions++
            if(nearby_obstructions >= 2)
                break
    // Hysteresis: a passing obstruction, flashlight turn or one-tile move
    // must not destroy/rebuild the four atlas plates on each environment poll.
    if(nearby_obstructions >= 2)
        parallax_obstructed_checks = min(parallax_obstructed_checks + 1, 3)
    else
        parallax_obstructed_checks = max(parallax_obstructed_checks - 1, 0)
    if(parallax_obstructed_checks >= 3)
        stop_ocean_parallax()
        return
    if(parallax_obstructed_checks > 0 && !length(ocean_parallax_plates))
        return
    if(length(ocean_parallax_plates))
        return
    var/list/types = list(/atom/movable/screen/ocean_parallax_plate, /atom/movable/screen/ocean_parallax_plate/middle, /atom/movable/screen/ocean_parallax_plate/near, /atom/movable/screen/ocean_parallax_plate/fine)
    var/list/durations = list(130 SECONDS, 92 SECONDS, 71 SECONDS, 48 SECONDS)
    var/i = 0
    for(var/plate_type in types)
        i++
        var/atom/movable/screen/ocean_parallax_plate/P = new plate_type(null)
        var/matrix/scaled = matrix()
        scaled.Scale(2)
        // Previously CENTER-8 placed the 512px icon's anchor outside many
        // normal views. Keep the SCREEN anchor centered and translate the
        // *appearance* by the equivalent eight tiles (256px) instead.
        // This retains the four-plate alignment without viewport expansion.
        scaled.Translate(-256, -256)
        P.transform = scaled
        // An exact one-tile scroll (128 source px * 2) loops seamlessly.
        // The atlas is seamless along both axes and its outer bounds fade.
        var/from_x = -18
        var/from_y = -18
        P.pixel_x = from_x
        P.pixel_y = from_y
        SET_PLANE_EXPLICIT(P, GAME_PLANE_FOV_HIDDEN, owner)
        C.screen += P
        ocean_parallax_plates += P
        animate(P, pixel_x = from_x + 256, pixel_y = from_y, time = durations[i], loop = -1, flags = ANIMATION_PARALLEL)
        animate(pixel_x = from_x, pixel_y = from_y, time = 0.1)

/datum/status_effect/ocean_swimming/proc/stop_ocean_parallax()
    for(var/atom/movable/screen/ocean_parallax_plate/P as anything in ocean_parallax_plates)
        if(ocean_visual_client)
            ocean_visual_client.screen -= P
        if(owner?.client && owner.client != ocean_visual_client)
            owner.client.screen -= P
        qdel(P)
    ocean_parallax_plates.Cut()

/datum/status_effect/ocean_swimming/proc/stop_ocean_visuals()
    for(var/obj/effect/ocean_marine_snow_tile/emitter as anything in ocean_motes)
        ocean_water_release_shared_mote(emitter)
    ocean_motes.Cut()
    for(var/obj/effect/ocean_marine_snow_tile/illuminated/emitter as anything in ocean_lit_motes)
        ocean_water_release_shared_mote(emitter)
    ocean_lit_motes.Cut()
    ocean_lit_last_seen.Cut()
    stop_ocean_parallax()
    stop_ocean_refraction()
    owner?.clear_fullscreen("ocean_immersion_haze", FALSE)
    ocean_haze = null
    ocean_visual_client = null

/// Stop only our dedicated loop; do not interfere with Oshan's other sounds.
/datum/status_effect/ocean_swimming/proc/stop_ocean_sound()
    if(ocean_sound_client)
        SEND_SOUND(ocean_sound_client, sound(null, repeat = FALSE, wait = FALSE, channel = CHANNEL_OCEAN_RUMBLE))
        ocean_sound_client = null
        ocean_sound_volume = 0
        next_ocean_sound_check_ds = 0

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
    // A cached volume cannot prove that BYOND's channel is still playing.
    if(ocean_sound_client == current_client && ocean_sound_volume == new_volume && world.time < next_ocean_sound_check_ds)
        return
    var/still_playing = FALSE
    if(new_volume > 0)
        for(var/sound/active as anything in current_client.SoundQuery())
            if(active.channel == CHANNEL_OCEAN_RUMBLE && active.repeat)
                still_playing = TRUE
                break
    next_ocean_sound_check_ds = world.time + 50
    if(ocean_sound_client == current_client && ocean_sound_volume == new_volume && still_playing)
        return
    if(ocean_sound_client == current_client && ocean_sound_volume > 0 && !still_playing && new_volume > 0)
        ocean_sound_recoveries++
    if(new_volume <= 0)
        SEND_SOUND(current_client, sound(null, repeat = FALSE, wait = FALSE, channel = CHANNEL_OCEAN_RUMBLE))
    else if(ocean_sound_client == current_client && ocean_sound_volume > 0 && still_playing)
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
    if(!is_submerged_ocean_turf(get_turf(source)))
        return NONE
    if((source.internal || source.external) && !source.invalid_internals())
        return NONE
    return BREATHE_SKIP_BREATH

/datum/status_effect/ocean_swimming/proc/prevent_underwater_impact(mob/living/source, levels, turf/landing_turf)
    SIGNAL_HANDLER
    if(ocean_water_is_swimmable_environment(landing_turf))
        return NO_Z_IMPACT_DAMAGE

/datum/status_effect/ocean_swimming/on_remove()
    for(var/obj/effect/ocean_breathing_bubbles/breath_puff as anything in ocean_breath_puffs)
        if(!QDELETED(breath_puff))
            qdel(breath_puff)
    ocean_breath_puffs.Cut()
    for(var/obj/effect/ocean_swim_wake/wake as anything in ocean_wakes)
        if(!QDELETED(wake))
            qdel(wake)
    ocean_wakes.Cut()
    stop_ocean_visuals()
    stop_ocean_sound()
    UnregisterSignal(owner, list(COMSIG_MOVABLE_MOVED, COMSIG_MOVABLE_Z_CHANGED, COMSIG_LIVING_Z_IMPACT, COMSIG_CARBON_ATTEMPT_BREATHE, COMSIG_LIVING_DEATH))
    REMOVE_TRAIT(owner, TRAIT_MOVE_FLOATING, "ocean_swimming")
    if(swimming_footsteps_muted)
        REMOVE_TRAIT(owner, TRAIT_SILENT_FOOTSTEPS, "ocean_swimming")
        swimming_footsteps_muted = FALSE
    if(swimming_slowdown_active)
        owner.remove_movespeed_modifier(/datum/movespeed_modifier/ocean_swimming)
        swimming_slowdown_active = FALSE
    // The base status effect Destroy() cleans up particle_effect automatically.
    return ..()

/datum/movespeed_modifier/ocean_swimming
    multiplicative_slowdown = 0.6

// Observe whether the expensive-looking visual effects are actually attached
// to this diver. This verb only inspects local metadata; no world scans.
ADMIN_VERB(ocean_water_rendering_inspect, R_DEBUG, FALSE, "Water: Inspect Underwater Rendering", "Inspect the local underwater visual emitters and native-light integration.", ADMIN_CATEGORY_DEBUG)
    if(!isliving(user.mob))
        to_chat(user, span_warning("Use this diagnostic while controlling a living diver."))
        return
    var/mob/living/swimmer = user.mob
    var/datum/status_effect/ocean_swimming/active = swimmer.has_status_effect(/datum/status_effect/ocean_swimming)
    if(!active)
        to_chat(user, span_notice("Underwater rendering inactive: no ocean swimming status effect."))
        return
    to_chat(user, span_notice("Underwater state: [is_submerged_ocean_turf(get_turf(swimmer)) ? "submerged" : "dry connector"]; world ambient cells [length(active.ocean_motes)], illuminated cells [length(active.ocean_lit_motes)], breathing puffs [length(active.ocean_breath_puffs)]."))
    to_chat(user, span_notice("Motes exist only on visible underwater world tiles. Lighting uses native turf illumination and wall occlusion; no additional lights or raycaster."))
    to_chat(user, span_notice("Shared underwater particle emitters: [length(GLOB.ocean_water_shared_motes)]. Each visible tile/variant is allocated once, regardless of nearby diver count."))
    var/turf/swimmer_turf = get_turf(swimmer)
    var/seabed_bubble_count = 0
    var/last_bubble_plane = 0
    for(var/obj/effect/ocean_breathing_bubbles/bubble as anything in active.ocean_breath_puffs)
        if(!QDELETED(bubble))
            if(isoceanturf(get_turf(bubble)))
                seabed_bubble_count++
            last_bubble_plane = bubble.plane
    to_chat(user, span_notice("Water C4.5.2: turf [swimmer_turf?.type], seabed [!!isoceanturf(swimmer_turf)], seabed bubble emitters [seabed_bubble_count], last bubble plane [last_bubble_plane], Z transition pending [active.z_transition_refresh_pending]."))
    to_chat(user, span_notice("C4.5.1: texture plates [length(active.ocean_parallax_plates)] (enabled [active.ocean_parallax_enabled], obstruction checks [active.parallax_obstructed_checks]), wave filter attached [!!active.ocean_refraction_controller?.get_filter("ocean_soft_refraction")] (enabled [active.ocean_refraction_enabled]), native lit cells [length(active.ocean_lit_motes)], visual Z [active.last_underwater_visual_z], mob Z [swimmer.z]."))

ADMIN_VERB(ocean_water_toggle_refraction, R_DEBUG, FALSE, "Water: Toggle Refraction", "Toggle the local diver's world-only underwater refraction filter for A/B testing.", ADMIN_CATEGORY_DEBUG)
    if(!isliving(user.mob))
        return
    var/mob/living/swimmer = user.mob
    var/datum/status_effect/ocean_swimming/status = swimmer.has_status_effect(/datum/status_effect/ocean_swimming)
    if(!status)
        to_chat(user, span_notice("No underwater swimming status effect is active."))
        return
    status.ocean_refraction_enabled = !status.ocean_refraction_enabled
    status.update_ocean_refraction()
    to_chat(user, span_notice("Underwater world refraction is now [status.ocean_refraction_enabled ? "on" : "off"]."))

/// A/B test the large parallax sprites separately from the plane-master wave.
/// Re-check immediately rather than waiting for the one-second environment poll.
ADMIN_VERB(ocean_water_toggle_parallax, R_DEBUG, FALSE, "Water: Toggle Parallax", "Toggle the local diver's layered ocean texture plates for viewport testing.", ADMIN_CATEGORY_DEBUG)
    if(!isliving(user.mob))
        return
    var/mob/living/swimmer = user.mob
    var/datum/status_effect/ocean_swimming/status = swimmer.has_status_effect(/datum/status_effect/ocean_swimming)
    if(!status)
        to_chat(user, span_notice("No underwater swimming status effect is active."))
        return
    status.ocean_parallax_enabled = !status.ocean_parallax_enabled
    status.next_parallax_environment_check_at = 0
    status.update_ocean_parallax()
    to_chat(user, span_notice("Underwater texture parallax is now [status.ocean_parallax_enabled ? "on" : "off"]."))

#undef CHANNEL_OCEAN_RUMBLE

/*
 * TEMPORARY RENDER DIAGNOSTICS, remove after the ocean-hole graphics issue is fixed.
 * These admin verbs do not change the flooding simulation, swimming, or lighting.
 * The optional overlay test changes only the visual appearance of one opening.
 */

/// Select an ordinary open-space hole above a water turf near the admin.
/proc/ocean_debug_find_nearby_opening(mob/user_mob)
    var/turf/start = get_turf(user_mob)
    if(!start)
        return null
    if(isopenspaceturf(start) && GET_TURF_BELOW(start))
        return start
    for(var/turf/candidate in range(2, start))
        if(!isopenspaceturf(candidate))
            continue
        var/turf/underneath = GET_TURF_BELOW(candidate)
        if(!underneath)
            continue
        if(isoceanturf(underneath) || istype(underneath, /turf/open/openspace/ocean_column))
            return candidate
    return null

/// Read-only diagnosis of the hole and the z-level directly below.
ADMIN_VERB(ocean_water_debug_hole_view, R_DEBUG, FALSE, "Water: Inspect Ocean Opening", "Inspect the lower turf, area lighting and Z-level visuals beneath an opening.", ADMIN_CATEGORY_DEBUG)
    var/turf/hole = ocean_debug_find_nearby_opening(user.mob)
    if(!hole)
        to_chat(user, span_warning("No linked open-space hole found underfoot or within two tiles above ocean."))
        return
    var/turf/below = GET_TURF_BELOW(hole)
    if(!below)
        to_chat(user, span_warning("That opening is not linked to a lower Z-level."))
        return
    var/area/hole_area = get_area(hole)
    var/area/below_area = get_area(below)
    var/lower_overlay_count = 0
    for(var/atom/movable/appearance_object as anything in below.vis_contents)
        if(istype(appearance_object, /obj/effect/abstract/ocean_overlay))
            lower_overlay_count++
    to_chat(user, span_notice("Ocean opening at ([hole.x], [hole.y], [hole.z]): [hole.type] (plane [hole.plane], vis_contents [length(hole.vis_contents)])."))
    to_chat(user, span_notice("Directly below: ([below.x], [below.y], [below.z]): [below.type] (plane [below.plane], vis_contents [length(below.vis_contents)], ocean overlays [lower_overlay_count])."))
    to_chat(user, span_notice("Lower tile is ocean: [isoceanturf(below) || istype(below, /turf/open/openspace/ocean_column) ? "YES" : "NO"]."))
    to_chat(user, span_notice("Upper area: [hole_area?.type], base lighting alpha [hole_area?.base_lighting_alpha], static lighting [hole_area?.static_lighting]."))
    to_chat(user, span_notice("Lower area: [below_area?.type], base lighting alpha [below_area?.base_lighting_alpha], static lighting [below_area?.static_lighting]."))
    to_chat(user, span_notice("Lower light: outer range [below.light_outer_range], light color [below.light_color]; upper light: outer range [hole.light_outer_range], color [hole.light_color]."))

/// Temporarily add/remove the existing water overlay type on the hole's own Z-level.
/// This isolates missing upper-level tint from problems with the lower-Z display.
ADMIN_VERB(ocean_water_debug_hole_tint, R_DEBUG, FALSE, "Water: Toggle Ocean Hole Tint Test", "Temporarily toggle ocean water color on one linked opening; no flooding or light changes.", ADMIN_CATEGORY_DEBUG)
    var/turf/hole = ocean_debug_find_nearby_opening(user.mob)
    if(!hole)
        to_chat(user, span_warning("No linked open-space hole found underfoot or within two tiles above ocean."))
        return
    var/turf/below = GET_TURF_BELOW(hole)
    if(!below || !(isoceanturf(below) || istype(below, /turf/open/openspace/ocean_column)))
        to_chat(user, span_warning("The opening must lead directly to an ocean turf for this visual test."))
        return
    var/static/list/debug_visuals_by_offset = list()
    var/plane_offset = GET_Z_PLANE_OFFSET(hole.z)
    var/offset_key = "[plane_offset]"
    var/obj/effect/abstract/ocean_overlay/test_water = debug_visuals_by_offset[offset_key]
    if(!test_water)
        test_water = new(null, list(/datum/reagent/water = 10))
        SET_PLANE_W_SCALAR(test_water, AREA_PLANE, plane_offset)
        debug_visuals_by_offset[offset_key] = test_water
    if(test_water in hole.vis_contents)
        hole.vis_contents -= test_water
        to_chat(user, span_notice("Temporary ocean tint REMOVED from the opening at [hole.x], [hole.y], [hole.z]."))
    else
        hole.vis_contents += test_water
        to_chat(user, span_notice("Temporary ocean tint ADDED to the opening at [hole.x], [hole.y], [hole.z]. Check whether the hole now shows blue water instead of black."))
