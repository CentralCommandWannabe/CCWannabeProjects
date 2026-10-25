# BarotraumaStation combined C4.5 + D0 + D1 + D2 integration

Base commit: dd2ff3e83a4f2d137f0246e665262c470cdfaa64. This is an **uncompiled experimental integration**.

## Implemented
* C4.5: matching room/door/shaft opacity by liquid depth state; stronger flashlight-independent ambient motes; subdued breach rush tiles; retain fullscreen/parallax/refraction visual attachments between submerged Zs; verify underwater rumble via SoundQuery every 5s and restart when necessary.
* D0: per-transfer water conservation assertion counter, bounded registered-compartment invariant and workload reporting via **Water: D0 Contracts**.
* D1: shallow-ocean depth estimated from linked Z levels (5m top layer, 25m/deck), estimated ambient hydrostatic pressure, idealized isothermal compressible trapped air, gradual depth-dependent blue haze, **Water: D1 Pressure** diagnostic.
* D2: bounded pressure-based exterior inflow, pressure-driven horizontal links, air equalization on open doors, gravity / pressure-driven vertical transfer that only moves existing stored WU. Currents and local audio still use actual transferred WU/s.
* Fix test-map JSON to reference the actual checked-in four-level DMM file.

## Important model limitations
This remains a room-averaged approximation, not CFD. The 25m/deck value is illustrative and must be calibrated for final maps. There is no modeled air venting to the ocean, atmos gas exchange, breach aperture geometry or real buoyancy, so trapped-air pockets can prevent rooms reaching 100% fill. No new sprite assets were authored. Fluid properties must remain decoupled from pixel-space tile overlays.

## One comprehensive local test pass
1. Compile with BUILD.bat and check warnings/runtimes.
2. Load **barotraumastation_multiz_poc.json** and confirm the correct 4-level map.
3. Flood one and two exposed rooms, inspect D1 pressures and compare total WU with external ingress.
4. Open and close an airlock between rooms with unequal water levels. Verify conservation in D0; inspect currents.
5. Flood and drain a vertical shaft and confirm no phantom ocean source in upper rooms.
6. Travel between submerged Z levels, test flashlight/refraction/parallax independently and seabed bubbles.
7. Sit submerged without moving for several minutes. The rumble should remain audible.
8. Verify floodwater color/alpha matching on floors, airlock thresholds, shafts, and breach water.
9. Stress simultaneous breaches to check SSprocessing time and sound/particle caps.

**Do not merge before compilation and in-game verification.**