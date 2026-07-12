#+build !windows
package medit

import "core:os"

impl App {
	// Show path in the system file manager: Finder selects the item,
	// xdg-open falls back to opening the containing directory.
	reveal_in_file_manager :: proc(path: string) {
		abs := abs_path(path)
		cmd: []string
		when ODIN_OS == .Darwin {
			cmd = []string{"open", "-R", abs}
		} else {
			dir, _ := os.split_path(abs)
			cmd = []string{"xdg-open", dir if dir != "" else abs}
		}
		if _, err := os.process_start({command = cmd}); err != nil {
			self.set_status("could not open the file manager")
		}
	}
}
