#define _GNU_SOURCE
#include <gio/gio.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// This executable deliberately does not initialize GLFW/raylib. libdecor may
// load GTK3 into the picker; GTK3 and GTK4 cannot share their GType names.
// GTK is only a headless icon-theme resolver; the picker is rendered by raylib.
// Runtime loading avoids a GTK development dependency and initializing its display.
static char *resolve_icon(const char *description) {
    if (!description || !*description) return NULL;
    static void *gtk;
    static void *(*theme_new)(void);
    static void (*theme_set_name)(void *, const char *);
    static void *(*lookup)(void *, GIcon *, int, int, int, int);
    static int (*has_gicon)(void *, GIcon *);
    static void (*add_path)(void *, const char *);
    static GFile *(*get_file)(void *);
    static void *theme;
    if (!gtk) {
        gtk = dlopen("libgtk-4.so.1", RTLD_LAZY | RTLD_LOCAL);
        if (!gtk) return NULL;
        *(void **)(&theme_new) = dlsym(gtk, "gtk_icon_theme_new");
        *(void **)(&theme_set_name) = dlsym(gtk, "gtk_icon_theme_set_theme_name");
        *(void **)(&lookup) = dlsym(gtk, "gtk_icon_theme_lookup_by_gicon");
        *(void **)(&get_file) = dlsym(gtk, "gtk_icon_paintable_get_file");
        *(void **)(&has_gicon) = dlsym(gtk, "gtk_icon_theme_has_gicon");
        *(void **)(&add_path) = dlsym(gtk, "gtk_icon_theme_add_search_path");
        if (!theme_new || !lookup || !get_file || !theme_set_name || !has_gicon || !add_path) return NULL;
        theme = theme_new();
        // Include exports even when a custom-shortcut launcher has a reduced
        // XDG_DATA_DIRS environment. GTK already searches ordinary XDG paths.
        char *user_exports = g_build_filename(g_get_home_dir(), ".local", "share",
            "flatpak", "exports", "share", "icons", NULL);
        add_path(theme, user_exports);
        g_free(user_exports);
        add_path(theme, "/var/lib/flatpak/exports/share/icons");
        GSettings *settings = g_settings_new("org.gnome.desktop.interface");
        char *name = g_settings_get_string(settings, "icon-theme");
        theme_set_name(theme, name); g_free(name); g_object_unref(settings);
    }
    if (!theme) return NULL;
    GIcon *icon = g_icon_new_for_string(description, NULL);
    if (!icon) return NULL;
    GFile *file = NULL;
    void *paintable = NULL;
    if (G_IS_FILE_ICON(icon)) file = g_file_icon_get_file(G_FILE_ICON(icon));
    else if (has_gicon(theme, icon)) {
        paintable = lookup(theme, icon, 256, 1, 0, 0);
        if (paintable) file = get_file(paintable);
    }
    char *path = file ? g_file_get_path(file) : NULL;
    if (path && !g_file_test(path, G_FILE_TEST_IS_REGULAR)) g_clear_pointer(&path, g_free);
    if (paintable) g_object_unref(paintable);
    g_object_unref(icon);
    return path;
}

int main(void) {
    char *line = NULL;
    size_t capacity = 0;
    while (getline(&line, &capacity, stdin) >= 0) {
        gsize length;
        guchar *decoded = g_base64_decode(line, &length);
        char *description = g_strndup((const char *)decoded, length);
        g_free(decoded);
        char *path = resolve_icon(description);
        g_free(description);
        char *encoded = path ? g_base64_encode((const guchar *)path, strlen(path)) : g_strdup("");
        g_free(path);
        printf("%s\n", encoded);
        g_free(encoded);
        if (fflush(stdout) == EOF) break;
    }
    free(line);
    return ferror(stdin) ? 1 : 0;
}
