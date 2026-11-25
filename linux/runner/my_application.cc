#include "my_application.h"

#include <algorithm>
#include <flutter_linux/flutter_linux.h>
#include <string.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* main_window;
  gint normal_width;
  gint normal_height;
  gint normal_x;
  gint normal_y;
  gboolean has_position;
  gboolean is_maximized;
  gboolean state_initialized;
  GdkWindowState window_state_flags;
  guint save_debounce_source_id;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

namespace {

constexpr gint kDefaultWindowWidth = 1280;
constexpr gint kDefaultWindowHeight = 800;
constexpr gint kMinWindowWidth = 420;
constexpr gint kMinWindowHeight = 600;
constexpr gint kMaxReasonableDimension = 32768;
constexpr gint kMinReasonableCoord = -32768;
constexpr gint kMaxReasonableCoord = 32768;
constexpr gint kTitleBarDragWidth = 120;
constexpr gint kTitleBarDragHeight = 32;
constexpr guint kSaveDebounceMs = 180;
constexpr const gchar* kWindowStateGroup = "window";

constexpr GdkWindowState kNonNormalWindowMask = static_cast<GdkWindowState>(
    GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN |
    GDK_WINDOW_STATE_ICONIFIED | GDK_WINDOW_STATE_TILED
#if GTK_CHECK_VERSION(3, 22, 23)
    | GDK_WINDOW_STATE_TOP_TILED | GDK_WINDOW_STATE_RIGHT_TILED |
    GDK_WINDOW_STATE_BOTTOM_TILED | GDK_WINDOW_STATE_LEFT_TILED
#endif
);

const gchar* resolve_window_title() {
  const gchar* const* languages = g_get_language_names();
  if (languages != nullptr) {
    for (const gchar* const* it = languages; *it != nullptr; ++it) {
      const gchar* lang = *it;
      if (lang[0] == '\0') {
        continue;
      }
      if (g_ascii_strcasecmp(lang, "C") == 0 ||
          g_ascii_strcasecmp(lang, "POSIX") == 0) {
        break;
      }
      if (g_ascii_strncasecmp(lang, "zh", 2) == 0 &&
          (lang[2] == '\0' || lang[2] == '_' || lang[2] == '-' ||
           lang[2] == '.' || lang[2] == '@')) {
        return "帐屿";
      }
      break;
    }
  }
  return "TallyIsle";
}

constexpr const gchar* kRelativeLogoAssetPath =
    "data/flutter_assets/assets/branding/tallyisle-logo-original.png";

gboolean is_x11_display() {
#ifdef GDK_WINDOWING_X11
  GdkDisplay* display = gdk_display_get_default();
  return display != nullptr && GDK_IS_X11_DISPLAY(display);
#else
  return FALSE;
#endif
}

gboolean should_use_gnome_header_bar(GtkWindow* window) {
  const gchar* kde_session = g_getenv("KDE_FULL_SESSION");
  if (kde_session != nullptr && kde_session[0] != '\0' &&
      g_ascii_strcasecmp(kde_session, "false") != 0 &&
      g_strcmp0(kde_session, "0") != 0) {
    return FALSE;
  }

  const gchar* xdg_desktop = g_getenv("XDG_CURRENT_DESKTOP");
  if (xdg_desktop == nullptr || xdg_desktop[0] == '\0') {
    return FALSE;
  }
  g_autofree gchar* xdg_lower = g_ascii_strdown(xdg_desktop, -1);
  if (strstr(xdg_lower, "gnome") == nullptr) {
    return FALSE;
  }

#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      return FALSE;
    }
  }
#else
  (void)window;
#endif

  return TRUE;
}

