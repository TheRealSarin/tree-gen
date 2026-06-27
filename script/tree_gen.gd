@tool
extends MeshInstance3D

enum FoliageStyle {
	BLOBS, ## Icosphere clusters at branch tips. Use an opaque foliage material.
	CARDS, ## Crossed leaf cards (quads) for fluffy trees. Use an alpha/cutout leaf texture.
}

@export_category("Tree")
## Rebuild the mesh from the current seed and settings. Keeps the same tree;
## use this to apply slider changes without generating a different shape.
@export var generate_new: bool = false:
	set(value):
		if value and is_node_ready():
			_generate()
		generate_new = false

## Deterministic seed. The same seed and settings always produce the same tree.
@export var seed: int = 0
## Pick a new random seed and rebuild, producing a different tree shape.
@export var randomize_seed: bool = false:
	set(value):
		if value and is_node_ready():
			seed = randi()
			_generate()
		randomize_seed = false

@export_category("Trunk & Branches")
## Maximum branching depth. Higher values give a fuller, more detailed tree.
@export_range(2, 7) var max_depth: int = 4
## Number of child branches spawned at each split.
@export_range(1, 4) var splits_per_branch: int = 2
## Height of the trunk in metres.
@export_range(0.5, 6.0) var trunk_height: float = 2.2
## Radius of the trunk base in metres.
@export_range(0.05, 1.0) var trunk_radius: float = 0.28
## Fraction of length passed to each child branch. Lower values shorten faster.
## Ignored when a Branch Length Curve is assigned.
@export_range(0.4, 0.95) var length_falloff: float = 0.72
## Fraction of radius passed to each child branch. Lower values taper faster.
## Ignored when a Branch Radius Curve is assigned.
@export_range(0.4, 0.95) var radius_falloff: float = 0.62
## Angle in degrees that child branches diverge from their parent.
@export_range(10.0, 70.0) var branch_angle: float = 35.0
## Per-segment bend applied along each branch for a more natural curve.
@export_range(0.0, 0.6) var curve_amount: float = 0.25
## Number of sides on each branch tube. Higher values give rounder branches.
@export_range(3, 8) var trunk_sides: int = 5

@export_category("Branch Shape Curves")
## Optional curve mapping branch depth (0 = trunk, 1 = deepest) to a radius
## multiplier of the trunk radius. Lets splits be different sizes at different
## depths for more organic trees. When null, radius_falloff is used instead.
@export var branch_radius_curve: Curve:
	set(value):
		branch_radius_curve = value
		if is_node_ready(): _generate()
## Optional curve mapping branch depth (0..1) to a length multiplier of the
## trunk height. When null, length_falloff is used instead.
@export var branch_length_curve: Curve:
	set(value):
		branch_length_curve = value
		if is_node_ready(): _generate()
## Random size variation between sibling splits. 0 = all equal, higher = more
## irregular thickness across branches at the same depth.
@export_range(0.0, 0.5) var branch_radius_jitter: float = 0.15

@export_category("Foliage")
## Generate foliage at branch tips.
@export var foliage_enabled: bool = true
## Blobs (icosphere clusters) or crossed leaf cards (quads, for fluffy trees).
@export var foliage_style: FoliageStyle = FoliageStyle.BLOBS
## Base size of each foliage element (blob radius or card half-extent).
@export_range(0.1, 2.0) var foliage_size: float = 0.7
## Random variation applied to foliage size per element.
@export_range(0.0, 1.0) var foliage_size_jitter: float = 0.3
## Branch depth at which foliage starts appearing.
@export_range(1, 4) var foliage_depth_start: int = 2

@export_subgroup("Blob Style")
## Mesh density of each foliage blob. Higher values are rounder.
@export_range(0, 2) var foliage_subdivisions: int = 1
## Per-vertex displacement on foliage blobs for an irregular canopy.
@export_range(0.0, 0.4) var foliage_jaggedness: float = 0.12
## Smooth shading across foliage faces (soft canopy) versus hard facets.
@export var foliage_smooth_normals: bool = true

