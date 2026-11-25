#include "win32_window.h"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <dwmapi.h>
#include <flutter_windows.h>
#include <objbase.h>
#include <shlobj.h>

#include "resource.h"

#ifdef _MSC_VER
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#endif

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] =
    L"AppsUseLightTheme";

constexpr int kMinClientWidth = 420;
constexpr int kMinClientHeight = 600;
constexpr int kMinTitleBarVisibleWidth = 120;
constexpr int kMinTitleBarVisibleHeight = 32;
constexpr int kMaxReasonableDimension = 32768;
constexpr int kMinReasonableCoord = -32768;
constexpr int kMaxReasonableCoord = 32768;
constexpr size_t kPathBufferChars = 1024;

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) noexcept {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) noexcept {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

struct PersistedWindowState {
  int width = 1280;
  int height = 800;
  int x = 0;
  int y = 0;
  bool has_position = false;
  bool is_maximized = false;
};

struct WindowStatePaths {
  wchar_t company_dir[kPathBufferChars];
  wchar_t app_dir[kPathBufferChars];
  wchar_t ini_file[kPathBufferChars];
  wchar_t tmp_file[kPathBufferChars];
};

bool AppendWidePath(const wchar_t* base,
                    const wchar_t* suffix,
                    wchar_t* out,
                    size_t out_capacity) noexcept {
  if (base == nullptr || suffix == nullptr || out == nullptr) {
    return false;
  }
  const size_t base_len = std::wcslen(base);
  const size_t suffix_len = std::wcslen(suffix);
  if (base_len == 0 || base_len + suffix_len + 1 > out_capacity) {
    return false;
  }
  std::wmemcpy(out, base, base_len);
  std::wmemcpy(out + base_len, suffix, suffix_len + 1);
  return true;
}

bool ResolveWindowStatePaths(WindowStatePaths* paths) noexcept {
  if (paths == nullptr) {
    return false;
  }
  PWSTR roaming_app_data = nullptr;
  const HRESULT hr = SHGetKnownFolderPath(
      FOLDERID_RoamingAppData, KF_FLAG_DEFAULT, nullptr, &roaming_app_data);
  if (FAILED(hr) || roaming_app_data == nullptr) {
    if (roaming_app_data != nullptr) {
      CoTaskMemFree(roaming_app_data);
    }
    return false;
  }
  const bool ok =
      AppendWidePath(roaming_app_data, L"\\TallyIsle", paths->company_dir,
                     kPathBufferChars) &&
      AppendWidePath(paths->company_dir, L"\\TallyIsle", paths->app_dir,
                     kPathBufferChars) &&
      AppendWidePath(paths->app_dir, L"\\window_state.ini", paths->ini_file,
                     kPathBufferChars) &&
      AppendWidePath(paths->app_dir, L"\\window_state.ini.tmp", paths->tmp_file,
                     kPathBufferChars);
  CoTaskMemFree(roaming_app_data);
  return ok;
}

bool ParseBoundedInt(const char* text,
                     int min_value,
                     int max_value,
                     int* out_value) noexcept {
  if (text == nullptr || out_value == nullptr) {
    return false;
  }
  while (*text == ' ' || *text == '\t') {
    ++text;
  }
  if (*text == '\0') {
    return false;
  }
  errno = 0;
  char* end_ptr = nullptr;
  const long parsed = std::strtol(text, &end_ptr, 10);
  if (errno == ERANGE || end_ptr == text) {
    return false;
  }
  while (*end_ptr == ' ' || *end_ptr == '\t') {
    ++end_ptr;
  }
  if (*end_ptr != '\0') {
    return false;
  }
  if (parsed < static_cast<long>(min_value) ||
      parsed > static_cast<long>(max_value)) {
    return false;
  }
  *out_value = static_cast<int>(parsed);
  return true;
}

bool LoadPersistedWindowState(PersistedWindowState* out_state) noexcept {
  if (out_state == nullptr) {
    return false;
  }
  WindowStatePaths paths{};
  if (!ResolveWindowStatePaths(&paths)) {
    return false;
  }

  HANDLE file = CreateFileW(
      paths.ini_file, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }

  char buffer[4096];
  DWORD bytes_read = 0;
  const BOOL read_ok =
      ReadFile(file, buffer, static_cast<DWORD>(sizeof(buffer) - 1),
               &bytes_read, nullptr);
  CloseHandle(file);
  if (!read_ok || bytes_read == 0) {
    return false;
  }
  buffer[bytes_read] = '\0';

  PersistedWindowState parsed{};
  bool got_width = false;
  bool got_height = false;
  bool got_x = false;
  bool got_y = false;
  int has_pos_flag = 0;
  int is_max_flag = 0;

  char* cursor = buffer;
  while (*cursor != '\0') {
    char* line_start = cursor;
    while (*cursor != '\0' && *cursor != '\r' && *cursor != '\n') {
      ++cursor;
    }
    if (*cursor != '\0') {
      *cursor = '\0';
      ++cursor;
      while (*cursor == '\r' || *cursor == '\n') {
        ++cursor;
      }
    }

    while (*line_start == ' ' || *line_start == '\t') {
      ++line_start;
    }
    if (*line_start == '\0' || *line_start == ';' || *line_start == '#' ||
        *line_start == '[') {
      continue;
    }

    char* eq = std::strchr(line_start, '=');
    if (eq == nullptr) {
      continue;
    }
    *eq = '\0';
    char* key = line_start;
    char* value = eq + 1;

    size_t key_len = std::strlen(key);
    while (key_len > 0 &&
           (key[key_len - 1] == ' ' || key[key_len - 1] == '\t')) {
      key[--key_len] = '\0';
    }

    int temp = 0;
    if (std::strcmp(key, "width") == 0) {
      if (ParseBoundedInt(value, 1, kMaxReasonableDimension, &temp)) {
        parsed.width = std::max(kMinClientWidth, temp);
        got_width = true;
      }
    } else if (std::strcmp(key, "height") == 0) {
      if (ParseBoundedInt(value, 1, kMaxReasonableDimension, &temp)) {
        parsed.height = std::max(kMinClientHeight, temp);
        got_height = true;
      }
    } else if (std::strcmp(key, "x") == 0) {
      if (ParseBoundedInt(value, kMinReasonableCoord, kMaxReasonableCoord,
                          &temp)) {
        parsed.x = temp;
        got_x = true;
      }
    } else if (std::strcmp(key, "y") == 0) {
      if (ParseBoundedInt(value, kMinReasonableCoord, kMaxReasonableCoord,
                          &temp)) {
        parsed.y = temp;
        got_y = true;
      }
    } else if (std::strcmp(key, "has_position") == 0) {
      if (ParseBoundedInt(value, 0, 1, &temp)) {
        has_pos_flag = temp;
      }
    } else if (std::strcmp(key, "is_maximized") == 0) {
      if (ParseBoundedInt(value, 0, 1, &temp)) {
        is_max_flag = temp;
      }
    }
  }

  if (!got_width || !got_height) {
    return false;
  }
  parsed.has_position = (has_pos_flag == 1) && got_x && got_y;
  parsed.is_maximized = (is_max_flag == 1);
  *out_state = parsed;
  return true;
}

bool WriteAllBytesToPath(const wchar_t* path,
                         const char* data,
                         DWORD length) noexcept {
  HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  DWORD written = 0;
  const BOOL ok = WriteFile(file, data, length, &written, nullptr);
  CloseHandle(file);
  return ok != FALSE && written == length;
}

void WritePersistedWindowState(const PersistedWindowState& state) noexcept {
  WindowStatePaths paths{};
  if (!ResolveWindowStatePaths(&paths)) {
    return;
  }

  CreateDirectoryW(paths.company_dir, nullptr);
  CreateDirectoryW(paths.app_dir, nullptr);

  char payload[256];
  const int clamped_width = std::max(kMinClientWidth, state.width);
  const int clamped_height = std::max(kMinClientHeight, state.height);
  const int formatted_len = std::snprintf(
      payload, sizeof(payload),
      "[window]\r\n"
      "width=%d\r\n"
      "height=%d\r\n"
      "x=%d\r\n"
      "y=%d\r\n"
      "has_position=%d\r\n"
      "is_maximized=%d\r\n",
      clamped_width, clamped_height, state.x, state.y,
      state.has_position ? 1 : 0, state.is_maximized ? 1 : 0);
  if (formatted_len <= 0 ||
      static_cast<size_t>(formatted_len) >= sizeof(payload)) {
    return;
  }

  const DWORD byte_count = static_cast<DWORD>(formatted_len);
  if (WriteAllBytesToPath(paths.tmp_file, payload, byte_count)) {
    if (MoveFileExW(paths.tmp_file, paths.ini_file,
                    MOVEFILE_REPLACE_EXISTING) != FALSE) {
      return;
    }
    DeleteFileW(paths.tmp_file);
  }
  WriteAllBytesToPath(paths.ini_file, payload, byte_count);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  has_shown_ = false;
  start_maximized_ = false;
  is_maximized_ = false;
  has_saved_position_ = false;
  normal_client_width_ =
      std::max(kMinClientWidth, static_cast<int>(size.width));
  normal_client_height_ =
      std::max(kMinClientHeight, static_cast<int>(size.height));
  normal_outer_x_ = static_cast<int>(origin.x);
  normal_outer_y_ = static_cast<int>(origin.y);

  PersistedWindowState saved{};
  if (LoadPersistedWindowState(&saved)) {
    normal_client_width_ = std::max(kMinClientWidth, saved.width);
    normal_client_height_ = std::max(kMinClientHeight, saved.height);
    if (saved.has_position) {
      normal_outer_x_ = saved.x;
      normal_outer_y_ = saved.y;
      has_saved_position_ = true;
    }
    start_maximized_ = saved.is_maximized;
    is_maximized_ = saved.is_maximized;
  }

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point =
      has_saved_position_
          ? POINT{static_cast<LONG>(normal_outer_x_ + 60),
                  static_cast<LONG>(normal_outer_y_ + 16)}
          : POINT{static_cast<LONG>(origin.x), static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi > 0 ? (dpi / 96.0) : 1.0;

  auto compute_outer_size = [&](UINT target_dpi, double target_scale,
                                int* out_w, int* out_h, int* min_w,
                                int* min_h) {
    RECT window_rect = {0, 0, Scale(normal_client_width_, target_scale),
                        Scale(normal_client_height_, target_scale)};
    AdjustWindowRectExForDpi(&window_rect, WS_OVERLAPPEDWINDOW, FALSE, 0,
                             target_dpi);
    *out_w = window_rect.right - window_rect.left;
    *out_h = window_rect.bottom - window_rect.top;

    RECT min_rect = {0, 0, Scale(kMinClientWidth, target_scale),
                     Scale(kMinClientHeight, target_scale)};
    AdjustWindowRectExForDpi(&min_rect, WS_OVERLAPPEDWINDOW, FALSE, 0,
                             target_dpi);
    *min_w = min_rect.right - min_rect.left;
    *min_h = min_rect.bottom - min_rect.top;
  };

  int outer_width = 0;
  int outer_height = 0;
  int min_outer_width = 0;
  int min_outer_height = 0;
  compute_outer_size(dpi, scale_factor, &outer_width, &outer_height,
                     &min_outer_width, &min_outer_height);

  if (has_saved_position_) {
    RECT candidate_rect = {normal_outer_x_, normal_outer_y_,
                           normal_outer_x_ + outer_width,
                           normal_outer_y_ + outer_height};
    HMONITOR rect_monitor =
        MonitorFromRect(&candidate_rect, MONITOR_DEFAULTTONEAREST);
    if (rect_monitor != nullptr && rect_monitor != monitor) {
      monitor = rect_monitor;
      dpi = FlutterDesktopGetDpiForMonitor(monitor);
      scale_factor = dpi > 0 ? (dpi / 96.0) : 1.0;
      compute_outer_size(dpi, scale_factor, &outer_width, &outer_height,
                         &min_outer_width, &min_outer_height);
    }
  }

  int window_x =
      has_saved_position_ ? normal_outer_x_ : Scale(origin.x, scale_factor);
  int window_y =
      has_saved_position_ ? normal_outer_y_ : Scale(origin.y, scale_factor);

  MONITORINFO monitor_info = {};
  monitor_info.cbSize = sizeof(monitor_info);
  if (GetMonitorInfo(monitor, &monitor_info)) {
    const RECT& work = monitor_info.rcWork;
    const int work_width = work.right - work.left;
    const int work_height = work.bottom - work.top;

    if (work_width > 0 && outer_width > work_width) {
      outer_width = work_width >= min_outer_width ? work_width : min_outer_width;
    }
    if (work_height > 0 && outer_height > work_height) {
      outer_height =
          work_height >= min_outer_height ? work_height : min_outer_height;
    }

    if (has_saved_position_) {
      const int min_drag_w =
          std::min(outer_width, Scale(kMinTitleBarVisibleWidth, scale_factor));
      const int min_drag_h =
          std::min(outer_height, Scale(kMinTitleBarVisibleHeight, scale_factor));
      const int inter_left = std::max<int>(window_x, work.left);
      const int inter_right =
          std::min<int>(window_x + outer_width, work.right);
      const int inter_top = std::max<int>(window_y, work.top);
      const int inter_bottom =
          std::min<int>(window_y + min_drag_h, work.bottom);
      const bool titlebar_visible =
          window_y >= work.top && (inter_right - inter_left) >= min_drag_w &&
          (inter_bottom - inter_top) >= min_drag_h;

      if (!titlebar_visible) {
        const int max_x = std::max<int>(work.left, work.right - outer_width);
        const int max_y = std::max<int>(work.top, work.bottom - outer_height);
        window_x = std::max<int>(work.left, std::min<int>(window_x, max_x));
        window_y = std::max<int>(work.top, std::min<int>(window_y, max_y));
      } else {
        window_x = std::max<int>(
            work.left + min_drag_w - outer_width,
            std::min<int>(window_x, work.right - min_drag_w));
        window_y = std::max<int>(
            work.top, std::min<int>(window_y, work.bottom - min_drag_h));
      }
    } else {
      window_x = work_width > outer_width
                     ? work.left + (work_width - outer_width) / 2
                     : work.left;
      window_y = work_height > outer_height
                     ? work.top + (work_height - outer_height) / 2
                     : work.top;
    }
  }

  normal_outer_x_ = window_x;
  normal_outer_y_ = window_y;
  has_saved_position_ = true;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      window_x, window_y, outer_width, outer_height,
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  if (!window_handle_) {
    return false;
  }
  const int show_cmd = start_maximized_ ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
  const BOOL result = ShowWindow(window_handle_, show_cmd);
  has_shown_ = true;
  UpdateCachedWindowState(window_handle_);
  return result != FALSE;
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_CLOSE:
      if (has_shown_) {
        UpdateCachedWindowState(hwnd);
      }
      SaveWindowState();
      break;

    case WM_DESTROY:
      if (has_shown_) {
        UpdateCachedWindowState(hwnd);
      }
      SaveWindowState();
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
      double scale_factor = dpi / 96.0;
      RECT min_rect = {0, 0, Scale(kMinClientWidth, scale_factor),
                       Scale(kMinClientHeight, scale_factor)};
      AdjustWindowRectExForDpi(&min_rect, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi);
      info->ptMinTrackSize.x = min_rect.right - min_rect.left;
      info->ptMinTrackSize.y = min_rect.bottom - min_rect.top;
      return 0;
    }

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }

    case WM_MOVE:
      if (has_shown_) {
        UpdateCachedWindowState(hwnd);
      }
      return 0;

    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      if (has_shown_) {
        const bool was_maximized = is_maximized_;
        UpdateCachedWindowState(hwnd);
        if (was_maximized != is_maximized_) {
          SaveWindowState();
        }
      }
      return 0;
    }

    case WM_EXITSIZEMOVE:
      if (has_shown_) {
        UpdateCachedWindowState(hwnd);
        SaveWindowState();
      }
      break;

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;

    case WM_SETTINGCHANGE:
      if (lparam != 0 &&
          std::wcscmp(reinterpret_cast<LPCWSTR>(lparam),
                      L"ImmersiveColorSet") == 0) {
        UpdateTheme(hwnd);
      }
      break;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::UpdateCachedWindowState(HWND hwnd) noexcept {
  if (hwnd == nullptr || !IsWindow(hwnd)) {
    return;
  }
  if (IsIconic(hwnd)) {
    return;
  }
  const bool zoomed = IsZoomed(hwnd) != FALSE;
  is_maximized_ = zoomed;
  if (!IsIconic(hwnd) && !IsZoomed(hwnd)) {
    RECT outer_rect{};
    RECT client_rect{};
    if (GetWindowRect(hwnd, &outer_rect) && GetClientRect(hwnd, &client_rect)) {
      const int client_w = client_rect.right - client_rect.left;
      const int client_h = client_rect.bottom - client_rect.top;
      if (client_w > 0 && client_h > 0) {
        HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
        const double scale_factor = dpi > 0 ? (dpi / 96.0) : 1.0;
        const int logical_w = static_cast<int>(client_w / scale_factor + 0.5);
        const int logical_h = static_cast<int>(client_h / scale_factor + 0.5);
        normal_client_width_ = std::max(kMinClientWidth, logical_w);
        normal_client_height_ = std::max(kMinClientHeight, logical_h);
        normal_outer_x_ = outer_rect.left;
        normal_outer_y_ = outer_rect.top;
        has_saved_position_ = true;
      }
    }
  }
}

void Win32Window::SaveWindowState() const noexcept {
  PersistedWindowState state{};
  state.width = std::max(kMinClientWidth, normal_client_width_);
  state.height = std::max(kMinClientHeight, normal_client_height_);
  state.x = normal_outer_x_;
  state.y = normal_outer_y_;
  state.has_position = has_saved_position_;
  state.is_maximized = is_maximized_;
  WritePersistedWindowState(state);
}

void Win32Window::Destroy() {
  if (window_handle_) {
    if (has_shown_) {
      UpdateCachedWindowState(window_handle_);
    }
    SaveWindowState();
  }

  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
