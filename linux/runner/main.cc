#include <string.h>

#include "my_application.h"

namespace {

gboolean is_gnome_desktop() {
  const gchar* kde_session = g_getenv("KDE_FULL_SESSION");
  if (kde_session != nullptr && kde_session[0] != '\0' &&
      g_ascii_strcasecmp(kde_session, "false") != 0 &&
      g_strcmp0(kde_session, "0") != 0) {
    return FALSE;
  }

  const gchar* xdg_desktop = g_getenv("XDG_CURRENT_DESKTOP");
  if (xdg_desktop != nullptr && xdg_desktop[0] != '\0') {
    g_autofree gchar* lower = g_ascii_strdown(xdg_desktop, -1);
    return strstr(lower, "gnome") != nullptr;
  }

  const gchar* desktop_session = g_getenv("DESKTOP_SESSION");
  if (desktop_session != nullptr && desktop_session[0] != '\0') {
    g_autofree gchar* lower = g_ascii_strdown(desktop_session, -1);
    return strstr(lower, "gnome") != nullptr ||
           g_strcmp0(lower, "ubuntu") == 0;
  }

  return FALSE;
}

}  // namespace

int main(int argc, char** argv) {
  // Route GtkFileChooserNative (file_selector_linux) through xdg-desktop-portal
  // on KDE Plasma and other non-GNOME desktops so users get native Dolphin/Qt
  // file dialogs unless GTK_USE_PORTAL was explicitly configured.
  if (g_getenv("GTK_USE_PORTAL") == nullptr && !is_gnome_desktop()) {
    g_setenv("GTK_USE_PORTAL", "1", FALSE);
  }

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