void set_window_icon_best_effort(GtkWindow* window) {
  g_autofree gchar* exe_path = g_file_read_link("/proc/self/exe", nullptr);
  g_autofree gchar* exe_dir =
      exe_path != nullptr ? g_path_get_dirname(exe_path) : nullptr;
  g_autofree gchar* bundled_icon_path =
      exe_dir != nullptr
          ? g_build_filename(exe_dir, kRelativeLogoAssetPath, nullptr)
          : nullptr;

  const gchar* candidates[] = {bundled_icon_path, kRelativeLogoAssetPath};
  for (const gchar* candidate : candidates) {
    if (candidate == nullptr ||
        !g_file_test(candidate, G_FILE_TEST_IS_REGULAR)) {
      continue;
    }
    GError* icon_error = nullptr;
    if (gtk_window_set_icon_from_file(window, candidate, &icon_error)) {
      return;
    }
    g_clear_error(&icon_error);
  }
}

void load_window_state(MyApplication* self) {
  self->normal_width = kDefaultWindowWidth;
  self->normal_height = kDefaultWindowHeight;
  self->normal_x = 0;
  self->normal_y = 0;
  self->has_position = FALSE;
  self->is_maximized = FALSE;
  self->state_initialized = TRUE;

  g_autofree gchar* state_path = g_build_filename(
      g_get_user_config_dir(), APPLICATION_ID, "window_state.ini", nullptr);
  g_autoptr(GKeyFile) key_file = g_key_file_new();
  if (!g_key_file_load_from_file(key_file, state_path, G_KEY_FILE_NONE,
                                 nullptr)) {
    return;
  }

  GError* error = nullptr;
  const gint width =
      g_key_file_get_integer(key_file, kWindowStateGroup, "width", &error);
  const gboolean has_width =
      (error == nullptr && width > 0 && width <= kMaxReasonableDimension);
  g_clear_error(&error);

  const gint height =
      g_key_file_get_integer(key_file, kWindowStateGroup, "height", &error);
  const gboolean has_height =
      (error == nullptr && height > 0 && height <= kMaxReasonableDimension);
  g_clear_error(&error);

  if (!has_width || !has_height) {
    return;
  }

  self->normal_width = std::max(kMinWindowWidth, width);
  self->normal_height = std::max(kMinWindowHeight, height);

  const gboolean has_pos_flag = g_key_file_get_boolean(
      key_file, kWindowStateGroup, "has_position", &error);
  const gboolean valid_has_pos = (error == nullptr && has_pos_flag);
  g_clear_error(&error);

  const gint pos_x =
      g_key_file_get_integer(key_file, kWindowStateGroup, "x", &error);
  const gboolean valid_x = (error == nullptr && pos_x >= kMinReasonableCoord &&
                            pos_x <= kMaxReasonableCoord);
  g_clear_error(&error);

  const gint pos_y =
      g_key_file_get_integer(key_file, kWindowStateGroup, "y", &error);
  const gboolean valid_y = (error == nullptr && pos_y >= kMinReasonableCoord &&
                            pos_y <= kMaxReasonableCoord);
  g_clear_error(&error);

  if (valid_has_pos && valid_x && valid_y) {
    self->normal_x = pos_x;
    self->normal_y = pos_y;
    self->has_position = TRUE;
  }

  const gboolean is_max_flag = g_key_file_get_boolean(
      key_file, kWindowStateGroup, "is_maximized", &error);
  if (error == nullptr) {
    self->is_maximized = is_max_flag;
  }
  g_clear_error(&error);
}

void save_window_state(MyApplication* self) {
  if (!self->state_initialized) {
    return;
  }
  g_autofree gchar* config_dir =
      g_build_filename(g_get_user_config_dir(), APPLICATION_ID, nullptr);
  if (g_mkdir_with_parents(config_dir, 0700) != 0) {
    return;
  }

  g_autofree gchar* state_path = g_build_filename(
      g_get_user_config_dir(), APPLICATION_ID, "window_state.ini", nullptr);
  g_autoptr(GKeyFile) key_file = g_key_file_new();
  g_key_file_set_integer(key_file, kWindowStateGroup, "width",
                         std::max(kMinWindowWidth, self->normal_width));
  g_key_file_set_integer(key_file, kWindowStateGroup, "height",
                         std::max(kMinWindowHeight, self->normal_height));
  g_key_file_set_boolean(key_file, kWindowStateGroup, "has_position",
                         self->has_position);
  if (self->has_position) {
    g_key_file_set_integer(key_file, kWindowStateGroup, "x", self->normal_x);
    g_key_file_set_integer(key_file, kWindowStateGroup, "y", self->normal_y);
  }
  g_key_file_set_boolean(key_file, kWindowStateGroup, "is_maximized",
                         self->is_maximized);

  g_autoptr(GError) error = nullptr;
  g_key_file_save_to_file(key_file, state_path, &error);
}

