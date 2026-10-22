// SPDX-License-Identifier: GPL-3.0-or-later
#include <gdk-pixbuf/gdk-pixbuf.h>

static inline int whisky_image_dimensions(const unsigned char *data, size_t length, int *width, int *height) {
    GdkPixbufLoader *loader = gdk_pixbuf_loader_new();
    GError *error = NULL;
    gboolean wrote = gdk_pixbuf_loader_write(loader, data, length, &error);
    if (error) { g_error_free(error); error = NULL; }
    gboolean closed = gdk_pixbuf_loader_close(loader, &error);
    if (error) g_error_free(error);
    GdkPixbuf *image = gdk_pixbuf_loader_get_pixbuf(loader);
    int valid = wrote && closed && image != NULL;
    if (valid) {
        *width = gdk_pixbuf_get_width(image);
        *height = gdk_pixbuf_get_height(image);
        const char *orientation = gdk_pixbuf_get_option(image, "orientation");
        if (orientation && orientation[0] >= '5' && orientation[0] <= '8') {
            int old_width = *width;
            *width = *height;
            *height = old_width;
        }
    }
    g_object_unref(loader);
    return valid;
}
