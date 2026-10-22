// SPDX-License-Identifier: GPL-3.0-or-later
#include <gtk/gtk.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <signal.h>
#include <unistd.h>

static GMainLoop *loop;
static int result = 2;

static void response(GtkNativeDialog *dialog, int value, gpointer context) {
    (void)context;
    if (result == 5) return;
    if (value == GTK_RESPONSE_ACCEPT) {
        GListModel *files = gtk_file_chooser_get_files(GTK_FILE_CHOOSER(dialog));
        for (guint index = 0; index < g_list_model_get_n_items(files); index++) {
            GFile *file = g_list_model_get_item(files, index);
            char *path = g_file_get_path(file);
            if (!path) {
                g_object_unref(file);
                g_object_unref(files);
                result = 2;
                g_main_loop_quit(loop);
                return;
            }
            fwrite(path, 1, strlen(path), stdout);
            fputc(0, stdout);
            g_free(path);
            g_object_unref(file);
        }
        g_object_unref(files);
        fflush(stdout);
        result = 0;
    } else {
        result = 1;
    }
    g_main_loop_quit(loop);
}

static gboolean timed_out(gpointer dialog) {
    result = 5;
    gtk_native_dialog_hide(GTK_NATIVE_DIALOG(dialog));
    g_main_loop_quit(loop);
    return G_SOURCE_REMOVE;
}

static void set_initial_path(GtkFileChooser *chooser, const char *filename, gboolean save) {
    if (!filename) return;
    GFile *file = g_file_new_for_commandline_arg(filename);
    if (g_file_query_file_type(file, G_FILE_QUERY_INFO_NONE, NULL) == G_FILE_TYPE_DIRECTORY) {
        gtk_file_chooser_set_current_folder(chooser, file, NULL);
    } else {
        GFile *parent = g_file_get_parent(file);
        if (parent) {
            gtk_file_chooser_set_current_folder(chooser, parent, NULL);
            g_object_unref(parent);
        }
        if (save) {
            char *name = g_file_get_basename(file);
            gtk_file_chooser_set_current_name(chooser, name);
            g_free(name);
        } else {
            gtk_file_chooser_set_file(chooser, file, NULL);
        }
    }
    g_object_unref(file);
}

static void add_filters(GtkFileChooser *chooser, char **filters) {
    for (guint index = 0; filters && filters[index]; index++) {
        GtkFileFilter *filter = gtk_file_filter_new();
        char **parts = g_strsplit(filters[index], "|", 2);
        gtk_file_filter_set_name(filter, g_strstrip(parts[0]));
        char **patterns = g_strsplit_set(parts[1] ? parts[1] : parts[0], " \t", -1);
        for (guint item = 0; patterns[item]; item++) {
            if (*patterns[item]) gtk_file_filter_add_pattern(filter, patterns[item]);
        }
        gtk_file_chooser_add_filter(chooser, filter);
        g_object_unref(filter);
        g_strfreev(parts);
        g_strfreev(patterns);
    }
}

int main(int argc, char **argv) {
    pid_t parent = getppid();
    if (prctl(PR_SET_PDEATHSIG, SIGTERM) != 0 || getppid() != parent) return 2;
    gboolean enabled = FALSE, directory = FALSE, multiple = FALSE, save = FALSE, overwrite = FALSE;
    char *title = NULL, *filename = NULL;
    char **filters = NULL;
    int timeout = 300;
    GOptionEntry options[] = {
        {"file-selection", 0, 0, G_OPTION_ARG_NONE, &enabled, "File chooser", NULL},
        {"directory", 0, 0, G_OPTION_ARG_NONE, &directory, "Choose directories", NULL},
        {"multiple", 0, 0, G_OPTION_ARG_NONE, &multiple, "Choose multiple paths", NULL},
        {"save", 0, 0, G_OPTION_ARG_NONE, &save, "Choose a save destination", NULL},
        {"confirm-overwrite", 0, 0, G_OPTION_ARG_NONE, &overwrite, "Use native save confirmation", NULL},
        {"title", 0, 0, G_OPTION_ARG_STRING, &title, "Window title", NULL},
        {"filename", 0, 0, G_OPTION_ARG_FILENAME, &filename, "Initial path", NULL},
        {"file-filter", 0, 0, G_OPTION_ARG_STRING_ARRAY, &filters, "File filter", NULL},
        {"timeout", 0, 0, G_OPTION_ARG_INT, &timeout, "Dialog deadline", NULL},
        {NULL, 0, 0, 0, NULL, NULL, NULL}
    };
    GOptionContext *options_context = g_option_context_new(NULL);
    g_option_context_add_main_entries(options_context, options, NULL);
    gboolean valid = g_option_context_parse(options_context, &argc, &argv, NULL);
    g_option_context_free(options_context);
    if (!valid || !enabled || timeout < 1 || timeout > 300 || !gtk_init_check()) return 2;
    g_set_prgname("whisky-file-picker");
    GtkFileChooserAction action = directory ? GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER
        : save ? GTK_FILE_CHOOSER_ACTION_SAVE : GTK_FILE_CHOOSER_ACTION_OPEN;
    GtkFileChooserNative *dialog = gtk_file_chooser_native_new(title ? title : "Whisky", NULL, action,
        save ? "Save" : directory ? "Select" : "Open", "Cancel");
    GtkFileChooser *chooser = GTK_FILE_CHOOSER(dialog);
    gtk_file_chooser_set_select_multiple(chooser, multiple);
    set_initial_path(chooser, filename, save);
    add_filters(chooser, filters);
    loop = g_main_loop_new(NULL, FALSE);
    g_signal_connect(dialog, "response", G_CALLBACK(response), NULL);
    guint timer = g_timeout_add_seconds(timeout, timed_out, dialog);
    gtk_native_dialog_show(GTK_NATIVE_DIALOG(dialog));
    g_main_loop_run(loop);
    if (result != 5) g_source_remove(timer);
    gtk_native_dialog_hide(GTK_NATIVE_DIALOG(dialog));
    g_object_unref(dialog);
    g_main_loop_unref(loop);
    g_free(title);
    g_free(filename);
    g_strfreev(filters);
    return result;
}
