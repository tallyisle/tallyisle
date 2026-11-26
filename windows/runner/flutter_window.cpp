#include "flutter_window.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <cctype>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

#ifdef _MSC_VER
#pragma comment(lib, "shell32.lib")
#endif

namespace {

constexpr const char kFilesChannelName[] = "com.tallyisle/files";

bool IsValidMailtoAddress(const std::string& addr) {
  if (addr.empty()) {
    return false;
  }
  const size_t at = addr.find('@');
  if (at == std::string::npos || at == 0 || at + 1 >= addr.size() ||
      addr.find('@', at + 1) != std::string::npos) {
    return false;
  }
  const std::string local = addr.substr(0, at);
  const std::string domain = addr.substr(at + 1);
  for (unsigned char ch : local) {
    if (!(std::isalnum(ch) || ch == '.' || ch == '_' || ch == '%' ||
          ch == '+' || ch == '-')) {
      return false;
    }
  }
  const size_t last_dot = domain.rfind('.');
  if (last_dot == std::string::npos || last_dot == 0 ||
      domain.size() - last_dot - 1 < 2) {
    return false;
  }
  for (unsigned char ch : domain) {
    if (!(std::isalnum(ch) || ch == '.' || ch == '-')) {
      return false;
    }
  }
  for (size_t i = last_dot + 1; i < domain.size(); ++i) {
    if (!std::isalpha(static_cast<unsigned char>(domain[i]))) {
      return false;
    }
  }
  return true;
}

bool HasAllowedExternalScheme(const std::string& url) {
  for (unsigned char ch : url) {
    if (ch <= 0x1F || ch == 0x7F) {
      return false;
    }
  }
  auto starts_with_ignore_case = [&](const char* prefix, size_t prefix_len) {
    if (url.size() <= prefix_len) {
      return false;
    }
    for (size_t i = 0; i < prefix_len; ++i) {
      const auto ch = static_cast<unsigned char>(url[i]);
      if (std::tolower(ch) != prefix[i]) {
        return false;
      }
    }
    return true;
  };
  if (starts_with_ignore_case("https://", 8)) {
    return url[8] != '/' && url[8] != ' ';
  }
  if (starts_with_ignore_case("http://", 7)) {
    return url[7] != '/' && url[7] != ' ';
  }
  if (starts_with_ignore_case("mailto:", 7)) {
    for (unsigned char ch : url) {
      if (std::isspace(ch) || ch == '"' || ch == '\'' || ch == '`' ||
          ch == '$' || ch == '|' || ch == '&' || ch == ';' || ch == '<' ||
          ch == '>' || ch == '\\' || ch == '?' || ch == '#') {
        return false;
      }
    }
    return IsValidMailtoAddress(url.substr(7));
  }
  return false;
}

std::optional<std::wstring> WideFromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int target_length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
      static_cast<int>(utf8.size()), nullptr, 0);
  if (target_length <= 0) {
    return std::nullopt;
  }
  std::wstring wide(static_cast<size_t>(target_length), L'\0');
  const int converted = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
      static_cast<int>(utf8.size()), wide.data(), target_length);
  if (converted != target_length) {
    return std::nullopt;
  }
  return wide;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  flutter::MethodChannel<flutter::EncodableValue> files_channel(
      flutter_controller_->engine()->messenger(), kFilesChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  files_channel.SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "openExternalUrl") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            result->Error("INVALID_ARGS", "Expected map arguments");
            return;
          }
          const auto url_it = args->find(flutter::EncodableValue("url"));
          if (url_it == args->end()) {
            result->Error("INVALID_ARGS", "Missing url argument");
            return;
          }
          const auto* url = std::get_if<std::string>(&url_it->second);
          if (url == nullptr || !HasAllowedExternalScheme(*url)) {
            result->Error("INVALID_URL",
                          "Only HTTP/HTTPS or mailto URLs are allowed");
            return;
          }
          const auto wide_url = WideFromUtf8(*url);
          if (!wide_url.has_value() || wide_url->empty()) {
            result->Error("INVALID_URL", "Invalid UTF-8 URL");
            return;
          }
          HINSTANCE res = ::ShellExecuteW(
              nullptr, L"open", wide_url->c_str(), nullptr, nullptr,
              SW_SHOWNORMAL);
          const bool launched = reinterpret_cast<INT_PTR>(res) > 32;
          result->Success(flutter::EncodableValue(launched));
          return;
        }
        result->NotImplemented();
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