void apply_restored_window_geometry(MyApplication* self, GtkWindow* window) {
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  if (display == nullptr) {
    display = gdk_display_get_default();
  }

  gint width = std::max(kMinWindowWidth, self->normal_width);
  gint height = std::max(kMinWindowHeight, self->normal_height);
  const int n_monitors =
      display != nullptr ? gdk_display_get_n_monitors(display) : 0;

  if (!is_x11_display()) {
    if (n_monitors > 0) {
      GdkMonitor* monitor = gdk_display_get_primary_monitor(display);
      if (monitor == nullptr) {
        monitor = gdk_display_get_monitor(display, 0);
      }
      if (monitor != nullptr) {
        GdkRectangle work{};
        gdk_monitor_get_workarea(monitor, &work);
        if (work.width >= kMinWindowWidth && width > work.width) {
          width = work.width;
        }
        if (work.height >= kMinWindowHeight && height > work.height) {
          height = work.height;
        }
      }
    }
    self->normal_width = width;
    self->normal_height = height;
    gtk_window_set_default_size(window, width, height);
    if (self->is_maximized) {
      gtk_window_maximize(window);
    }
    return;
  }

  if (self->has_position && n_monitors > 0) {
    gint x = self->normal_x;
    gint y = self->normal_y;

    GdkMonitor* best_monitor = nullptr;
    gint64 best_overlap_area = 0;
    GdkMonitor* nearest_monitor = nullptr;
    gint64 nearest_dist_sq = G_MAXINT64;
    gboolean any_titlebar_visible = FALSE;

    const gint center_x = x + width / 2;
    const gint center_y = y + height / 2;
    const gint min_drag_w = std::min(width, kTitleBarDragWidth);
    const gint min_drag_h = std::min(height, kTitleBarDragHeight);

    for (int i = 0; i < n_monitors; ++i) {
      GdkMonitor* monitor = gdk_display_get_monitor(display, i);
      if (monitor == nullptr) {
        continue;
      }
      GdkRectangle work{};
      gdk_monitor_get_workarea(monitor, &work);

      const gint inter_left = std::max(x, work.x);
      const gint inter_right = std::min(x + width, work.x + work.width);
      const gint inter_top = std::max(y, work.y);
      const gint inter_bottom = std::min(y + height, work.y + work.height);
      if (inter_right > inter_left && inter_bottom > inter_top) {
        const gint64 area = static_cast<gint64>(inter_right - inter_left) *
                            static_cast<gint64>(inter_bottom - inter_top);
        if (area > best_overlap_area) {
          best_overlap_area = area;
          best_monitor = monitor;
        }
      }

      const gint drag_bottom =
          std::min(y + min_drag_h, work.y + work.height);
      if (y >= work.y && (inter_right - inter_left) >= min_drag_w &&
          (drag_bottom - inter_top) >= min_drag_h) {
        any_titlebar_visible = TRUE;
      }

      const gint64 dx =
          static_cast<gint64>(center_x) - (work.x + work.width / 2);
      const gint64 dy =
          static_cast<gint64>(center_y) - (work.y + work.height / 2);
      const gint64 dist_sq = dx * dx + dy * dy;
      if (dist_sq < nearest_dist_sq) {
        nearest_dist_sq = dist_sq;
        nearest_monitor = monitor;
      }
    }

    GdkMonitor* target_monitor =
        best_monitor != nullptr ? best_monitor : nearest_monitor;
    if (target_monitor == nullptr) {
      target_monitor = gdk_display_get_primary_monitor(display);
    }
    if (target_monitor == nullptr) {
      target_monitor = gdk_display_get_monitor(display, 0);
    }

    if (target_monitor != nullptr) {
      GdkRectangle work{};
      gdk_monitor_get_workarea(target_monitor, &work);
      if (work.width > 0 && width > work.width) {
        width = work.width >= kMinWindowWidth ? work.width : kMinWindowWidth;
      }
      if (work.height > 0 && height > work.height) {
        height =
            work.height >= kMinWindowHeight ? work.height : kMinWindowHeight;
      }

      const gint clamped_drag_w = std::min(width, kTitleBarDragWidth);
      const gint clamped_drag_h = std::min(height, kTitleBarDragHeight);
      if (!any_titlebar_visible) {
        const gint max_x = work.x + std::max(0, work.width - width);
        const gint max_y = work.y + std::max(0, work.height - height);
        x = std::max(work.x, std::min(x, max_x));
        y = std::max(work.y, std::min(y, max_y));
      } else {
        x = std::max(work.x + clamped_drag_w - width,
                     std::min(x, work.x + work.width - clamped_drag_w));
        y = std::max(work.y,
                     std::min(y, work.y + work.height - clamped_drag_h));
      }
    }

    self->normal_width = width;
    self->normal_height = height;
    self->normal_x = x;
    self->normal_y = y;
    gtk_window_set_default_size(window, width, height);
    gtk_window_move(window, x, y);
  } else {
    if (n_monitors > 0) {
      GdkMonitor* monitor = gdk_display_get_primary_monitor(display);
      if (monitor == nullptr) {
        monitor = gdk_display_get_monitor(display, 0);
      }
      if (monitor != nullptr) {
        GdkRectangle work{};
        gdk_monitor_get_workarea(monitor, &work);
        if (work.width >= kMinWindowWidth && width > work.width) {
          width = work.width;
        }
        if (work.height >= kMinWindowHeight && height > work.height) {
          height = work.height;
        }
      }
    }
    self->normal_width = width;
    self->normal_height = height;
    gtk_window_set_default_size(window, width, height);
    gtk_window_set_position(window, GTK_WIN_POS_CENTER);
  }

  if (self->is_maximized) {
    gtk_window_maximize(window);
  }
}

