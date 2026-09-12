-- settings_demo.lua - 动态设置页示例（Lua 插件绘制 UI）
-- @name 插件设置页示例
-- @desc 用 ui.page 声明一个独立插件窗口，含勾选框、滑条、下拉与按钮，演示 ui.event 回调。
-- 演示脚本通过 ui.page() 在头部「Set」设置弹窗里声明一个动态页，
-- 控件由 C++ 桥按行式文法渲染；交互经 ui.event() 回调回传。
--
-- 运行方式：脚本控制台启用 settings_demo.lua 后，点标题栏「Set」芯片，
-- 设置窗口出现 "Demo" 页签；勾选 Echo 后收到的每一行都会原样回发，
-- 前缀取自 Interval 滑条与 Format 下拉，Send HELLO 按钮手动发一帧。
--
-- spec 文法（一行一控件，wid 仅限字母数字与 _ . -）：
--   title:文本 / check:wid:标签:0|1 / slider:wid:标签:min:max:默认
--   combo:wid:标签:默认idx:a|b|c / button:wid:标签

local state = {
    echo = false,        -- check:echo 开关
    upper = false,       -- check:upper 开关
    interval = 100,      -- slider:interval 毫秒
    format = 0,          -- combo:format 当前项索引
}

-- 页 ID（引擎会自动加 "settings_demo.lua:" 前缀，回调里收到的是完整 ID）
local PAGE_ID = "demo"

local spec = table.concat({
    "title:DEMO SETTINGS",
    "check:echo:Echo:0",
    "check:upper:Upper:0",
    "slider:interval:Interval:10:1000:100",
    "combo:format:Format:0:raw|line|hex",
    "button:hello:Send HELLO",
}, "\n")

ui.page(PAGE_ID, "Demo", spec)

-- 交互回调：kind 为 check/slider/combo/click，value 为字符串（click 时无）
ui.event = function(page, kind, widget, value)
    log.info("settings_demo", page .. " " .. kind .. ":" .. widget ..
             " = " .. tostring(value))
    if kind == "check" then
        if widget == "echo" then state.echo = value == "1" end
        if widget == "upper" then state.upper = value == "1" end
    elseif kind == "slider" then
        if widget == "interval" then state.interval = tonumber(value) or 100 end
    elseif kind == "combo" then
        if widget == "format" then state.format = tonumber(value) or 0 end
    elseif kind == "click" then
        if widget == "hello" then
            -- 按当前面板状态拼一帧示例命令（hex 模式发 AA 55 帧头）
            if state.format == 2 then
                uart.send_hex("AA5548454C4C4F0D0A")
            else
                uart.send("HELLO\r\n")
            end
            log.info("settings_demo", "sent HELLO frame (format=" ..
                     state.format .. ")")
        end
    end
end

-- Echo 开关真正控制行为：收到数据按设定间隔回发
on.receive(function(text)
    if not state.echo then return text end
    local payload = state.upper and text:upper() or text
    sys.timer_start(state.interval, function()
        uart.send(payload)
    end)
    return text
end)

log.info("settings_demo", "open the header Set chip to see the Demo tab")
