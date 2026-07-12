package medit

import "core:strings"
import "core:testing"
import "core:time"

@test
test_tasks_parse_expand_split :: proc(t: ^testing.T) {
	ts: Task_State
	defer tasks_destroy(&ts)
	tasks_parse(&ts, "; comment\n[run]\ncmd = odin run ${workspaceFolder}\ncwd = ${fileDir}\n\n[no command]\nnote = ignored\n\n[test]\ncmd = odin test .\n")
	testing.expect_value(t, len(ts.tasks), 2) // cmd-less sections are dropped
	testing.expect_value(t, ts.tasks[0].name, "run")
	testing.expect_value(t, ts.tasks[0].cmd, "odin run ${workspaceFolder}")
	testing.expect_value(t, ts.tasks[0].cwd, "${fileDir}")
	testing.expect_value(t, ts.tasks[1].name, "test")

	got := task_expand("run ${file} in ${workspaceFolder} (${fileName})", "C:/ws/pkg/a.odin", "C:/ws")
	testing.expect_value(t, got, "run C:/ws/pkg/a.odin in C:/ws (a.odin)")

	args := task_split(`odin run "my dir/main.odin" -define:X=1`)
	testing.expect_value(t, len(args), 4)
	testing.expect_value(t, args[1], "run")
	testing.expect_value(t, args[2], "my dir/main.odin")
	testing.expect_value(t, args[3], "-define:X=1")
}

@test
test_task_run_captures_output :: proc(t: ^testing.T) {
	app: App
	app.theme = theme_default()
	app.buf = buffer_make()
	append(&app.cursors, cursor_at(Pos{0, 0}))
	defer app_destroy(&app)

	when ODIN_OS == .Windows {
		tasks_parse(&app.task, "[hi]\ncmd = cmd /c echo hello task\n")
	} else {
		tasks_parse(&app.task, "[hi]\ncmd = echo hello task\n")
	}
	app.task_run(0)
	testing.expect_value(t, app.task.running, true)
	testing.expect_value(t, app.task.open, true)

	for _ in 0 ..< 400 { // give it up to ~2s
		task_poll(&app)
		if !app.task.running {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, app.task.running, false)
	testing.expect_value(t, app.task.last, "hi")
	found := false
	for l in app.task.lines {
		if strings.contains(l, "hello task") {
			found = true
		}
	}
	testing.expect(t, found, "expected the task output to contain 'hello task'")
}

@test
test_task_output_links :: proc(t: ^testing.T) {
	links: [dynamic]Task_Link
	defer delete(links)

	// Odin style: path(line:col).
	task_scan_links("C:/ws/main.odin(9:8) Error: bad thing", &links)
	testing.expect_value(t, len(links), 1)
	if len(links) == 1 {
		testing.expect_value(t, links[0].path, "C:/ws/main.odin")
		testing.expect_value(t, links[0].line, 9)
		testing.expect_value(t, links[0].col, 8)
		testing.expect_value(t, links[0].lo, 0)
	}

	// gcc style, with the trailing prose colon.
	clear(&links)
	task_scan_links("  src/foo.c:12:5: error: x", &links)
	testing.expect_value(t, len(links), 1)
	if len(links) == 1 {
		testing.expect_value(t, links[0].path, "src/foo.c")
		testing.expect_value(t, links[0].line, 12)
		testing.expect_value(t, links[0].col, 5)
	}

	// Line-only reference, backslashes.
	clear(&links)
	task_scan_links(`--> editor\tasks.odin:33`, &links)
	testing.expect_value(t, len(links), 1)
	if len(links) == 1 {
		testing.expect_value(t, links[0].path, `editor\tasks.odin`)
		testing.expect_value(t, links[0].line, 33)
		testing.expect_value(t, links[0].col, 0)
	}

	// Not files: bare times and prose.
	clear(&links)
	task_scan_links("at 12:30 Error: nothing here", &links)
	testing.expect_value(t, len(links), 0)
}
