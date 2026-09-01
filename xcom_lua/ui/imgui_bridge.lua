local ffi = require("ffi")

ffi.cdef[[
int xcom_imgui_init(void* hwnd);
void xcom_imgui_set_ports(const char* const* names, int count);
int xcom_imgui_new_frame(void);
int xcom_imgui_render(void);
int xcom_imgui_wndproc(void* hwnd, unsigned int msg, uintptr_t wparam, intptr_t lparam);
int xcom_imgui_draw_console(char* port, size_t port_capacity, int connected,
  int rx_bytes, int tx_bytes, int* baud, int* data_bits, int* stop_bits,
  int* parity, int* flow, int* dtr, int* rts, int* receive_hex,
  int* timestamp, int* pause_display, int* auto_clear, int* auto_clear_bytes,
  char* send_text, size_t send_capacity, int* send_hex, int* send_crlf,
  int* send_auto, int* send_period,
  char* multi_text, size_t multi_slot_capacity, int* multi_enabled,
  int* multi_hex, int* multi_crlf, int* multi_page, int* multi_page_count,
  int* multi_auto, int* multi_period, int* auto_save,
  const char* receive_text, size_t receive_length);
void xcom_imgui_shutdown(void);
]]

local M = {}
local ok, lib = pcall(ffi.load, "xcom_imgui")
M.available = ok and lib or nil

local PORT_CAPACITY = 128
local SEND_CAPACITY = 4096
local MULTI_SLOTS = 8
local MULTI_SLOT_CAPACITY = 512
local RECEIVE_CAPACITY = 64 * 1024

local function int1(value)
    return ffi.new("int[1]", value or 0)
end

local function bool1(value)
    return int1(value and 1 or 0)
end

local BAUD = { 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200,
    230400, 460800, 921600, 1000000, 2000000, 3000000 }

local function index_of(values, value, fallback)
    for index, candidate in ipairs(values) do
        if candidate == value then return index - 1 end
    end
    return fallback or 0
end

function M.new(hwnd, cfg)
    if not M.available then return nil end
    if M.available.xcom_imgui_init(hwnd) == 0 then return nil end
    local self = {
        lib = M.available,
        port = ffi.new("char[?]", PORT_CAPACITY),
        send = ffi.new("char[?]", SEND_CAPACITY),
        baud = int1(index_of(BAUD, cfg.baud_rate, 7)),
        data_bits = int1(math.max(0, math.min(3, (cfg.data_bits or 8) - 5))),
        stop_bits = int1(cfg.stop_bits),
        parity = int1(cfg.parity),
        flow = int1(cfg.flow_control),
        dtr = bool1(cfg.dtr_enable),
        rts = bool1(cfg.rts_enable),
        receive_hex = bool1(cfg.receive_hex),
        timestamp = bool1(cfg.timestamp),
        pause_display = bool1(cfg.pause_display),
        auto_clear = bool1((cfg.auto_clear_bytes or 0) > 0),
        auto_clear_bytes = int1(cfg.auto_clear_bytes),
        send_hex = bool1(cfg.send_hex),
        send_crlf = bool1(cfg.send_crlf),
        send_auto = int1(),
        send_period = int1(cfg.autosend_period_ms or 1000),
        multi_text = ffi.new("char[?]", MULTI_SLOTS * MULTI_SLOT_CAPACITY),
        multi_enabled = ffi.new("int[?]", MULTI_SLOTS),
        multi_hex = int1(),
        multi_crlf = int1(),
        multi_page = int1(),
        multi_page_count = int1(1),
        multi_auto = int1(),
        multi_period = int1(1000),
        auto_save = bool1(cfg.auto_save),
        pages = { { text = {}, enabled = {} } },
    }
    return setmetatable(self, { __index = M })
end

