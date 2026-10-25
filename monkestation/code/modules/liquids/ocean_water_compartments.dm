/*
 * Ocean water compartments
 *
 * Connected interior floor detection, door-link diagnostics, and a persistent
 * lazy compartment registry for ocean-enabled maps, ruins, and ghost roles.
 *
 * The mapped /area is metadata, not a watertight boundary. Door tiles are
 * excluded from either room's geometry regardless of their open/closed state.
 * A door floor tile is counted ONCE as connection space, not as part of both
 * compartments. For example, two six-tile rooms joined by one door have
 * thirteen floor tiles in total, with the door tile counted only once.
 *
 * Stage A3 adds a lazy persistent registry, event-driven invalidation, and
 * multi-Z vertical passage diagnostics. Open-space turfs are NOT room floors;
 * they are connections between separately registered regions and/or the ocean.
 *
 * Stage B1: bounded room water volumes (100 WU per floor tile), diagnostics,
 * and water preservation through topology changes.
 * Stage B2: only directly exposed ocean boundaries produce infinite water.
 * Stage B3: conservative transfer through open doors and vertical shafts.
 * Water movement is stored in WU, never simulated as turf liquid per tick.
 * Stage C3 / C3.3: native depth stages, visual-only door bridges, fully-flooded
 * swimming, deferred room discovery, listener-limited audio and currents.
 * These are approximations of room-averaged depth, NOT per-turf CFD.
 * The old per-turf ocean-column liquid source must not feed the same room.
 */

#define OCEAN_WATER_PROBE_MAX_TILES 12000
// Registry scans must stay smaller than an exploratory admin probe. An
// unbounded test-map floor must never stall server startup or debugging.
#define OCEAN_WATER_REGISTRY_MAX_TILES 2000
#define OCEAN_WATER_PROBE_MAX_REGIONS 16
#define OCEAN_WATER_PROBE_MAX_DOORS 12
#define OCEAN_WATER_PROBE_MAX_VERTICAL_LINKS 12
#define OCEAN_WATER_MAX_VERTICAL_SHAFT 16
// Stage B1: Abstract water units (WU), not physical liters. Revise when a physical tile-height model exists.
#define OCEAN_WATER_UNITS_PER_FLOOR_TILE 100
// Stage B2: Rate per directly ocean-exposed edge or floor opening, in WU/s.
// A six-tile room with one breach fills in roughly 4 s at 150 WU/s.
#define OCEAN_WATER_INGRESS_WU_PER_SECOND 150
// Prevent pathological long process deltas and unlimited massive breach rates.
#define OCEAN_WATER_INGRESS_MAX_DELTA_SECONDS 3
#define OCEAN_WATER_INGRESS_MAX_WU_PER_SECOND 2400
// B3: Per-link flow caps, in abstract water units per second.
#define OCEAN_WATER_DOOR_FLOW_WU_PER_SECOND 200
#define OCEAN_WATER_VERTICAL_DOWN_WU_PER_SECOND 250
#define OCEAN_WATER_VERTICAL_UP_WU_PER_SECOND 100
// No upward hydrostatic flow from a dry or partially filled lower room.
// For now pressure assistance requires an actual ocean inlet in the lower room.
#define OCEAN_WATER_VERTICAL_RISE_THRESHOLD 1
// Stage C3.1: bounded tile rendering, not liquid-group spread or per-tile fluid solving.
#define OCEAN_WATER_VISUAL_BANDS 10
#define OCEAN_WATER_VISUAL_TILES_PER_TICK 256
#define OCEAN_WATER_FLOW_RADIUS 3
#define OCEAN_WATER_FLOW_MAX_MOVABLES 20
#define OCEAN_WATER_FLOW_THROTTLE_DS 5
#define OCEAN_WATER_AUDIO_IDLE_DS 12
#define OCEAN_WATER_MAX_AUDIO_LOOPS 24
#define OCEAN_WATER_AUDIO_MAX_RANGE 8
// Private, dedicated per-client looping channels, distinct from ocean rumble 993.
#define OCEAN_WATER_AUDIO_BREACH_CHANNEL 994
#define OCEAN_WATER_AUDIO_TRANSFER_CHANNEL 995
#define OCEAN_WATER_AUDIO_ROOM_CHANNEL 996
// Maximum work per tick while automatically discovering newly mapped rooms.
#define OCEAN_WATER_AUTO_SCAN_BUDGET 192
#define OCEAN_WATER_AUTO_SCAN_MAX_SEEDS 1024
// Near-full rooms should look and behave submerged before numerical 100%.
#define OCEAN_WATER_FULL_SWIM_FRACTION 0.98

/// Stable across ChangeTurf() replacing the turf object at this location.
/proc/ocean_water_volume_tile_key(turf/tile)
    return "[tile.x]:[tile.y]:[tile.z]"

/// Only genuine open-space turfs on an explicitly mapped multiz stack qualify.
/// This deliberately excludes unlinked Z levels and floor-like objects.
/proc/ocean_water_is_vertical_opening(turf/candidate)
    return candidate && isopenspaceturf(candidate) && GET_TURF_BELOW(candidate)

/// Only actual ocean-column and ocean-floor turf types are infinite sources.
/// /area/ocean is insufficient evidence of water: mapped areas may also be
/// shared with ruins, interiors or other non-ocean turfs.
/proc/ocean_water_is_exterior_source(turf/check_turf)
    if(!check_turf)
        return FALSE
    return istype(check_turf, /turf/open/openspace/ocean_column) || isoceanturf(check_turf)

/// Stage B2: test IMMEDIATE water contact, not line of sight or ocean somewhere
/// at the end of a multiz shaft. A shaft leading through another compartment
/// is a room-to-room connection (future B3), not an infinite-ocean inlet.
/// This deliberately doesn't traverse GET_TURF_BELOW() recursively.
/proc/ocean_water_vertical_shaft_exposed(turf/opening)
    if(!ocean_water_is_vertical_opening(opening))
        return FALSE
    // An open floor directly over the seabed or a water column is an inlet.
    if(ocean_water_is_exterior_source(GET_TURF_BELOW(opening)))
        return TRUE
    // An ocean turf touching the opening on this SAME Z level is also direct.
    for(var/direction in GLOB.cardinals)
        var/turf/side = get_step(opening, direction)
        if(!side || side.z != opening.z)
            continue
        if(ocean_water_is_exterior_source(side) && TURFS_CAN_SHARE(opening, side))
            return TRUE
    return FALSE

/proc/ocean_water_is_full_compartment_turf(turf/check_turf)
    if(!check_turf || !GLOB.ocean_water_compartment_registry)
        return FALSE
    var/datum/ocean_water_compartment_registry/registry = GLOB.ocean_water_compartment_registry
    var/datum/ocean_water_registered_compartment/room = registry.turf_to_compartment[check_turf]
    if(room)
        return room.get_fill_fraction() >= OCEAN_WATER_FULL_SWIM_FRACTION
    // A repaired wall invalidates room geometry for a brief rediscovery.
    // While water credits are in escrow, preserve the occupant's submersion
    // if the retained water appearance was already fully submerged.
    if(registry.pending_visual_reconcile[check_turf])
        var/obj/effect/ocean_water_surface/retained = registry.surface_by_turf[check_turf]
        return retained && retained.liquid_depth_state == LIQUID_STATE_FULLTILE
    return FALSE

/// A vertical connector inherits the fully submerged state of an actual
/// neighboring room on THIS deck, not from distant ocean visible below it.
/// This lookup is cache-only and never triggers lazy registration.
/proc/ocean_water_is_flooded_shaft(turf/check_turf)
    if(!ocean_water_is_vertical_opening(check_turf) || !GLOB.ocean_water_compartment_registry)
        return FALSE
    var/datum/ocean_water_compartment_registry/registry = GLOB.ocean_water_compartment_registry
    for(var/direction in GLOB.cardinals)
        var/turf/neighbor = get_step(check_turf, direction)
        if(!neighbor || neighbor.z != check_turf.z || !TURFS_CAN_SHARE(check_turf, neighbor))
            continue
        var/datum/ocean_water_registered_compartment/room = registry.turf_to_compartment[neighbor]
        if(room && room.get_fill_fraction() >= OCEAN_WATER_FULL_SWIM_FRACTION)
            return TRUE
        if(!room && ocean_water_is_full_compartment_turf(neighbor))
            return TRUE
    return FALSE

/// Doors are connectors, never water capacity. Use the cached link state
/// without triggering a compartment scan from movement or breath processing.
/proc/ocean_water_is_flooded_doorway(turf/check_turf)
    if(!check_turf || !GLOB.ocean_water_compartment_registry)
        return FALSE
    var/datum/ocean_water_compartment_registry/registry = GLOB.ocean_water_compartment_registry
    for(var/obj/machinery/door/door in check_turf)
        var/datum/ocean_water_registered_connection/link = registry.door_to_connection[door]
        if(!link || !link.is_passable())
            continue
        for(var/datum/ocean_water_registered_compartment/room as anything in link.adjacent_compartments)
            if(room && (room in registry.compartments) && room.get_fill_fraction() >= OCEAN_WATER_FULL_SWIM_FRACTION)
                return TRUE
    return FALSE

/proc/ocean_water_is_swimmable_environment(turf/check_turf)
    return is_swimmable_ocean_turf(check_turf) || ocean_water_is_full_compartment_turf(check_turf) || ocean_water_is_flooded_shaft(check_turf) || ocean_water_is_flooded_doorway(check_turf)

/datum/ocean_water_compartment_probe
    /// Connected interior floor turfs reached by this scan.
    var/list/turf/member_turfs = list()
    /// Mapped area instances represented in the scanned geometry.
    var/list/area/area_membership = list()
    /// Door objects encountered at the boundary, regardless of door state.
    var/list/obj/machinery/door/boundary_doors = list()
    /// Open-space turfs bordering this region or immediately above its floor.
    var/list/turf/boundary_vertical_openings = list()
    /// Boundary turfs watched for splits/merges when their geometry changes.
    var/list/turf/boundary_turfs = list()
    /// A capped scan is NOT a complete compartment and should not be trusted.
    var/hit_safety_limit = FALSE
    var/min_x = 0
    var/min_y = 0
    var/max_x = 0
    var/max_y = 0
    var/scanned_z = 0

/datum/ocean_water_compartment_probe/proc/can_contain(turf/candidate, expected_z)
    if(!istype(candidate, /turf/open))
        return FALSE
    if(candidate.z != expected_z || candidate.density)
        return FALSE
    // Ocean water and holes in the floor are not ordinary interior floors.
    if(isgroundlessturf(candidate) || isoceanturf(candidate) || is_swimmable_ocean_turf(candidate))
        return FALSE
    // Door tiles remain boundaries even when the door is currently open.
    if(locate(/obj/machinery/door) in candidate)
        return FALSE
    // A solid window on a floor tile is also a boundary.
    for(var/obj/structure/window/window in candidate)
        if(window.density)
            return FALSE
    return TRUE

/datum/ocean_water_compartment_probe/proc/scan(turf/start, maximum_tiles = OCEAN_WATER_PROBE_MAX_TILES)
    if(!start || !can_contain(start, start.z))
        return FALSE

    scanned_z = start.z
    min_x = start.x
    max_x = start.x
    min_y = start.y
    max_y = start.y

    var/list/turf/frontier = list(start)
    var/list/visited = list()
    visited[start] = TRUE
    var/head = 1

    // A moving queue index avoids repeatedly removing the first item.
    while(head <= length(frontier))
        if(length(member_turfs) >= maximum_tiles)
            hit_safety_limit = TRUE
            break

        var/turf/current = frontier[head]
        head++
        member_turfs += current

        min_x = min(min_x, current.x)
        max_x = max(max_x, current.x)
        min_y = min(min_y, current.y)
        max_y = max(max_y, current.y)

        var/area/mapped_area = get_area(current)
        if(mapped_area)
            area_membership |= mapped_area

        // A compartment can be the LOWER endpoint of an open shaft. Inspect
        // the turf above every registered member, including holes not reachable
        // from a same-Z cardinal boundary. Watch upper turf replacements too:
        // drilling a hole above a registered lower room must invalidate it.
        var/turf/above = GET_TURF_ABOVE(current)
        if(above)
            boundary_turfs |= above
            if(ocean_water_is_vertical_opening(above))
                boundary_vertical_openings |= above

        for(var/direction in GLOB.cardinals)
            var/turf/neighbor = get_step(current, direction)
            if(!neighbor || neighbor.z != scanned_z)
                continue

            var/obj/machinery/door/neighbor_door = locate(/obj/machinery/door) in neighbor
            if(neighbor_door)
                boundary_doors |= neighbor_door
                boundary_turfs |= neighbor
                continue

            if(visited[neighbor])
                continue
            if(!can_contain(neighbor, scanned_z))
                boundary_turfs |= neighbor
                if(ocean_water_is_vertical_opening(neighbor))
                    boundary_vertical_openings |= neighbor
                continue
            visited[neighbor] = TRUE
            frontier += neighbor

    return TRUE

/*
 * On-demand, temporary connectivity discovery.
 *
 * One scan per distinct encountered region. The turf -> region cache avoids
 * repeating a potentially expensive flood fill when a door has multiple
 * neighboring tiles in the same compartment, or when several doors border
 * the same compartment. This is debug infrastructure, not a runtime graph.
 */

/datum/ocean_water_compartment_network_probe
    var/list/datum/ocean_water_compartment_probe/compartments = list()
    var/list/turf_to_compartment = list()
    var/max_regions = OCEAN_WATER_PROBE_MAX_REGIONS
    var/hit_region_limit = FALSE

/datum/ocean_water_compartment_network_probe/proc/get_compartment(turf/start)
    if(!start)
        return null

    var/datum/ocean_water_compartment_probe/cached = turf_to_compartment[start]
    if(cached)
        return cached

    if(length(compartments) >= max_regions)
        hit_region_limit = TRUE
        return null

    var/datum/ocean_water_compartment_probe/found = new
    if(!found.scan(start))
        qdel(found)
        return null

    compartments += found
    for(var/turf/member as anything in found.member_turfs)
        turf_to_compartment[member] = found
    return found

/datum/ocean_water_compartment_network_probe/Destroy()
    for(var/datum/ocean_water_compartment_probe/compartment as anything in compartments)
        qdel(compartment)
    compartments.Cut()
    turf_to_compartment.Cut()
    return ..()

/datum/ocean_water_compartment_door_probe
    var/obj/machinery/door/target_door
    /// Distinct valid interior compartments on the cardinal sides of a door.
    var/list/datum/ocean_water_compartment_probe/adjacent_compartments = list()
    /// A valid interior floor underneath the door contributes one bridge tile.
    var/bridge_floor_tiles = 0

/datum/ocean_water_compartment_door_probe/proc/inspect(obj/machinery/door/door, datum/ocean_water_compartment_network_probe/network)
    if(!door || !network)
        return FALSE

    target_door = door
    var/turf/door_turf = get_turf(door)
    if(!door_turf)
        return FALSE

    // The door's floor is excluded from compartment geometry but counted once
    // for future water capacity calculations, if it is interior floor turf.
    if(istype(door_turf, /turf/open) && !isopenspaceturf(door_turf) && !isoceanturf(door_turf) && !is_swimmable_ocean_turf(door_turf))
        bridge_floor_tiles = 1

    // Check ALL cardinal sides, not merely east/west or north/south. Some
    // mapped airlocks can have more than two independently connected sides.
    for(var/direction in GLOB.cardinals)
        var/turf/neighbor = get_step(door_turf, direction)
        if(!neighbor || neighbor.z != door_turf.z)
            continue

        // An adjacent door or window is not a compartment floor; our existing
        // can_contain() rules exclude ocean, space and dense turfs as well.
        var/datum/ocean_water_compartment_probe/region = network.get_compartment(neighbor)
        if(region)
            adjacent_compartments |= region

    return TRUE

/datum/ocean_water_compartment_door_probe/proc/is_open()
    if(!target_door)
        return FALSE
    // Density is the physical obstruction check. A locked-but-open door is
    // traversable; a closed door is not. Respect stacked dense doors too.
    var/turf/door_turf = get_turf(target_door)
    if(!door_turf)
        return FALSE
    for(var/obj/machinery/door/other_door in door_turf)
        if(other_door.density)
            return FALSE
    return TRUE

/datum/ocean_water_compartment_door_probe/proc/is_complete()
    for(var/datum/ocean_water_compartment_probe/region as anything in adjacent_compartments)
        if(region.hit_safety_limit)
            return FALSE
    return TRUE

/datum/ocean_water_compartment_door_probe/proc/has_two_sides()
    return length(adjacent_compartments) >= 2

/*
 * Shared multiz shaft discovery. Each open-space turf is a possible passage,
 * and stacked open-space turfs form one shaft. Regions alongside ANY shaft
 * level and the region directly beneath its lowest opening may exchange water
 * in the future. This is strictly a geometry probe, not a fluid simulation.
 *
 * Using GET_TURF_* prevents unrelated Z levels from being treated as connected.
 */
/datum/ocean_water_vertical_network_probe
    var/list/turf/opening_turfs = list()
    var/list/datum/ocean_water_compartment_probe/adjacent_compartments = list()
    var/turf/landing_turf
    var/exposed_to_ocean = FALSE
    var/hit_safety_limit = FALSE

/datum/ocean_water_vertical_network_probe/proc/inspect(turf/seed, datum/ocean_water_compartment_network_probe/network)
    if(!network || !ocean_water_is_vertical_opening(seed))
        return FALSE

    // Find the uppermost consecutive opening in the connected stack.
    var/turf/top = seed
    var/height = 0
    while(TRUE)
        var/turf/above = GET_TURF_ABOVE(top)
        if(!ocean_water_is_vertical_opening(above) || GET_TURF_BELOW(above) != top)
            break
        height++
        if(height >= OCEAN_WATER_MAX_VERTICAL_SHAFT)
            hit_safety_limit = TRUE
            return FALSE
        top = above

    var/turf/current = top
    var/turf/above_top = GET_TURF_ABOVE(top)
    if(above_top && (isoceanturf(above_top) || is_swimmable_ocean_turf(above_top)))
        exposed_to_ocean = TRUE
    while(ocean_water_is_vertical_opening(current))
        if(length(opening_turfs) >= OCEAN_WATER_MAX_VERTICAL_SHAFT)
            hit_safety_limit = TRUE
            return FALSE
        opening_turfs += current
        for(var/direction in GLOB.cardinals)
            var/turf/neighbor = get_step(current, direction)
            if(!neighbor || neighbor.z != current.z)
                continue
            if(isoceanturf(neighbor) || is_swimmable_ocean_turf(neighbor))
                exposed_to_ocean = TRUE
            var/datum/ocean_water_compartment_probe/side = network.get_compartment(neighbor)
            if(side)
                adjacent_compartments |= side
        var/turf/below = GET_TURF_BELOW(current)
        if(!below)
            return TRUE
        if(!isopenspaceturf(below))
            landing_turf = below
            if(isoceanturf(below) || is_swimmable_ocean_turf(below))
                exposed_to_ocean = TRUE
            else
                var/datum/ocean_water_compartment_probe/landing_region = network.get_compartment(below)
                if(landing_region)
                    adjacent_compartments |= landing_region
            return TRUE
        current = below
    return TRUE

