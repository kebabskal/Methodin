// Cross-file in-struct method collision regression: `Time` declares
// `update` here, `FpsCamera` declares `update` in fps_camera.odin.
// Without the package-level proc-group assembly the lifted free procs
// would clash at file scope. The parser now always mangles the lifted
// name to `<Struct>__<method>` and synthesises one
// `update :: proc { Time__update, FpsCamera__update }` per package
// after every file has been parsed.

package test_pr_in_struct_procs_cross_file

Time :: struct {
	dt: f32,

	update :: proc(new_dt: f32) {
		dt = new_dt
	},
}
