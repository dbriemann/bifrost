#define _GNU_SOURCE
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
char *bf_icon(const char *);
void *bf_pixels(const char *, int *, int *);
void bf_free(void *);
int bf_save(const char *, const char *);
const char *bf_error(void);
int main(void) {
    char *path = bf_icon("folder");
    assert(path && "GTK standalone icon-theme lookup failed");
    int width = 0, height = 0;
    void *pixels = bf_pixels(path, &width, &height);
    if (!pixels) fprintf(stderr, "%s: %s\n", path, bf_error());
    assert(pixels && width > 0 && height > 0 && width <= 128 && height <= 128);
    printf("Icon resolution and RGBA conversion: %dx%d\n", width, height);
    bf_free(pixels); bf_free(path);
    assert(!bf_pixels("/nonexistent/bifrost-test.svg", &width, &height));
    char directory[] = "/tmp/bifrost-native-test-XXXXXX";
    assert(mkdtemp(directory));
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
    unlink(filename); rmdir(directory);
    puts("Atomic state replacement and permissions: OK");
}