/*
 * Admin verb for geometry and connection diagnostics.
 * Deliberately read-only: opening a door never merges the detected compartments.
 */
ADMIN_VERB(ocean_water_probe_compartment, R_DEBUG, FALSE, "Water: Probe Compartments", "Inspect connected floor geometry and door links without changing flooding.", ADMIN_CATEGORY_DEBUG)
    var/turf/starting_turf = get_turf(user.mob)
    var/datum/ocean_water_compartment_network_probe/network = new
    var/datum/ocean_water_compartment_probe/probe = network.get_compartment(starting_turf)

    if(!probe)
        to_chat(user, span_warning("Compartment probe: Stand on a dry interior floor tile (not a door, wall, ocean column, or open space)."))
        qdel(network)
        return

    var/limit_status = probe.hit_safety_limit ? "YES" : "no"
    to_chat(user, span_notice("Compartment probe (Z [probe.scanned_z]): [length(probe.member_turfs)] connected floor tiles; [length(probe.area_membership)] mapped area instances; [length(probe.boundary_doors)] adjacent door objects."))
    to_chat(user, span_notice("Bounds: X [probe.min_x]-[probe.max_x], Y [probe.min_y]-[probe.max_y]. Safety cap reached: [limit_status]. Nearby vertical openings: [length(probe.boundary_vertical_openings)]."))

    var/areas_shown = 0
    for(var/area/mapped_area as anything in probe.area_membership)
        areas_shown++
        if(areas_shown > 8)
            to_chat(user, span_notice("Additional mapped areas omitted from debug output."))
            break
        to_chat(user, span_notice("Area [areas_shown]: [mapped_area.name] ([mapped_area.type])"))

    if(probe.hit_safety_limit)
        to_chat(user, span_warning("The starting compartment exceeded the scan cap. Door-link results may be incomplete."))

    var/doors_checked = 0
    var/links_found = 0
    for(var/obj/machinery/door/boundary_door as anything in probe.boundary_doors)
        if(doors_checked >= OCEAN_WATER_PROBE_MAX_DOORS)
            break
        doors_checked++

        var/datum/ocean_water_compartment_door_probe/connection = new
        if(!connection.inspect(boundary_door, network))
            qdel(connection)
            continue

        var/turf/door_turf = get_turf(boundary_door)
        var/door_state = connection.is_open() ? "OPEN" : "CLOSED"
        var/side_count = length(connection.adjacent_compartments)
        var/complete = connection.is_complete() && !network.hit_region_limit
        var/connection_status = "No two-sided link"
        if(side_count >= 2)
            connection_status = connection.is_open() ? "PASSABLE" : "BLOCKED"
            links_found++
        if(!complete)
            connection_status = "INCOMPLETE SCAN"

        var/list/side_descriptions = list()
        var/combined_floor_tiles = connection.bridge_floor_tiles
        for(var/datum/ocean_water_compartment_probe/neighbor_region as anything in connection.adjacent_compartments)
            var/region_number = network.compartments.Find(neighbor_region)
            var/region_tiles = length(neighbor_region.member_turfs)
            side_descriptions += "C[region_number] ([region_tiles] tiles)"
            combined_floor_tiles += region_tiles

        var/sides_text = length(side_descriptions) ? jointext(side_descriptions, ", ") : "no valid interior sides"
        var/connection_coords = "([door_turf.x], [door_turf.y], [door_turf.z])"
        to_chat(user, span_notice("Door [doors_checked] at [connection_coords]: [door_state]; [side_count] compartment side(s): [sides_text]. Link: [connection_status]."))

        if(side_count >= 2)
            to_chat(user, span_notice("Door bridge: [connection.bridge_floor_tiles] floor tile(s), counted once. Distinct side regions + bridge: [combined_floor_tiles] tiles (diagnostic only)."))
        qdel(connection)

    // Temporary vertical diagnostics, using the same capped region cache.
    var/vertical_checked = 0
    var/list/seen_openings = list()
    for(var/turf/opening as anything in probe.boundary_vertical_openings)
        if(seen_openings[opening])
            continue
        if(vertical_checked >= OCEAN_WATER_PROBE_MAX_VERTICAL_LINKS)
            break
        vertical_checked++
        var/datum/ocean_water_vertical_network_probe/shaft = new
        if(!shaft.inspect(opening, network))
            to_chat(user, span_warning("Vertical opening ([opening.x], [opening.y], [opening.z]): incomplete or unlinked multiz shaft."))
            qdel(shaft)
            continue
        for(var/turf/hole as anything in shaft.opening_turfs)
            seen_openings[hole] = TRUE
        var/list/side_names = list()
        for(var/datum/ocean_water_compartment_probe/side as anything in shaft.adjacent_compartments)
            side_names += "C[network.compartments.Find(side)] ([length(side.member_turfs)] tiles; Z [side.scanned_z])"
        var/side_text = length(side_names) ? jointext(side_names, ", ") : "no interior endpoints"
        var/exterior_text = shaft.exposed_to_ocean ? "OCEAN ENDPOINT" : "no ocean endpoint found"
        to_chat(user, span_notice("Vertical shaft ([opening.x], [opening.y], [opening.z]): [length(shaft.opening_turfs)] opening turf(s), sides: [side_text]; [exterior_text]."))
        qdel(shaft)

    to_chat(user, span_notice("Connection summary: inspected [doors_checked]/[length(probe.boundary_doors)] adjacent door(s), [vertical_checked] distinct vertical shaft(s) ([length(seen_openings)] hole turfs); [links_found] doors with at least two detected sides; [length(network.compartments)] compartment scan(s) cached."))
    if(doors_checked < length(probe.boundary_doors) || length(seen_openings) < length(probe.boundary_vertical_openings) || network.hit_region_limit)
        to_chat(user, span_warning("Probe safety limit: Some door links or regions were not inspected. Do not treat these results as a complete graph."))

    qdel(network)

/*
 * Stage A3 - persistent, lazily discovered compartment registry.
 *
 * An interior compartment is registered the first time a caller requests it.
 * No global map scan, per-tick traversal, or assumption about mapped areas.
 * Registered compartments are observed for turf replacement and creation of
 * doors/windows on their member or boundary turfs. Door passability is read
 * live, so opening or closing doors NEVER invalidates room geometry.
 *
 * A future ocean-water breach handler can simply call
 * ocean_water_register_nearby_interiors(breach_turf), and subsequent flooding
 * code can call ocean_water_get_registered_compartment(interior_turf).
 *
 * Doors/windows that are removed without changing a turf require the related
 * code to call ocean_water_notify_geometry_changed(turf). Door destruction is
 * also watched when a door connection has been discovered. See limitations.
 */

GLOBAL_DATUM_INIT(ocean_water_compartment_registry, /datum/ocean_water_compartment_registry, new)

/datum/ocean_water_registered_compartment
    parent_type = /datum/ocean_water_compartment_probe
    /// IDs do not change unless the compartment's geometry is invalidated.
    var/compartment_id = 0
    var/list/datum/ocean_water_registered_connection/links = list()
    var/list/datum/ocean_water_registered_vertical_connection/vertical_links = list()
    /// B1: Water is stored on the room, not individually simulated on turfs.
    var/water_volume_units = 0
    var/water_capacity_units = 0
    /// Stable location keys survive turf object replacement during ChangeTurf.
    var/list/water_member_coordinates = list()
    /// B2: Cached direct ocean inlets. Recomputed only when geometry changes.
    var/ocean_ingress_edges = 0
    /// Breakdown for diagnostics. Counts do not include door-mediated flow.
    var/ocean_horizontal_edges = 0
    var/ocean_vertical_openings = 0
    /// B3: Link construction is deferred until this compartment first becomes wet.
    var/transfer_links_initialized = FALSE
    /// Stage C: sources are actual same-level inlet boundaries, not distant visible ocean.
    var/list/turf/ocean_inlet_sources = list()
    var/list/ocean_inlet_directions = list()
    /// Exact exterior breach tiles, saved instead of reconstructing by direction.
    var/list/ocean_inlet_exteriors = list()
    /// Cached visual presentation; refreshed in bounded batches.
    var/visual_band = -1
    var/visual_cursor = 1
    /// When the depth changes mid-batch, finish the sweep then update the tiles
    /// visited before the transition, rather than restarting every tick.
    var/visual_followup = FALSE
    /// One stable in-room source for the separate compartment filling ambience.
    var/turf/ambient_audio_turf

/datum/ocean_water_registered_compartment/proc/get_fill_fraction()
    if(water_capacity_units <= 0)
        return 0
    return clamp(water_volume_units / water_capacity_units, 0, 1)

/datum/ocean_water_registered_compartment/proc/set_water_volume_units(new_volume)
    if(!isnum(new_volume))
        return water_volume_units
    water_volume_units = clamp(new_volume, 0, water_capacity_units)
    // Admin draining a full room should wake the existing ocean breach again.
    GLOB.ocean_water_compartment_registry?.update_ocean_processing(src)
    GLOB.ocean_water_compartment_registry?.update_transfer_processing(src)
    GLOB.ocean_water_compartment_registry?.queue_visual_refresh(src)
    return water_volume_units

/datum/ocean_water_registered_compartment/proc/adjust_water_volume_units(delta)
    if(!isnum(delta))
        return water_volume_units
    return set_water_volume_units(water_volume_units + delta)

/datum/ocean_water_registered_connection
    var/obj/machinery/door/target_door
    var/list/datum/ocean_water_registered_compartment/adjacent_compartments = list()
    /// Door floor tiles are not assigned to either room, and are counted once.
    var/bridge_floor_tiles = 0

/datum/ocean_water_registered_connection/proc/is_passable()
    if(!target_door)
        return FALSE
    var/turf/door_turf = get_turf(target_door)
    if(!door_turf)
        return FALSE
    for(var/obj/machinery/door/other_door in door_turf)
        if(other_door.density)
            return FALSE
    return TRUE

/datum/ocean_water_registered_connection/proc/has_two_sides()
    return length(adjacent_compartments) >= 2

/datum/ocean_water_registered_vertical_connection
    /// Physical open-space turfs in this shaft, not interior capacity tiles.
    var/list/turf/opening_turfs = list()
    /// Cached initial shallow-water threshold for direct ocean-fed sources.
    var/list/entry_threshold_by_room = list()
    /// Once shallow water reaches a shaft, it remains wet until its room drains.
    var/list/entry_reached_by_room = list()
    var/list/datum/ocean_water_registered_compartment/adjacent_compartments = list()
    var/turf/landing_turf
    /// Ocean exposure is metadata, not simulated water ingress yet.
    var/exposed_to_ocean = FALSE

/datum/ocean_water_registered_vertical_connection/proc/has_two_sides()
    return length(adjacent_compartments) >= 2

/datum/ocean_water_registered_vertical_connection/proc/has_ocean_endpoint()
    return exposed_to_ocean

/* Incremental floor search for automatic discovery. Never explore a complete
 * room in Initialize(), ocean processing or atmos callbacks. */
/datum/ocean_water_discovery_job
    var/datum/ocean_water_registered_compartment/region
    var/list/turf/frontier = list()
    var/list/visited = list()
    var/head = 1
    var/done = FALSE
    var/rejected = FALSE

/datum/ocean_water_discovery_job/New(turf/seed)
    . = ..()
    region = new
    if(!seed || !region.can_contain(seed, seed.z))
        rejected = TRUE
        done = TRUE
        return
    region.scanned_z = seed.z
    region.min_x = seed.x
    region.max_x = seed.x
    region.min_y = seed.y
    region.max_y = seed.y
    frontier += seed
    visited[seed] = TRUE

/datum/ocean_water_discovery_job/proc/advance(budget)
    if(done)
        return
    while(budget > 0 && head <= length(frontier))
        budget--
        if(length(region.member_turfs) >= OCEAN_WATER_REGISTRY_MAX_TILES)
            rejected = TRUE
            done = TRUE
            return
        var/turf/current = frontier[head++]
        region.member_turfs += current
        region.min_x = min(region.min_x, current.x)
        region.max_x = max(region.max_x, current.x)
        region.min_y = min(region.min_y, current.y)
        region.max_y = max(region.max_y, current.y)
        var/area/mapped_area = get_area(current)
        if(mapped_area)
            region.area_membership |= mapped_area
        var/turf/above = GET_TURF_ABOVE(current)
        if(above)
            region.boundary_turfs |= above
            if(ocean_water_is_vertical_opening(above))
                region.boundary_vertical_openings |= above
        for(var/direction in GLOB.cardinals)
            var/turf/neighbor = get_step(current, direction)
            if(!neighbor || neighbor.z != region.scanned_z)
                continue
            var/obj/machinery/door/door = locate(/obj/machinery/door) in neighbor
            if(door)
                region.boundary_doors |= door
                region.boundary_turfs |= neighbor
                continue
            if(visited[neighbor])
                continue
            if(!region.can_contain(neighbor, region.scanned_z))
                region.boundary_turfs |= neighbor
                if(ocean_water_is_vertical_opening(neighbor))
                    region.boundary_vertical_openings |= neighbor
                continue
            visited[neighbor] = TRUE
            frontier += neighbor
    if(head > length(frontier))
        done = TRUE

/datum/ocean_water_discovery_job/Destroy()
    if(region)
        qdel(region)
        region = null
    return ..()

/datum/ocean_water_compartment_registry
    /// Accessed only on demand. The registry does not scan the world on startup.
    var/list/datum/ocean_water_registered_compartment/compartments = list()
    var/list/turf_to_compartment = list()
    var/list/door_to_connection = list()
    /// Every turf in a vertical shaft resolves to its shared connection datum.
    var/list/vertical_turf_to_connection = list()
    /// Each watched turf is associated with the regions that rely on it.
    var/list/turf_to_watching_regions = list()
    var/next_compartment_id = 1
    var/scan_count = 0
    var/cache_hits = 0
    var/rejected_scans = 0
    /// When geometry changes, water is held at former tile coordinates until
    /// the resulting rooms are lazily rediscovered. Each credit is used ONCE.
    /// Sparse: empty rooms do not produce any entries.
    var/list/pending_water_by_tile = list()
    /// Volume that could not fit in surviving geometry. Not silently erased.
    /// Stage B2 can resolve overflow via breaches/exterior discharge.
    var/unassigned_water_units = 0
    /// B2: Only non-full ocean-exposed compartments are processed.
    var/list/datum/ocean_water_registered_compartment/active_ocean_compartments = list()
    var/ocean_processing_enabled = TRUE
    var/ocean_is_processing = FALSE
    var/ocean_processed_ticks = 0
    var/ocean_total_added_units = 0
    /// B3: Registered wet rooms with potentially usable door or shaft links.
    var/list/datum/ocean_water_registered_compartment/active_transfer_compartments = list()
    var/transfer_processing_enabled = TRUE
    var/transfer_processed_ticks = 0
    /// WU moved across links. Ocean-fed vertical flow is also tracked in B2 ingress.
    var/transfer_total_moved_units = 0
    var/transfer_last_tick_moved_units = 0
    /// Stage C2 native: visual updates are batched, not redrawn per simulation tick.
    var/list/datum/ocean_water_registered_compartment/active_visual_compartments = list()
    var/list/surface_by_turf = list()
    var/list/shaft_surface_by_turf = list()
    var/list/door_surface_by_turf = list()
    /// Active gushing sprites on open, transferring doorway connections.
    var/list/door_waterfalls = list()
    var/list/door_waterfall_last_flow_ds = list()
    /// Entered() signals for bridge tiles, not registered room floors.
    var/list/observed_bridge_turfs = list()
    /// One visual per exterior breach tile; water volume still lives in rooms.
    var/list/waterfall_by_turf = list()
    var/list/waterfall_owner_by_turf = list()
    /// Retain visual objects while modified room geometry is rediscovered.
    var/list/pending_visual_reconcile = list()
    /// Wake sleepers when a door is opened, even before a B3 link exists.
    var/list/observed_doors = list()
    /// Flow observations rather than independent positional playback loops.
    var/list/audio_emitters = list()
    /// One state per listening client; at most three concurrent flood sounds.
    var/list/listener_audio = list()
    var/audio_last_mix_ds = 0
    var/list/turf/auto_seeds = list()
    var/list/auto_seed_lookup = list()
    var/datum/ocean_water_discovery_job/auto_job
    /// Limit event-triggered discovery to one bounded callback per burst.
    var/priority_discovery_scheduled = FALSE
    var/auto_registered_rooms = 0
    var/auto_scan_steps = 0
    var/effects_enabled = TRUE
    var/list/current_last_at = list()
    var/current_events = 0
    var/current_atoms_pushed = 0
    var/audio_events = 0