@export_subgroup("Card Style")
## Number of crossed quads emitted per foliage point. More = fluffier.
@export_range(1, 8) var cards_per_cluster: int = 3
## How far cards are scattered around each foliage point (× foliage_size).
@export_range(0.0, 1.5) var card_spread: float = 0.5

@export_category("Materials")
## Material for the trunk and branches.
@export var bark_material: Material:
	set(value):
		bark_material = value
		if is_node_ready(): _update_materials()
## Material for BLOB foliage. Use an opaque material. Optional  if null the
## foliage surface keeps no material (no crash).
@export var blob_material: Material:
	set(value):
		blob_material = value
		if is_node_ready(): _update_materials()
## Material for CARD foliage. Use an alpha/cutout, two-sided (cull disabled)
## leaf texture. Optional  if null the foliage surface keeps no material.
@export var card_material: Material:
	set(value):
		card_material = value
		if is_node_ready(): _update_materials()

@export_category("Export")
## Target directory for the saved mesh resource(s).
@export_global_dir var save_directory: String = "res://environment/trees"
## File name (without extension) for the saved mesh resource(s).
@export var resource_name: String = "low_poly_tree"
## Write the current mesh to disk as a .res in the save directory.
@export var save_to_disk: bool = false:
	set(value):
		if value and is_node_ready(): _save_mesh()
		save_to_disk = false
## Write three LOD meshes (lod0-lod2) to disk in the save directory.
@export var save_lods: bool = false:
	set(value):
		if value and is_node_ready(): _save_lods()
		save_lods = false

var _rng := RandomNumberGenerator.new()
var _bark_st: SurfaceTool
var _leaf_points: Array
# per-build overrides for LOD
var _lod_depth: int
var _lod_sides: int
var _lod_fol_subs: int

func _ready() -> void:
	_update_materials()

func _norm(v: Vector3) -> Vector3:
	return v.normalized() if v.length() > 0.0001 else Vector3.UP

