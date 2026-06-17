package test_pr_in_struct_procs_cross_file

FpsCamera :: struct {
	yaw: f32,

	update :: proc(delta: f32) {
		yaw += delta
	},
}