/// Recompute physical breach count only after region registration or geometry
/// changes. A breach touching two tiles has two inlet edges; an actual ocean-
/// facing opening counts once for the room on that SAME Z level. A vertical
/// shaft into a different dry room is NOT an ocean source (B3 will transfer).
/datum/ocean_water_compartment_registry/proc/refresh_ocean_sources(datum/ocean_water_registered_compartment/region)
    if(!region || !(region in compartments))
        return
    var/horizontal = 0
    var/vertical = 0
    // Old exterior edges can change during wall reconstruction.
    clear_waterfalls_for_room(region)
    region.ocean_inlet_sources.Cut()
    region.ocean_inlet_directions.Cut()
    region.ocean_inlet_exteriors.Cut()
    for(var/turf/floor as anything in region.member_turfs)
        for(var/direction in GLOB.cardinals)
            var/turf/adjacent = get_step(floor, direction)
            if(!adjacent || adjacent.z != floor.z || !isopenturf(adjacent))
                continue
            if(!ocean_water_is_exterior_source(adjacent))
                continue
            if(TURFS_CAN_SHARE(floor, adjacent))
                horizontal++
                region.ocean_inlet_sources |= floor
                region.ocean_inlet_directions[floor] = get_dir(adjacent, floor)
                region.ocean_inlet_exteriors[floor] = adjacent
    for(var/turf/opening as anything in region.boundary_vertical_openings)
        // A hole in the level ABOVE this room is a connection, not proof that
        // ocean enters the room from the bottom of a remote vertical shaft.
        if(opening.z != region.scanned_z)
            continue
        // The opening must actually share an unblocked cardinal boundary
        // with a floor belonging to THIS compartment on this Z level.
        var/touches_this_room = FALSE
        for(var/direction in GLOB.cardinals)
            var/turf/neighbor = get_step(opening, direction)
            if(!neighbor || neighbor.z != opening.z)
                continue
            if(turf_to_compartment[neighbor] == region && TURFS_CAN_SHARE(neighbor, opening))
                touches_this_room = TRUE
                break
        if(!touches_this_room)
            continue
        if(ocean_water_vertical_shaft_exposed(opening))
            vertical++
            // Purely vertical ingress: audio can originate here, but the
            // current must not invent a horizontal direction.
            region.ocean_inlet_sources |= opening
            region.ocean_inlet_directions[opening] = 0
    region.ocean_horizontal_edges = horizontal
    region.ocean_vertical_openings = vertical
    region.ocean_ingress_edges = horizontal + vertical
    update_ocean_processing(region)
    if(region in active_ocean_compartments)
        show_waterfalls_for_room(region)

/// B3: Water moving into/out of rooms wakes or idles their potential link work.
/// A flooded room behind a closed airlock must remain eligible for later opening.
/// We only poll links on registered wet rooms, not all tiles on the map.
/datum/ocean_water_compartment_registry/proc/update_transfer_processing(datum/ocean_water_registered_compartment/region)
    if(!region)
        return
    // Even a saturated room needs processing when a vertical outlet exists.
    var/has_open_path = length(region.boundary_vertical_openings) || length(region.vertical_links)
    if(!has_open_path)
        for(var/obj/machinery/door/door as anything in region.boundary_doors)
            if(!door.density)
                has_open_path = TRUE
                break
    if(transfer_processing_enabled && (region in compartments) && region.water_volume_units > 0 && has_open_path)
        active_transfer_compartments |= region
    else
        active_transfer_compartments -= region
    update_simulation_processing()

/// Shared SSprocessing lifecycle: don't stop the subsystem while B2 or B3 needs it.
/datum/ocean_water_compartment_registry/proc/update_simulation_processing()
    var/should_process = (ocean_processing_enabled && length(active_ocean_compartments)) || (transfer_processing_enabled && length(active_transfer_compartments)) || length(active_visual_compartments) || length(audio_emitters) || length(door_waterfalls) || length(auto_seeds) || auto_job || length(listener_audio)
    if(should_process && !ocean_is_processing)
        ocean_is_processing = TRUE
        START_PROCESSING(SSprocessing, src)
    else if(!should_process && ocean_is_processing)
        ocean_is_processing = FALSE
        STOP_PROCESSING(SSprocessing, src)

/datum/ocean_water_compartment_registry/proc/update_ocean_processing(datum/ocean_water_registered_compartment/region)
    if(!region)
        return
    var/should_process = ocean_processing_enabled && (region in compartments) && region.ocean_ingress_edges > 0 && region.water_volume_units < region.water_capacity_units
    var/was_processing = active_ocean_compartments.Find(region) != 0
    if(should_process)
        active_ocean_compartments |= region
    else
        active_ocean_compartments -= region
    if(should_process && !was_processing)
        show_waterfalls_for_room(region)
    else if(!should_process && was_processing)
        clear_waterfalls_for_room(region)
    update_simulation_processing()

/*
 * Stage C2 presentation adapter for upstream MonkeStation liquid assets.
 * This object deliberately DOES NOT inherit /obj/effect/abstract/liquid_turf:
 * native liquid groups and their processing would double-simulate flooding.
 * The source of truth remains each compartment's WU volume.
 */
/proc/ocean_water_native_color()
    // Use precisely the same reagent-mixing helper that native ocean overlays
    // use. Cache the result: the ocean water reagent recipe is constant.
    var/static/cached_color
    if(!cached_color)
        var/datum/reagents/water_colors = new
        water_colors.add_reagent_list(list(/datum/reagent/water = 10))
        cached_color = mix_color_from_reagents(water_colors.reagent_list)
        qdel(water_colors)
        if(!cached_color)
            cached_color = "#DDF"
    return cached_color

/proc/ocean_water_depth_state(fraction)
    if(fraction <= 0)
        return 0
    // Match the depth thresholds used by native liquid_groups.dm while
    // interpreting 100 WU per floor tile as one full-tile water column.
    var/height = fraction * LIQUID_FULLTILE_LEVEL_HEIGHT
    if(height < LIQUID_ANKLES_LEVEL_HEIGHT)
        return LIQUID_STATE_PUDDLE
    if(height < LIQUID_WAIST_LEVEL_HEIGHT)
        return LIQUID_STATE_ANKLES
    if(height < LIQUID_SHOULDERS_LEVEL_HEIGHT)
        return LIQUID_STATE_WAIST
    if(fraction < OCEAN_WATER_FULL_SWIM_FRACTION)
        return LIQUID_STATE_SHOULDERS
    return LIQUID_STATE_FULLTILE

/obj/effect/ocean_water_surface
    name = "floodwater"
    desc = "Water is rising inside this compartment."
    icon = 'icons/obj/effects/liquid.dmi'
    icon_state = "ocean"
    density = FALSE
    anchored = TRUE
    mouse_opacity = MOUSE_OPACITY_TRANSPARENT
    plane = FLOOR_PLANE
    layer = TURF_LAYER
    alpha = 175
    /// Native liquid state; overlays use stage1 through stage4.
    var/liquid_depth_state = 0

/obj/effect/ocean_water_surface/Initialize(mapload)
    . = ..()
    color = ocean_water_native_color()

/obj/effect/ocean_water_surface/proc/set_depth_state(new_state)
    if(liquid_depth_state == new_state)
        return
    liquid_depth_state = new_state
    update_appearance()

/obj/effect/ocean_water_surface/update_overlays()
    . = ..()
    // Identical icon naming, planes, and positional anchoring to upstream
    // /obj/effect/abstract/liquid_turf/update_overlays(). The parent object's
    // color is applied to the native water sprites by the engine.
    if(liquid_depth_state <= LIQUID_STATE_PUDDLE)
        return
    var/stage_number = liquid_depth_state - 1
    var/turf/floor_turf = get_turf(src)
    . += mutable_appearance('icons/obj/effects/liquid_overlays.dmi', "stage[stage_number]_bottom", offset_spokesman = floor_turf, plane = GAME_PLANE_UPPER, layer = ABOVE_MOB_LAYER)
    . += mutable_appearance('icons/obj/effects/liquid_overlays.dmi', "stage[stage_number]_top", offset_spokesman = floor_turf, plane = GAME_PLANE, layer = GATEWAY_UNDERLAY_LAYER)

/// A softly darkened view down a flooded opening. This is not a second
/// water plane: it remains mostly transparent to native z-transparency.
/// Open airlock art lives on GAME_PLANE above the bridge. The native
/// bottom depth mask should show ankle-high water as well as deeper water.
/// Do not add the native stage_top overlay here, because that covers the
/// airlock sprite rather than flowing underneath it.
/obj/effect/ocean_water_surface/door_bridge
    // A floor-plane base can be hidden behind the native turf on the door tile.
    // The complete water foundation instead lives in the GAME_PLANE overlays.
    icon_state = null

/obj/effect/ocean_water_surface/door_bridge/update_overlays()
    . = list()
    if(liquid_depth_state <= 0)
        return
    var/turf/bridge_turf = get_turf(src)
    if(!bridge_turf)
        return
    // Always add the same native ocean base used on an ordinary room tile,
    // including puddle/ankle stages. Keep it BELOW_OPEN_DOOR_LAYER (2.6),
    // below a visually open airlock (2.7); the default native top mask uses
    // GATEWAY_UNDERLAY_LAYER (2.85) and would cover the open airlock art.
    var/mutable_appearance/base_water = mutable_appearance('icons/obj/effects/liquid.dmi', "ocean", offset_spokesman = bridge_turf, plane = GAME_PLANE, layer = BELOW_OPEN_DOOR_LAYER)
    base_water.color = color
    base_water.alpha = alpha
    . += base_water
    if(liquid_depth_state <= LIQUID_STATE_PUDDLE)
        return
    var/stage_number = liquid_depth_state - 1
    var/mutable_appearance/top_water = mutable_appearance('icons/obj/effects/liquid_overlays.dmi', "stage[stage_number]_top", offset_spokesman = bridge_turf, plane = GAME_PLANE, layer = BELOW_OPEN_DOOR_LAYER + 0.01)
    top_water.color = color
    top_water.alpha = alpha
    . += top_water
    var/mutable_appearance/front_water = mutable_appearance('icons/obj/effects/liquid_overlays.dmi', "stage[stage_number]_bottom", offset_spokesman = bridge_turf, plane = GAME_PLANE_UPPER, layer = ABOVE_MOB_LAYER)
    front_water.color = color
    front_water.alpha = 175
    . += front_water

/obj/effect/ocean_water_shaft
    name = "deep flooded opening"
    icon = 'icons/obj/effects/ocean_atmosphere.dmi'
    icon_state = "shaft_glimpse"
    density = FALSE
    anchored = TRUE
    mouse_opacity = MOUSE_OPACITY_TRANSPARENT
    plane = GAME_PLANE
    layer = BELOW_MOB_LAYER
    alpha = 48
    var/liquid_depth_state = 0

/obj/effect/ocean_water_shaft/Initialize(mapload)
    . = ..()
    color = ocean_water_native_color()

/obj/effect/ocean_water_shaft/proc/set_depth_state(new_state, water_fraction = 0)
    var/new_water_alpha = clamp(70 + round(water_fraction * 85), 70, 155)
    if(liquid_depth_state == new_state && (new_state <= 0 || alpha == new_water_alpha))
        return
    liquid_depth_state = new_state
    if(new_state > 0)
        // The shaft retains native multiz transparency beneath the water.
        // Native water appearance is added on its own GAME_PLANE overlay;
        // the old standalone dark glimpse must not cover its center.
        icon_state = null
        alpha = new_water_alpha
    else
        // -1 is a faint exposed-ocean cue for otherwise dry shafts.
        icon_state = "shaft_glimpse"
        alpha = 44
    update_appearance()

/obj/effect/ocean_water_shaft/update_overlays()
    . = ..()
    if(liquid_depth_state <= 0)
        return
    var/turf/opening = get_turf(src)
    if(!opening)
        return
    // Every wet stage has a base tile on THIS deck. Unlike the room floor,
    // this is a connector: do not replace the openspace turf or block vision
    // into lower Z levels. Water layers remain translucent.
    var/mutable_appearance/base_water = mutable_appearance('icons/obj/effects/liquid.dmi', "ocean", offset_spokesman = opening, plane = GAME_PLANE, layer = BELOW_OPEN_DOOR_LAYER)
    base_water.color = color
    base_water.alpha = alpha
    . += base_water
    if(liquid_depth_state <= LIQUID_STATE_PUDDLE)
        return
    var/stage_number = liquid_depth_state - 1
    var/mutable_appearance/top_water = mutable_appearance('icons/obj/effects/liquid_overlays.dmi', "stage[stage_number]_top", offset_spokesman = opening, plane = GAME_PLANE, layer = BELOW_OPEN_DOOR_LAYER + 0.01)
    top_water.color = color
    top_water.alpha = alpha
    . += top_water
    var/mutable_appearance/front_water = mutable_appearance('icons/obj/effects/liquid_overlays.dmi', "stage[stage_number]_bottom", offset_spokesman = opening, plane = GAME_PLANE_UPPER, layer = ABOVE_MOB_LAYER)
    front_water.color = color
    front_water.alpha = 175
    . += front_water

/// One small, directional sheet of falling water occupying the actual breach.
/// The player supplies the "water_gushing" icon state in native liquid.dmi.
/// No separate DMI, foam/spray object or extra water simulation is created.
/obj/effect/ocean_water_gushing
    name = "rushing seawater"
    icon = 'icons/obj/effects/liquid.dmi'
    icon_state = "water_gushing"
    anchored = TRUE
    density = FALSE
    mouse_opacity = MOUSE_OPACITY_TRANSPARENT
    plane = GAME_PLANE
    layer = BELOW_OPEN_DOOR_LAYER
    // Fully flooded floor water uses alpha 155, so match that transparency.
    // Per-pixel transparency in the DMI is preserved.
    alpha = 155
    var/flow_direction = 0

/obj/effect/ocean_water_gushing/Initialize(mapload)
    . = ..()
    color = ocean_water_native_color()

/// Draw the single SOUTH-facing "water_gushing" animation once in liquid.dmi;
/// rotate it by exact right angles rather than requiring four artist variants.
/obj/effect/ocean_water_gushing/proc/set_inflow_direction(inflow_dir)
    if(flow_direction == inflow_dir)
        return
    flow_direction = inflow_dir
    dir = SOUTH
    var/matrix/orientation = matrix()
    // BYOND matrix Turn() is CLOCKWISE. From SOUTH, EAST is -90.
    switch(inflow_dir)
        if(EAST)
            orientation.Turn(270)
        if(NORTH)
            orientation.Turn(180)
        if(WEST)
            orientation.Turn(90)
    transform = orientation

/* C3 sound emitter metadata; actual playback is per-client and explicitly
 * range-limited. The OGGs are seamless loops on dedicated channels. */
/datum/ocean_water_audio_emitter
    var/turf/source
    var/sound_type
    var/datum/ocean_water_registered_compartment/room
    var/rate = 0
    var/last_active_ds = 0

// Test-fixture only. These airlocks work without a powered APC and remain
// open until manually closed, making water-transfer tests deterministic.
/obj/machinery/door/airlock/maintenance/ocean_water_test
    name = "water test bulkhead"
    autoclose = FALSE
    req_access = list()

/obj/machinery/door/airlock/maintenance/ocean_water_test/hasPower()
    return TRUE

// Test-fixture breach switch. Place two tiles east of an exterior wall.
// Clicking toggles the wall into a real ocean turf, triggering the existing
// turf-change detection. It never reaches through several Z-levels.
/obj/structure/ocean_water_test_switch
    name = "hull breach test switch"
    desc = "Toggles the wall two tiles to the west between intact and breached."
    icon = 'icons/obj/stationobjs.dmi'
    icon_state = "igniter0"
    density = FALSE
    anchored = TRUE

/obj/structure/ocean_water_test_switch/attack_hand(mob/user, list/modifiers)
    if(!Adjacent(user))
        return
    var/turf/first_west = get_step(get_turf(src), WEST)
    var/turf/breach = get_step(first_west, WEST)
    if(!breach)
        return
    if(istype(breach, /turf/closed/wall/mineral/titanium/submarine))
        breach.ChangeTurf(/turf/open/floor/plating/ocean/dark)
        to_chat(user, span_warning("The test hull opens to the sea!"))
        return
    if(isoceanturf(breach))
        breach.ChangeTurf(/turf/closed/wall/mineral/titanium/submarine)
        to_chat(user, span_notice("The test hull breach is sealed."))

/// Breach presentation is separate from water volume. Horizontal inlets
/// are the INTERIOR floor tile next to a physical ocean breach. The former
/// C3.2 implementation rendered the sprite on the exterior tile, one tile
/// too far out on the ocean side in our test map. Anchor visually on the
/// inward-facing inlet instead. The actual source remains the exterior ocean.
/datum/ocean_water_compartment_registry/proc/show_waterfalls_for_room(datum/ocean_water_registered_compartment/room)
    if(!effects_enabled || !room || room.get_fill_fraction() >= OCEAN_WATER_FULL_SWIM_FRACTION)
        return
    for(var/turf/inlet as anything in room.ocean_inlet_sources)
        var/inward = room.ocean_inlet_directions[inlet]
        if(!inward)
            continue // Vertical floor holes aren't sideways hull breaches.
        var/turf/exterior = room.ocean_inlet_exteriors[inlet]
        if(!exterior || get_step(exterior, inward) != inlet || !ocean_water_is_exterior_source(exterior))
            continue
        if(waterfall_by_turf[inlet])
            continue
        var/obj/effect/ocean_water_gushing/gush = new(inlet)
        gush.set_inflow_direction(inward)
        waterfall_by_turf[inlet] = gush
        waterfall_owner_by_turf[inlet] = room

/datum/ocean_water_compartment_registry/proc/clear_waterfalls_for_room(datum/ocean_water_registered_compartment/room)
    var/list/inlet_tiles = waterfall_owner_by_turf.Copy()
    for(var/turf/inlet as anything in inlet_tiles)
        if(waterfall_owner_by_turf[inlet] != room)
            continue
        var/obj/effect/ocean_water_gushing/gush = waterfall_by_turf[inlet]
        if(gush)
            qdel(gush)
        waterfall_by_turf -= inlet
        waterfall_owner_by_turf -= inlet

/datum/ocean_water_compartment_registry/proc/refresh_swimmer_on_turf(turf/location)
    if(!location)
        return
    for(var/mob/living/swimmer in location)
        if(swimmer.incorporeal_move)
            continue
        var/datum/status_effect/ocean_swimming/active_swim = swimmer.has_status_effect(/datum/status_effect/ocean_swimming)
        if(ocean_water_is_swimmable_environment(location))
            if(!active_swim)
                swimmer.apply_status_effect(/datum/status_effect/ocean_swimming)
            else
                active_swim.refresh_ocean_immersion()
        else if(active_swim)
            swimmer.remove_status_effect(/datum/status_effect/ocean_swimming)

/// Stage transitions are rare compared to water-volume changes. Keep status
/// effects synchronized INDEPENDENTLY of batched tile rendering.
/datum/ocean_water_compartment_registry/proc/sync_room_immersion(datum/ocean_water_registered_compartment/region)
    if(!region)
        return
    for(var/turf/member as anything in region.member_turfs)
        refresh_swimmer_on_turf(member)
    for(var/turf/opening as anything in region.boundary_vertical_openings)
        if(opening.z == region.scanned_z)
            refresh_swimmer_on_turf(opening)

