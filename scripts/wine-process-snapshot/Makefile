CC = x86_64-w64-mingw32-gcc
TARGET = ../../WhiskyKit/Sources/WhiskyKit/Wine/Resources/WhiskyProcessSnapshot.exe
CFLAGS = -Os -Wall -Wextra -Werror -nostdlib -s
LDFLAGS = -Wl,--entry,mainCRTStartup -Wl,--subsystem,console -Wl,--no-insert-timestamp -lkernel32

.PHONY: all clean
all: $(TARGET)

$(TARGET): snapshot.c Makefile
	$(CC) $(CFLAGS) $< -o $@ $(LDFLAGS)

clean:
	rm -f $(TARGET)
