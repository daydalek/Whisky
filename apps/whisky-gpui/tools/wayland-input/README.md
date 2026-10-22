# Native Wayland input acceptance helper

The test compositor receives a persistent virtual pointer device through the
wlroots virtual-pointer protocol. Pointer, button and wheel requests travel
through the compositor and the application's normal Wayland seat handling.
The helper runs only in the Wayland acceptance image.

The adjacent XML is preserved verbatim from the official wlr-protocols repository:

https://github.com/swaywm/wlr-protocols/blob/b010a03648b88d143236de193bddbfea0c08bc84/unstable/wlr-virtual-pointer-unstable-v1.xml

Its embedded MIT copyright and permission notice are retained. Docker generates
client bindings with `wayland-scanner`; compiled output stays in the build stage.

The persistent keyboard uses the same virtual-keyboard protocol as wtype,
preserved from its official repository at commit
`4b9cc29664f178cf380ccfe7f98405d38dffda3c`:

https://github.com/atx/wtype/blob/4b9cc29664f178cf380ccfe7f98405d38dffda3c/protocol/virtual-keyboard-unstable-v1.xml

The client keeps its devices connected throughout the session and sends a
standard US XKB keymap plus explicit modifier state. Unicode text is exercised
through the compositor's clipboard and the application's Paste handling.