/// Shafts are connection tiles, not compartment water-storage tiles. Only
/// render native translucent depth overlays when there is water in a room
/// touching the opening on the SAME Z-level. Water visible a deck below is
/// not evidence that this opening is wet on the current deck.
/datum/ocean_water_compartment_registry/proc/refresh_shaft_visual(turf/opening)
    if(!ocean_water_is_vertical_opening(opening))
        return
    var/fraction = 0
    for(var/direction in GLOB.cardinals)
        var/turf/neighbor = get_step(opening, direction)
        if(!neighbor || neighbor.z != opening.z || !TURFS_CAN_SHARE(opening, neighbor))
            continue
        var/datum/ocean_water_registered_compartment/adjacent = turf_to_compartment[neighbor]
        if(adjacent)
            fraction = max(fraction, adjacent.get_fill_fraction())
    var/depth_state = effects_enabled ? ocean_water_depth_state(fraction) : 0
    var/obj/effect/ocean_water_shaft/shaft = shaft_surface_by_turf[opening]
    if(depth_state == 0)
        if(!effects_enabled || !ocean_water_vertical_shaft_exposed(opening))
            if(shaft)
                shaft_surface_by_turf -= opening
                qdel(shaft)
            return
        // A dry deck looking immediately onto real ocean still gets a very
        // faint, feathered ocean cue; NOT a solid bright or black tile.
        depth_state = -1
    if(!shaft)
        // An exposed-to-ocean opening can receive its harmless depth cue
        // before compartment registration; adopt that effect instead of
        // stacking a second dark square over it.
        shaft = locate(/obj/effect/ocean_water_shaft) in opening
        if(!shaft)
            shaft = new(opening)
        shaft_surface_by_turf[opening] = shaft
    shaft.set_depth_state(depth_state, fraction)

/datum/ocean_water_compartment_registry/proc/refresh_room_shaft_visuals(datum/ocean_water_registered_compartment/region)
    if(!region)
        return
    for(var/turf/opening as anything in region.boundary_vertical_openings)
        if(opening.z == region.scanned_z)
            refresh_shaft_visual(opening)

/datum/ocean_water_compartment_registry/proc/queue_visual_refresh(datum/ocean_water_registered_compartment/region)
    if(!region || !(region in compartments))
        return
    // Native depth bands, no redundant per-WU appearance rebuilds.
    var/next_band = effects_enabled ? ocean_water_depth_state(region.get_fill_fraction()) : 0
    if(region.visual_band == next_band)
        return
    region.visual_band = next_band
    // Trigger promptly for stationary swimmers, even if visual tiles are queued.
    sync_room_immersion(region)
    refresh_room_shaft_visuals(region)
    for(var/datum/ocean_water_registered_connection/link as anything in region.links)
        update_door_water_bridge(link)
    if(region in active_visual_compartments)
        // Do not repeatedly reset to tile 1 during fast flooding. Queue a
        // catch-up pass for the tiles already visited instead.
        region.visual_followup = TRUE
    else
        region.visual_cursor = 1
        region.visual_followup = FALSE
        active_visual_compartments |= region
    update_simulation_processing()

/datum/ocean_water_compartment_registry/proc/clear_room_visuals(datum/ocean_water_registered_compartment/region, preserve = FALSE)
    active_visual_compartments -= region
    region.visual_followup = FALSE
    if(preserve)
        // Geometry edits must not visually drain an already flooded room.
        // Existing overlays will be taken over by the replacement region.
        for(var/turf/member as anything in region.member_turfs)
            pending_visual_reconcile[member] = TRUE
        return
    for(var/turf/member as anything in region.member_turfs)
        var/obj/effect/ocean_water_surface/surface = surface_by_turf[member]
        if(surface)
            surface_by_turf -= member
            qdel(surface)
        var/turf/above = GET_TURF_ABOVE(member)
        if(above)
            var/obj/effect/ocean_water_shaft/shaft = shaft_surface_by_turf[above]
            if(shaft)
                shaft_surface_by_turf -= above
                qdel(shaft)

/datum/ocean_water_compartment_registry/proc/reconcile_abandoned_visuals()
    if(auto_job || length(auto_seeds))
        return
    for(var/turf/previous as anything in pending_visual_reconcile)
        if(!previous || QDELETED(previous))
            surface_by_turf -= previous
            continue
        if(turf_to_compartment[previous])
            continue
        var/obj/effect/ocean_water_surface/old_visual = surface_by_turf[previous]
        if(old_visual)
            surface_by_turf -= previous
            qdel(old_visual)
        var/turf/above = GET_TURF_ABOVE(previous)
        if(above && !ocean_water_is_flooded_shaft(above))
            var/obj/effect/ocean_water_shaft/old_shaft = shaft_surface_by_turf[above]
            if(old_shaft)
                shaft_surface_by_turf -= above
                qdel(old_shaft)
    pending_visual_reconcile.Cut()

/datum/ocean_water_compartment_registry/proc/process_visual_refreshes()
    var/budget = OCEAN_WATER_VISUAL_TILES_PER_TICK
    var/list/datum/ocean_water_registered_compartment/pending = active_visual_compartments.Copy()
    for(var/datum/ocean_water_registered_compartment/region as anything in pending)
        if(budget <= 0)
            break
        if(!(region in compartments))
            active_visual_compartments -= region
            continue
        var/band = region.visual_band
        var/fraction = region.get_fill_fraction()
        var/depth_state = band
        while(region.visual_cursor <= length(region.member_turfs) && budget > 0)
            var/turf/member = region.member_turfs[region.visual_cursor]
            region.visual_cursor++
            budget--
            var/obj/effect/ocean_water_surface/surface = surface_by_turf[member]
            if(band <= 0)
                if(surface)
                    surface_by_turf -= member
                    qdel(surface)
            else
                if(!surface)
                    surface = new(member)
                    surface_by_turf[member] = surface
                // The base is the complete native "ocean" tile, with the
                // upstream liquid depth layers added on top of characters.
                // Match upstream liquid group opacity bounds for water.
                // Retain native full-tile ocean water, but allow floors and
                // movable objects to remain readable through the water mask.
                surface.alpha = clamp(70 + round(fraction * 85), 70, 155)
                surface.set_depth_state(depth_state)
            // Covers stationary characters when the water rises around them.
            // Immersion is synchronized once per stage change above, not
            // dependent on whichever floor tile the visual cursor reaches.
            // Keep the native multi-Z view: never infer this shaft is wet
            // simply because the floor beneath it is wet. Check same-Z
            // neighbors and draw transparent depth stages only.
            var/turf/above = GET_TURF_ABOVE(member)
            if(above && ocean_water_is_vertical_opening(above))
                refresh_shaft_visual(above)
        if(region.visual_cursor > length(region.member_turfs))
            if(region.visual_followup)
                region.visual_followup = FALSE
                region.visual_cursor = 1
            else
                active_visual_compartments -= region
                for(var/datum/ocean_water_registered_connection/link as anything in region.links)
                    update_door_water_bridge(link)
    update_simulation_processing()

/datum/ocean_water_compartment_registry/proc/note_water_audio(key, turf/source, sound_type, rate, datum/ocean_water_registered_compartment/room = null)
    if(!effects_enabled || !source || rate <= 0)
        return
    var/datum/ocean_water_audio_emitter/emitter = audio_emitters[key]
    var/created_new_emitter = !emitter
    if(!emitter)
        if(length(audio_emitters) >= OCEAN_WATER_MAX_AUDIO_LOOPS)
            return
        emitter = new
        emitter.source = source
        audio_emitters[key] = emitter
        audio_events++
    emitter.sound_type = sound_type
    emitter.rate = rate
    emitter.room = room
    emitter.last_active_ds = world.time
    update_simulation_processing()
    // Make a new breach audible as soon as water actually moves. This is
    // bounded: only the first new breach per world tick forces a re-mix.
    if(created_new_emitter && audio_last_mix_ds != world.time)
        // Newly active door and breach sources both deserve immediate sound.
        update_listener_audio(TRUE)

/// Immediately disconnect audio tied to invalidated geometry. In particular,
/// repairing a breach should not leave a stale source roaring at its old turf.
/datum/ocean_water_compartment_registry/proc/stop_audio_for_room(datum/ocean_water_registered_compartment/room)
    var/removed = FALSE
    var/list/keys = audio_emitters.Copy()
    for(var/key as anything in keys)
        var/datum/ocean_water_audio_emitter/emitter = audio_emitters[key]
        if(!emitter || emitter.room != room)
            continue
        audio_emitters -= key
        qdel(emitter)
        removed = TRUE
    if(removed)
        update_listener_audio(TRUE)

/datum/ocean_water_compartment_registry/proc/note_room_filling(datum/ocean_water_registered_compartment/room, rate)
    if(!effects_enabled || !room || rate < 10 || !length(room.member_turfs))
        return
    if(!room.ambient_audio_turf || !(room.ambient_audio_turf in room.member_turfs))
        room.ambient_audio_turf = room.member_turfs[ceil(length(room.member_turfs) / 2)]
    note_water_audio("R:[room.compartment_id]", room.ambient_audio_turf, "room", rate, room)

/datum/ocean_water_compartment_registry/proc/stop_flood_listener_channel(client/listener, channel)
    SEND_SOUND(listener, sound(null, repeat = FALSE, wait = FALSE, channel = channel))

/datum/ocean_water_compartment_registry/proc/update_listener_audio(force = FALSE)
    // Regular mix updates are rate limited; new breaches can force an update.
    if(!force && world.time < audio_last_mix_ds + 2)
        return
    audio_last_mix_ds = world.time
    var/list/connected = list()
    for(var/client/listener as anything in GLOB.clients)
        var/mob/avatar = listener.mob
        if(!avatar)
            continue
        connected[listener] = TRUE
        var/list/current = listener_audio[listener]
        if(!current)
            current = list()
        // Aggregate simultaneous independent streams rather than choosing
        // only the loudest doorway, which caused apparently missing sources.
        // Root-sum-squares preserves separation without linear loudness
        // stacking when several airlocks are active.
        var/list/mix_power = list("B" = 0, "T" = 0, "R" = 0)
        var/list/best = list("B" = 0, "T" = 0, "R" = 0)
        var/list/best_type = list()
        for(var/key as anything in audio_emitters)
            var/datum/ocean_water_audio_emitter/emitter = audio_emitters[key]
            if(!emitter || !emitter.source || world.time > emitter.last_active_ds + OCEAN_WATER_AUDIO_IDLE_DS)
                continue
            var/category = emitter.sound_type == "room" ? "R" : (emitter.sound_type == "breach_heavy" || emitter.sound_type == "breach_medium") ? "B" : "T"
            var/volume = 0
            if(category == "R")
                if(emitter.room && turf_to_compartment[get_turf(avatar)] == emitter.room)
                    volume = min(20, 10 + round(emitter.rate / 35))
            else if(avatar.z == emitter.source.z)
                var/distance = get_dist(avatar, emitter.source)
                if(distance <= OCEAN_WATER_AUDIO_MAX_RANGE)
                    var/base_volume = category == "B" ? min(49, 27 + round(emitter.rate / 12)) : min(33, 19 + round(emitter.rate / 16))
                    // Sharper spatial attenuation than default playsound() and hard cutoff.
                    volume = round(base_volume * (1 - distance / (OCEAN_WATER_AUDIO_MAX_RANGE + 1)) ** 2)
                    // Walls and separate closed rooms strongly reduce distant sound.
                    var/datum/ocean_water_registered_compartment/listener_room = turf_to_compartment[get_turf(avatar)]
                    if(listener_room && listener_room != emitter.room && emitter.room)
                        volume = round(volume * 0.35)
            if(volume <= 0)
                continue
            mix_power[category] += volume * volume
            if(volume > best[category])
                best[category] = volume
                best_type[category] = emitter.sound_type
        for(var/category in list("B", "T", "R"))
            var/volume = round(sqrt(mix_power[category]))
            var/category_ceiling = category == "B" ? 49 : category == "T" ? 36 : 22
            volume = min(category_ceiling, volume)
            var/channel = category == "B" ? OCEAN_WATER_AUDIO_BREACH_CHANNEL : category == "T" ? OCEAN_WATER_AUDIO_TRANSFER_CHANNEL : OCEAN_WATER_AUDIO_ROOM_CHANNEL
            // A transfer loop has ONE stable sound file regardless of which
            // doorway dominates. Preserve the active breach sample until it
            // really stops, avoiding repeated OGG restarts near thresholds.
            var/sound_kind = best_type[category]
            var/previous_kind = current[category]
            if(category == "B" && previous_kind && volume > 0)
                sound_kind = previous_kind
            var/previous_volume = current["[category]_volume"] || 0
            var/real_volume = volume > 0 ? calculate_mixed_volume(listener, volume, CHANNEL_SOUND_EFFECTS) : 0
            // Smooth the level, not the playback position. SOUND_UPDATE
            // preserves the stream when more doors open or close.
            if(previous_kind && real_volume > 0)
                real_volume = clamp(real_volume, max(1, previous_volume - 8), previous_volume + 8)
            if(real_volume > 0)
                current["[category]_last_heard"] = world.time
            if(real_volume <= 0 && previous_kind)
                // Brief gaps occur when multiple compartment links refresh in
                // successive ticks. Keep the SAME channel for 0.8 s and
                // softly fade it instead of issuing sound(null) for one tick.
                var/last_heard = current["[category]_last_heard"] || 0
                if(world.time - last_heard <= 8)
                    real_volume = max(1, round(previous_volume * 0.72))
                    sound_kind = previous_kind
            if(real_volume <= 0)
                if(previous_kind)
                    stop_flood_listener_channel(listener, channel)
                current[category] = null
                current["[category]_volume"] = 0
                continue
            if(sound_kind != previous_kind)
                if(previous_kind)
                    stop_flood_listener_channel(listener, channel)
                var/file_to_play
                if(sound_kind == "breach_heavy")
                    file_to_play = 'sound/effects/ocean_water/heavy_water_flow.ogg'
                else if(sound_kind == "room")
                    file_to_play = 'sound/effects/ocean_water/compartment_flood.ogg'
                else
                    file_to_play = 'sound/effects/ocean_water/med_water_flow.ogg'
                SEND_SOUND(listener, sound(file_to_play, repeat = TRUE, wait = FALSE, volume = real_volume, channel = channel))
            else if(real_volume != previous_volume)
                var/sound/volume_update = sound(null, channel = channel, volume = real_volume)
                volume_update.status = SOUND_UPDATE
                SEND_SOUND(listener, volume_update)
            current[category] = sound_kind
            current["[category]_volume"] = real_volume
        // Silent clients do not need a persistent entry or an idle process tick.
        if(current["B"] || current["T"] || current["R"])
            listener_audio[listener] = current
        else
            listener_audio -= listener
    // Clients who disconnected still need their states discarded.
    for(var/client/old_listener as anything in listener_audio)
        if(!connected[old_listener])
            listener_audio -= old_listener

/datum/ocean_water_compartment_registry/proc/expire_flow_effects()
    for(var/key as anything in audio_emitters)
        var/datum/ocean_water_audio_emitter/emitter = audio_emitters[key]
        if(!emitter || world.time > emitter.last_active_ds + OCEAN_WATER_AUDIO_IDLE_DS || !effects_enabled)
            audio_emitters -= key
            if(emitter)
                qdel(emitter)
    update_listener_audio()
    update_simulation_processing()

/datum/ocean_water_compartment_registry/proc/clear_flow_effects()
    for(var/client/listener as anything in listener_audio)
        stop_flood_listener_channel(listener, OCEAN_WATER_AUDIO_BREACH_CHANNEL)
        stop_flood_listener_channel(listener, OCEAN_WATER_AUDIO_TRANSFER_CHANNEL)
        stop_flood_listener_channel(listener, OCEAN_WATER_AUDIO_ROOM_CHANNEL)
    listener_audio.Cut()
    for(var/key as anything in audio_emitters)
        var/datum/ocean_water_audio_emitter/emitter = audio_emitters[key]
        if(emitter)
            qdel(emitter)
    audio_emitters.Cut()
    update_simulation_processing()

/// A direction approximating the center-to-center line of two same-Z rooms.
/proc/ocean_water_direction_between_rooms(datum/ocean_water_registered_compartment/source_room, datum/ocean_water_registered_compartment/target_room)
    if(!source_room || !target_room)
        return 0
    var/dx = (target_room.min_x + target_room.max_x) - (source_room.min_x + source_room.max_x)
    var/dy = (target_room.min_y + target_room.max_y) - (source_room.min_y + source_room.max_y)
    if(abs(dx) > abs(dy))
        return dx > 0 ? EAST : WEST
    if(dy)
        return dy > 0 ? NORTH : SOUTH
    return 0

