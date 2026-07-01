package vendor_box3d

// Prebuilt libs live in lib/ (see build_box3d.sh). Box3D has a single SIMD variant
// (SSE2 baseline / -msimd128 on wasm), so no AVX2/SSE2 split like box2d.
//
// Static by default. Build with `-define:BOX3D_SHARED=true` to link the shared lib —
// required to hot-reload (`odin watch`) a project that uses box3d, so the host and the
// reload DLL share one instance of box3d's global world state. When shared, ensure the
// loader finds libbox3d.so.0 at runtime (rpath or LD_LIBRARY_PATH).

when #config(BOX3D_SHARED, false) {
	when ODIN_OS == .Windows {
		@(private) LIB_PATH :: "lib/box3d.dll.lib"
	} else when ODIN_OS == .Darwin {
		@(private) LIB_PATH :: "lib/libbox3d.dylib"
	} else {
		@(private) LIB_PATH :: "lib/libbox3d.so"
	}
} else when ODIN_OS == .Windows {
	@(private) LIB_PATH :: "lib/box3d_windows_amd64.lib"
} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	@(private) LIB_PATH :: "lib/box3d_darwin_arm64.a"
} else when ODIN_OS == .Darwin {
	@(private) LIB_PATH :: "lib/box3d_darwin_amd64.a"
} else when ODIN_ARCH == .amd64 {
	@(private) LIB_PATH :: "lib/box3d_other_amd64.a"
} else {
	@(private) LIB_PATH :: "lib/box3d_other.a"
}
