# Box3D

Odin bindings for [Box3D](https://github.com/erincatto/box3d) — Erin Catto's 3D rigid
body physics engine (the 3D sibling of Box2D), pinned to **v0.1.0**.

Two layers in one package (`import b3 "vendor:box3d"`):

- **Flat C API** — a complete 1:1 binding of all 578 `b3*` functions (`b3.World_Step`,
  `b3.CreateBody`, joints, queries, …), generated from the headers by `gen/generate.py`.
- **Methods layer** — optional Methodin sugar over the flat API (`box3d_methods.odin`):
  `world.step(dt)`, `body.add_sphere(...)`, `body.position()`. Zero-cost id-handle wrappers.

Math primitives are Odin array/matrix types for native arithmetic: `Vec3 :: [3]f32`,
`Matrix3 :: matrix[3,3]f32`, `Pos :: [3]f64` (double-precision world translation).

```odin
import b3 "vendor:box3d"

world  := b3.create_world({0, -10, 0})
ground := world.add_static_body({0, -1, 0}); ground.add_box({10, 1, 10})
ball   := world.add_dynamic_body({0, 8, 0}); ball.add_sphere({radius = 0.5})

for _ in 0..<180 do world.step(1.0 / 60.0)
p := ball.position() // rests at y ≈ 0.5
```

## Building the libraries

`lib/` ships prebuilt static libs. To rebuild (and regenerate the bindings from the
pinned headers):

```
./build_box3d.sh   # needs cmake; regen also needs clang + python libclang
```

## Hot reload

To hot-reload (`odin watch`) a project that links box3d, build with
`-define:BOX3D_SHARED=true` so the host and the reload DLL share one instance of box3d's
global world state (a static lib would be re-linked into the reload DLL as a divergent
copy and crash on the first call). Ensure `libbox3d.so.0` is on the loader path at
runtime (rpath or `LD_LIBRARY_PATH`).

## Regenerating

`gen/generate.py <box3d_include_dir> <out_dir>` walks the headers via libclang and emits
the flat binding. Internal structs with bitfields / anonymous unions are bound as opaque
blobs with exact size/alignment. The methods layer and math primitives are hand-written
and never overwritten.