/// Input is the *actual* rate moved through this aperture, in WU/s.
/// No water motion means no force or sound. Do not process whole wet rooms.
/datum/ocean_water_compartment_registry/proc/emit_local_flow(turf/source, push_direction, rate, datum/ocean_water_registered_compartment/receiving_room, datum/ocean_water_registered_compartment/upstream_room = null, is_breach = FALSE)
    if(!effects_enabled || !source || !receiving_room || rate < 10)
        return
    if(!(receiving_room in compartments))
        return
    var/sound_type = is_breach ? (rate >= 120 ? "breach_heavy" : "breach_medium") : "transfer"
    var/key = is_breach ? "B:[source.x]:[source.y]:[source.z]" : "T:[source.x]:[source.y]:[source.z]"
    note_water_audio(key, source, sound_type, rate, receiving_room)
    if(!push_direction || world.time < (current_last_at[source] || 0) + OCEAN_WATER_FLOW_THROTTLE_DS)
        return
    current_last_at[source] = world.time
    current_events++
    var/checked = 0
    for(var/atom/movable/moving in range(OCEAN_WATER_FLOW_RADIUS, source))
        if(checked >= OCEAN_WATER_FLOW_MAX_MOVABLES)
            break
        if(moving.z != source.z || !isturf(moving.loc) || moving.anchored)
            continue
        var/is_character = istype(moving, /mob/living)
        var/is_item = istype(moving, /obj/item)
        var/is_crate = istype(moving, /obj/structure/closet/crate)
        if(!is_character && !is_item && !is_crate)
            continue
        if(is_character)
            var/mob/living/person = moving
            if(person.buckled)
                continue
        var/turf/standing = get_turf(moving)
        var/datum/ocean_water_registered_compartment/occupying_room = turf_to_compartment[standing]
        // Ocean-side suction is meaningful only for real breaches, NOT
        // arbitrary room transfers. Respect existing world ocean predicates.
        var/is_exterior_swimmer = is_breach && !occupying_room && is_swimmable_ocean_turf(standing)
        if(occupying_room != receiving_room && occupying_room != upstream_room && standing != source && !is_exterior_swimmer)
            continue
        var/distance = get_dist(source, standing)
        var/chance = min(98, round(48 + rate * 0.48)) - 15 * distance
        if(distance == 0)
            chance = max(chance, min(98, 66 + round(rate * 0.17)))
        if(is_exterior_swimmer)
            chance = max(chance, min(97, 72 + round(rate * 0.13) - distance * 10))
        if(is_character)
            chance -= is_exterior_swimmer ? 4 : 10
        else if(is_crate)
            chance -= 28
        if(chance <= 0)
            continue
        checked++
        if(!prob(chance))
            continue
        // On the ocean side the current converges TOWARD the opening. At
        // and inside the opening it follows the calculated inward direction.
        var/actual_push_direction = is_exterior_swimmer ? get_dir(standing, source) : push_direction
        if(is_exterior_swimmer && !GLOB.cardinals.Find(actual_push_direction))
            // Avoid diagonal stepping through solid hull corners. Pull from
            // ocean along the dominant cardinal axis toward the inlet.
            var/dx = source.x - standing.x
            var/dy = source.y - standing.y
            actual_push_direction = abs(dx) >= abs(dy) ? (dx > 0 ? EAST : WEST) : (dy > 0 ? NORTH : SOUTH)
        if(!actual_push_direction)
            continue
        // Strong water throws nearby tools several tiles over time, but
        // standard step() collisions still protect walls and closed bulkheads.
        var/move_steps = (!is_character && !is_crate && rate >= 75 && distance <= 2) ? 2 : 1
        for(var/i in 1 to move_steps)
            var/turf/before = get_turf(moving)
            step(moving, actual_push_direction)
            if(get_turf(moving) == before)
                break
            current_atoms_pushed++
            if(is_character)
                break

/datum/ocean_water_compartment_registry/proc/emit_vertical_flow(datum/ocean_water_registered_vertical_connection/link, datum/ocean_water_registered_compartment/source_room, datum/ocean_water_registered_compartment/target_room, rate)
    if(!length(link.opening_turfs))
        return
    var/is_draining_down = source_room.scanned_z > target_room.scanned_z
    var/datum/ocean_water_registered_compartment/affected_room = is_draining_down ? source_room : target_room
    // Select the shaft opening on the same deck as the people being affected.
    // Don't push a character on Z3 using an origin several Z levels below.
    var/turf/hole
    for(var/turf/possible as anything in link.opening_turfs)
        if(possible.z == affected_room.scanned_z)
            hole = possible
            break
    if(!hole)
        return
    var/direction = 0
    for(var/cardinal in GLOB.cardinals)
        var/turf/neighbor = get_step(hole, cardinal)
        if(turf_to_compartment[neighbor] == affected_room)
            direction = is_draining_down ? get_dir(neighbor, hole) : get_dir(hole, neighbor)
            break
    // A downward current moves people toward the opening, without forcing Z
    // transitions. Any eventual falls must obey the existing movement rules.
    emit_local_flow(hole, direction, rate, affected_room)

/// Discover only the bordering links of a wet compartment, once per geometry version.
/// get_connection/get_vertical_connection each uses bounded room scans (not a world scan).
/datum/ocean_water_compartment_registry/proc/update_door_water_bridge(datum/ocean_water_registered_connection/link)
    if(!link || !link.target_door)
        return
    var/turf/bridge = get_turf(link.target_door)
    if(!bridge)
        return
    var/obj/effect/ocean_water_surface/surface = door_surface_by_turf[bridge]
    var/water_fraction = 0
    if(effects_enabled && link.is_passable())
        for(var/datum/ocean_water_registered_compartment/room as anything in link.adjacent_compartments)
            water_fraction = max(water_fraction, room.get_fill_fraction())
    var/new_state = ocean_water_depth_state(water_fraction)
    if(!new_state)
        if(surface)
            door_surface_by_turf -= bridge
            qdel(surface)
        refresh_swimmer_on_turf(bridge)
        return
    if(!surface)
        surface = new /obj/effect/ocean_water_surface/door_bridge(bridge)
        door_surface_by_turf[bridge] = surface
    surface.alpha = clamp(70 + round(water_fraction * 85), 70, 155)
    surface.set_depth_state(new_state)
    refresh_swimmer_on_turf(bridge)

/datum/ocean_water_compartment_registry/proc/watch_boundary_doors(datum/ocean_water_registered_compartment/region)
    for(var/obj/machinery/door/door as anything in region.boundary_doors)
        if(observed_doors[door])
            continue
        observed_doors[door] = TRUE
        RegisterSignal(door, COMSIG_ATOM_DOOR_OPEN, PROC_REF(on_unlinked_door_opened))
        RegisterSignal(door, COMSIG_AIRLOCK_CLOSE, PROC_REF(on_unlinked_door_closed))
        RegisterSignal(door, COMSIG_QDELETING, PROC_REF(on_observed_door_deleted))

/datum/ocean_water_compartment_registry/proc/on_unlinked_door_opened(obj/machinery/door/door)
    SIGNAL_HANDLER
    // Registering another signal inside SEND_SIGNAL may modify its iterator.
    addtimer(CALLBACK(src, PROC_REF(complete_unlinked_door_open), door), 1)

/datum/ocean_water_compartment_registry/proc/on_unlinked_door_closed(obj/machinery/door/door)
    SIGNAL_HANDLER
    clear_door_waterfall(door)
    addtimer(CALLBACK(src, PROC_REF(complete_unlinked_door_open), door), 1)
    // Airlock close signals are sent before the door becomes dense.
    addtimer(CALLBACK(src, PROC_REF(complete_unlinked_door_open), door), 10)

/datum/ocean_water_compartment_registry/proc/complete_unlinked_door_open(obj/machinery/door/door)
    if(!door || QDELETED(door))
        return
    var/datum/ocean_water_registered_connection/link = door_to_connection[door] || get_connection(door)
    if(!link)
        return
    for(var/datum/ocean_water_registered_compartment/room as anything in link.adjacent_compartments)
        update_transfer_processing(room)
    update_door_water_bridge(link)

/datum/ocean_water_compartment_registry/proc/on_observed_door_deleted(obj/machinery/door/door)
    SIGNAL_HANDLER
    observed_doors -= door
    // One watcher owns both door signals, avoiding duplicate registrations.
    on_cached_door_deleted(door)

/datum/ocean_water_compartment_registry/proc/ensure_transfer_links(datum/ocean_water_registered_compartment/region)
    if(!region || !(region in compartments) || region.transfer_links_initialized)
        return
    region.transfer_links_initialized = TRUE
    for(var/obj/machinery/door/door as anything in region.boundary_doors)
        get_connection(door)
    for(var/turf/opening as anything in region.boundary_vertical_openings)
        get_vertical_connection(opening)

/// Move existing water only. Never create WU on a B3 link.
/// A partial flow aims toward equal fractional fill (same idealized floor height).
/datum/ocean_water_compartment_registry/proc/transfer_water(datum/ocean_water_registered_compartment/source_room, datum/ocean_water_registered_compartment/target_room, requested)
    if(!source_room || !target_room || source_room == target_room || !(source_room in compartments) || !(target_room in compartments))
        return 0
    var/amount = min(max(0, requested), source_room.water_volume_units, max(0, target_room.water_capacity_units - target_room.water_volume_units))
    if(amount <= 0)
        return 0
    source_room.water_volume_units -= amount
    target_room.water_volume_units += amount
    transfer_total_moved_units += amount
    transfer_last_tick_moved_units += amount
    update_ocean_processing(source_room)
    update_ocean_processing(target_room)
    update_transfer_processing(source_room)
    update_transfer_processing(target_room)
    queue_visual_refresh(source_room)
    queue_visual_refresh(target_room)
    return amount

/// No new particles or simulated liquids: both kinds of waterfall share
/// the one user-supplied water_gushing state in liquid.dmi.
/datum/ocean_water_compartment_registry/proc/clear_door_waterfall(obj/machinery/door/door)
    var/obj/effect/ocean_water_gushing/gush = door_waterfalls[door]
    if(gush)
        qdel(gush)
    door_waterfalls -= door
    door_waterfall_last_flow_ds -= door

/datum/ocean_water_compartment_registry/proc/update_door_waterfall(datum/ocean_water_registered_connection/link, direction, rate, datum/ocean_water_registered_compartment/receiving)
    if(!link || !link.target_door)
        return
    var/obj/machinery/door/door = link.target_door
    if(!effects_enabled || !link.is_passable() || rate < 10 || !direction || !receiving || receiving.get_fill_fraction() >= OCEAN_WATER_FULL_SWIM_FRACTION)
        clear_door_waterfall(door)
        return
    var/turf/bridge = get_turf(door)
    if(!bridge)
        return
    var/obj/effect/ocean_water_gushing/gush = door_waterfalls[door]
    if(!gush || QDELETED(gush) || get_turf(gush) != bridge)
        if(gush)
            qdel(gush)
        gush = new(bridge)
        door_waterfalls[door] = gush
    gush.set_inflow_direction(direction)
    door_waterfall_last_flow_ds[door] = world.time
    update_simulation_processing()

/datum/ocean_water_compartment_registry/proc/expire_door_waterfalls()
    if(!length(door_waterfalls))
        return
    var/list/doors = door_waterfalls.Copy()
    for(var/obj/machinery/door/door as anything in doors)
        if(!door || QDELETED(door) || door.density || world.time > (door_waterfall_last_flow_ds[door] || 0) + 12)
            clear_door_waterfall(door)

/// Prefer direction at the actual aperture to box-center approximations.
/proc/ocean_water_flow_direction_at_door(turf/bridge, datum/ocean_water_registered_compartment/to_room)
    if(!bridge || !to_room)
        return 0
    for(var/direction in GLOB.cardinals)
        var/turf/neighbor = get_step(bridge, direction)
        if(neighbor && neighbor.z == bridge.z && GLOB.ocean_water_compartment_registry.turf_to_compartment[neighbor] == to_room)
            return direction
    return 0

/// The door itself isn't a water-storage compartment. It is one throttled link.
/datum/ocean_water_compartment_registry/proc/process_door_flow(datum/ocean_water_registered_connection/link, delta_seconds)
    if(!link)
        return
    update_door_water_bridge(link)
    if(!link.is_passable() || !link.has_two_sides())
        clear_door_waterfall(link.target_door)
        return
    var/list/datum/ocean_water_registered_compartment/sides = link.adjacent_compartments
    // Common case: a doorway joins exactly two independent rooms.
    // Ambiguous 3+-room door footprints need dedicated junction capacity later.
    if(length(sides) != 2)
        return
    var/datum/ocean_water_registered_compartment/first = sides[1]
    var/datum/ocean_water_registered_compartment/second = sides[2]
    if(!(first in compartments) || !(second in compartments))
        return
    var/total_capacity = first.water_capacity_units + second.water_capacity_units
    if(total_capacity <= 0)
        return
    var/fraction = (first.water_volume_units + second.water_volume_units) / total_capacity
    var/excess_first = first.water_volume_units - (fraction * first.water_capacity_units)
    // Flow weakens as water levels equalize. Bounded approximation, not CFD.
    var/pressure_difference = abs(first.get_fill_fraction() - second.get_fill_fraction())
    var/budget = OCEAN_WATER_DOOR_FLOW_WU_PER_SECOND * delta_seconds * clamp(pressure_difference * 2, 0, 1.5)
    if(excess_first > 0.01)
        var/moved = transfer_water(first, second, min(excess_first, budget))
        if(moved > 0)
            var/turf/door_turf = get_turf(link.target_door)
            var/flow_dir = ocean_water_flow_direction_at_door(door_turf, second) || ocean_water_direction_between_rooms(first, second)
            update_door_waterfall(link, flow_dir, moved / delta_seconds, second)
            emit_local_flow(door_turf, flow_dir, moved / delta_seconds, second, first)
            note_room_filling(second, moved / delta_seconds)
            note_room_filling(first, moved / delta_seconds)
    else if(excess_first < -0.01)
        var/moved = transfer_water(second, first, min(-excess_first, budget))
        if(moved > 0)
            var/turf/door_turf = get_turf(link.target_door)
            var/flow_dir = ocean_water_flow_direction_at_door(door_turf, first) || ocean_water_direction_between_rooms(second, first)
            update_door_waterfall(link, flow_dir, moved / delta_seconds, first)
            emit_local_flow(door_turf, flow_dir, moved / delta_seconds, first, second)
            note_room_filling(first, moved / delta_seconds)
            note_room_filling(second, moved / delta_seconds)
    else
        clear_door_waterfall(link.target_door)

/// B3: Move water between physical neighboring decks along a single shaft.
/// The shaft must have a valid ordered route between the involved Z levels.
/// DO NOT use has_ocean_endpoint() to add water or flood rooms on sight.
/datum/ocean_water_compartment_registry/proc/process_vertical_flow(datum/ocean_water_registered_vertical_connection/link, delta_seconds)
    if(!link || !link.has_two_sides())
        return
    var/list/datum/ocean_water_registered_compartment/ordered = link.adjacent_compartments.Copy()
    // In a multi-deck shaft, flow only between consecutive registered elevations,
    // not directly from the ocean through every level.
    for(var/i in 1 to length(ordered))
        for(var/j in (i + 1) to length(ordered))
            var/datum/ocean_water_registered_compartment/first = ordered[i]
            var/datum/ocean_water_registered_compartment/second = ordered[j]
            if(first.scanned_z > second.scanned_z)
                ordered[i] = second
                ordered[j] = first
    // A branching shaft with multiple separate rooms on the same deck needs
    // junction capacity. Skip it rather than allowing leaks through walls.
    var/previous_z = 0
    for(var/datum/ocean_water_registered_compartment/candidate as anything in ordered)
        if(!(candidate in compartments) || candidate.scanned_z == previous_z)
            return
        previous_z = candidate.scanned_z
    // Track whether hydrostatic ocean pressure has reached this level through
    // already saturated lower rooms. This is NOT an ocean inlet for upper decks.
    var/pressure_from_below = FALSE
    for(var/level_index in 2 to length(ordered))
        var/datum/ocean_water_registered_compartment/lower = ordered[level_index - 1]
        var/datum/ocean_water_registered_compartment/upper = ordered[level_index]
        if(lower.ocean_ingress_edges > 0)
            pressure_from_below = TRUE
        var/lower_fill = lower.get_fill_fraction()
        // Gravity can drain an upper compartment into an unsaturated lower one.
        // Avoid draining a pressurized upper room straight back into its source.
        if(upper.water_volume_units > 0 && lower_fill < (pressure_from_below ? 0.85 : 1))
            // The C4.1 room-average solver drained distant shafts before any
            // shallow water had visibly spread. For an *actively ocean-fed*
            // upper room, wait for a small, distance-dependent surface layer.
            // This gate is skipped for retained water after a breach is fixed:
            // no phantom stranded water in a room with an open drain.
            var/may_drain = TRUE
            if(upper.ocean_ingress_edges > 0 && !link.entry_reached_by_room[upper])
                var/minimum_surface = link.entry_threshold_by_room[upper]
                if(isnull(minimum_surface))
                    var/closest_inlet = 100
                    for(var/turf/inlet as anything in upper.ocean_inlet_sources)
                        for(var/turf/shaft_turf as anything in link.opening_turfs)
                            if(shaft_turf.z == upper.scanned_z)
                                closest_inlet = min(closest_inlet, get_dist(inlet, shaft_turf))
                    minimum_surface = clamp(0.06 + closest_inlet * 0.018, 0.06, 0.22)
                    link.entry_threshold_by_room[upper] = minimum_surface
                // Near the inlet it may fall immediately; on the far side,
                // the shallow-water stage must first become visible.
                if(upper.get_fill_fraction() < minimum_surface)
                    may_drain = FALSE
                else
                    link.entry_reached_by_room[upper] = TRUE
            var/moved_down = may_drain ? transfer_water(upper, lower, OCEAN_WATER_VERTICAL_DOWN_WU_PER_SECOND * delta_seconds) : 0
            if(moved_down > 0)
                emit_vertical_flow(link, upper, lower, moved_down / delta_seconds)
                note_room_filling(lower, moved_down / delta_seconds)
            lower_fill = lower.get_fill_fraction()
        if(ocean_processing_enabled && pressure_from_below && lower_fill >= OCEAN_WATER_VERTICAL_RISE_THRESHOLD && upper.water_volume_units < upper.water_capacity_units)
            // Source water reaches upper compartment THROUGH the full lower room.
            // This is water from a proven B2 ocean inlet, not an infinite source
            // appearing beside upper deck. Count it as external ocean ingress.
            var/remaining = upper.water_capacity_units - upper.water_volume_units
            var/source_rate = min(OCEAN_WATER_VERTICAL_UP_WU_PER_SECOND, OCEAN_WATER_INGRESS_WU_PER_SECOND)
            var/added = min(remaining, source_rate * delta_seconds)
            if(added > 0)
                // Model the water crossing the saturated lower compartment,
                // followed by immediate B2 make-up water entering its real inlet.
                // No water is generated by the shaft itself.
                lower.water_volume_units -= added
                upper.water_volume_units += added
                lower.water_volume_units += added
                ocean_total_added_units += added
                transfer_total_moved_units += added
                transfer_last_tick_moved_units += added
                update_ocean_processing(upper)
                update_transfer_processing(upper)
                queue_visual_refresh(upper)
                emit_vertical_flow(link, lower, upper, added / delta_seconds)
                note_room_filling(upper, added / delta_seconds)
        // Only propagate ocean pressure further upward when this intermediary
        // room is also nearly full. A hole is not enough to skip a dry deck.
        pressure_from_below = pressure_from_below && upper.get_fill_fraction() >= OCEAN_WATER_VERTICAL_RISE_THRESHOLD

