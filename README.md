# tree-gen

Procedurally generated trees in Godot, built as an `@tool` script that runs live
in the editor. This is the most up-to-date of several versions I've made of this
generator, and I'm still working to make it better.

## What it is

A single `@tool` script (`script/tree_gen.gd`) extending `MeshInstance3D`. It
grows a tree recursively from the trunk up, emitting branch tubes and foliage
straight into an `ArrayMesh` using `SurfaceTool`. Everything regenerates in the
editor as you change settings  no play mode needed.

Generation is **deterministic**: the same seed plus the same settings always
produce the same tree. Change the seed (or hit *Randomize Seed*) for a different
shape.

## Features

- Recursive branching with configurable depth, splits, angle, taper and bend.
- Optional `Curve` resources to map branch depth to radius/length for more
  organic shapes (falls back to simple falloff multipliers when unset).
- Two foliage styles:
  - **Blobs**  icosphere clusters at branch tips. Use an opaque material.
  - **Cards**  crossed leaf quads (two-sided) for fluffy trees. Use an
    alpha/cutout leaf texture.
- Smooth or hard-faceted foliage normals, with per-vertex jaggedness.
- Export baked meshes to disk as `.res`, including a 3-level **LOD** set
  (lod0lod2) that reduces branch depth, tube sides and foliage detail.

## Usage

1. Open the project in Godot 4.6+ (Forward+).
2. Open `Generator/tree_gen.tscn` (or add a `MeshInstance3D` with
   `script/tree_gen.gd` attached).
3. Tweak the exported properties in the Inspector. The tree rebuilds live.
   - **Generate New**  rebuild current seed after slider changes.
   - **Randomize Seed**  pick a new seed and rebuild.
   - **Save To Disk** / **Save LODs**  write meshes to `save_directory`.

## Project layout

| Path | Purpose |
|------|---------|
| `script/tree_gen.gd` | The generator (`@tool`). |
| `Generator/tree_gen.tscn` | Scene with the generator node. |
| `Materials/` | Bark, blob-leaf and card-leaf materials. |
| `Textures/` | Bark and leaf textures. |
| `exports/` | Example saved tree resources. |
| `environment/trees/` | Baked output meshes (incl. LODs). |