function M:draw(connected, rx_bytes, tx_bytes, text)
    text = text or ""
    local n = math.min(#text, RECEIVE_CAPACITY - 1)
    local actions = self.lib.xcom_imgui_draw_console(
        self.port, PORT_CAPACITY, connected and 1 or 0, rx_bytes or 0, tx_bytes or 0,
        self.baud, self.data_bits, self.stop_bits, self.parity, self.flow, self.dtr, self.rts,
        self.receive_hex, self.timestamp, self.pause_display, self.auto_clear, self.auto_clear_bytes,
        self.send, SEND_CAPACITY, self.send_hex, self.send_crlf, self.send_auto, self.send_period,
        self.multi_text, MULTI_SLOT_CAPACITY, self.multi_enabled, self.multi_hex, self.multi_crlf,
        self.multi_page, self.multi_page_count, self.multi_auto, self.multi_period, self.auto_save,
        text, n)
    return tonumber(actions)
end

function M:port_name()
    return ffi.string(self.port)
end

function M:send_text()
    return ffi.string(self.send)
end

function M:serial_config()
    return BAUD[self.baud[0] + 1] or 115200, self.data_bits[0] + 5,
        self.stop_bits[0], self.parity[0], self.flow[0], self.dtr[0] ~= 0, self.rts[0] ~= 0
end

function M:display_options()
    return self.receive_hex[0] ~= 0, self.timestamp[0] ~= 0,
        self.pause_display[0] ~= 0,
        self.auto_clear[0] ~= 0 and math.max(0, self.auto_clear_bytes[0]) or 0
end

function M:multi_entry(index)
    local offset = index * MULTI_SLOT_CAPACITY
    return ffi.string(self.multi_text + offset), self.multi_enabled[index] ~= 0
end

function M:_store_page()
    local page = self.pages[self.multi_page[0] + 1]
    for index = 0, 7 do
        page.text[index + 1] = ffi.string(self.multi_text + index * MULTI_SLOT_CAPACITY)
        page.enabled[index + 1] = self.multi_enabled[index] ~= 0
    end
end

function M:_load_page()
    local page = self.pages[self.multi_page[0] + 1]
    ffi.fill(self.multi_text, MULTI_SLOTS * MULTI_SLOT_CAPACITY, 0)
    for index = 0, 7 do
        local text = page.text[index + 1] or ""
        ffi.copy(self.multi_text + index * MULTI_SLOT_CAPACITY, text, math.min(#text, MULTI_SLOT_CAPACITY - 1))
        self.multi_enabled[index] = page.enabled[index + 1] and 1 or 0
    end
end

function M:change_page(delta)
    self:_store_page()
    self.multi_page[0] = math.max(0, math.min(self.multi_page_count[0] - 1, self.multi_page[0] + delta))
    self:_load_page()
end

function M:add_page()
    self:_store_page()
    if self.multi_page_count[0] >= 50 then return end
    table.insert(self.pages, { text = {}, enabled = {} })
    self.multi_page_count[0] = #self.pages
    self.multi_page[0] = #self.pages - 1
    self:_load_page()
end

function M:remove_page()
    if self.multi_page_count[0] <= 1 then return end
    self:_store_page()
    table.remove(self.pages, self.multi_page[0] + 1)
    self.multi_page_count[0] = #self.pages
    self.multi_page[0] = math.min(self.multi_page[0], #self.pages - 1)
    self:_load_page()
end

function M:set_pages(pages)
    if type(pages) ~= "table" or #pages == 0 then return end
    self.pages = pages
    self.multi_page_count[0] = #pages
    self.multi_page[0] = 0
    self:_load_page()
end

function M:set_ports(ports)
    if #ports == 0 then
        self.lib.xcom_imgui_set_ports(nil, 0)
        return
    end
    local names = ffi.new("const char *[?]", #ports)
    self._port_names = {}
    for index, port in ipairs(ports) do
        self._port_names[index] = port.name
        names[index - 1] = self._port_names[index]
    end
    self.lib.xcom_imgui_set_ports(names, #ports)
end

function M:wndproc(hwnd, msg, wparam, lparam)
    return self.lib.xcom_imgui_wndproc(hwnd, msg, wparam, lparam) ~= 0
end

function M:frame()
    return self.lib.xcom_imgui_new_frame() ~= 0
end

function M:render()
    return self.lib.xcom_imgui_render() ~= 0
end

function M:close()
    self.lib.xcom_imgui_shutdown()
end

return M