void refresh_cached_window_geometry(MyApplication* self) {
  if (self->main_window == nullptr ||
      !gtk_widget_get_visible(GTK_WIDGET(self->main_window))) {
    return;
  }
  GdkWindow* gdk_win = gtk_widget_get_window(GTK_WIDGET(self->main_window));
  const GdkWindowState live_state =
      gdk_win != nullptr ? gdk_window_get_state(gdk_win)
                         : self->window_state_flags;
  const GdkWindowState effective_state =
      static_cast<GdkWindowState>(live_state | self->window_state_flags);
  if ((effective_state & GDK_WINDOW_STATE_ICONIFIED) != 0) {
    return;
  }

  const gboolean maximized =
      gtk_window_is_maximized(self->main_window) ||
      (effective_state &
       (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN)) != 0;
  self->is_maximized = maximized;

  if (!maximized && (effective_state & kNonNormalWindowMask) == 0) {
    gint width = 0;
    gint height = 0;
    gtk_window_get_size(self->main_window, &width, &height);
    if (width > 0 && height > 0) {
      self->normal_width = std::max(kMinWindowWidth, width);
      self->normal_height = std::max(kMinWindowHeight, height);
    }
    if (is_x11_display()) {
      gint pos_x = 0;
      gint pos_y = 0;
      gtk_window_get_position(self->main_window, &pos_x, &pos_y);
      self->normal_x = pos_x;
      self->normal_y = pos_y;
      self->has_position = TRUE;
    }
  }
}

gboolean save_window_state_debounce_cb(gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  self->save_debounce_source_id = 0;
  refresh_cached_window_geometry(self);
  save_window_state(self);
  return G_SOURCE_REMOVE;
}

void cancel_pending_save_debounce(MyApplication* self) {
  if (self->save_debounce_source_id != 0) {
    g_source_remove(self->save_debounce_source_id);
    self->save_debounce_source_id = 0;
  }
}

