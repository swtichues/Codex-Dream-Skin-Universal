#include <windows.h>

#define BUFFER_CHARS 32768

static WCHAR module_path[BUFFER_CHARS];
static WCHAR base_directory[BUFFER_CHARS];
static WCHAR script_path[BUFFER_CHARS];
static WCHAR powershell_path[BUFFER_CHARS];
static WCHAR command_line[BUFFER_CHARS * 2];

static BOOL append_text(WCHAR *target, DWORD capacity, const WCHAR *text) {
  DWORD position = lstrlenW(target);
  DWORD length = lstrlenW(text);
  if (position + length + 1 > capacity) return FALSE;
  CopyMemory(target + position, text, (length + 1) * sizeof(WCHAR));
  return TRUE;
}

static void show_error(const WCHAR *message) {
  MessageBoxW(NULL, message, L"Codex Dream Skin", MB_OK | MB_ICONERROR | MB_SETFOREGROUND);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR arguments, int show) {
  (void)instance;
  (void)previous;
  (void)show;

  DWORD module_length = GetModuleFileNameW(NULL, module_path, BUFFER_CHARS);
  if (module_length == 0 || module_length >= BUFFER_CHARS) {
    show_error(L"Unable to resolve the launcher path.");
    return 2;
  }

  CopyMemory(base_directory, module_path, (module_length + 1) * sizeof(WCHAR));
  WCHAR *last_slash = NULL;
  for (WCHAR *cursor = base_directory; *cursor; ++cursor) {
    if (*cursor == L'\\' || *cursor == L'/') last_slash = cursor;
  }
  if (last_slash == NULL) {
    show_error(L"Unable to resolve the launcher directory.");
    return 2;
  }
  *last_slash = L'\0';

  script_path[0] = L'\0';
  if (!append_text(script_path, BUFFER_CHARS, base_directory) ||
      !append_text(script_path, BUFFER_CHARS, L"\\CodexDreamSkinLauncher.ps1")) {
    show_error(L"The launcher script path is too long.");
    return 2;
  }
  if (GetFileAttributesW(script_path) == INVALID_FILE_ATTRIBUTES) {
    show_error(L"CodexDreamSkinLauncher.ps1 was not found beside this EXE.");
    return 3;
  }

  UINT system_length = GetSystemDirectoryW(powershell_path, BUFFER_CHARS);
  if (system_length == 0 || system_length >= BUFFER_CHARS ||
      !append_text(powershell_path, BUFFER_CHARS, L"\\WindowsPowerShell\\v1.0\\powershell.exe")) {
    show_error(L"Unable to locate Windows PowerShell.");
    return 4;
  }
  if (GetFileAttributesW(powershell_path) == INVALID_FILE_ATTRIBUTES) {
    show_error(L"Windows PowerShell 5.1 is not available.");
    return 4;
  }

  command_line[0] = L'\0';
  if (!append_text(command_line, BUFFER_CHARS * 2, L"\"") ||
      !append_text(command_line, BUFFER_CHARS * 2, powershell_path) ||
      !append_text(command_line, BUFFER_CHARS * 2,
        L"\" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"") ||
      !append_text(command_line, BUFFER_CHARS * 2, script_path) ||
      !append_text(command_line, BUFFER_CHARS * 2, L"\"")) {
    show_error(L"The PowerShell command line is too long.");
    return 5;
  }
  if (arguments != NULL && arguments[0] != L'\0') {
    if (!append_text(command_line, BUFFER_CHARS * 2, L" ") ||
        !append_text(command_line, BUFFER_CHARS * 2, arguments)) {
      show_error(L"The launcher arguments are too long.");
      return 5;
    }
  }

  STARTUPINFOW startup;
  PROCESS_INFORMATION process;
  ZeroMemory(&startup, sizeof(startup));
  ZeroMemory(&process, sizeof(process));
  startup.cb = sizeof(startup);

  if (!CreateProcessW(
        powershell_path,
        command_line,
        NULL,
        NULL,
        FALSE,
        CREATE_NO_WINDOW,
        NULL,
        base_directory,
        &startup,
        &process)) {
    show_error(L"Windows PowerShell could not start the Dream Skin GUI.");
    return 6;
  }

  CloseHandle(process.hThread);
  WaitForSingleObject(process.hProcess, INFINITE);
  DWORD exit_code = 1;
  if (!GetExitCodeProcess(process.hProcess, &exit_code)) exit_code = 1;
  CloseHandle(process.hProcess);
  return (int)exit_code;
}
