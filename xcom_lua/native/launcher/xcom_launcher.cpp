#include <windows.h>

#include <string>
#include <vector>

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    wchar_t module_path[MAX_PATH]{};
    const DWORD length = GetModuleFileNameW(nullptr, module_path, MAX_PATH);
    if (length == 0U || length >= MAX_PATH) return ERROR_BUFFER_OVERFLOW;

    std::wstring runtime_dir(module_path, length);
    const std::size_t slash = runtime_dir.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return ERROR_PATH_NOT_FOUND;
    runtime_dir.resize(slash);
    std::wstring working_dir = runtime_dir;
    const std::size_t parent_slash = working_dir.find_last_of(L"\\/");
    if (parent_slash == std::wstring::npos) return ERROR_PATH_NOT_FOUND;
    working_dir.resize(parent_slash);

    const std::wstring child = runtime_dir + L"\\luajit.exe";
    std::wstring command = L"\"" + child + L"\" \"" + working_dir + L"\\main.lua\"";
    std::vector<wchar_t> command_buffer(command.begin(), command.end());
    command_buffer.push_back(L'\0');

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    // Launch luajit.exe (a console-subsystem interpreter) with its console
    // window hidden, so no black console flashes alongside the ImGui window.
    startup.dwFlags = STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(child.c_str(), command_buffer.data(), nullptr, nullptr,
                        FALSE, 0U, nullptr, working_dir.c_str(), &startup,
                        &process)) {
        return static_cast<int>(GetLastError());
    }
    CloseHandle(process.hThread);
    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD exit_code = 0U;
    GetExitCodeProcess(process.hProcess, &exit_code);
    CloseHandle(process.hProcess);
    return static_cast<int>(exit_code);
}