# Two perpendicular unit vectors spanning the plane orthogonal to dir.
func _basis_for(dir: Vector3) -> Array:
	var d := _norm(dir)
	var ref := Vector3.UP if abs(d.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var u := ref.cross(d).normalized()
	var w := d.cross(u).normalized()
	return [u, w]

func _build_icosphere(radius, subs) -> Array:
	radius = float(radius) if radius != null else 0.5
	subs = int(subs) if subs != null else 1
	var t := (1.0 + sqrt(5.0)) / 2.0
	var verts: Array[Vector3] = [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	]
	for i in range(verts.size()):
		verts[i] = verts[i].normalized() * radius
	var faces: Array = [
		[0,11,5],[0,5,1],[0,1,7],[0,7,10],[0,10,11],
		[1,5,9],[5,11,4],[11,10,2],[10,7,6],[7,1,8],
		[3,9,4],[3,4,2],[3,2,6],[3,6,8],[3,8,9],
		[4,9,5],[2,4,11],[6,2,10],[8,6,7],[9,8,1],
	]
	var mc := {}
	for _s in range(subs):
		var nf: Array = []
		for f in faces:
			var a: int = f[0]; var b: int = f[1]; var c: int = f[2]
			var ab := _mid(a, b, verts, mc, radius)
			var bc := _mid(b, c, verts, mc, radius)
			var ca := _mid(c, a, verts, mc, radius)
			nf.append([a, ab, ca]); nf.append([b, bc, ab])
			nf.append([c, ca, bc]); nf.append([ab, bc, ca])
		faces = nf
	return [verts, faces]

func _mid(i: int, j: int, verts: Array, cache: Dictionary, radius: float) -> int:
	var key := str(min(i, j)) + "_" + str(max(i, j))
	if cache.has(key): return cache[key]
	var m: Vector3 = ((verts[i] + verts[j]) * 0.5).normalized() * radius
	verts.append(m); var idx := verts.size() - 1; cache[key] = idx
	return idx

func _emit_tri(a: Vector3, b: Vector3, c: Vector3) -> void:
	var n := (b - a).cross(c - a).normalized()
	_bark_st.set_normal(n); _bark_st.add_vertex(a)
	_bark_st.set_normal(n); _bark_st.add_vertex(b)
	_bark_st.set_normal(n); _bark_st.add_vertex(c)

func _ring(center: Vector3, u: Vector3, w: Vector3, sides: int, r: float) -> Array:
	var ring: Array[Vector3] = []
	for s in range(sides):
		var ang := TAU * float(s) / float(sides)
		ring.append(center + (u * cos(ang) + w * sin(ang)) * r)
	return ring

func _emit_branch(base: Vector3, dir: Vector3, length: float, radius: float) -> Dictionary:
	var sides := _lod_sides
	var segs := 3
	var seg_len := length / float(segs)
	var pos := base
	var d := _norm(dir)
	var r := radius
	var bz := _basis_for(d)
	var u: Vector3 = bz[0]
	var w: Vector3 = bz[1]
	var prev_ring := _ring(pos, u, w, sides, r)

	for i in range(segs):
		var bend := Vector3(
			_rng.randf_range(-1, 1), _rng.randf_range(-0.6, 0.2), _rng.randf_range(-1, 1)
		) * curve_amount
		var new_d := _norm(d + bend)
		var rot_axis := d.cross(new_d)
		if rot_axis.length() > 0.0001:
			var ang := d.angle_to(new_d)
			var q := Basis(rot_axis.normalized(), ang)
			u = (q * u).normalized(); w = (q * w).normalized()
		d = new_d
		var nxt := pos + d * seg_len
		var r_next := r * 0.85
		var next_ring := _ring(nxt, u, w, sides, r_next)
		for s in range(sides):
			var s2 := (s + 1) % sides
			_emit_tri(prev_ring[s], next_ring[s], prev_ring[s2])
			_emit_tri(prev_ring[s2], next_ring[s], next_ring[s2])
		prev_ring = next_ring
		pos = nxt
		r = r_next

	# cap tip to seal splits
	for s in range(sides):
		var s2 := (s + 1) % sides
		_emit_tri(prev_ring[s], pos, prev_ring[s2])

	return {"pos": pos, "dir": d, "radius": r}

# Radius for child branches at the given child depth.
func _child_radius(parent_radius: float, child_depth: int) -> float:
	var base_r: float
	if branch_radius_curve:
		var t := float(child_depth) / float(max(1, max_depth))
		base_r = trunk_radius * branch_radius_curve.sample_baked(t)
	else:
		base_r = parent_radius * radius_falloff
	var jit := 1.0 + _rng.randf_range(-branch_radius_jitter, branch_radius_jitter)
	return max(0.01, base_r * jit)

# Length for child branches at the given child depth.
func _child_length(parent_length: float, child_depth: int) -> float:
	if branch_length_curve:
		var t := float(child_depth) / float(max(1, max_depth))
		return trunk_height * branch_length_curve.sample_baked(t)
	return parent_length * length_falloff

func _grow(base: Vector3, dir: Vector3, length: float, radius: float, depth: int) -> void:
	if depth > _lod_depth or length < 0.05:
		if foliage_enabled:
			_leaf_points.append({"pos": base, "dir": dir, "size": foliage_size})
		return
	var br := _emit_branch(base, dir, length, radius)
	var tip: Vector3 = br["pos"]
	var tip_dir: Vector3 = br["dir"]
	if foliage_enabled and depth >= foliage_depth_start:
		var jit := 1.0 + _rng.randf_range(-foliage_size_jitter, foliage_size_jitter)
		_leaf_points.append({"pos": tip, "dir": tip_dir, "size": foliage_size * jit * (float(_lod_depth - depth + 1) / float(_lod_depth))})
	var n_children := splits_per_branch
	if depth >= _lod_depth - 1:
		n_children = max(2, splits_per_branch)
	for c in range(n_children):
		var child_len := _child_length(length, depth + 1)
		var child_rad := _child_radius(radius, depth + 1)
		var spin := TAU * float(c) / float(n_children) + _rng.randf_range(-0.4, 0.4)
		var axis := tip_dir
		var ref := Vector3.UP if abs(axis.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
		var side := ref.cross(axis).normalized()
		var bent := axis.rotated(side, deg_to_rad(branch_angle) * _rng.randf_range(0.6, 1.2))
		bent = bent.rotated(axis, spin)
		_grow(tip, bent, child_len, child_rad, depth + 1)

# --- Foliage builders ---------------------------------------------------------

func _build_blobs(leaf_st: SurfaceTool) -> void:
	var blob := _build_icosphere(0.5, _lod_fol_subs)
	var bverts: Array = blob[0]
	var bfaces: Array = blob[1]
	for lp in _leaf_points:
		var center: Vector3 = lp["pos"]
		var sz: float = lp["size"]
		# jitter unique verts ONCE so the blob stays closed
		var jset: Array[Vector3] = []
		for v in bverts:
			var dir := _norm(v)
			var push := _rng.randf_range(-foliage_jaggedness, foliage_jaggedness)
			jset.append((v + dir * push) * sz + center)
		if foliage_smooth_normals:
			# indexed: generate_normals averages across shared verts -> soft blobs
			var start := _leaf_vert_count
			for i in range(jset.size()):
				leaf_st.set_uv(_sphere_uv(_norm(bverts[i])))
				leaf_st.add_vertex(jset[i])
			for f in bfaces:
				leaf_st.add_index(start + f[0])
				leaf_st.add_index(start + f[1])
				leaf_st.add_index(start + f[2])
			_leaf_vert_count += jset.size()
		else:
			for f in bfaces:
				var a: Vector3 = jset[f[0]]; var b: Vector3 = jset[f[1]]; var c: Vector3 = jset[f[2]]
				var n := (b - a).cross(c - a).normalized()
				leaf_st.set_normal(n); leaf_st.set_uv(_sphere_uv(_norm(bverts[f[0]]))); leaf_st.add_vertex(a)
				leaf_st.set_normal(n); leaf_st.set_uv(_sphere_uv(_norm(bverts[f[1]]))); leaf_st.add_vertex(b)
				leaf_st.set_normal(n); leaf_st.set_uv(_sphere_uv(_norm(bverts[f[2]]))); leaf_st.add_vertex(c)
	if foliage_smooth_normals:
		leaf_st.generate_normals()  # averages across shared verts -> soft blobs

func _sphere_uv(dir: Vector3) -> Vector2:
	return Vector2(atan2(dir.z, dir.x) / TAU + 0.5, acos(clamp(dir.y, -1.0, 1.0)) / PI)

func _build_cards(leaf_st: SurfaceTool) -> void:
	for lp in _leaf_points:
		var center: Vector3 = lp["pos"]
		var sz: float = lp["size"]
		var spread := sz * card_spread
		for _i in range(cards_per_cluster):
			# random plane orientation per card
			var n := Vector3(
				_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)
			)
			n = _norm(n)
			var bz := _basis_for(n)
			var u: Vector3 = bz[0]
			var w: Vector3 = bz[1]
			var off := Vector3(
				_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)
			) * spread
			var c := center + off
			var sz2 := sz * _rng.randf_range(0.7, 1.0)
			_emit_card(leaf_st, c, u, w, n, sz2)

