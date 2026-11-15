#define _GNU_SOURCE
#include <assert.h>
#include <dlfcn.h>
#include <gio/gio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
char *bf_icon(const char *);
char *bf_app_icon(const char *, const char *);
void *bf_pixels(const char *, int *, int *);
void bf_free(void *);
int bf_save(const char *, const char *);
const char *bf_error(void);
void bf_shutdown(void);
int main(void) {
    // Isolate XDG lookups from the user's applications and icon preferences.
    char directory[] = "/tmp/bifrost-native-test-XXXXXX";
    assert(mkdtemp(directory));
    assert(!setenv("XDG_DATA_HOME", directory, 1));
    char *applications = g_build_filename(directory, "applications", NULL);
    assert(!g_mkdir_with_parents(applications, 0700));
    char *desktop = g_build_filename(applications, "org.bifrost.IconFixture.desktop", NULL);
    char *cwd = g_get_current_dir();
    char *fixture = g_build_filename(cwd, "tests", "fixtures", "app.svg", NULL);
    char *entry = g_strdup_printf("[Desktop Entry]\nType=Application\nName=Fixture\nExec=/bin/true\nIcon=%s\n", fixture);
    assert(g_file_set_contents(desktop, entry, -1, NULL));
    g_free(entry);
    char *png_fixture = g_build_filename(cwd, "tests", "fixtures", "app.png", NULL);
    const char *extra_ids[] = {"org.bifrost.WindowClassFixture.desktop", "org.bifrost.SuffixFixture.desktop",
        "org.bifrost.DuplicateA.desktop", "org.bifrost.DuplicateB.desktop",
        "org.bifrost.ExactFixture.desktop", "org.bifrost.ExactFixture-desktop.desktop"};
    const char *classes[] = {"BifrostWindowClass", "", "bifrost-shared-class", "bifrost-shared-class", "", ""};
    char *extra_desktops[G_N_ELEMENTS(extra_ids)];
    for (guint i = 0; i < G_N_ELEMENTS(extra_ids); i++) {
        extra_desktops[i] = g_build_filename(applications, extra_ids[i], NULL);
        const char *icon = (i == 0 || i == 3 || i == 5) ? png_fixture : fixture;
        entry = g_strdup_printf("[Desktop Entry]\nType=Application\nName=Fixture\nExec=/bin/true\nIcon=%s\nStartupWMClass=%s\n", icon, classes[i]);
        assert(g_file_set_contents(extra_desktops[i], entry, -1, NULL));
        g_free(entry);
    }

    // Reproduce libdecor's GTK3 dependency before asking for a GTK4-resolved
    // icon. The old in-process resolver fails to register GtkIconTheme here.
    void *gtk3 = dlopen("libgtk-3.so.0", RTLD_LAZY | RTLD_LOCAL);
    if (gtk3) {
        void *(*theme_new)(void);
        *(void **)(&theme_new) = dlsym(gtk3, "gtk_icon_theme_new");
        assert(theme_new);
        void *theme = theme_new();
        assert(theme);
        g_object_unref(theme);
        puts("GTK3 preloaded to reproduce the GLFW/libdecor environment");
    }

    char *resolved = bf_app_icon("", "org.bifrost.IconFixture.desktop");
    assert(resolved && !strcmp(resolved, fixture));
    bf_free(resolved);
    resolved = bf_app_icon("bifrost-nonexistent-icon-regression", "org.bifrost.IconFixture");
    assert(resolved && !strcmp(resolved, fixture));
    bf_free(resolved);
    assert(!bf_icon("bifrost-nonexistent-icon-regression"));
    assert(!bf_app_icon("", "bifrost-nonexistent.desktop"));
    // A broken file icon must not prevent desktop-entry fallback either.
    resolved = bf_app_icon("/nonexistent/bifrost.svg", "org.bifrost.IconFixture.desktop");
    assert(resolved && !strcmp(resolved, fixture));
    bf_free(resolved);
    puts("Desktop-entry icons, missing descriptor fallback, and placeholder rejection: OK");

    resolved = bf_app_icon("", "BIFROSTWINDOWCLASS.desktop");
    assert(resolved && !strcmp(resolved, png_fixture));
    bf_free(resolved);
    resolved = bf_app_icon("", "org.bifrost.SuffixFixture-desktop");
    assert(resolved && !strcmp(resolved, fixture));
    bf_free(resolved);
    resolved = bf_app_icon("", "ORG.BIFROST.SUFFIXFIXTURE-DESKTOP");
    assert(resolved && !strcmp(resolved, fixture));
    bf_free(resolved);
    // Exact descriptors and desktop IDs must win over matching/alias fallbacks.
    resolved = bf_app_icon(fixture, "BifrostWindowClass");
    assert(resolved && !strcmp(resolved, fixture));
    bf_free(resolved);
    resolved = bf_app_icon("", "org.bifrost.ExactFixture-desktop");
    assert(resolved && !strcmp(resolved, png_fixture));
    bf_free(resolved);
    assert(!bf_app_icon("", "bifrost-shared-class"));
    assert(!bf_app_icon("", "org.bifrost.SuffixFixture-desktop-helper"));
    puts("Window-class matching, trailing -desktop aliases, exact-entry priority, and ambiguous-match rejection: OK");

    char *path = bf_icon("folder");
    assert(path && "GTK standalone icon-theme lookup failed");
    int width = 0, height = 0;
    void *pixels = bf_pixels(path, &width, &height);
    if (!pixels) fprintf(stderr, "%s: %s\n", path, bf_error());
    assert(pixels && width > 0 && height > 0 && width <= 256 && height <= 256);
    printf("Icon resolution and RGBA conversion: %dx%d\n", width, height);
    bf_free(pixels); bf_free(path);
    assert(!bf_pixels("/nonexistent/bifrost-test.svg", &width, &height));
    char filename[512];
    snprintf(filename, sizeof filename, "%s/order.json", directory);
    assert(bf_save(filename, "{\"version\":1,\"ids\":[\"browser\"]}"));
    assert(bf_save(filename, "{\"version\":1,\"ids\":[\"terminal\"]}"));
    struct stat info;
    assert(!stat(filename, &info) && (info.st_mode & 0777) == 0600);
    FILE *f = fopen(filename, "r");
    assert(f);
    char contents[128] = {0};
    assert(fread(contents, 1, sizeof(contents)-1, f)); fclose(f);
    assert(strstr(contents, "terminal"));
    for (guint i = 0; i < G_N_ELEMENTS(extra_desktops); i++) {
        unlink(extra_desktops[i]); g_free(extra_desktops[i]);
    }
    unlink(filename); unlink(desktop); rmdir(applications); rmdir(directory);
    g_free(png_fixture);
    g_free(desktop); g_free(applications); g_free(fixture); g_free(cwd);
    puts("Atomic state replacement and permissions: OK");
    bf_shutdown();
}
