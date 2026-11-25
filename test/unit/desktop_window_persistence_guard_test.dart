import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _readRepoFile(String relativePath) {
  final file = File(relativePath);
  expect(
    file.existsSync(),
    isTrue,
    reason: 'Expected repository file to exist: $relativePath',
  );
  return file.readAsStringSync();
}

String _stripCppComments(String source) {
  final withoutBlock = source.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  return withoutBlock.replaceAll(RegExp(r'//.*$', multiLine: true), '');
}

void main() {
  group('Desktop native window size & position persistence guards', () {
    test('pubspec.yaml remains zero-plugin for desktop window management', () {
      final pubspec = _readRepoFile('pubspec.yaml');
      for (final forbidden in const <String>[
        'window_manager',
        'bitsdojo_window',
        'window_size',
      ]) {
        expect(
          pubspec.contains(forbidden),
          isFalse,
          reason: 'pubspec.yaml must not add $forbidden',
        );
      }
    });

    test(
      'Windows Win32Window persists normal bounds & maximized state safely under _HAS_EXCEPTIONS=0',
      () {
        final header = _readRepoFile('windows/runner/win32_window.h');
        final impl = _readRepoFile('windows/runner/win32_window.cpp');
        final strippedImpl = _stripCppComments(impl);
        final strippedHeader = _stripCppComments(header);

        // Zero C++ exceptions or throwing STL helpers (_HAS_EXCEPTIONS=0 + /W4 /WX).
        for (final forbiddenPattern in <RegExp>[
          RegExp(r'\btry\b'),
          RegExp(r'\bcatch\b'),
          RegExp(r'\bthrow\b'),
          RegExp(r'\bstd::sto[a-z]+\b'),
          RegExp(r'\bstd::filesystem\b'),
        ]) {
          expect(
            forbiddenPattern.hasMatch(strippedImpl),
            isFalse,
            reason:
                'win32_window.cpp must not match ${forbiddenPattern.pattern}',
          );
          expect(
            forbiddenPattern.hasMatch(strippedHeader),
            isFalse,
            reason: 'win32_window.h must not match ${forbiddenPattern.pattern}',
          );
        }

        // KnownFolder %APPDATA%\TallyIsle\TallyIsle\window_state.ini & linked Win32 libs.
        expect(impl, contains('SHGetKnownFolderPath'));
        expect(impl, contains('FOLDERID_RoamingAppData'));
        expect(impl, contains('CoTaskMemFree'));
        expect(impl, contains(r'L"\\TallyIsle"'));
        expect(impl, contains(r'L"\\window_state.ini"'));
        expect(impl, contains('#pragma comment(lib, "shell32.lib")'));
        expect(impl, contains('#pragma comment(lib, "ole32.lib")'));

        // Minimum 420x600 logical client bounds, DPI scaling, work-area clamping, maximized restore.
        expect(impl, contains('kMinClientWidth = 420'));
        expect(impl, contains('kMinClientHeight = 600'));
        expect(impl, contains('MonitorFromPoint'));
        expect(impl, contains('AdjustWindowRectExForDpi'));
        expect(impl, contains('rcWork'));
        expect(impl, contains('SW_SHOWMAXIMIZED'));
        expect(impl, contains('SW_SHOWNORMAL'));
        expect(impl, contains('!IsIconic(hwnd) && !IsZoomed(hwnd)'));

        // Persistence hooks on WM_CLOSE, WM_EXITSIZEMOVE, and WM_DESTROY BEFORE window_handle_ = nullptr.
        expect(impl, contains('case WM_CLOSE:'));
        expect(impl, contains('case WM_EXITSIZEMOVE:'));
        final destroyCaseMatch = RegExp(
          r'case WM_DESTROY:([\s\S]*?)return 0;',
        ).firstMatch(strippedImpl);
        expect(
          destroyCaseMatch,
          isNotNull,
          reason: 'WM_DESTROY handler must exist in win32_window.cpp',
        );
        final destroyBody = destroyCaseMatch!.group(1)!;
        final saveIndex = destroyBody.indexOf('SaveWindowState()');
        final nullHandleIndex = destroyBody.indexOf('window_handle_ = nullptr');
        expect(saveIndex, greaterThanOrEqualTo(0));
        expect(nullHandleIndex, greaterThan(saveIndex));
      },
    );

    test(
      'Linux GTK3 runner persists via GKeyFile, guards Wayland (0,0) & CSD shadows, and hooks delete-event before FlView realize',
      () {
        final linuxSrc = _readRepoFile('linux/runner/my_application.cc');
        final strippedLinux = _stripCppComments(linuxSrc);

        // Config path & GKeyFile persistence.
        expect(linuxSrc, contains('g_get_user_config_dir()'));
        expect(linuxSrc, contains('APPLICATION_ID'));
        expect(linuxSrc, contains('"window_state.ini"'));
        expect(linuxSrc, contains('g_key_file_load_from_file'));
        expect(linuxSrc, contains('g_key_file_save_to_file'));

        // 420x600 minimum & 1280x800 default bounds.
        expect(linuxSrc, contains('kMinWindowWidth = 420'));
        expect(linuxSrc, contains('kMinWindowHeight = 600'));
        expect(linuxSrc, contains('kDefaultWindowWidth = 1280'));
        expect(linuxSrc, contains('kDefaultWindowHeight = 800'));

        // Non-deprecated GTK 3.22+ monitor APIs (-Wall -Werror clean).
        expect(linuxSrc, contains('gdk_display_get_n_monitors'));
        expect(linuxSrc, contains('gdk_display_get_monitor'));
        expect(linuxSrc, contains('gdk_monitor_get_workarea'));
        expect(strippedLinux.contains('gdk_screen_get_n_monitors'), isFalse);
        expect(
          strippedLinux.contains('gdk_screen_get_monitor_workarea'),
          isFalse,
        );

        // X11 vs Wayland guard and CSD shadow-safe gtk_window_get_size.
        expect(linuxSrc, contains('#ifdef GDK_WINDOWING_X11'));
        expect(linuxSrc, contains('GDK_IS_X11_DISPLAY'));
        expect(linuxSrc, contains('gtk_window_move'));
        expect(linuxSrc, contains('gtk_window_maximize'));
        expect(linuxSrc, contains('gtk_window_get_size'));
        expect(linuxSrc, contains('GDK_WINDOW_STATE_MAXIMIZED'));
        expect(linuxSrc, contains('GDK_WINDOW_STATE_FULLSCREEN'));
        expect(linuxSrc, contains('GDK_WINDOW_STATE_ICONIFIED'));
        expect(linuxSrc, contains('GDK_WINDOW_STATE_TILED'));
        expect(strippedLinux.contains('event->width'), isFalse);
        expect(strippedLinux.contains('event->height'), isFalse);

        // Connect "delete-event" BEFORE gtk_widget_realize(GTK_WIDGET(view)).
        final activateIdx = strippedLinux.indexOf('my_application_activate(');
        expect(activateIdx, greaterThanOrEqualTo(0));
        final activateBody = strippedLinux.substring(activateIdx);
        final deleteConnectIdx = activateBody.indexOf('"delete-event"');
        final realizeIdx = activateBody.indexOf(
          'gtk_widget_realize(GTK_WIDGET(view))',
        );
        expect(deleteConnectIdx, greaterThan(0));
        expect(
          realizeIdx,
          greaterThan(deleteConnectIdx),
          reason:
              '"delete-event" must be connected before gtk_widget_realize(view)',
        );
        expect(linuxSrc, contains('my_application_shutdown'));

        // Bilingual brand title invariants preserved.
        expect(linuxSrc, contains('g_get_language_names'));
        expect(linuxSrc, contains('"帐屿"'));
        expect(linuxSrc, contains('"TallyIsle"'));
      },
    );

    test(
      'macOS MainFlutterWindow disables AppKit restorable conflict, clamps visibleFrame, and persists normal/zoomed/fullscreen state',
      () {
        final macSrc = _readRepoFile('macos/Runner/MainFlutterWindow.swift');

        expect(macSrc, contains('self.isRestorable = false'));
        expect(macSrc, contains('UserDefaults.standard'));
        expect(macSrc, contains('minContentWidth: CGFloat = 420'));
        expect(macSrc, contains('minContentHeight: CGFloat = 600'));
        expect(macSrc, contains('defaultContentWidth: CGFloat = 1280'));
        expect(macSrc, contains('defaultContentHeight: CGFloat = 800'));

        // Multi-monitor & menu bar clamping against NSScreen.screens visibleFrame.
        expect(macSrc, contains('NSScreen.screens'));
        expect(macSrc, contains('visibleFrame'));
        expect(macSrc, contains('visibleFrame.maxY'));

        // Zoom & async fullscreen restore + observer hooks + normal-frame guard.
        expect(macSrc, contains('self.zoom(nil)'));
        expect(macSrc, contains('DispatchQueue.main.async'));
        expect(macSrc, contains('self.toggleFullScreen(nil)'));
        expect(macSrc, contains('NSWindow.didResizeNotification'));
        expect(macSrc, contains('NSWindow.didMoveNotification'));
        expect(macSrc, contains('NSWindow.didEnterFullScreenNotification'));
        expect(macSrc, contains('NSWindow.didExitFullScreenNotification'));
        expect(macSrc, contains('NSWindow.willCloseNotification'));
        // Guard against nonexistent AppKit NSWindow notification members
        // (windowDidFailToEnter/ExitFullScreen are NSWindowDelegate-only).
        expect(
          macSrc.contains('didFailToEnterFullScreenNotification'),
          isFalse,
        );
        expect(macSrc.contains('didFailToExitFullScreenNotification'), isFalse);
        expect(
          macSrc,
          contains(
            '!self.styleMask.contains(.fullScreen) && !self.isMiniaturized && !self.isZoomed',
          ),
        );

        // Bilingual brand title invariants preserved.
        expect(macSrc, contains('Locale.preferredLanguages'));
        expect(macSrc, contains('"帐屿"'));
        expect(macSrc, contains('"TallyIsle"'));
      },
    );
  });
}