void schedule_window_state_save(MyApplication* self) {
  cancel_pending_save_debounce(self);
  self->save_debounce_source_id =
      g_timeout_add(kSaveDebounceMs, save_window_state_debounce_cb, self);
}

gboolean window_configure_event_cb(GtkWidget* widget,
                                   GdkEventConfigure* event,
                                   gpointer user_data) {
  (void)widget;
  (void)event;
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->main_window != nullptr &&
      gtk_widget_get_visible(GTK_WIDGET(self->main_window))) {
    schedule_window_state_save(self);
  }
  return FALSE;
}

gboolean window_state_event_cb(GtkWidget* widget,
                               GdkEventWindowState* event,
                               gpointer user_data) {
  (void)widget;
  MyApplication* self = MY_APPLICATION(user_data);
  self->window_state_flags = event->new_window_state;
  if ((event->new_window_state & GDK_WINDOW_STATE_ICONIFIED) == 0) {
    self->is_maximized =
        (event->new_window_state &
         (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN)) != 0;
  }
  if (self->main_window != nullptr &&
      gtk_widget_get_visible(GTK_WIDGET(self->main_window))) {
    schedule_window_state_save(self);
  }
  return FALSE;
}

gboolean window_delete_event_cb(GtkWidget* widget,
                                GdkEvent* event,
                                gpointer user_data) {
  (void)widget;
  (void)event;
  MyApplication* self = MY_APPLICATION(user_data);
  cancel_pending_save_debounce(self);
  refresh_cached_window_geometry(self);
  save_window_state(self);
  return FALSE;
}

void window_destroy_cb(GtkWidget* widget, gpointer user_data) {
  (void)widget;
  MyApplication* self = MY_APPLICATION(user_data);
  self->main_window = nullptr;
}

}  // namespace

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  (void)self;
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  GList* existing_windows =
      gtk_application_get_windows(GTK_APPLICATION(application));
  if (existing_windows != nullptr) {
    gtk_window_present(GTK_WINDOW(existing_windows->data));
    return;
  }

  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->main_window = window;
  self->window_state_flags = static_cast<GdkWindowState>(0);

  // Only attach GtkHeaderBar when genuinely running on GNOME (Wayland or X11
  // GNOME Shell). On KDE Plasma (Wayland and X11) and other window managers,
  // let KWin / native WM draw native titlebars instead of a GNOME HeaderBar.
  const gboolean use_header_bar = should_use_gnome_header_bar(window);
  const gchar* window_title = resolve_window_title();
  gtk_window_set_title(window, window_title);
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, window_title);
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  }

  load_window_state(self);
  apply_restored_window_geometry(self, window);
  set_window_icon_best_effort(window);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  gtk_widget_set_size_request(GTK_WIDGET(view), kMinWindowWidth,
                              kMinWindowHeight);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Connect window state handlers BEFORE gtk_widget_realize(view) because
  // FlView connects its own "delete-event" handler inside realize and returns
  // TRUE to stop propagation.
  g_signal_connect(window, "delete-event", G_CALLBACK(window_delete_event_cb),
                   self);
  g_signal_connect(window, "window-state-event",
                   G_CALLBACK(window_state_event_cb), self);
  g_signal_connect(window, "configure-event",
                   G_CALLBACK(window_configure_event_cb), self);
  g_signal_connect(window, "destroy", G_CALLBACK(window_destroy_cb), self);

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  if (arguments != nullptr && *arguments != nullptr &&
      (*arguments)[0] != nullptr) {
    self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);
  }

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  cancel_pending_save_debounce(self);
  refresh_cached_window_geometry(self);
  save_window_state(self);

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  cancel_pending_save_debounce(self);
  self->main_window = nullptr;
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->main_window = nullptr;
  self->normal_width = kDefaultWindowWidth;
  self->normal_height = kDefaultWindowHeight;
  self->normal_x = 0;
  self->normal_y = 0;
  self->has_position = FALSE;
  self->is_maximized = FALSE;
  self->state_initialized = FALSE;
  self->window_state_flags = static_cast<GdkWindowState>(0);
  self->save_debounce_source_id = 0;
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     nullptr));
}