/datum/ocean_water_compartment_registry/proc/process_compartment_transfers(delta_seconds)
    if(!transfer_processing_enabled || !length(active_transfer_compartments))
        return
    transfer_processed_ticks++
    var/list/datum/ocean_water_registered_compartment/wet_rooms = active_transfer_compartments.Copy()
    var/list/seen_doors = list()
    var/list/seen_shafts = list()
    // A room can go dry while a previous door is handled this tick.
    for(var/datum/ocean_water_registered_compartment/region as anything in wet_rooms)
        if(!(region in active_transfer_compartments))
            continue
        ensure_transfer_links(region)
        for(var/datum/ocean_water_registered_connection/door_link as anything in region.links)
            if(seen_doors[door_link])
                continue
            seen_doors[door_link] = TRUE
            process_door_flow(door_link, delta_seconds)
        for(var/datum/ocean_water_registered_vertical_connection/shaft as anything in region.vertical_links)
            if(seen_shafts[shaft])
                continue
            seen_shafts[shaft] = TRUE
            process_vertical_flow(shaft, delta_seconds)
        // Wake only on new flow or a door-opening event after this room sleeps.
        update_transfer_processing(region)

/datum/ocean_water_compartment_registry/process(seconds_per_tick)
    var/delta_seconds = clamp(seconds_per_tick, 0, OCEAN_WATER_INGRESS_MAX_DELTA_SECONDS)
    if(delta_seconds <= 0)
        return
    if(ocean_processing_enabled)
        ocean_processed_ticks++
        var/list/datum/ocean_water_registered_compartment/to_process = active_ocean_compartments.Copy()
        for(var/datum/ocean_water_registered_compartment/room as anything in to_process)
            if(!(room in active_ocean_compartments))
                continue
            var/rate = min(room.ocean_ingress_edges * OCEAN_WATER_INGRESS_WU_PER_SECOND, OCEAN_WATER_INGRESS_MAX_WU_PER_SECOND)
            var/remaining_capacity = room.water_capacity_units - room.water_volume_units
            if(rate <= 0 || remaining_capacity <= 0)
                update_ocean_processing(room)
                continue
            var/added = min(remaining_capacity, rate * delta_seconds)
            room.water_volume_units += added
            ocean_total_added_units += added
            update_ocean_processing(room)
            update_transfer_processing(room)
            queue_visual_refresh(room)
            note_room_filling(room, added / delta_seconds)
            // One localized effect per actual ocean inlet, bounded by rate.
            if(length(room.ocean_inlet_sources))
                var/rate_per_source = (added / delta_seconds) / length(room.ocean_inlet_sources)
                var/emitted = 0
                for(var/turf/inlet as anything in room.ocean_inlet_sources)
                    if(emitted >= 8)
                        break
                    emitted++
                    emit_local_flow(inlet, room.ocean_inlet_directions[inlet], rate_per_source, room, null, TRUE)
    transfer_last_tick_moved_units = 0
    process_compartment_transfers(delta_seconds)
    if(length(active_visual_compartments))
        process_visual_refreshes()
    if(length(auto_seeds) || auto_job)
        process_auto_discovery()
    if(length(audio_emitters) || length(listener_audio))
        expire_flow_effects()
    if(length(door_waterfalls))
        expire_door_waterfalls()

/// Event hook for a newly exposed ocean face or for an edited watertight room.
/// The caller must supply the changed/exposed turf, not a whole map or area.
/datum/ocean_water_compartment_registry/proc/enqueue_auto_seed(turf/seed)
    if(!seed || turf_to_compartment[seed] || auto_seed_lookup[seed] || length(auto_seeds) >= OCEAN_WATER_AUTO_SCAN_MAX_SEEDS)
        return
    if(isgroundlessturf(seed) || isoceanturf(seed) || !isopenturf(seed) || (locate(/obj/machinery/door) in seed))
        return
    auto_seeds += seed
    auto_seed_lookup[seed] = TRUE
    update_simulation_processing()

/datum/ocean_water_compartment_registry/proc/enqueue_exterior_neighbors(turf/exterior)
    if(!exterior)
        return
    for(var/direction in GLOB.cardinals)
        var/turf/adjacent = get_step(exterior, direction)
        if(adjacent && adjacent.z == exterior.z && isopenturf(adjacent) && TURFS_CAN_SHARE(exterior, adjacent))
            enqueue_auto_seed(adjacent)
    // Newly breached exterior tiles are a time-critical event during a round.
    // Map loading MUST stay deferred: thousands of mapped ocean turfs can
    // call this proc as the level initializes.
    if(!priority_discovery_scheduled && length(auto_seeds) && SSticker && SSticker.HasRoundStarted())
        priority_discovery_scheduled = TRUE
        addtimer(CALLBACK(src, PROC_REF(process_priority_discovery)), 1)

/datum/ocean_water_compartment_registry/proc/process_priority_discovery()
    priority_discovery_scheduled = FALSE
    if(length(auto_seeds) || auto_job)
        // At most 512 tile visits in this single callback. Do not rediscover
        // an unbounded exterior; ordinary background scanning handles overflow.
        process_auto_discovery(512)

/datum/ocean_water_compartment_registry/proc/process_auto_discovery(budget = OCEAN_WATER_AUTO_SCAN_BUDGET)
    if(!auto_job && length(auto_seeds))
        var/turf/seed = auto_seeds[1]
        auto_seeds.Cut(1, 2)
        auto_seed_lookup -= seed
        if(!turf_to_compartment[seed])
            auto_job = new(seed)
    if(!auto_job)
        return
    if(!auto_job.done)
        var/previous_head = auto_job.head
        auto_job.advance(budget)
        auto_scan_steps += auto_job.head - previous_head
    if(!auto_job.done)
        return
    var/datum/ocean_water_registered_compartment/region = auto_job.region
    if(!auto_job.rejected && length(region.member_turfs) && !turf_to_compartment[region.member_turfs[1]])
        auto_job.region = null
        region.compartment_id = next_compartment_id++
        restore_room_water(region)
        compartments += region
        scan_count++
        auto_registered_rooms++
        for(var/turf/member as anything in region.member_turfs)
            turf_to_compartment[member] = region
            pending_visual_reconcile -= member
            watch_turf(member, region)
        for(var/turf/boundary as anything in region.boundary_turfs)
            watch_turf(boundary, region)
        refresh_ocean_sources(region)
        watch_boundary_doors(region)
        update_transfer_processing(region)
        queue_visual_refresh(region)
        // Walking up the existing shaft graph discovers upper dry rooms only
        // when water makes the lower room relevant to the transfer system.
    else if(auto_job.rejected)
        rejected_scans++
    qdel(auto_job)
    auto_job = null
    reconcile_abandoned_visuals()
    update_simulation_processing()

/datum/ocean_water_compartment_registry/proc/discover_exposed_near(turf/source)
    if(!source)
        return
    var/list/turf/seeds = list(source)
    for(var/direction in GLOB.cardinals)
        var/turf/neighbor = get_step(source, direction)
        if(neighbor && neighbor.z == source.z)
            seeds |= neighbor
    var/turf/below = GET_TURF_BELOW(source)
    if(below)
        seeds |= below
    for(var/turf/seed as anything in seeds)
        var/datum/ocean_water_registered_compartment/room = get_compartment(seed)
        if(room)
            // Existing region may have new ocean geometry at its edge.
            refresh_ocean_sources(room)

/datum/ocean_water_compartment_registry/proc/invalidate_and_discover(turf/changed)
    if(!changed)
        return 0
    var/invalidated = invalidate_near(changed)
    // The old rooms' water has already been credited to surviving coordinates.
    // Rebuild just those near the edit, including both sides of a repaired hull.
    if(invalidated)
        enqueue_auto_seed(changed)
        enqueue_exterior_neighbors(changed)
        for(var/direction in GLOB.cardinals)
            enqueue_auto_seed(get_step(changed, direction))

/datum/ocean_water_compartment_registry/proc/credit_room_water(datum/ocean_water_registered_compartment/region)
    if(!region || region.water_volume_units <= 0)
        return

    // A wall placed through a flooded room may split it; record equal shares
    // on currently valid ORIGINAL floor positions, so whichever partitions
    // are later discovered get their correct shares without re-scanning now.
    // For a destroyed floor, redistribute its share across survivors.
    var/list/turf/survivors = list()
    for(var/old_key as anything in region.water_member_coordinates)
        var/list/position = splittext(old_key, ":")
        var/turf/current = locate(text2num(position[1]), text2num(position[2]), text2num(position[3]))
        if(current && region.can_contain(current, region.scanned_z))
            survivors += current

    if(!length(survivors))
        unassigned_water_units += region.water_volume_units
        region.water_volume_units = 0
        return

    var/share = region.water_volume_units / length(survivors)
    for(var/turf/survivor as anything in survivors)
        var/key = ocean_water_volume_tile_key(survivor)
        var/current_credit = pending_water_by_tile[key] || 0
        pending_water_by_tile[key] = current_credit + share
    region.water_volume_units = 0

/datum/ocean_water_compartment_registry/proc/restore_room_water(datum/ocean_water_registered_compartment/region)
    region.water_capacity_units = length(region.member_turfs) * OCEAN_WATER_UNITS_PER_FLOOR_TILE
    var/restored = 0
    // Only take credits for members of THIS geometry. Other, not-yet-visited
    // split rooms retain their water credits until they are discovered.
    for(var/turf/member as anything in region.member_turfs)
        var/key = ocean_water_volume_tile_key(member)
        region.water_member_coordinates += key
        var/credit = pending_water_by_tile[key]
        if(credit > 0)
            restored += credit
            pending_water_by_tile -= key
    region.water_volume_units = min(restored, region.water_capacity_units)
    if(restored > region.water_capacity_units)
        unassigned_water_units += restored - region.water_capacity_units

/datum/ocean_water_compartment_registry/proc/reset_all_water()
    for(var/datum/ocean_water_registered_compartment/region as anything in compartments)
        region.water_volume_units = 0
    pending_water_by_tile.Cut()
    unassigned_water_units = 0
    for(var/datum/ocean_water_registered_compartment/region as anything in compartments)
        update_ocean_processing(region)
        update_transfer_processing(region)
        queue_visual_refresh(region)

/datum/ocean_water_compartment_registry/proc/get_compartment(turf/start)
    if(!start)
        return null
    var/datum/ocean_water_registered_compartment/cached = turf_to_compartment[start]
    if(cached)
        if(cached.can_contain(start, start.z))
            cache_hits++
            return cached
        // A door/window may have appeared without a turf replacement.
        invalidate_near(start)

    var/datum/ocean_water_registered_compartment/found = new
    if(!found.scan(start, OCEAN_WATER_REGISTRY_MAX_TILES))
        qdel(found)
        return null
    scan_count++
    if(found.hit_safety_limit)
        // NEVER register a partial region. Such a cache would incorrectly
        // partition a physically continuous space.
        rejected_scans++
        qdel(found)
        return null

    found.compartment_id = next_compartment_id++
    restore_room_water(found)
    compartments += found
    for(var/turf/member as anything in found.member_turfs)
        turf_to_compartment[member] = found
        pending_visual_reconcile -= member
        watch_turf(member, found)
    for(var/turf/boundary as anything in found.boundary_turfs)
        watch_turf(boundary, found)
    // B2: A one-time perimeter inspection, not per-turf processing.
    refresh_ocean_sources(found)
    watch_boundary_doors(found)
    update_transfer_processing(found)
    queue_visual_refresh(found)
    return found

/datum/ocean_water_compartment_registry/proc/get_connection(obj/machinery/door/door)
    if(!door)
        return null
    var/datum/ocean_water_registered_connection/cached = door_to_connection[door]
    if(cached)
        return cached
    var/turf/door_turf = get_turf(door)
    if(!door_turf)
        return null

    var/datum/ocean_water_registered_connection/connection = new
    connection.target_door = door
    if(istype(door_turf, /turf/open) && !isopenspaceturf(door_turf) && !isoceanturf(door_turf) && !is_swimmable_ocean_turf(door_turf))
        connection.bridge_floor_tiles = 1

    // Discover at most the cardinally adjacent regions here. Do NOT
    // recursively walk every airlock in every discovered compartment.
    for(var/direction in GLOB.cardinals)
        var/turf/neighbor = get_step(door_turf, direction)
        if(!neighbor || neighbor.z != door_turf.z)
            continue
        var/datum/ocean_water_registered_compartment/side = get_compartment(neighbor)
        if(side)
            connection.adjacent_compartments |= side

    door_to_connection[door] = connection
    if(!observed_bridge_turfs[door_turf])
        RegisterSignal(door_turf, COMSIG_ATOM_ENTERED, PROC_REF(on_registered_turf_entered))
    observed_bridge_turfs[door_turf] = (observed_bridge_turfs[door_turf] || 0) + 1
    for(var/datum/ocean_water_registered_compartment/side as anything in connection.adjacent_compartments)
        side.links |= connection
    // Registered by watch_boundary_doors(), even when the adjacent rooms sleep.
    update_door_water_bridge(connection)
    return connection

/datum/ocean_water_compartment_registry/proc/get_vertical_connection(turf/opening)
    if(!ocean_water_is_vertical_opening(opening))
        return null
    var/datum/ocean_water_registered_vertical_connection/cached = vertical_turf_to_connection[opening]
    if(cached)
        return cached

    // Use a bounded stack walk; otherwise a badly mapped void could trigger
    // an arbitrarily deep series of compartment discoveries.
    var/turf/top = opening
    var/height = 0
    while(TRUE)
        var/turf/above = GET_TURF_ABOVE(top)
        if(!ocean_water_is_vertical_opening(above) || GET_TURF_BELOW(above) != top)
            break
        height++
        if(height >= OCEAN_WATER_MAX_VERTICAL_SHAFT)
            return null
        top = above

    var/list/turf/shaft_turfs = list()
    var/list/datum/ocean_water_registered_compartment/regions = list()
    var/turf/bottom
    var/turf/current = top
    var/ocean_endpoint = FALSE
    var/turf/above_top = GET_TURF_ABOVE(top)
    if(above_top && (isoceanturf(above_top) || is_swimmable_ocean_turf(above_top)))
        ocean_endpoint = TRUE
    while(ocean_water_is_vertical_opening(current))
        if(length(shaft_turfs) >= OCEAN_WATER_MAX_VERTICAL_SHAFT)
            return null
        shaft_turfs += current
        for(var/direction in GLOB.cardinals)
            var/turf/neighbor = get_step(current, direction)
            if(!neighbor || neighbor.z != current.z)
                continue
            if(isoceanturf(neighbor) || is_swimmable_ocean_turf(neighbor))
                ocean_endpoint = TRUE
            var/datum/ocean_water_registered_compartment/side = get_compartment(neighbor)
            if(side)
                regions |= side
        bottom = GET_TURF_BELOW(current)
        if(!bottom || !isopenspaceturf(bottom))
            break
        current = bottom

    if(bottom)
        if(isoceanturf(bottom) || is_swimmable_ocean_turf(bottom))
            ocean_endpoint = TRUE
        else
            var/datum/ocean_water_registered_compartment/bottom_region = get_compartment(bottom)
            if(bottom_region)
                regions |= bottom_region

    var/datum/ocean_water_registered_vertical_connection/link = new
    link.opening_turfs = shaft_turfs
    link.landing_turf = bottom
    link.adjacent_compartments = regions
    link.exposed_to_ocean = ocean_endpoint
    for(var/turf/hole as anything in shaft_turfs)
        vertical_turf_to_connection[hole] = link
    for(var/datum/ocean_water_registered_compartment/region as anything in regions)
        region.vertical_links |= link
        // Observe the shaft, its landing, and immediate exterior neighbors.
        // That catches both a floor patch and an ocean breach beside the shaft.
        for(var/turf/hole as anything in shaft_turfs)
            region.boundary_turfs |= hole
            watch_turf(hole, region)
            for(var/direction in GLOB.cardinals)
                var/turf/side_turf = get_step(hole, direction)
                if(!side_turf || side_turf.z != hole.z)
                    continue
                region.boundary_turfs |= side_turf
                watch_turf(side_turf, region)
        if(above_top)
            region.boundary_turfs |= above_top
            watch_turf(above_top, region)
        if(bottom)
            region.boundary_turfs |= bottom
            watch_turf(bottom, region)
    return link

/datum/ocean_water_compartment_registry/proc/remove_vertical_connection(datum/ocean_water_registered_vertical_connection/link)
    if(!link)
        return
    for(var/turf/hole as anything in link.opening_turfs)
        if(vertical_turf_to_connection[hole] == link)
            vertical_turf_to_connection -= hole
    for(var/datum/ocean_water_registered_compartment/region as anything in link.adjacent_compartments)
        region.vertical_links -= link
    qdel(link)

/datum/ocean_water_compartment_registry/proc/watch_turf(turf/watched, datum/ocean_water_registered_compartment/region)
    if(!watched || !region)
        return
    var/list/regions = turf_to_watching_regions[watched]
    if(!regions)
        regions = list()
        turf_to_watching_regions[watched] = regions
        RegisterSignal(watched, COMSIG_TURF_CHANGE, PROC_REF(on_watched_turf_changed))
        RegisterSignal(watched, COMSIG_ATOM_AFTER_SUCCESSFUL_INITIALIZED_ON, PROC_REF(on_watched_atom_initialized))
        RegisterSignal(watched, COMSIG_ATOM_ENTERED, PROC_REF(on_registered_turf_entered))
    regions |= region

/datum/ocean_water_compartment_registry/proc/unwatch_turf(turf/watched, datum/ocean_water_registered_compartment/region)
    var/list/regions = turf_to_watching_regions[watched]
    if(!regions)
        return
    regions -= region
    if(length(regions))
        return
    turf_to_watching_regions -= watched
    UnregisterSignal(watched, list(COMSIG_TURF_CHANGE, COMSIG_ATOM_AFTER_SUCCESSFUL_INITIALIZED_ON, COMSIG_ATOM_ENTERED))

/datum/ocean_water_compartment_registry/proc/on_registered_turf_entered(turf/source, atom/movable/arrived)
    SIGNAL_HANDLER
    if(!isliving(arrived) || !ocean_water_is_swimmable_environment(source))
        return
    var/mob/living/swimmer = arrived
    if(!swimmer.incorporeal_move)
        if(!swimmer.has_status_effect(/datum/status_effect/ocean_swimming))
            swimmer.apply_status_effect(/datum/status_effect/ocean_swimming)
        else
            var/datum/status_effect/ocean_swimming/effect = swimmer.has_status_effect(/datum/status_effect/ocean_swimming)
            effect.refresh_ocean_immersion()

/datum/ocean_water_compartment_registry/proc/on_watched_turf_changed(turf/source, path, list/new_baseturfs, flags, list/post_change_callbacks)
    SIGNAL_HANDLER
    // COMSIG_TURF_CHANGE fires BEFORE the replacement is installed. Defer
    // invalidation until the callback receives the actual replacement turf.
    // Otherwise a drilled hole could be credited as a surviving floor.
    post_change_callbacks += CALLBACK(src, PROC_REF(invalidate_and_discover))

