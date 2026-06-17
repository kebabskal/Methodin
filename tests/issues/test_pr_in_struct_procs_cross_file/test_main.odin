package test_pr_in_struct_procs_cross_file

import "core:testing"

@test
test_cross_file_method_collision :: proc(t: ^testing.T) {
	tm: Time
	cam: FpsCamera

	tm.update(0.016)
	cam.update(0.5)

	testing.expect_value(t, tm.dt, f32(0.016))
	testing.expect_value(t, cam.yaw, f32(0.5))
}
