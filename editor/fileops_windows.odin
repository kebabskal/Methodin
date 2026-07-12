#+build windows
package medit

import "core:fmt"
import win32 "core:sys/windows"

impl App {
	// Show path in File Explorer with the item selected. Explorer wants the
	// parameter text `/select,"C:\path"` verbatim; spawning it through
	// os.process_start would wrap the whole argument in quotes (it contains
	// a comma), which explorer answers by opening Documents instead.
	// ShellExecuteW passes the parameter string through untouched.
	reveal_in_file_manager :: proc(path: string) {
		params := win32.utf8_to_wstring(fmt.tprintf(`/select,"%s"`, abs_path(path)), context.temp_allocator)
		file := win32.utf8_to_wstring("explorer.exe", context.temp_allocator)
		inst := win32.ShellExecuteW(nil, nil, file, params, nil, win32.SW_SHOWNORMAL)
		if uintptr(inst) <= 32 { // ShellExecute: values up to 32 are error codes
			self.set_status("could not open the file manager")
		}
	}
}
