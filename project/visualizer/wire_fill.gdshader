shader_type spatial;
render_mode cull_disabled, unshaded;

// Full length of the wire box in local space (= BoxMesh size.x). Set once per wire.
uniform float wire_length = 1.0;

// Fraction of the wire that has been "painted" with the new voltage color.
// 0.0 = cursor just started (nothing painted yet)
// 1.0 = cursor has passed completely (whole wire shows new color)
uniform float fill_fraction : hint_range(0.0, 1.0) = 1.0;

// 1 = fill sweeps from the p1 end (local x = -wire_length/2) toward p2.
// 0 = fill sweeps from the p2 end (local x = +wire_length/2) toward p1.
// Using int instead of bool for broadest Godot 4 compatibility.
uniform int fill_from_p1 = 1;

// Voltage color and brightness for the region the cursor has already passed
// (the NEW voltage — the signal has arrived here).
uniform vec3  color_behind  : source_color = vec3(0.0, 0.0, 0.0);
uniform float energy_behind : hint_range(0.0, 5.0) = 0.0;

// Voltage color and brightness for the region the cursor hasn't reached yet
// (the OLD voltage — signal hasn't arrived here yet).
uniform vec3  color_ahead   : source_color = vec3(0.0, 0.0, 0.0);
uniform float energy_ahead  : hint_range(0.0, 5.0) = 0.0;

// Position along the wire interpolated from vertex() to fragment().
// 0.0 = p1 end,  1.0 = p2 end.
varying float wire_pos;

void vertex() {
	// VERTEX.x is in local/model space.
	// BoxMesh is centered at origin: x spans [-wire_length/2, +wire_length/2].
	// Remap to [0, 1].
	wire_pos = VERTEX.x / wire_length + 0.5;
}

void fragment() {
	// Determine if this fragment is in the already-filled (cursor-passed) region.
	float in_filled;
	if (fill_from_p1 == 1) {
		// Fill sweeps from wire_pos=0 (p1) toward wire_pos=fill_fraction.
		// step(edge, x) returns 1 when x >= edge.
		// step(wire_pos, fill_fraction) = 1 when fill_fraction >= wire_pos.
		in_filled = step(wire_pos, fill_fraction);
	} else {
		// Fill sweeps from wire_pos=1 (p2) down to wire_pos=(1 - fill_fraction).
		in_filled = step(1.0 - fill_fraction, wire_pos);
	}

	vec3  col = mix(color_ahead,  color_behind,  in_filled);
	float ene = mix(energy_ahead, energy_behind, in_filled);

	// render_mode unshaded: ALBEDO is the final color, no lighting applied.
	// Small constant base keeps the wire faintly visible at zero energy.
	// Kept low (0.08) so the vivid spectral voltage colours are not washed out.
	ALBEDO = vec3(0.08, 0.08, 0.08) + col * ene;
}