/datum/ocean_water_compartment_registry/proc/on_watched_atom_initialized(turf/source, atom/movable/created)
    SIGNAL_HANDLER
    if(istype(created, /obj/machinery/door) || istype(created, /obj/structure/window))
        invalidate_near(source)

/datum/ocean_water_compartment_registry/proc/on_cached_door_deleted(obj/machinery/door/source)
    SIGNAL_HANDLER
    var/turf/old_turf = get_turf(source)
    remove_connection(source)
    invalidate_near(old_turf)

/datum/ocean_water_compartment_registry/proc/remove_connection(obj/machinery/door/door)
    var/datum/ocean_water_registered_connection/connection = door_to_connection[door]
    if(!connection)
        return
    door_to_connection -= door
    // Door observation stays registered until the registry is cleared or it dies.
    var/turf/bridge = get_turf(door)
    clear_door_waterfall(door)
    var/obj/effect/ocean_water_surface/surface = door_surface_by_turf[bridge]
    if(surface)
        door_surface_by_turf -= bridge
        qdel(surface)
    if(bridge && observed_bridge_turfs[bridge])
        var/remaining_bridge_watchers = observed_bridge_turfs[bridge] - 1
        if(remaining_bridge_watchers > 0)
            observed_bridge_turfs[bridge] = remaining_bridge_watchers
        else
            observed_bridge_turfs -= bridge
            UnregisterSignal(bridge, COMSIG_ATOM_ENTERED)
        refresh_swimmer_on_turf(bridge)
    for(var/datum/ocean_water_registered_compartment/side as anything in connection.adjacent_compartments)
        side.links -= connection
    qdel(connection)

/datum/ocean_water_compartment_registry/proc/remove_compartment(datum/ocean_water_registered_compartment/region, preserve_visuals = FALSE)
    if(!region)
        return
    // Remove it from the processing set BEFORE the datum is destroyed.
    region.ocean_ingress_edges = 0
    active_transfer_compartments -= region
    update_ocean_processing(region)
    update_simulation_processing()
    // Remove visuals and audio tied to this room before its geometry is replaced.
    stop_audio_for_room(region)
    clear_waterfalls_for_room(region)
    clear_room_visuals(region, preserve_visuals)
    for(var/turf/inlet as anything in region.ocean_inlet_sources)
        current_last_at -= inlet
    // Snapshot volume BEFORE qdel and BEFORE potentially losing any regions.
    // This happens only when geometry is invalidated, not on every water tick.
    credit_room_water(region)
    // First sever its cached door links, including links seen by other regions.
    var/list/obj/machinery/door/doors_to_clear = region.boundary_doors.Copy()
    for(var/datum/ocean_water_registered_connection/link as anything in region.links)
        if(link.target_door)
            doors_to_clear |= link.target_door
    for(var/obj/machinery/door/door as anything in doors_to_clear)
        remove_connection(door)
    var/list/datum/ocean_water_registered_vertical_connection/vertical_to_clear = region.vertical_links.Copy()
    for(var/turf/opening as anything in region.boundary_vertical_openings)
        var/datum/ocean_water_registered_vertical_connection/cached_shaft = vertical_turf_to_connection[opening]
        if(cached_shaft)
            vertical_to_clear |= cached_shaft
    for(var/datum/ocean_water_registered_vertical_connection/shaft as anything in vertical_to_clear)
        remove_vertical_connection(shaft)

    for(var/turf/member as anything in region.member_turfs)
        if(turf_to_compartment[member] == region)
            turf_to_compartment -= member
        unwatch_turf(member, region)
    for(var/turf/boundary as anything in region.boundary_turfs)
        unwatch_turf(boundary, region)
    compartments -= region
    qdel(region)

/datum/ocean_water_compartment_registry/proc/invalidate_near(turf/changed)
    if(!changed)
        return 0
    // A removed wall can MERGE two rooms. A new wall can SPLIT one room.
    // Include all nearby regions, not just the region containing 'changed'.
    var/list/turf/affected_turfs = list(changed)
    for(var/direction in GLOB.cardinals)
        var/turf/neighbor = get_step(changed, direction)
        if(neighbor && neighbor.z == changed.z)
            affected_turfs |= neighbor
    // Rebuild other decks only for a real vertical opening, not whenever an
    // unrelated wall is repaired. The old behavior unnecessarily discarded
    // registered water visuals on decks above/below every wall edit.
    var/turf/above = GET_TURF_ABOVE(changed)
    var/turf/below = GET_TURF_BELOW(changed)
    var/vertical_change = ocean_water_is_vertical_opening(changed) || ocean_water_is_vertical_opening(above) || ocean_water_is_vertical_opening(below) || vertical_turf_to_connection[changed]
    if(vertical_change)
        if(above)
            affected_turfs |= above
        if(below)
            affected_turfs |= below

    var/list/datum/ocean_water_registered_compartment/affected_regions = list()
    var/list/obj/machinery/door/affected_doors = list()
    var/list/datum/ocean_water_registered_vertical_connection/affected_shafts = list()
    for(var/turf/nearby as anything in affected_turfs)
        var/datum/ocean_water_registered_vertical_connection/shaft = vertical_turf_to_connection[nearby]
        if(shaft)
            affected_shafts |= shaft
        var/datum/ocean_water_registered_compartment/region = turf_to_compartment[nearby]
        if(region)
            affected_regions |= region
        var/list/watching_regions = turf_to_watching_regions[nearby]
        if(watching_regions)
            for(var/datum/ocean_water_registered_compartment/watcher as anything in watching_regions)
                affected_regions |= watcher
        for(var/obj/machinery/door/door in nearby)
            affected_doors |= door

    // Do this before deleting regions so no stale connection can survive.
    for(var/obj/machinery/door/door as anything in affected_doors)
        remove_connection(door)
    for(var/datum/ocean_water_registered_vertical_connection/shaft as anything in affected_shafts)
        remove_vertical_connection(shaft)
    for(var/datum/ocean_water_registered_compartment/region as anything in affected_regions)
        remove_compartment(region, TRUE)
    // Fallback cleanup for edits without a replacement discovery queue, e.g.
    // deleting an isolated door. If discovery is still active, cleanup defers.
    if(length(affected_regions))
        addtimer(CALLBACK(src, PROC_REF(reconcile_abandoned_visuals)), 50)
    return length(affected_regions)

/datum/ocean_water_compartment_registry/proc/clear_registry()
    var/list/datum/ocean_water_registered_compartment/to_clear = compartments.Copy()
    for(var/datum/ocean_water_registered_compartment/region as anything in to_clear)
        remove_compartment(region)
    reconcile_abandoned_visuals()
    pending_visual_reconcile.Cut()
    current_last_at.Cut()
    auto_seeds.Cut()
    auto_seed_lookup.Cut()
    priority_discovery_scheduled = FALSE
    if(auto_job)
        qdel(auto_job)
        auto_job = null
    clear_flow_effects()
    for(var/turf/exterior as anything in waterfall_by_turf)
        var/obj/effect/ocean_water_gushing/gush = waterfall_by_turf[exterior]
        if(gush)
            qdel(gush)
    waterfall_by_turf.Cut()
    waterfall_owner_by_turf.Cut()
    for(var/turf/bridge in door_surface_by_turf)
        var/obj/effect/ocean_water_surface/surface = door_surface_by_turf[bridge]
        if(surface)
            qdel(surface)
    door_surface_by_turf.Cut()
    for(var/turf/bridge as anything in observed_bridge_turfs)
        UnregisterSignal(bridge, COMSIG_ATOM_ENTERED)
    observed_bridge_turfs.Cut()
    for(var/obj/machinery/door/door as anything in door_waterfalls)
        clear_door_waterfall(door)
    for(var/obj/machinery/door/door as anything in observed_doors)
        UnregisterSignal(door, list(COMSIG_ATOM_DOOR_OPEN, COMSIG_AIRLOCK_CLOSE, COMSIG_QDELETING))
    observed_doors.Cut()
    // Stale water masks must not survive manual registry resets.
    for(var/turf/source as anything in shaft_surface_by_turf)
        var/obj/effect/ocean_water_shaft/shaft = shaft_surface_by_turf[source]
        if(shaft)
            qdel(shaft)
    shaft_surface_by_turf.Cut()
    // Some door records can exist without a valid floor on either side.
    var/list/remaining_doors = list()
    for(var/obj/machinery/door/door as anything in door_to_connection)
        remaining_doors += door
    for(var/obj/machinery/door/door as anything in remaining_doors)
        remove_connection(door)
    // Vertical links with no cached interior endpoint can still exist.
    var/list/datum/ocean_water_registered_vertical_connection/remaining_shafts = list()
    for(var/turf/hole as anything in vertical_turf_to_connection)
        remaining_shafts |= vertical_turf_to_connection[hole]
    for(var/datum/ocean_water_registered_vertical_connection/shaft as anything in remaining_shafts)
        remove_vertical_connection(shaft)

/datum/ocean_water_compartment_registry/Destroy()
    clear_registry()
    if(ocean_is_processing)
        STOP_PROCESSING(SSprocessing, src)
        ocean_is_processing = FALSE
    return ..()

/// Public API for flooding systems, dynamic ruin generation, and hull breaches.
/// Calls are lazy: no ocean map content needs a custom area or mapper-placed datum.
/proc/ocean_water_get_registered_compartment(turf/interior)
    return GLOB.ocean_water_compartment_registry.get_compartment(interior)

/// B2: Use from an ocean source when its exposed edges are discovered/changed.
/// Direct exterior breaches use the room-volume model, NOT per-turf liquids.
/proc/ocean_water_register_exposed_boundary(turf/exterior)
    if(!exterior)
        return
    GLOB.ocean_water_compartment_registry.enqueue_exterior_neighbors(exterior)

/// Runtime creation of ordinary Z-level holes registers adjacent rooms only
/// if the NEW opening immediately borders a real exterior ocean source.
/// A distant ocean visible at the end of a shaft is not a B2 inlet.
/turf/open/openspace/AfterChange(flags, oldType)
    . = ..()
    if(istype(src, /turf/open/openspace/ocean_column))
        return
    if(!ocean_water_vertical_shaft_exposed(src))
        return
    // Defer past ChangeTurf's post-change callbacks and any credit transfer.
    addtimer(CALLBACK(GLOB.ocean_water_compartment_registry, TYPE_PROC_REF(/datum/ocean_water_compartment_registry, enqueue_exterior_neighbors), src), 1)

/// B1 API. These do not run a flow simulation; they modify one room's storage.
/proc/ocean_water_set_compartment_volume(turf/interior, volume_units)
    var/datum/ocean_water_registered_compartment/room = ocean_water_get_registered_compartment(interior)
    if(!room)
        return null
    return room.set_water_volume_units(volume_units)

/proc/ocean_water_adjust_compartment_volume(turf/interior, delta_units)
    var/datum/ocean_water_registered_compartment/room = ocean_water_get_registered_compartment(interior)
    if(!room)
        return null
    return room.adjust_water_volume_units(delta_units)

/proc/ocean_water_get_registered_door_link(obj/machinery/door/door)
    return GLOB.ocean_water_compartment_registry.get_connection(door)

/// Returns the persistent shaft link for any mapped open-space turf in a multiz stack.
/proc/ocean_water_get_registered_vertical_link(turf/opening)
    return GLOB.ocean_water_compartment_registry.get_vertical_connection(opening)

/// Call after a wall/door/window/floor geometry change not covered by turf signals.
/proc/ocean_water_notify_geometry_changed(turf/changed)
    return GLOB.ocean_water_compartment_registry.invalidate_near(changed)

/// Call when an ocean-exposed turf is created or an underwater ruin is inserted.
/// Registers interior immediately beside it; does not scan the whole Z level.
/proc/ocean_water_register_nearby_interiors(turf/source)
    if(!source)
        return 0
    var/count = 0
    // Handles callers standing on a newly exposed interior tile as well.
    if(ocean_water_get_registered_compartment(source))
        count++
    for(var/direction in GLOB.cardinals)
        var/turf/neighbor = get_step(source, direction)
        if(neighbor && ocean_water_get_registered_compartment(neighbor))
            count++
        if(ocean_water_is_vertical_opening(neighbor))
            ocean_water_get_registered_vertical_link(neighbor)
    if(ocean_water_is_vertical_opening(source))
        ocean_water_get_registered_vertical_link(source)
    var/turf/above = GET_TURF_ABOVE(source)
    if(ocean_water_is_vertical_opening(above))
        ocean_water_get_registered_vertical_link(above)
    return count

/*
 * Stage A3/B1 admin diagnostics. Stored water values do NOT produce visuals,
 * ocean ingress, or water transfer between open rooms at this stage.
 */
ADMIN_VERB(ocean_water_registry_inspect, R_DEBUG, FALSE, "Water: Inspect Registry", "Lazily register the room underfoot and inspect cached door links.", ADMIN_CATEGORY_DEBUG)
    var/turf/starting_turf = get_turf(user.mob)
    var/datum/ocean_water_compartment_registry/registry = GLOB.ocean_water_compartment_registry
    var/datum/ocean_water_registered_compartment/region = registry.get_compartment(starting_turf)
    if(!region)
        to_chat(user, span_warning("Registry: Stand on an interior floor tile. The scan may also have exceeded its safety cap."))
        return
    to_chat(user, span_notice("Registry C[region.compartment_id] (Z [region.scanned_z]): [length(region.member_turfs)] tiles, bounds X [region.min_x]-[region.max_x], Y [region.min_y]-[region.max_y]."))
    var/doors_checked = 0
    for(var/obj/machinery/door/door as anything in region.boundary_doors)
        if(doors_checked >= OCEAN_WATER_PROBE_MAX_DOORS)
            break
        doors_checked++
        var/datum/ocean_water_registered_connection/link = registry.get_connection(door)
        if(!link)
            continue
        var/list/side_names = list()
        for(var/datum/ocean_water_registered_compartment/side as anything in link.adjacent_compartments)
            side_names += "C[side.compartment_id] ([length(side.member_turfs)] tiles)"
        var/turf/door_turf = get_turf(door)
        var/status = link.has_two_sides() ? (link.is_passable() ? "PASSABLE" : "BLOCKED") : "ONE-SIDED"
        var/sides_text = length(side_names) ? jointext(side_names, ", ") : "none"
        to_chat(user, span_notice("Door ([door_turf.x], [door_turf.y], [door_turf.z]): [status]; sides: [sides_text]; bridge [link.bridge_floor_tiles] tile(s)."))
    var/vertical_checked = 0
    var/list/seen_vertical_shafts = list()
    for(var/turf/opening as anything in region.boundary_vertical_openings)
        if(vertical_checked >= OCEAN_WATER_PROBE_MAX_VERTICAL_LINKS)
            break
        var/datum/ocean_water_registered_vertical_connection/shaft = registry.get_vertical_connection(opening)
        if(!shaft)
            to_chat(user, span_warning("Vertical opening ([opening.x], [opening.y], [opening.z]): unable to register shaft (check stack length)."))
            continue
        if(seen_vertical_shafts[shaft])
            continue
        seen_vertical_shafts[shaft] = TRUE
        vertical_checked++
        var/list/side_names = list()
        for(var/datum/ocean_water_registered_compartment/side as anything in shaft.adjacent_compartments)
            side_names += "C[side.compartment_id] (Z [side.scanned_z]; [length(side.member_turfs)] tiles)"
        var/sides_text = length(side_names) ? jointext(side_names, ", ") : "no room"
        var/shaft_state = shaft.has_ocean_endpoint() ? "OCEAN ENDPOINT" : (shaft.has_two_sides() ? "CONNECTED" : "ONE-SIDED")
        to_chat(user, span_notice("Vertical ([opening.x], [opening.y], [opening.z]): [shaft_state]; [length(shaft.opening_turfs)] hole turf(s); sides: [sides_text]."))
    to_chat(user, span_notice("Registry totals: [length(registry.compartments)] regions, [length(registry.door_to_connection)] door links, [length(registry.vertical_turf_to_connection)] vertical hole turfs cached, [registry.scan_count] completed scans, [registry.cache_hits] cache hits, [registry.rejected_scans] oversized scans rejected."))

ADMIN_VERB(ocean_water_registry_invalidate, R_DEBUG, FALSE, "Water: Invalidate Nearby", "Invalidate registered compartments around your turf for geometry-change testing.", ADMIN_CATEGORY_DEBUG)
    var/turf/starting_turf = get_turf(user.mob)
    var/affected = GLOB.ocean_water_compartment_registry.invalidate_near(starting_turf)
    to_chat(user, span_notice("Registry invalidation: [affected] nearby registered compartment(s) cleared. They will be rediscovered on demand."))

ADMIN_VERB(ocean_water_registry_statistics, R_DEBUG, FALSE, "Water: Registry Statistics", "Inspect compartment registry size without scanning geometry.", ADMIN_CATEGORY_DEBUG)
    var/datum/ocean_water_compartment_registry/registry = GLOB.ocean_water_compartment_registry
    var/list/datum/ocean_water_registered_vertical_connection/unique_shafts = list()
    for(var/turf/hole as anything in registry.vertical_turf_to_connection)
        unique_shafts |= registry.vertical_turf_to_connection[hole]
    to_chat(user, span_notice("Registry: [length(registry.compartments)] compartments; [length(registry.door_to_connection)] door links; [length(unique_shafts)] vertical shafts ([length(registry.vertical_turf_to_connection)] hole turfs); [length(registry.turf_to_watching_regions)] watched turfs; [registry.scan_count] scans; [registry.cache_hits] cache hits; [registry.rejected_scans] rejected oversized scans."))


/*
 * Stage B1 volume diagnostics. Admin-only so no gameplay flooding is enabled.
 */
ADMIN_VERB(ocean_water_volume_inspect, R_DEBUG, FALSE, "Water: Inspect Volume", "Display stored water and capacity in the room underfoot.", ADMIN_CATEGORY_DEBUG)
    var/datum/ocean_water_compartment_registry/registry = GLOB.ocean_water_compartment_registry
    var/datum/ocean_water_registered_compartment/room = registry.get_compartment(get_turf(user.mob))
    if(!room)
        to_chat(user, span_warning("Water volume: Stand on an interior floor to inspect a compartment."))
        return
    var/fill_percent = round(room.get_fill_fraction() * 100, 0.1)
    to_chat(user, span_notice("Water volume C[room.compartment_id]: [round(room.water_volume_units, 0.1)] / [room.water_capacity_units] WU ([fill_percent]% full); [length(room.member_turfs)] floor tiles; Z [room.scanned_z]."))
    to_chat(user, span_notice("Unregistered water credits: [length(registry.pending_water_by_tile)] tile keys; overflow escrow: [round(registry.unassigned_water_units, 0.1)] WU. Door bridge tiles do not count toward either room's B1 capacity."))