# Two-sided quad (front + back faces) with full 0..1 UVs for a leaf texture.
func _emit_card(st: SurfaceTool, c: Vector3, u: Vector3, w: Vector3, n: Vector3, half: float) -> void:
	var p0 := c - u * half - w * half
	var p1 := c + u * half - w * half
	var p2 := c + u * half + w * half
	var p3 := c - u * half + w * half
	var uv0 := Vector2(0, 1); var uv1 := Vector2(1, 1)
	var uv2 := Vector2(1, 0); var uv3 := Vector2(0, 0)
	# front
	_card_tri(st, p0, p1, p2, uv0, uv1, uv2, n)
	_card_tri(st, p0, p2, p3, uv0, uv2, uv3, n)
	# back (reversed winding, flipped normal) so cards show from both sides
	_card_tri(st, p0, p2, p1, uv0, uv2, uv1, -n)
	_card_tri(st, p0, p3, p2, uv0, uv3, uv2, -n)

func _card_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, ua: Vector2, ub: Vector2, uc: Vector2, n: Vector3) -> void:
	st.set_normal(n); st.set_uv(ua); st.add_vertex(a)
	st.set_normal(n); st.set_uv(ub); st.add_vertex(b)
	st.set_normal(n); st.set_uv(uc); st.add_vertex(c)

