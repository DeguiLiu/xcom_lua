# Startup-flash capture: launch the client, screenshot at ~0.2s and ~3s, save both.
import subprocess, time, sys, os
import ctypes
import ctypes.wintypes as wt
from PIL import Image

ROOT = r"D:\workspace\SSCOM_lua\xcom_lua"
user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32

def find():
    return user32.FindWindowW("XComSerialLua", None)

def capture(hwnd, path):
    rect = wt.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(rect))
    w, h = rect.right - rect.left, rect.bottom - rect.top
    hdc = user32.GetDC(hwnd)
    mdc = gdi32.CreateCompatibleDC(hdc)
    bmp = gdi32.CreateCompatibleBitmap(hdc, w, h)
    gdi32.SelectObject(mdc, bmp)
    gdi32.BitBlt(mdc, 0, 0, w, h, hdc, 0, 0, 0x00CC0020)  # SRCCOPY
    class BMI(ctypes.Structure):
        _fields_ = [("biSize", wt.DWORD), ("biWidth", wt.LONG), ("biHeight", wt.LONG),
                    ("biPlanes", wt.WORD), ("biBitCount", wt.WORD), ("biCompression", wt.DWORD),
                    ("biSizeImage", wt.DWORD), ("biXPelsPerMeter", wt.LONG),
                    ("biYPelsPerMeter", wt.LONG), ("biClrUsed", wt.DWORD),
                    ("biClrImportant", wt.DWORD)]
    bmi = BMI()
    bmi.biSize = ctypes.sizeof(BMI); bmi.biWidth = w; bmi.biHeight = -h
    bmi.biPlanes = 1; bmi.biBitCount = 32; bmi.biCompression = 0
    buf = ctypes.create_string_buffer(w * h * 4)
    gdi32.GetDIBits(mdc, bmp, 0, h, buf, ctypes.byref(bmi), 0)
    img = Image.frombytes("RGBA", (w, h), buf.raw).convert("RGB")
    img.save(path)
    gdi32.DeleteObject(bmp); gdi32.DeleteDC(mdc); user32.ReleaseDC(hwnd, hdc)
    return path

subprocess.run(["taskkill", "/IM", "luvjit.exe", "/F"], capture_output=True)
p = subprocess.Popen([ROOT + r"\runtime\luvjit.exe", "main.lua"], cwd=ROOT,
                     creationflags=0x00000008,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
t0 = time.time()
hwnd = 0
while time.time() - t0 < 30:
    hwnd = find()
    if hwnd:
        break
    time.sleep(0.02)
if not hwnd:
    print("window not found"); sys.exit(1)
user32.ShowWindow(hwnd, 5)
user32.SetWindowPos(hwnd, 0, 80, 60, 920, 650, 0x0004)
# fire captures as early as possible, then steady state
early = None
while time.time() - t0 < 1.5:
    now = time.time() - t0
    path = ROOT + f"\\startup_{now:.2f}s.png"
    capture(hwnd, path)
    if early is None:
        early = path
    time.sleep(0.25)
time.sleep(2.0)
steady = capture(hwnd, ROOT + "\\startup_steady.png")
print("EARLY:", early)
print("STEADY:", steady)
