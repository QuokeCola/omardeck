CXX      ?= g++
CXXFLAGS ?= -O2 -g
CXXFLAGS += -std=c++26 -fPIC -shared -Wall -Wno-deprecated-declarations
PKGS     := hyprland pixman-1 libdrm hyprlang hyprutils hyprgraphics aquamarine egl
CXXFLAGS += $(shell pkg-config --cflags $(PKGS))

all: liquidglass.so

liquidglass.so: src/main.cpp src/glass.frag.inc
	$(CXX) $(CXXFLAGS) src/main.cpp -o $@ $(shell pkg-config --libs $(PKGS)) -lGLESv2

src/glass.frag.inc: src/glass.frag
	{ echo 'R"GLSL('; cat $<; echo ')GLSL"'; } > $@

# Hyprland never really unloads a plugin's library, so loading the same path
# again brings the old code back. Load each build from a fresh copy instead.
# The session's runtime dir, or a private one: never a shared /tmp, where
# someone else could plant the library or the note of which one is loaded.
RUNDIR := $(or $(XDG_RUNTIME_DIR),$(HOME)/.cache/omardeck/run)
LOADED := $(RUNDIR)/liquidglass.loaded

reload: liquidglass.so
	mkdir -p -m 700 $(RUNDIR)
	-hyprctl plugin unload "$$(cat $(LOADED) 2>/dev/null || echo $(CURDIR)/liquidglass.so)"
	-rm -f "$$(cat $(LOADED) 2>/dev/null)"
	copy=$(RUNDIR)/liquidglass-$$(date +%s%N).so; cp $< $$copy && hyprctl plugin load $$copy && echo $$copy > $(LOADED)

unload:
	-hyprctl plugin unload "$$(cat $(LOADED) 2>/dev/null || echo $(CURDIR)/liquidglass.so)"
	-rm -f "$$(cat $(LOADED) 2>/dev/null)" $(LOADED)

clean:
	rm -f liquidglass.so src/glass.frag.inc

.PHONY: all clean reload unload