# Build one full tree mesh at a given LOD (0 = full). Returns ArrayMesh.
func _build_tree(lod: int) -> ArrayMesh:
	_rng = RandomNumberGenerator.new()
	_rng.seed = seed  # same seed -> same tree at every LOD

	# LOD scaling: reduce depth, tube sides, foliage detail
	_lod_depth = max(2, max_depth - lod)
	_lod_sides = max(3, trunk_sides - lod)
	_lod_fol_subs = max(0, foliage_subdivisions - lod)

	_leaf_points = []
	_bark_st = SurfaceTool.new()
	_bark_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_grow(Vector3.ZERO, Vector3.UP, trunk_height, trunk_radius, 0)
	var final_mesh: ArrayMesh = _bark_st.commit()

	if foliage_enabled and _leaf_points.size() > 0:
		var leaf_st := SurfaceTool.new()
		leaf_st.begin(Mesh.PRIMITIVE_TRIANGLES)
		if foliage_style == FoliageStyle.CARDS:
			_build_cards(leaf_st)
		else:
			_build_blobs(leaf_st)
		final_mesh = leaf_st.commit(final_mesh)

	return final_mesh

var _leaf_vert_count := 0

func _generate() -> void:
	_leaf_vert_count = 0
	mesh = _build_tree(0)
	_update_materials()

# Material for the current foliage style. Null is allowed.
func _foliage_material() -> Material:
	return card_material if foliage_style == FoliageStyle.CARDS else blob_material

func _update_materials() -> void:
	if not mesh: return
	if mesh.get_surface_count() > 0 and bark_material:
		mesh.surface_set_material(0, bark_material)
	var fol_mat := _foliage_material()
	if mesh.get_surface_count() > 1 and fol_mat:
		mesh.surface_set_material(1, fol_mat)

func _save_mesh() -> void:
	if not mesh: return
	if not DirAccess.dir_exists_absolute(save_directory):
		DirAccess.make_dir_recursive_absolute(save_directory)
	var full_path := save_directory + "/" + resource_name + ".res"
	var err := ResourceSaver.save(mesh, full_path)
	if err == OK: print("Saved tree mesh to: ", full_path)
	else: push_error("Failed to save mesh: " + str(err))

func _save_lods() -> void:
	if not DirAccess.dir_exists_absolute(save_directory):
		DirAccess.make_dir_recursive_absolute(save_directory)
	for lod in range(3):
		_leaf_vert_count = 0
		var m := _build_tree(lod)
		if m.get_surface_count() > 0 and bark_material:
			m.surface_set_material(0, bark_material)
		var fol_mat := _foliage_material()
		if m.get_surface_count() > 1 and fol_mat:
			m.surface_set_material(1, fol_mat)
		var path := save_directory + "/" + resource_name + "_lod" + str(lod) + ".res"
		var err := ResourceSaver.save(m, path)
		if err == OK: print("Saved LOD", lod, " to: ", path)
		else: push_error("Failed LOD" + str(lod) + ": " + str(err))
	# restore the editor preview to full detail
	_generate()