ADMIN_VERB(ocean_water_volume_set_fill, R_DEBUG, FALSE, "Water: Set Fill Percentage", "Set compartment water volume for testing.", ADMIN_CATEGORY_DEBUG)
    var/percentage = input(user, "Target room fill percentage (0 to 100):", "Compartment Water Test", 25) as num|null
    if(isnull(percentage))
        return
    var/datum/ocean_water_registered_compartment/room = ocean_water_get_registered_compartment(get_turf(user.mob))
    if(!room)
        to_chat(user, span_warning("Water volume: Stand on an interior floor."))
        return
    room.set_water_volume_units(room.water_capacity_units * clamp(percentage, 0, 100) / 100)
    to_chat(user, span_notice("Water volume C[room.compartment_id] set to [round(room.water_volume_units, 0.1)] / [room.water_capacity_units] WU ([round(room.get_fill_fraction() * 100, 0.1)]%). Native liquid-depth visuals refresh according to fill level."))
    log_admin("[key_name(user)] set B1 water in C[room.compartment_id] to [round(room.water_volume_units, 0.1)] WU")

ADMIN_VERB(ocean_water_volume_adjust, R_DEBUG, FALSE, "Water: Adjust Volume", "Add or remove stored water in WU (negative value drains).", ADMIN_CATEGORY_DEBUG)
    var/delta_units = input(user, "Water to add in WU (negative to drain):", "Compartment Water Test", 100) as num|null
    if(isnull(delta_units))
        return
    var/datum/ocean_water_registered_compartment/room = ocean_water_get_registered_compartment(get_turf(user.mob))
    if(!room)
        to_chat(user, span_warning("Water volume: Stand on an interior floor."))
        return
    var/previous_volume = room.water_volume_units
    room.adjust_water_volume_units(delta_units)
    var/change = room.water_volume_units - previous_volume
    to_chat(user, span_notice("Water volume C[room.compartment_id]: [round(room.water_volume_units, 0.1)] / [room.water_capacity_units] WU ([round(room.get_fill_fraction() * 100, 0.1)]%). Applied [round(change, 0.1)] WU (clamped to room capacity)."))
    log_admin("[key_name(user)] adjusted B1 water in C[room.compartment_id] by [round(change, 0.1)] WU")

ADMIN_VERB(ocean_water_volume_reset_all, R_DEBUG, FALSE, "Water: Reset Test Volumes", "Clear all B1 diagnostic water, including deferred water credits.", ADMIN_CATEGORY_DEBUG)
    var/confirmation = alert(user, "Clear ALL stored B1 water volumes in the registry, including unregistered-room credits and overflow escrow?", "Reset Water Test", "Cancel", "Reset")
    if(confirmation != "Reset")
        return
    GLOB.ocean_water_compartment_registry.reset_all_water()
    log_admin("[key_name(user)] reset all B1 diagnostic compartment water volumes")
    to_chat(user, span_notice("All B1 test water volumes and deferred credits cleared."))

/* Stage C diagnostics and presentation toggle */
ADMIN_VERB(ocean_water_effects_inspect, R_DEBUG, FALSE, "Water: Inspect Flood Effects", "Inspect sound, force and visual update activity.", ADMIN_CATEGORY_DEBUG)
    var/datum/ocean_water_compartment_registry/registry = GLOB.ocean_water_compartment_registry
    var/datum/ocean_water_registered_compartment/room = registry.get_compartment(get_turf(user.mob))
    if(!room)
        to_chat(user, span_warning("Flood effects: Stand on an interior floor."))
        return
    to_chat(user, span_notice("Flood effects in C[room.compartment_id]: [round(room.get_fill_fraction() * 100, 0.1)]% fill; visual substeps [room.visual_band]/[OCEAN_WATER_VISUAL_BANDS], native state [ocean_water_depth_state(room.get_fill_fraction())]; sources [length(room.ocean_inlet_sources)]."))
    to_chat(user, span_notice("Effects [registry.effects_enabled ? "ON" : "OFF"]; visual update queue [length(registry.active_visual_compartments)] rooms, [length(registry.surface_by_turf)] wet floor tiles, [length(registry.door_surface_by_turf)] doorway bridges, [length(registry.shaft_surface_by_turf)] shaft tiles; [length(registry.waterfall_by_turf)] waterfall sprites; [registry.current_events] currents, [registry.current_atoms_pushed] forced steps, [registry.audio_events] flow starts, [length(registry.audio_emitters)] flow sources, [length(registry.listener_audio)] listener mixes."))

ADMIN_VERB(ocean_water_effects_toggle, R_DEBUG, FALSE, "Water: Toggle Flood Effects", "Enable/disable floodwater visuals, sounds and currents.", ADMIN_CATEGORY_DEBUG)
    var/datum/ocean_water_compartment_registry/registry = GLOB.ocean_water_compartment_registry
    registry.effects_enabled = !registry.effects_enabled
    if(!registry.effects_enabled)
        registry.clear_flow_effects()
        for(var/datum/ocean_water_registered_compartment/room as anything in registry.compartments)
            registry.clear_waterfalls_for_room(room)
    else
        for(var/datum/ocean_water_registered_compartment/room as anything in registry.active_ocean_compartments)
            registry.show_waterfalls_for_room(room)
    for(var/datum/ocean_water_registered_compartment/room as anything in registry.compartments)
        registry.queue_visual_refresh(room)
    to_chat(user, span_notice("Floodwater visuals, current forces and sounds [registry.effects_enabled ? "ENABLED" : "DISABLED"]."))

/* Stage B3 diagnostics: observe conservation and connection behavior. */
ADMIN_VERB(ocean_water_transfer_inspect, R_DEBUG, FALSE, "Water: Inspect Transfers", "Inspect adjacent room transfer, connection state and moved water units.", ADMIN_CATEGORY_DEBUG)
    var/turf/underfoot = get_turf(user.mob)
    var/datum/ocean_water_compartment_registry/registry = GLOB.ocean_water_compartment_registry
    var/datum/ocean_water_registered_compartment/region = registry.get_compartment(underfoot)
    if(!region)
        to_chat(user, span_warning("Water transfers: Stand on an interior floor tile."))
        return
    registry.ensure_transfer_links(region)
    to_chat(user, span_notice("Transfer C[region.compartment_id] (Z [region.scanned_z]): [round(region.water_volume_units, 0.1)] / [region.water_capacity_units] WU ([round(region.get_fill_fraction() * 100, 0.1)]%); [length(region.links)] door links; [length(region.vertical_links)] shaft links."))
    for(var/datum/ocean_water_registered_connection/link as anything in region.links)
        var/list/neighbor_labels = list()
        for(var/datum/ocean_water_registered_compartment/neighbor as anything in link.adjacent_compartments)
            neighbor_labels += "C[neighbor.compartment_id]=[round(neighbor.water_volume_units, 0.1)]/[neighbor.water_capacity_units] WU"
        to_chat(user, span_notice("Door [link.is_passable() ? "OPEN" : "CLOSED"]: [jointext(neighbor_labels, ", ")]."))
    for(var/datum/ocean_water_registered_vertical_connection/shaft as anything in region.vertical_links)
        var/list/vertical_labels = list()
        for(var/datum/ocean_water_registered_compartment/neighbor as anything in shaft.adjacent_compartments)
            vertical_labels += "C[neighbor.compartment_id](Z[neighbor.scanned_z])=[round(neighbor.water_volume_units, 0.1)]/[neighbor.water_capacity_units] WU"
        to_chat(user, span_notice("Shaft: [jointext(vertical_labels, ", ")]; [length(shaft.opening_turfs)] hole turf(s). Ocean endpoint flag is diagnostic only, not a B3 source."))
    to_chat(user, span_notice("Global B3: [length(registry.active_transfer_compartments)] wet rooms, [registry.transfer_processed_ticks] transfer ticks, [round(registry.transfer_last_tick_moved_units, 0.1)] WU moved last tick, [round(registry.transfer_total_moved_units, 0.1)] WU moved cumulatively."))

ADMIN_VERB(ocean_water_transfer_toggle, R_DEBUG, FALSE, "Water: Toggle Transfers", "Pause/resume door and shaft water transfers for controlled testing.", ADMIN_CATEGORY_DEBUG)
    var/datum/ocean_water_compartment_registry/registry = GLOB.ocean_water_compartment_registry
    registry.transfer_processing_enabled = !registry.transfer_processing_enabled
    var/list/datum/ocean_water_registered_compartment/registered = registry.compartments.Copy()
    for(var/datum/ocean_water_registered_compartment/room as anything in registered)
        registry.update_transfer_processing(room)
    to_chat(user, span_notice("Compartment water transfers are now [registry.transfer_processing_enabled ? "ENABLED" : "PAUSED"]."))
    log_admin("[key_name(user)] toggled compartment water transfers [registry.transfer_processing_enabled]")

/* Stage B2 admin diagnostics */
ADMIN_VERB(ocean_water_ingress_inspect, R_DEBUG, FALSE, "Water: Inspect Ocean Ingress", "Inspect direct-ocean breach rate and live room volume.", ADMIN_CATEGORY_DEBUG)
    var/datum/ocean_water_compartment_registry/registry = GLOB.ocean_water_compartment_registry
    var/datum/ocean_water_registered_compartment/room = registry.get_compartment(get_turf(user.mob))
    if(!room)
        to_chat(user, span_warning("Ocean ingress: Stand on an interior room floor."))
        return
    registry.refresh_ocean_sources(room)
    var/rate = min(room.ocean_ingress_edges * OCEAN_WATER_INGRESS_WU_PER_SECOND, OCEAN_WATER_INGRESS_MAX_WU_PER_SECOND)
    var/remaining = max(0, room.water_capacity_units - room.water_volume_units)
    var/fill = round(room.get_fill_fraction() * 100, 0.1)
    var/eta = rate ? "[round(remaining / rate, 0.1)] s at constant rate" : "no direct exterior inlet"
    to_chat(user, span_notice("Ocean ingress C[room.compartment_id]: [round(room.water_volume_units, 0.1)] / [room.water_capacity_units] WU ([fill]%); horizontal edges [room.ocean_horizontal_edges]; exposed Z-hole openings [room.ocean_vertical_openings]; total inlet edges [room.ocean_ingress_edges]; rate [rate] WU/s; estimated remaining: [eta]."))
    to_chat(user, span_notice("Ingress processing: [registry.ocean_processing_enabled ? "ENABLED" : "PAUSED"]; [length(registry.active_ocean_compartments)] active rooms; [registry.ocean_processed_ticks] simulation ticks; [round(registry.ocean_total_added_units, 0.1)] WU entered globally."))
    to_chat(user, span_notice("B3 transfer: [length(registry.active_transfer_compartments)] wet rooms monitored; [round(registry.transfer_total_moved_units, 0.1)] WU moved across links (ocean-driven flow also counted in inlet total)."))

ADMIN_VERB(ocean_water_ingress_toggle, R_DEBUG, FALSE, "Water: Toggle Ocean Ingress", "Pause/resume simulated ocean inflow globally for testing.", ADMIN_CATEGORY_DEBUG)
    var/datum/ocean_water_compartment_registry/registry = GLOB.ocean_water_compartment_registry
    registry.ocean_processing_enabled = !registry.ocean_processing_enabled
    var/list/datum/ocean_water_registered_compartment/registered = registry.compartments.Copy()
    for(var/datum/ocean_water_registered_compartment/room as anything in registered)
        registry.update_ocean_processing(room)
    to_chat(user, span_notice("Direct-ocean compartment ingress is now [registry.ocean_processing_enabled ? "ENABLED" : "PAUSED"]."))
    log_admin("[key_name(user)] toggled direct ocean ingress [registry.ocean_processing_enabled]")

ADMIN_VERB(ocean_water_c3_stats, R_DEBUG, FALSE, "Water: C3 Performance", "Inspect automatic discovery queue, registered rooms and active flow work.", ADMIN_CATEGORY_DEBUG)
    var/datum/ocean_water_compartment_registry/registry = GLOB.ocean_water_compartment_registry
    to_chat(user, span_notice("C3: [length(registry.compartments)] registered compartments ([registry.auto_registered_rooms] discovered automatically), [length(registry.auto_seeds)] queued seeds, scan job [registry.auto_job ? "active" : "idle"], scanned steps [registry.auto_scan_steps], rejected rooms [registry.rejected_scans]."))
    to_chat(user, span_notice("Activity: ocean [length(registry.active_ocean_compartments)] rooms, transfer [length(registry.active_transfer_compartments)] rooms, visual queue [length(registry.active_visual_compartments)] rooms, [length(registry.audio_emitters)] flow audio sources, [length(registry.listener_audio)] listening clients; [length(registry.waterfall_by_turf)] hull and [length(registry.door_waterfalls)] door waterfalls."))

/* C3.2 focused diagnostics. These do not mutate or register geometry. */
ADMIN_VERB(ocean_water_debug_audio_sources, R_DEBUG, FALSE, "Water: Inspect Flow Audio", "Show current localized sound sources and their last reported flow.", ADMIN_CATEGORY_DEBUG)
    var/datum/ocean_water_compartment_registry/registry = GLOB.ocean_water_compartment_registry
    to_chat(user, span_notice("Flow audio: [length(registry.audio_emitters)] sources; [length(registry.listener_audio)] listener mixes; world time [world.time] ds."))
    for(var/key as anything in registry.audio_emitters)
        var/datum/ocean_water_audio_emitter/emitter = registry.audio_emitters[key]
        if(!emitter)
            continue
        var/turf/source = emitter.source
        var/coords = source ? "([source.x],[source.y],[source.z])" : "deleted"
        var/room_id = emitter.room ? "C[emitter.room.compartment_id]" : "none"
        to_chat(user, span_notice("[key]: [emitter.sound_type] at [coords], rate [round(emitter.rate, 0.1)] WU/s, room [room_id], age [world.time - emitter.last_active_ds] ds."))

ADMIN_VERB(ocean_water_debug_waterfall, R_DEBUG, FALSE, "Water: Inspect Waterfalls", "Inspect breach animation tile placement, direction and sprite dimensions.", ADMIN_CATEGORY_DEBUG)
    var/datum/ocean_water_compartment_registry/registry = GLOB.ocean_water_compartment_registry
    to_chat(user, span_notice("Active hull waterfalls: [length(registry.waterfall_by_turf)]; doorway waterfalls: [length(registry.door_waterfalls)]. Expected SOUTH-oriented icon state: water_gushing. Alpha: 175; layer: BELOW_OPEN_DOOR_LAYER."))
    for(var/obj/machinery/door/door as anything in registry.door_waterfalls)
        var/obj/effect/ocean_water_gushing/door_gush = registry.door_waterfalls[door]
        if(!door_gush)
            continue
        var/turf/bridge = get_turf(door)
        if(bridge)
            to_chat(user, span_notice("Door waterfall at ([bridge.x],[bridge.y],[bridge.z]), visual dir [door_gush.dir]; flow age [world.time - (registry.door_waterfall_last_flow_ds[door] || 0)] ds."))
    for(var/turf/inlet as anything in registry.waterfall_by_turf)
        var/obj/effect/ocean_water_gushing/gush = registry.waterfall_by_turf[inlet]
        if(!gush)
            continue
        var/datum/ocean_water_registered_compartment/room = registry.waterfall_owner_by_turf[inlet]
        var/room_id = room ? "C[room.compartment_id]" : "none"
        var/turf/exterior
        var/inward = 0
        if(room)
            exterior = room.ocean_inlet_exteriors[inlet]
            inward = room.ocean_inlet_directions[inlet]
        var/source_text = exterior ? "([exterior.x],[exterior.y],[exterior.z])" : "unknown"
        to_chat(user, span_notice("Waterfall [room_id]: visual inlet ([inlet.x],[inlet.y],[inlet.z]); exterior source [source_text]; inward [dir2text(inward)]; sprite at ([gush.x],[gush.y],[gush.z]); pixel shift ([gush.pixel_x],[gush.pixel_y])."))

#undef OCEAN_WATER_INGRESS_WU_PER_SECOND
#undef OCEAN_WATER_INGRESS_MAX_DELTA_SECONDS
#undef OCEAN_WATER_INGRESS_MAX_WU_PER_SECOND
#undef OCEAN_WATER_DOOR_FLOW_WU_PER_SECOND
#undef OCEAN_WATER_VERTICAL_DOWN_WU_PER_SECOND
#undef OCEAN_WATER_VERTICAL_UP_WU_PER_SECOND
#undef OCEAN_WATER_VERTICAL_RISE_THRESHOLD
#undef OCEAN_WATER_REGISTRY_MAX_TILES
#undef OCEAN_WATER_PROBE_MAX_TILES
#undef OCEAN_WATER_PROBE_MAX_REGIONS
#undef OCEAN_WATER_PROBE_MAX_DOORS
#undef OCEAN_WATER_PROBE_MAX_VERTICAL_LINKS
#undef OCEAN_WATER_MAX_VERTICAL_SHAFT
#undef OCEAN_WATER_UNITS_PER_FLOOR_TILE
#undef OCEAN_WATER_VISUAL_BANDS
#undef OCEAN_WATER_VISUAL_TILES_PER_TICK
#undef OCEAN_WATER_FLOW_RADIUS
#undef OCEAN_WATER_FLOW_MAX_MOVABLES
#undef OCEAN_WATER_FLOW_THROTTLE_DS
#undef OCEAN_WATER_AUDIO_IDLE_DS
#undef OCEAN_WATER_MAX_AUDIO_LOOPS

#undef OCEAN_WATER_AUDIO_MAX_RANGE
#undef OCEAN_WATER_AUDIO_BREACH_CHANNEL
#undef OCEAN_WATER_AUDIO_TRANSFER_CHANNEL
#undef OCEAN_WATER_AUDIO_ROOM_CHANNEL
#undef OCEAN_WATER_AUTO_SCAN_BUDGET
#undef OCEAN_WATER_AUTO_SCAN_MAX_SEEDS
#undef OCEAN_WATER_FULL_SWIM_FRACTION
