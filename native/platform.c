#define _GNU_SOURCE
#include <gio/gio.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// Stable GLFW 3.4 ABI: use the system GLFW instead of raylib's bundled X11 GLFW.
extern void glfwInitHint(int, int);
extern int glfwInit(void);
extern int glfwPlatformSupported(int);
extern int glfwGetPlatform(void);
extern void glfwWindowHintString(int, const char *);
extern void __real_glfwDefaultWindowHints(void);
void __wrap_glfwDefaultWindowHints(void) {
    __real_glfwDefaultWindowHints();
    glfwWindowHintString(0x00026001, "org.bifrost.Picker");
}
static GDBusConnection *bus;
static char *last_error;
static char *command;
static guint runtime_registration;
static int owner;
static const char *bridge_name = "org.bifrost.WindowBridge";
static const char *runtime_name = "org.bifrost.PickerRuntime";
static const char *runtime_path = "/org/bifrost/PickerRuntime";
static void error_set(const char *message) {
    g_free(last_error);
    last_error = g_strdup(message ? message : "Unknown error");
}
const char *bf_error(void) { return last_error ? last_error : ""; }
void bf_free(void *p) { g_free(p); }

static int connect_bus(void) {
    if (bus) return 1;
    GError *error = NULL;
    bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (!bus) { error_set(error->message); g_error_free(error); return 0; }
    return 1;
}
char *bf_call(const char *method, const char *input) {
    if (!connect_bus()) return NULL;
    GError *error = NULL;
    GVariant *result = g_dbus_connection_call_sync(bus, bridge_name,
        "/org/bifrost/WindowBridge", bridge_name, method, g_variant_new("(s)", input),
        G_VARIANT_TYPE("(s)"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 2500, NULL, &error);
    if (!result) { error_set(error->message); g_error_free(error); return NULL; }
    char *value = NULL;
    g_variant_get(result, "(s)", &value);
    g_variant_unref(result);
    return value;
}
static void runtime_call(GDBusConnection *connection, const char *sender,
    const char *path, const char *interface, const char *method,
    GVariant *parameters, GDBusMethodInvocation *invocation, gpointer data) {
    (void)connection; (void)sender; (void)path; (void)interface; (void)method; (void)data;
    const char *value;
    g_variant_get(parameters, "(&s)", &value);
    g_free(command); command = g_strdup(value);
    g_dbus_method_invocation_return_value(invocation, g_variant_new("()"));
}
// 1 means this process owns the picker; 0 means command was forwarded; -1 error.
int bf_instance(const char *request) {
    if (!connect_bus()) return -1;
    GError *error = NULL;
    GVariant *reply = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus",
        "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
        g_variant_new("(su)", runtime_name, 4u), G_VARIANT_TYPE("(u)"),
        G_DBUS_CALL_FLAGS_NONE, 2000, NULL, &error);
    if (!reply) { error_set(error->message); g_error_free(error); return -1; }
    guint result; g_variant_get(reply, "(u)", &result); g_variant_unref(reply);
    if (result != 1) {
        reply = g_dbus_connection_call_sync(bus, runtime_name, runtime_path,
            runtime_name, "Command", g_variant_new("(s)", request),
            G_VARIANT_TYPE("()"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 2000, NULL, &error);
        if (!reply) { error_set(error->message); g_error_free(error); return -1; }
        g_variant_unref(reply); return 0;
    }
    owner = 1;
    GDBusNodeInfo *node = g_dbus_node_info_new_for_xml(
        "<node><interface name='org.bifrost.PickerRuntime'><method name='Command'>"
        "<arg type='s' direction='in'/></method></interface></node>", NULL);
    static const GDBusInterfaceVTable vtable = {.method_call = runtime_call};
    runtime_registration = g_dbus_connection_register_object(bus, runtime_path,
        node->interfaces[0], &vtable, NULL, NULL, &error);
    g_dbus_node_info_unref(node);
    if (!runtime_registration) { error_set(error->message); g_error_free(error); return -1; }
    return 1;
}
char *bf_poll(void) {
    for (int i = 0; i < 32 && g_main_context_pending(NULL); ++i)
        g_main_context_iteration(NULL, FALSE);
    char *result = command; command = NULL; return result;
}
int bf_wayland_prepare(void) {
    if (!getenv("WAYLAND_DISPLAY")) { error_set("WAYLAND_DISPLAY is absent: a Wayland session is required"); return 0; }
    if (!glfwPlatformSupported(0x00060003)) { error_set("System GLFW was built without Wayland support"); return 0; }
    glfwInitHint(0x00050003, 0x00060003);
    if (!glfwInit()) { error_set("GLFW could not connect to the Wayland compositor"); return 0; }
    glfwWindowHintString(0x00026001, "org.bifrost.Picker");
    return 1;
}
int bf_wayland_active(void) { return glfwGetPlatform() == 0x00060003; }

// GTK is only a headless icon-theme resolver; the picker is rendered by raylib.
// Runtime loading avoids a GTK development dependency and initializing its display.
char *bf_icon(const char *description) {
    if (!description || !*description) return NULL;
    static void *gtk;
    static void *(*theme_new)(void);
    static void (*theme_set_name)(void *, const char *);
    static void *(*lookup)(void *, GIcon *, int, int, int, int);
    static GFile *(*get_file)(void *);
    static void *theme;
    if (!gtk) {
        gtk = dlopen("libgtk-4.so.1", RTLD_LAZY | RTLD_LOCAL);
        if (!gtk) return NULL;
        *(void **)(&theme_new) = dlsym(gtk, "gtk_icon_theme_new");
        *(void **)(&theme_set_name) = dlsym(gtk, "gtk_icon_theme_set_theme_name");
        *(void **)(&lookup) = dlsym(gtk, "gtk_icon_theme_lookup_by_gicon");
        *(void **)(&get_file) = dlsym(gtk, "gtk_icon_paintable_get_file");
        if (!theme_new || !lookup || !get_file || !theme_set_name) return NULL;
        theme = theme_new();
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
    else { paintable = lookup(theme, icon, 128, 1, 0, 0); if (paintable) file = get_file(paintable); }
    char *path = file ? g_file_get_path(file) : NULL;
    if (paintable) g_object_unref(paintable);
    g_object_unref(icon);
    return path;
}
// Rasterize SVG in-process. New GdkPixbuf installations may route SVG decoding
// through an external sandbox service; librsvg gives us deterministic RGBA here.
static unsigned char *svg_pixels(const char *path, int *width, int *height) {
    static void *rsvg, *cairo;
    static void *(*handle_new)(const char *, GError **);
    static int (*render)(void *, void *, const void *, GError **);
    static void *(*surface_new)(int, int, int), *(*context_new)(void *);
    static unsigned char *(*surface_data)(void *);
    static int (*surface_stride)(void *), (*surface_status)(void *);
    static void (*context_destroy)(void *), (*surface_destroy)(void *), (*surface_flush)(void *);
    if (!rsvg) {
        rsvg = dlopen("librsvg-2.so.2", RTLD_LAZY | RTLD_LOCAL);
        cairo = dlopen("libcairo.so.2", RTLD_LAZY | RTLD_LOCAL);
        if (!rsvg || !cairo) return NULL;
        *(void **)(&handle_new) = dlsym(rsvg, "rsvg_handle_new_from_file");
        *(void **)(&render) = dlsym(rsvg, "rsvg_handle_render_document");
        *(void **)(&surface_new) = dlsym(cairo, "cairo_image_surface_create");
        *(void **)(&context_new) = dlsym(cairo, "cairo_create");
        *(void **)(&surface_data) = dlsym(cairo, "cairo_image_surface_get_data");
        *(void **)(&surface_stride) = dlsym(cairo, "cairo_image_surface_get_stride");
        *(void **)(&surface_status) = dlsym(cairo, "cairo_surface_status");
        *(void **)(&context_destroy) = dlsym(cairo, "cairo_destroy");
        *(void **)(&surface_destroy) = dlsym(cairo, "cairo_surface_destroy");
        *(void **)(&surface_flush) = dlsym(cairo, "cairo_surface_flush");
    }
    if (!handle_new || !render || !surface_new || !context_new || !surface_data ||
        !surface_stride || !surface_status || !context_destroy || !surface_destroy || !surface_flush)
        return NULL;
    GError *error = NULL;
    void *handle = handle_new(path, &error);
    if (!handle) { if (error) { error_set(error->message); g_error_free(error); } return NULL; }
    void *surface = surface_new(0, 128, 128); // CAIRO_FORMAT_ARGB32
    void *context = context_new(surface);
    const double viewport[4] = {0, 0, 128, 128};
    unsigned char *rgba = NULL;
    if (!surface_status(surface) && render(handle, context, viewport, &error)) {
        surface_flush(surface);
        unsigned char *data = surface_data(surface);
        int stride = surface_stride(surface);
        rgba = g_malloc(128 * 128 * 4);
        for (int y = 0; y < 128; ++y) for (int x = 0; x < 128; ++x) {
            guint32 pixel; memcpy(&pixel, data + y * stride + x * 4, 4);
            guint alpha = pixel >> 24;
            unsigned char *out = rgba + (y * 128 + x) * 4;
            out[0] = alpha ? MIN(255u, (((pixel >> 16) & 255) * 255 + alpha/2) / alpha) : 0;
            out[1] = alpha ? MIN(255u, (((pixel >> 8) & 255) * 255 + alpha/2) / alpha) : 0;
            out[2] = alpha ? MIN(255u, ((pixel & 255) * 255 + alpha/2) / alpha) : 0;
            out[3] = alpha;
        }
        *width = *height = 128;
    }
    if (error) { error_set(error->message); g_error_free(error); }
    context_destroy(context); surface_destroy(surface); g_object_unref(handle);
    return rgba;
}

// Decode themed SVG/PNG via GdkPixbuf so raylib can upload plain RGBA pixels.
unsigned char *bf_pixels(const char *path, int *width, int *height) {
    if (g_str_has_suffix(path, ".svg") || g_str_has_suffix(path, ".svgz"))
        return svg_pixels(path, width, height);
    static void *lib;
    static void *(*load)(const char *, int, int, int, GError **);
    static int (*get_width)(void *), (*get_height)(void *), (*get_stride)(void *), (*get_channels)(void *);
    static unsigned char *(*get_pixels)(void *);
    if (!lib) {
        lib = dlopen("libgdk_pixbuf-2.0.so.0", RTLD_LAZY | RTLD_LOCAL);
        if (!lib) return NULL;
        *(void **)(&load) = dlsym(lib, "gdk_pixbuf_new_from_file_at_scale");
        *(void **)(&get_width) = dlsym(lib, "gdk_pixbuf_get_width");
        *(void **)(&get_height) = dlsym(lib, "gdk_pixbuf_get_height");
        *(void **)(&get_stride) = dlsym(lib, "gdk_pixbuf_get_rowstride");
        *(void **)(&get_channels) = dlsym(lib, "gdk_pixbuf_get_n_channels");
        *(void **)(&get_pixels) = dlsym(lib, "gdk_pixbuf_get_pixels");
    }
    if (!load || !get_width || !get_height || !get_stride || !get_channels || !get_pixels) return NULL;
    GError *error = NULL;
    void *image = load(path, 128, 128, TRUE, &error);
    if (!image) { if (error) { error_set(error->message); g_error_free(error); } return NULL; }
    *width = get_width(image); *height = get_height(image);
    int channels = get_channels(image), stride = get_stride(image);
    unsigned char *src = get_pixels(image), *rgba = g_malloc((size_t)*width * *height * 4);
    for (int y = 0; y < *height; y++) for (int x = 0; x < *width; x++) {
        unsigned char *p = src + y * stride + x * channels;
        unsigned char *q = rgba + (y * *width + x) * 4;
        q[0] = p[0]; q[1] = p[1]; q[2] = p[2]; q[3] = channels == 4 ? p[3] : 255;
    }
    g_object_unref(image); return rgba;
}

// Atomic, private state writes, creating the directory only on explicit writes.
int bf_save(const char *path, const char *json) {
    char *directory = g_path_get_dirname(path);
    if (g_mkdir_with_parents(directory, 0700)) { g_free(directory); return 0; }
    g_free(directory);
    GError *error = NULL;
    gboolean ok = g_file_set_contents_full(path, json, -1,
        G_FILE_SET_CONTENTS_CONSISTENT | G_FILE_SET_CONTENTS_DURABLE, 0600, &error);
    if (!ok) { error_set(error->message); g_error_free(error); }
    return ok;
}
void bf_shutdown(void) {
    if (bus && runtime_registration) g_dbus_connection_unregister_object(bus, runtime_registration);
    if (bus && owner) {
        GVariant *reply = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus",
            "/org/freedesktop/DBus", "org.freedesktop.DBus", "ReleaseName",
            g_variant_new("(s)", runtime_name), NULL, G_DBUS_CALL_FLAGS_NONE, 500, NULL, NULL);
        if (reply) g_variant_unref(reply);
    }
    g_clear_object(&bus);
    g_clear_pointer(&command, g_free);
    g_clear_pointer(&last_error, g_free);
    runtime_registration = 0; owner = 0;
}
