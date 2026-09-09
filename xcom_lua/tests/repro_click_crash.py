# Automated repro driver for the "bad callback" crash (XCOM_DEBUG=1 required).
# Launches luvjit main.lua with VIRTUAL auto-open + sim pump armed, waits for
# the window, then posts ONE real click into the ImGui console at the coords
# that reproduced the panic manually (x=420,y=596 screen-offset).  Exits when
# the process dies and reports exit code + last log lines.
import os, subprocess, sys, time, ctypes
import ctypes.wintypes as wt

ROOT = os.path.dirname(os.path.abspath(__file__)) + r"\.."
user32 = ctypes.windll.user32

class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wt.LONG), ("dy", wt.LONG), ("mouseData", wt.DWORD),
                ("dwFlags", wt.DWORD), ("time", wt.DWORD), ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong))]
class INPUT(ctypes.Structure):
    _fields_ = [("type", wt.DWORD), ("mi", MOUSEINPUT)]

env = dict(os.environ, XCOM_DEBUG="1", XCOM_SMOKE_OPEN="1")
log = os.path.join(ROOT, "xcom_debug.log")
open(log, "w").close()
fh = open(log, "a", encoding="utf-8", errors="replace")

subprocess.run(["taskkill", "/IM", "luvjit.exe", "/F"], capture_output=True)
p = subprocess.Popen([os.path.join(ROOT, r"runtime\luvjit.exe"), "main.lua"],
                     cwd=ROOT, env=env, stdout=subprocess.DEVNULL, stderr=fh,
                     creationflags=0x00000008)
hwnd = 0
t0 = time.time()
while time.time() - t0 < 30:
    hwnd = user32.FindWindowW("XComSerialLua", None)
    if hwnd:
        break
    time.sleep(0.02)
if not hwnd:
    print("window not found"); sys.exit(1)
user32.ShowWindow(hwnd, 5)
user32.SetWindowPos(hwnd, 0, 80, 60, 920, 650, 0x0004)
time.sleep(2.5)  # let the sim pump + first frames settle

rc = wt.RECT()
user32.GetClientRect(hwnd, ctypes.byref(rc))
def click(ox, oy):
    pt = wt.POINT(ox, oy)
    user32.ClientToScreen(hwnd, ctypes.byref(pt))
    user32.SetCursorPos(pt.x, pt.y)
    time.sleep(0.12)
    ctypes.windll.user32.mouse_event(0x0002, 0, 0, 0, 0)
    time.sleep(0.05)
    ctypes.windll.user32.mouse_event(0x0004, 0, 0, 0, 0)
    time.sleep(0.3)

# Sweep a grid over the dashboard, clicking ImGui widgets the same way a
# user does (the manual repro took ~6 clicks before the PANIC).
xs = [55, 130, 235, 470, 600, 720, 830]
ys = [42, 85, 130, 175, 220, 265, 320, 380, 440, 500, 560, 596]
t0 = time.time()
for y in ys:
    if p.poll() is not None:
        break
    for x in xs:
        if p.poll() is not None or time.time() - t0 > 90:
            break
        click(x, y)

t0 = time.time()
while p.poll() is None and time.time() - t0 < 15:
    time.sleep(0.2)
alive = p.poll() is None
if alive:
    subprocess.run(["taskkill", "/IM", "luvjit.exe", "/F"], capture_output=True)
    print("NO-CRASH (killed after 15s)")
else:
    print(f"EXITED code={p.returncode}")
fh.close()
with open(log, encoding="utf-8", errors="replace") as f:
    lines = f.readlines()
print("".join(lines[-12:]))
