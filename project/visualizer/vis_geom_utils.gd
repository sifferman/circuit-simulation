class_name VisGeomUtils
extends RefCounted

## Geometry constants (xschem symbol units → 3D path fractions).
const CHANNEL_FRAC: float = 0.3125   # 12.5 / 40
const STUB_FRAC:    float = 7.0 / 12.0  # 17.5 / 30
const VTH:          float = 0.5      # MOS threshold voltage (sky130 approx.)


## 6-waypoint path through the transistor symbol body:
##   pin → stub_turn → enter_channel → traverse_channel → exit_channel → pin
static func transistor_path(p_from: Vector3, p_to: Vector3, p_gate: Vector3) -> Array:
	var ds_mid    := (p_from + p_to) * 0.5
	var to_gate   := (p_gate - ds_mid).normalized()
	var d_gate    := (p_gate - ds_mid).length()
	var ch_off    := to_gate * (d_gate * CHANNEL_FRAC)
	var stub_from := ds_mid.lerp(p_from, STUB_FRAC)
	var stub_to   := ds_mid.lerp(p_to,   STUB_FRAC)
	return [
		p_from,
		stub_from,
		stub_from + ch_off,
		stub_to   + ch_off,
		stub_to,
		p_to,
	]


## Pre-computes cumulative arc-lengths for path_eval.
static func path_cum_lengths(pts: Array) -> Array:
	var result: Array = []
	var acc: float = 0.0
	for i: int in range(1, pts.size()):
		acc += (pts[i] as Vector3).distance_to(pts[i - 1] as Vector3)
		result.append(acc)
	return result


## Evaluates piecewise-linear path at normalized t ∈ [0, 1].
static func path_eval(pts: Array, cum: Array, t: float) -> Vector3:
	if pts.size() < 2:
		return pts[0] as Vector3 if pts.size() > 0 else Vector3.ZERO
	var dist: float = t * float(cum.back())
	for i: int in range(cum.size()):
		if dist <= float(cum[i]) + 1e-6:
			var d0: float = 0.0 if i == 0 else float(cum[i - 1])
			var s:  float = (dist - d0) / maxf(float(cum[i]) - d0, 1e-6)
			return (pts[i] as Vector3).lerp(pts[i + 1] as Vector3, s)
	return pts.back() as Vector3


## Returns t ∈ (0, 1) if p lies strictly inside segment a→b, else -1.
static func seg_interior_t(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab     := b - a
	var len_sq := ab.length_squared()
	if len_sq < 0.25:
		return -1.0
	var t: float = (p - a).dot(ab) / len_sq
	if t < 0.001 or t > 0.999:
		return -1.0
	if a.lerp(b, t).distance_squared_to(p) > 0.25:
		return -1.0
	return t


## Splits wires whose interiors are pierced by another wire's endpoint.
static func split_wires_at_junctions(wires: Array) -> Array:
	var endpoints: Array[Vector2] = []
	for w: Dictionary in wires:
		endpoints.append(Vector2(float(w["x1"]), float(w["y1"])))
		endpoints.append(Vector2(float(w["x2"]), float(w["y2"])))

	var result: Array = []
	for w: Dictionary in wires:
		var a := Vector2(float(w["x1"]), float(w["y1"]))
		var b := Vector2(float(w["x2"]), float(w["y2"]))

		var ts: Array[float] = []
		for ep: Vector2 in endpoints:
			var t: float = seg_interior_t(ep, a, b)
			if t < 0.0:
				continue
			var dup: bool = false
			for prev_t: float in ts:
				if absf(prev_t - t) < 0.001:
					dup = true
					break
			if not dup:
				ts.append(t)

		if ts.is_empty():
			result.append(w)
			continue

		ts.sort()
		var prev := a
		for t: float in ts:
			var mid := a.lerp(b, t)
			var seg: Dictionary = w.duplicate()
			seg["x1"] = prev.x;  seg["y1"] = prev.y
			seg["x2"] = mid.x;   seg["y2"] = mid.y
			result.append(seg)
			prev = mid
		var tail: Dictionary = w.duplicate()
		tail["x1"] = prev.x;  tail["y1"] = prev.y
		tail["x2"] = b.x;     tail["y2"] = b.y
		result.append(tail)

	return result


## Strips v(...) wrapper, subcircuit prefix, and '#' from a vector name.
## "v(x1.clk)" → "clk",  "#net1" → "net1"
static func normalize_vec_name(name: String) -> String:
	var n: String = name.strip_edges().to_lower()
	if n.begins_with("v(") and n.ends_with(")"):
		n = n.substr(2, n.length() - 3)
	var dot: int = n.rfind(".")
	if dot >= 0:
		n = n.substr(dot + 1)
	n = n.replace("#", "")
	return n


## Parses a SPICE subcircuit file and extracts D/G/S/B connections per transistor.
static func parse_spice_transistors(path: String) -> Dictionary:
	var result: Dictionary = {}
	var text: String = FileAccess.get_file_as_string(path)
	if text.is_empty():
		return result

	for raw_line: String in text.split("\n"):
		var line: String = raw_line.strip_edges()
		if line.is_empty() or line.begins_with("*") or line.begins_with(".") or line.begins_with("+"):
			continue
		if not line.to_lower().begins_with("x"):
			continue
		var parts: PackedStringArray = line.split(" ", false)
		if parts.size() < 6:
			continue
		var model: String = str(parts[5]).to_lower()
		if not ("pfet" in model or "nfet" in model or "pmos" in model or "nmos" in model):
			continue
		var comp_name: String = str(parts[0]).substr(1)   # "XM7" → "M7"
		var is_pmos: bool = "pfet" in model or "pmos" in model
		result[comp_name] = {
			"d":    str(parts[1]).to_lower(),
			"g":    str(parts[2]).to_lower(),
			"s":    str(parts[3]).to_lower(),
			"b":    str(parts[4]).to_lower(),
			"type": "pfet" if is_pmos else "nfet",
		}

	return result
