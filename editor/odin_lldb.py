# LLDB data formatters for Odin/Methodin types. medit loads this into every
# lldb-dap session (launch initCommands), so strings render as text and
# slices/dynamic arrays expand to their elements — in hovers, locals, and any
# other LLDB frontend that imports it:
#
#   (lldb) command script import odin_lldb.py
import lldb

MAX_STRING = 256
MAX_ELEMS = 1024


def string_summary(v, _d):
    try:
        raw = v.GetNonSyntheticValue()
        n = raw.GetChildMemberWithName("len").GetValueAsSigned()
        if n <= 0:
            return '""'
        addr = raw.GetChildMemberWithName("data").GetValueAsUnsigned()
        if addr == 0:
            return '""'
        err = lldb.SBError()
        mem = v.GetProcess().ReadMemory(addr, min(n, MAX_STRING), err)
        if err.Fail():
            return "<unreadable>"
        text = mem.decode("utf-8", "replace")
        return '"%s%s"' % (text, "..." if n > MAX_STRING else "")
    except Exception:
        return "<error>"


def slice_summary(v, _d):
    n = v.GetNonSyntheticValue().GetChildMemberWithName("len").GetValueAsSigned()
    return "len=%d" % n


def dynamic_summary(v, _d):
    raw = v.GetNonSyntheticValue()
    n = raw.GetChildMemberWithName("len").GetValueAsSigned()
    c = raw.GetChildMemberWithName("cap").GetValueAsSigned()
    return "len=%d cap=%d" % (n, c)


class SliceSynth(object):
    """Children [0]..[len-1] for []T and [dynamic]T (same member names)."""

    def __init__(self, valobj, _d):
        self.v = valobj
        self.n = 0
        self.update()

    def update(self):
        try:
            raw = self.v.GetNonSyntheticValue()
            self.data = raw.GetChildMemberWithName("data")
            self.elem = self.data.GetType().GetPointeeType()
            self.esize = self.elem.GetByteSize()
            n = raw.GetChildMemberWithName("len").GetValueAsSigned()
            self.n = max(0, min(n, MAX_ELEMS)) if self.esize else 0
        except Exception:
            self.n = 0
        return False

    def num_children(self):
        return self.n

    def has_children(self):
        return self.n > 0

    def get_child_index(self, name):
        try:
            return int(name.lstrip("[").rstrip("]"))
        except Exception:
            return -1

    def get_child_at_index(self, i):
        if i < 0 or i >= self.n:
            return None
        addr = self.data.GetValueAsUnsigned() + i * self.esize
        return self.v.CreateValueFromAddress("[%d]" % i, addr, self.elem)


def __lldb_init_module(debugger, _d):
    debugger.HandleCommand('type summary add -w odin -F odin_lldb.string_summary string')
    debugger.HandleCommand('type synthetic add -w odin -l odin_lldb.SliceSynth -x "^\\[\\]"')
    debugger.HandleCommand('type synthetic add -w odin -l odin_lldb.SliceSynth -x "^\\[dynamic\\]"')
    debugger.HandleCommand('type summary add -w odin -F odin_lldb.slice_summary -x "^\\[\\]"')
    debugger.HandleCommand('type summary add -w odin -F odin_lldb.dynamic_summary -x "^\\[dynamic\\]"')
    debugger.HandleCommand("type category enable odin")
