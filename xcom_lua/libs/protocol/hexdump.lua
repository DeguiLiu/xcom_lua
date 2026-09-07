local BYTES_PER_LINE    = 16
local MIDDLE_SEP_POS    = 8
local READ_BUFFER_SIZE  = 4096
local FLUSH_INTERVAL    = 1000
local ASCII_PRINT_START = 32
local ASCII_PRINT_END   = 126

local function build_hex_lookup_table()
    local hex_lookup = {}
    for byte_value = 0, 255 do
        hex_lookup[byte_value] = string.format("%02X", byte_value)
    end
    return hex_lookup
end

local HEX_LOOKUP = build_hex_lookup_table()

local MESSAGES_BY_LOCALE = {
    en = {
        file    = "File   ",
        size    = "Size   ",
        time    = "Time   ",
        error   = "Error opening '%s': %s\n",
        usage   = "Usage: lua hexdump.lua <file>\n",
        example = "Example: lua hexdump.lua image.png\n",
    },
    pt = {
        file    = "Arquivo",
        size    = "Tamanho",
        time    = "Tempo  ",
        error   = "Erro ao abrir '%s': %s\n",
        usage   = "Uso: lua hexdump.lua <arquivo>\n",
        example = "Exemplo: lua hexdump.lua imagem.png\n",
    }
}

local function resolve_system_locale()
    local lang_env = os.getenv("LANG") or os.getenv("LANGUAGE") or os.getenv("LC_ALL") or ""
    return lang_env:lower():find("pt") and "pt" or "en"
end

local SYSTEM_LOCALE   = resolve_system_locale()
local ACTIVE_MESSAGES = MESSAGES_BY_LOCALE[SYSTEM_LOCALE] or MESSAGES_BY_LOCALE["en"]

local function byte_to_printable_ascii(byte_value)
    if byte_value >= ASCII_PRINT_START and byte_value <= ASCII_PRINT_END then
        return string.char(byte_value)
    end
    return "."
end

local function format_readable_size(byte_count)
    if byte_count >= 1024 * 1024 then
        return string.format("%.1f MB", byte_count / (1024 * 1024))
    elseif byte_count >= 1024 then
        return string.format("%.1f KB", byte_count / 1024)
    else
        return string.format("%d B", byte_count)
    end
end

local function build_hex_and_ascii_columns(raw_bytes)
    local hex_parts   = {}
    local ascii_parts = {}
    local num_bytes   = #raw_bytes

    for col = 1, num_bytes do
        local byte_value = raw_bytes:byte(col)

        hex_parts[#hex_parts + 1] = HEX_LOOKUP[byte_value]
        hex_parts[#hex_parts + 1] = (col == MIDDLE_SEP_POS) and "  " or " "

        ascii_parts[#ascii_parts + 1] = byte_to_printable_ascii(byte_value)
    end

    for col = num_bytes + 1, BYTES_PER_LINE do
        hex_parts[#hex_parts + 1] = "   "
        if col == MIDDLE_SEP_POS then
            hex_parts[#hex_parts + 1] = " "
        end
        ascii_parts[#ascii_parts + 1] = " "
    end

    return table.concat(hex_parts), table.concat(ascii_parts)
end

local function format_classic_hex_line(byte_offset, raw_bytes)
    local hex_column, ascii_column = build_hex_and_ascii_columns(raw_bytes)
    return string.format("%08X  %s  |%s|", byte_offset, hex_column, ascii_column)
end

local DumperPrototype = {}
DumperPrototype.__index = DumperPrototype

function DumperPrototype.new(overrides)
    local instance = {
        on_open_file    = DumperPrototype.on_open_file,
        on_format_line  = format_classic_hex_line,
        on_write_output = DumperPrototype.on_write_output,
        on_show_summary = DumperPrototype.on_show_summary,
    }

    if overrides then
        for hook_name, hook_fn in pairs(overrides) do
            instance[hook_name] = hook_fn
        end
    end

    return setmetatable(instance, DumperPrototype)
end

function DumperPrototype:on_open_file(filepath)
    return io.open(filepath, "rb")
end

function DumperPrototype:on_write_output(accumulated_lines)
    io.write(table.concat(accumulated_lines, "\n"), "\n")
    for line_idx = 1, #accumulated_lines do
        accumulated_lines[line_idx] = nil
    end
    return accumulated_lines
end

function DumperPrototype:on_show_summary(filepath, total_bytes, elapsed_seconds)
    io.stderr:write(string.format(
        "%s : %s\n"                  ..
        "%s : %s (%d bytes)\n"       ..
        "%s : %.3f s\n",
        ACTIVE_MESSAGES.file, filepath,
        ACTIVE_MESSAGES.size, format_readable_size(total_bytes), total_bytes,
        ACTIVE_MESSAGES.time, elapsed_seconds
    ))
    io.stderr:flush()
end

function DumperPrototype:run_dump_pipeline(filepath)
    local file_handle, open_error = self:on_open_file(filepath)
    if not file_handle then
        io.stderr:write(string.format(ACTIVE_MESSAGES.error, filepath, open_error))
        return false
    end

    local total_bytes = file_handle:seek("end")
    file_handle:seek("set", 0)

    local start_clock    = os.clock()
    local current_offset = 0
    local line_buffer    = {}

    while true do
        local chunk = file_handle:read(READ_BUFFER_SIZE)
        if not chunk then break end

        for chunk_pos = 1, #chunk, BYTES_PER_LINE do
            local raw_bytes = chunk:sub(chunk_pos, chunk_pos + BYTES_PER_LINE - 1)
            line_buffer[#line_buffer + 1] = self.on_format_line(current_offset, raw_bytes)
            current_offset = current_offset + #raw_bytes
        end

        if #line_buffer >= FLUSH_INTERVAL then
            line_buffer = self:on_write_output(line_buffer)
        end
    end

    if #line_buffer > 0 then
        self:on_write_output(line_buffer)
    end

    self:on_show_summary(filepath, total_bytes, os.clock() - start_clock)

    file_handle:close()
    return true
end

local HexDumpModule = {}

function HexDumpModule.dump(filepath, dumper_overrides)
    local dumper = DumperPrototype.new(dumper_overrides)
    return dumper:run_dump_pipeline(filepath)
end

HexDumpModule.formats = {
    classic = format_classic_hex_line,
}

local is_main_script = (arg ~= nil) and (arg[0] ~= nil)
    and (arg[0]:match("[^/\\]+$") == "hexdump.lua")

if is_main_script then
    local target_filepath = arg[1]

    if not target_filepath then
        io.stderr:write(ACTIVE_MESSAGES.usage)
        io.stderr:write(ACTIVE_MESSAGES.example)
        os.exit(1)
    end

    if not HexDumpModule.dump(target_filepath) then
        os.exit(1)
    end
end

return HexDumpModule