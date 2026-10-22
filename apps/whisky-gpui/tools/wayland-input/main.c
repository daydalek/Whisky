/* Native Wayland virtual-pointer driver for headless Whisky acceptance.
 * Part of Whisky, licensed under GPL-3.0-or-later; see the repository LICENSE.
 * Protocol copyright/license is preserved in the adjacent upstream XML.
 */
#define _POSIX_C_SOURCE 200809L
#include <linux/input-event-codes.h>
#include <stdint.h>
#include <stdlib.h>
#include <xkbcommon/xkbcommon.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>
#include "virtual-pointer-client.h"
#include "virtual-keyboard-client.h"

static struct wl_seat *seat;
static struct zwlr_virtual_pointer_manager_v1 *manager;
static struct zwp_virtual_keyboard_manager_v1 *keyboard_manager;

static void capabilities(void *data, struct wl_seat *object, uint32_t value) {
    (void)data; (void)object; (void)value;
}
static const struct wl_seat_listener seat_listener = { .capabilities = capabilities };
static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(interface, wl_seat_interface.name) && !seat) {
        seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
        wl_seat_add_listener(seat, &seat_listener, NULL);
    } else if (!strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name)) {
        manager = wl_registry_bind(registry, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
    } else if (!strcmp(interface, zwp_virtual_keyboard_manager_v1_interface.name)) {
        keyboard_manager = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    }
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static const struct wl_registry_listener registry_listener = { .global = global, .global_remove = removed };
static uint32_t milliseconds(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (uint32_t)((uint64_t)time.tv_sec * 1000 + (uint64_t)time.tv_nsec / 1000000);
}
int main(void) {
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) return 2;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !manager || !keyboard_manager || !seat) return 3;
    struct zwlr_virtual_pointer_v1 *pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, seat);
    struct zwp_virtual_keyboard_v1 *keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(keyboard_manager, seat);
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    const struct xkb_rule_names names = {.layout = "us"};
    struct xkb_keymap *keymap = xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (!keymap) return 4;
    char *keymap_text = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
    FILE *keymap_file = tmpfile();
    if (!keymap_file || !keymap_text) return 4;
    size_t keymap_size = strlen(keymap_text) + 1;
    if (fwrite(keymap_text, 1, keymap_size, keymap_file) != keymap_size || fflush(keymap_file)) return 4;
    zwp_virtual_keyboard_v1_keymap(keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fileno(keymap_file), (uint32_t)keymap_size);
    if (wl_display_roundtrip(display) < 0) return 4;
    fclose(keymap_file);
    free(keymap_text);
    struct xkb_state *key_state = xkb_state_new(keymap);
    if (!key_state) return 4;
    puts("ready"); fflush(stdout);
    char line[128];
    while (fgets(line, sizeof(line), stdin)) {
        unsigned int x, y, button, state, key;
        int scroll;
        if (sscanf(line, "move %u %u", &x, &y) == 2 && x < 1280 && y < 900) {
            zwlr_virtual_pointer_v1_motion_absolute(pointer, milliseconds(), x, y, 1280, 900);
        } else if (sscanf(line, "button %u %u", &button, &state) == 2 && button >= 1 && button <= 3 && state <= 1) {
            const uint32_t buttons[] = {BTN_LEFT, BTN_MIDDLE, BTN_RIGHT};
            zwlr_virtual_pointer_v1_button(pointer, milliseconds(), buttons[button - 1], state);
        } else if (sscanf(line, "key %u %u", &key, &state) == 2 && key <= KEY_MAX && state <= 1) {
            xkb_state_update_key(key_state, key + 8, state ? XKB_KEY_DOWN : XKB_KEY_UP);
            zwp_virtual_keyboard_v1_key(keyboard, milliseconds(), key, state);
            zwp_virtual_keyboard_v1_modifiers(keyboard,
                xkb_state_serialize_mods(key_state, XKB_STATE_MODS_DEPRESSED),
                xkb_state_serialize_mods(key_state, XKB_STATE_MODS_LATCHED),
                xkb_state_serialize_mods(key_state, XKB_STATE_MODS_LOCKED),
                xkb_state_serialize_layout(key_state, XKB_STATE_LAYOUT_EFFECTIVE));
        } else if (sscanf(line, "scroll %d", &scroll) == 1 && scroll >= -100 && scroll <= 100) {
            zwlr_virtual_pointer_v1_axis_source(pointer, WL_POINTER_AXIS_SOURCE_WHEEL);
            zwlr_virtual_pointer_v1_axis_discrete(pointer, milliseconds(), WL_POINTER_AXIS_VERTICAL_SCROLL,
                                                wl_fixed_from_int(scroll * 15), scroll);
        } else {
            fputs("Invalid pointer command\n", stderr);
            return 5;
        }
        zwlr_virtual_pointer_v1_frame(pointer);
        if (wl_display_roundtrip(display) < 0) return 6;
        puts("ok"); fflush(stdout);
    }
    xkb_state_unref(key_state);
    xkb_keymap_unref(keymap);
    xkb_context_unref(context);
    zwp_virtual_keyboard_v1_destroy(keyboard);
    zwp_virtual_keyboard_manager_v1_destroy(keyboard_manager);
    zwlr_virtual_pointer_v1_destroy(pointer);
    zwlr_virtual_pointer_manager_v1_destroy(manager);
    wl_seat_destroy(seat);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return 0;
}
