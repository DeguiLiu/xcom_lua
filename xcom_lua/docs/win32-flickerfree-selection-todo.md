# 纯 Win32 实现"无闪烁拖选高亮"任务清单

目标：不依赖 ImGui，仅用 Win32 + GDI 在接收区实现鼠标拖选多行高亮，
且窗口内容持续变化（新数据到达）时不闪烁。

## 一、防闪烁骨架（先做，缺一即闪）

1. `WM_ERASEBKGND` 直接 `return 1`，永不系统擦背景。
2. 整窗双缓冲：`CreateCompatibleDC` + `CreateCompatibleBitmap`（客户区大小），
   每帧顺序：FillRect 底色 → 选区色块 → `ExtTextOut` 文字 → 一次 `BitBlt` 上屏。
3. 双缓冲位图在 `WM_SIZE` / `WM_DPICHANGED` 时销毁重建。
4. 窗口样式加 `WS_CLIPCHILDREN`。
5. 细粒度失效：新数据只 invalidate 末尾新增行带；拖选只 invalidate
   新旧选区差异的矩形。禁止 `InvalidateRect(NULL)` 全窗重绘。
6. 滚动用 `ScrollWindowEx` 搬移像素，只补画新露出的一条带。

## 二、拖选状态机

7. `WM_LBUTTONDOWN` → `SetCapture`，记录锚点为数据坐标（行号, 列）。
8. `WM_MOUSEMOVE`（capture 中）→ 当前行列换算，`begin/end = min/max`。
9. `WM_LBUTTONUP` → `ReleaseCapture`，选区保留；`WM_CAPTURECHANGED`
   兜底取消拖拽态（防止漏收 UP 卡死）。
10. 像素→行列：等宽字体 `GetTextExtentPoint32(L"M")` 一次测宽，除法即列号。

## 三、数据变化与选区共存

11. 选区只存（行,列）数据坐标，与滚动位置/窗口尺寸/DPI 解耦。
12. 自动贴底跟随：capture 中或用户已手动滚动时暂停跟随，避免选区被滚走。
13. 清空日志时同时清选区。

## 四、增强（可选）

14. 拖选到客户区边缘时定时器逐行自动滚动（`SetTimer`/`KillTimer`）。
15. 双击选单词、右键 Copy（`OpenClipboard`+`SetClipboardData(CF_UNICODETEXT)`，
    必须 UI 线程调用）。

验收：满带宽刷屏下按住左键跨 100+ 行往返拖动，无闪烁、高亮跟手、
松开后选区持久且滚动不错位。
