class_name WireGraph
extends RefCounted

## Assigns each wire-cursor entry a BFS hop-distance from the nearest input pin
## and records which endpoint is the "source" side.
##
## Usage:
##   var net_cascade := WireGraph.build(wire_cursors, input_positions, scale_factor)
##
## wire_cursors is modified in-place: each Dictionary gains:
##   "hop_dist"   int  — 0 = directly connected to an input pin
##   "source_end" int  — 0 = p1 is upstream, 1 = p2 is upstream
##
## Returns a net_cascade Dictionary keyed by net label:
##   { trigger_t, max_hop, color_old, color_new, energy_old, energy_new }


static func build(
		wire_cursors: Array,
		input_positions: Array,
		scale_factor: float) -> Dictionary:

	var snap: float       = scale_factor * 2.5   # half a schematic grid step
	var net_cascade: Dictionary = {}

	# Group cursor indices by net label.
	var net_groups: Dictionary = {}
	for i: int in range(wire_cursors.size()):
		var net: String = wire_cursors[i]["net"]
		if not net_groups.has(net):
			net_groups[net] = []
		(net_groups[net] as Array).append(i)

	for net: String in net_groups.keys():
		var max_hop: int = _bfs_net(wire_cursors, net_groups[net] as Array, input_positions, snap)
		net_cascade[net] = {
			"trigger_t":  -999.0,
			"max_hop":    max_hop,
			"color_old":  Color.BLACK,
			"color_new":  Color.BLACK,
			"energy_old": 0.0,
			"energy_new": 0.0,
		}

	return net_cascade


# BFS through one net's cursor segments.  Modifies wire_cursors in-place.
# Returns the maximum hop distance reached.
static func _bfs_net(
		wire_cursors: Array,
		indices: Array,
		input_positions: Array,
		snap: float) -> int:

	for i: int in indices:
		wire_cursors[i]["hop_dist"]   = 999
		wire_cursors[i]["source_end"] = 0

	# Endpoint key → list of cursor indices in this net.
	var ep_map: Dictionary = {}
	for i: int in indices:
		var wc: Dictionary = wire_cursors[i]
		for p: Vector3 in [wc["p1"] as Vector3, wc["p2"] as Vector3]:
			var key: String = _snap_key(p, snap)
			if not ep_map.has(key):
				ep_map[key] = []
			(ep_map[key] as Array).append(i)

	# Seed: cursor endpoint nearest to any input pin.
	var queue:  Array = []
	var best_d: float = 1e9
	for inp: Vector3 in input_positions:
		for i: int in indices:
			var wc: Dictionary = wire_cursors[i]
			for end_idx: int in [0, 1]:
				var p: Vector3 = wc["p1"] if end_idx == 0 else wc["p2"]
				var d: float   = inp.distance_to(p)
				if d < best_d:
					best_d = d
					queue.clear()
					for ii: int in indices:
						wire_cursors[ii]["hop_dist"] = 999
					wire_cursors[i]["hop_dist"]   = 0
					wire_cursors[i]["source_end"] = end_idx
					queue.append([i, end_idx])

	# Fallback: no input pin nearby — start from first cursor, p1 side.
	if queue.is_empty() and indices.size() > 0:
		var i0: int = indices[0]
		wire_cursors[i0]["hop_dist"]   = 0
		wire_cursors[i0]["source_end"] = 0
		queue.append([i0, 0])

	var max_hop: int = 0
	var head:    int = 0
	while head < queue.size():
		var item:  Array = queue[head]; head += 1
		var ci:    int   = item[0]
		var entry: int   = item[1]
		var hop:   int   = wire_cursors[ci]["hop_dist"]
		max_hop = maxi(max_hop, hop)

		# Propagate out through the far endpoint.
		var exit_end: int     = 1 - entry
		var exit_p:   Vector3 = wire_cursors[ci]["p2"] if exit_end == 1 else wire_cursors[ci]["p1"]
		var exit_key: String  = _snap_key(exit_p, snap)

		if ep_map.has(exit_key):
			for nci: int in (ep_map[exit_key] as Array):
				if nci == ci or wire_cursors[nci]["hop_dist"] <= hop + 1:
					continue
				var nwc:    Dictionary = wire_cursors[nci]
				var nk1:    String     = _snap_key(nwc["p1"] as Vector3, snap)
				var nentry: int        = 0 if nk1 == exit_key else 1
				wire_cursors[nci]["hop_dist"]   = hop + 1
				wire_cursors[nci]["source_end"] = nentry
				queue.append([nci, nentry])

	return max_hop


## Re-runs the BFS for a single net, seeded from a specific world-space point
## (e.g. a transistor drain pin) instead of from the input-pin list.
## Modifies wire_cursors in-place and returns the new max hop distance.
static func reseed_net(
		wire_cursors: Array,
		net: String,
		seed_pos: Vector3,
		scale_factor: float) -> int:
	var snap: float  = scale_factor * 2.5
	var indices: Array = []
	for i: int in range(wire_cursors.size()):
		if wire_cursors[i]["net"] == net:
			indices.append(i)
	if indices.is_empty():
		return 0
	return _bfs_net(wire_cursors, indices, [seed_pos], snap)


static func _snap_key(p: Vector3, snap: float) -> String:
	return "%d,%d" % [roundi(p.x / snap), roundi(p.z / snap)]
