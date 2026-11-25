// The titlebar's buttons: round, an icon on a faint disc, each eased into its own
// colour while the pointer is on it. Part of main.cpp (included there).
//
// Omarchy's titlebar plugin draws its buttons as fixed shapes with nothing for
// the pointer. So it is left the bar, the title and the clicks, with its own
// buttons made invisible (dock/minimize.lua), and these are drawn where they
// are, as a decoration of the window: part of what the genie bends.
//
// What to draw comes from a note dock/minimize.lua writes as it sets the bar up,
// $XDG_RUNTIME_DIR/omardeck-buttons.conf, `key=value` lines; read here at the
// start and after every reload of Hyprland's config.

#include <hyprland/src/render/decorations/IHyprWindowDecoration.hpp>
#include <hyprland/src/render/pass/RectPassElement.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>

#include <fstream>

namespace Buttons {

    static const int MAX = 6;

    static struct {
        bool        enabled = false;
        std::string tag;                 // only windows with this tag have a bar; "" is all
        float       barHeight = 30, padding = 10, gap = 8, hit = 20, dot = 12;
        int         count = 0;
        CHyprColor  rest, restInactive, glyph, glyphRest;
        CHyprColor  colors[MAX];
        std::string icons[MAX];
        std::string font = "monospace";
        float       ms = 140;
    } g_cfg;

    static CHyprColor colorOf(const std::string& hex, const CHyprColor& fallback) {
        if (hex.size() != 6 && hex.size() != 8)
            return fallback;
        try {
            const uint32_t v = std::stoul(hex, nullptr, 16);
            if (hex.size() == 6)
                return CHyprColor(((v >> 16) & 0xFF) / 255.F, ((v >> 8) & 0xFF) / 255.F, (v & 0xFF) / 255.F, 1.F);
            return CHyprColor(((v >> 24) & 0xFF) / 255.F, ((v >> 16) & 0xFF) / 255.F, ((v >> 8) & 0xFF) / 255.F, (v & 0xFF) / 255.F);
        } catch (...) { return fallback; }
    }

    static std::map<std::string, SP<ITexture>> g_glyphs; // by icon and size

    static void readConfig() {
        auto next    = decltype(g_cfg){};
        const char* dir = getenv("XDG_RUNTIME_DIR");
        std::ifstream file(std::string(dir ? dir : "/nonexistent") + "/omardeck-buttons.conf");
        std::string   line;
        while (file && std::getline(file, line)) {
            const auto eq = line.find('=');
            if (eq == std::string::npos)
                continue;
            const std::string k = line.substr(0, eq), v = line.substr(eq + 1);
            try {
                if (k == "enabled") next.enabled = v == "1";
                else if (k == "tag") next.tag = v;
                else if (k == "bar_height") next.barHeight = std::stof(v);
                else if (k == "padding") next.padding = std::stof(v);
                else if (k == "gap") next.gap = std::stof(v);
                else if (k == "hit") next.hit = std::stof(v);
                else if (k == "dot") next.dot = std::stof(v);
                else if (k == "count") next.count = std::clamp(std::stoi(v), 0, MAX);
                else if (k == "rest") next.rest = colorOf(v, next.rest);
                else if (k == "rest_inactive") next.restInactive = colorOf(v, next.restInactive);
                else if (k == "glyph") next.glyph = colorOf(v, next.glyph);
                else if (k == "glyph_rest") next.glyphRest = colorOf(v, next.glyphRest);
                else if (k == "font") next.font = v;
                else if (k.size() == 6 && k.starts_with("color") && k[5] >= '0' && k[5] < '0' + MAX) next.colors[k[5] - '0'] = colorOf(v, next.colors[k[5] - '0']);
                else if (k.size() == 5 && k.starts_with("icon") && k[4] >= '0' && k[4] < '0' + MAX) next.icons[k[4] - '0'] = v.substr(0, 16);
            } catch (...) {}
        }
        g_cfg = next;
        g_glyphs.clear();
        for (auto const& m : State::monitorState()->monitors())
            g_pHyprRenderer->damageMonitor(m);
    }

    class CDeco;
    static std::vector<CDeco*> g_decos;

    class CDeco : public IHyprWindowDecoration {
      public:
        PHLWINDOWREF    window;
        float           shown[MAX]  = {}; // 0 at rest .. 1 the pointer's
        bool            wanted[MAX] = {};
        Time::steady_tp last = Time::steadyNow();

        CDeco(PHLWINDOW w) : IHyprWindowDecoration(w), window(w) {
            g_decos.push_back(this);
        }
        virtual ~CDeco() {
            std::erase(g_decos, this);
        }

        bool on() const {
            const auto W = window.lock();
            if (!g_cfg.enabled || g_cfg.count <= 0 || !W || !W->m_isMapped || !W->m_workspace)
                return false;
            if (Fullscreen::controller()->getFullscreenModes(W).internal == Fullscreen::FSMODE_FULLSCREEN)
                return false;
            return g_cfg.tag.empty() || W->m_ruleApplicator->m_tagKeeper.isTagged(g_cfg.tag);
        }

        // Button `i`, counted from the right as the bar has them: where a click on
        // it lands, in the layout's logical pixels.
        CBox hitBox(int i) const {
            const auto W   = window.lock();
            CBox       box = W->getWindowMainSurfaceBox();
            if (!W->m_pinned)
                box.translate(W->m_workspace->m_renderOffset->value());
            box.translate(W->m_floatingOffset);
            const float right = box.x + box.width - g_cfg.padding - i * (g_cfg.hit + g_cfg.gap);
            return {right - g_cfg.hit, box.y - g_cfg.barHeight / 2.F - g_cfg.hit / 2.F, g_cfg.hit, g_cfg.hit};
        }
        CBox allBox() const {
            const CBox first = hitBox(0), last = hitBox(g_cfg.count - 1);
            return CBox{last.x, last.y, first.x + first.width - last.x, first.height}.expand(2);
        }

        // Where the pointer is among them; true when that is news.
        bool aim() {
            bool news = false;
            const bool ON = on();
            const auto MOUSE = g_pInputManager->getMouseCoordsInternal();
            for (int i = 0; i < g_cfg.count; i++) {
                const bool over = ON && hitBox(i).containsPoint(MOUSE);
                news            = news || over != wanted[i];
                wanted[i]       = over;
            }
            return news;
        }

        virtual SDecorationPositioningInfo getPositioningInfo() {
            SDecorationPositioningInfo info;
            info.policy = DECORATION_POSITION_ABSOLUTE;
            return info;
        }
        virtual void onPositioningReply(const SDecorationPositioningReply&) {}
        virtual eDecorationType getDecorationType() {
            return DECORATION_CUSTOM;
        }
        virtual void updateWindow(PHLWINDOW) {}
        virtual void damageEntire() {
            if (on())
                g_pHyprRenderer->damageBox(allBox());
        }
        // Over the window and so over the bar, and under the window's popups: the
        // layers Hyprland draws to the window's own buffer when it is being bent.
        virtual eDecorationLayer getDecorationLayer() {
            return DECORATION_LAYER_OVER;
        }
        virtual uint64_t getDecorationFlags() {
            return 0;
        }
        virtual std::string getDisplayName() {
            return "omardeck-buttons";
        }

        virtual void draw(PHLMONITOR monitor, float const& a) {
            if (!on() || !monitor)
                return;
            const auto W = window.lock();

            // The bar is a decoration too, and whichever was added last is drawn
            // over the other: these are kept last. Not from inside the drawing.
            if (!W->m_windowDecorations.empty() && W->m_windowDecorations.back().get() != this) {
                g_pEventLoopManager->doLater([self = this] {
                    if (std::ranges::find(g_decos, self) == g_decos.end())
                        return;
                    const auto W = self->window.lock();
                    if (!W)
                        return;
                    auto& all = W->m_windowDecorations;
                    auto  it  = std::ranges::find_if(all, [self](auto const& d) { return d.get() == self; });
                    if (it != all.end() && it + 1 != all.end()) {
                        std::rotate(it, it + 1, all.end());
                        self->damageEntire();
                    }
                });
            }

            aim();
            const auto  NOW = Time::steadyNow();
            const float dt  = std::clamp(std::chrono::duration<float, std::milli>(NOW - last).count(), 0.F, 100.F);
            last            = NOW;
            bool moving     = false;
            const bool FOCUSED = Desktop::focusState()->window() == W;

            for (int i = 0; i < g_cfg.count; i++) {
                const float to = wanted[i] ? 1.F : 0.F;
                if (shown[i] != to) {
                    const float step = dt / std::max(g_cfg.ms, 1.F);
                    shown[i]         = to > shown[i] ? std::min(to, shown[i] + step) : std::max(to, shown[i] - step);
                    moving           = moving || shown[i] != to;
                }
                // Eased, so it leaves and arrives gently.
                const float t = shown[i] * shown[i] * (3.F - 2.F * shown[i]);

                const CBox  hit = hitBox(i);
                const float d   = g_cfg.dot;
                CBox        dot = {hit.x + (hit.width - d) / 2.F, hit.y + (hit.height - d) / 2.F, d, d};
                dot.translate(-monitor->m_position).scale(monitor->m_scale).round();
                dot.width = dot.height = std::max(dot.width, dot.height);

                const CHyprColor from = FOCUSED ? g_cfg.rest : g_cfg.restInactive;
                const CHyprColor into = g_cfg.colors[i];
                CRectPassElement::SRectData rect;
                rect.box   = dot;
                rect.color = CHyprColor(from.r + (into.r - from.r) * t, from.g + (into.g - from.g) * t, from.b + (into.b - from.b) * t, (from.a + (into.a - from.a) * t) * a);
                rect.round = sc<int>(std::ceil(dot.width / 2.0));
                // On the main pass by name, as the bar under them is: while the window
                // is bent the genie brings both over to its buffer, in this order.
                // Sent the usual way they would land there first, under the bar.
                g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(rect));

                // The icon: its quiet colour at rest, crossed over to the one that
                // reads on the button's colour. A texture has one colour, so two.
                if (!g_cfg.icons[i].empty()) {
                    const int pt = std::max(4, sc<int>(std::round(d * 0.44F * monitor->m_scale)));
                    for (int which = 0; which < 2; which++) {
                        const float alpha = (which == 0 ? 1.F - t : t) * a * (which == 0 && !FOCUSED ? 0.6F : 1.F);
                        if (alpha < 0.01F)
                            continue;
                        const std::string key = std::format("{}@{}/{}", g_cfg.icons[i], pt, which);
                        auto&             tex = g_glyphs[key];
                        if (!tex)
                            tex = g_pHyprRenderer->renderText(g_cfg.icons[i], which == 0 ? g_cfg.glyphRest : g_cfg.glyph, pt, false, g_cfg.font);
                        if (!tex || tex->m_size.x <= 0)
                            continue;
                        CTexPassElement::SRenderData data;
                        data.tex = tex;
                        data.box = CBox{dot.x + (dot.width - tex->m_size.x) / 2.0, dot.y + (dot.height - tex->m_size.y) / 2.0, tex->m_size.x, tex->m_size.y}.round();
                        data.a   = alpha;
                        g_pHyprRenderer->m_renderPass.add(makeUnique<CTexPassElement>(std::move(data)));
                    }
                }
            }

            // Still on its way: another frame.
            if (moving)
                g_pEventLoopManager->doLater([self = this] {
                    if (std::ranges::find(g_decos, self) != g_decos.end())
                        self->damageEntire();
                });
        }
    };

    static CHyprSignalListener g_onOpen, g_onMove, g_onReload;

    static void give(PHLWINDOW w) {
        if (!w)
            return;
        for (auto* d : g_decos)
            if (d->window.lock() == w)
                return;
        HyprlandAPI::addWindowDecoration(g_handle, w, makeUnique<CDeco>(w));
    }

    static void init() {
        readConfig();
        for (auto const& w : Desktop::windowState()->windows())
            give(w);
        g_onOpen   = Event::bus()->m_events.window.open.listen([](PHLWINDOW w) { give(w); });
        g_onReload = Event::bus()->m_events.config.reloaded.listen([] { g_pEventLoopManager->doLater(readConfig); });
        g_onMove   = Event::bus()->m_events.input.mouse.move.listen([](Vector2D, Event::SCallbackInfo&) {
            for (auto* d : g_decos) {
                const bool was = std::ranges::any_of(d->wanted, [](bool b) { return b; });
                if (d->aim() || was)
                    d->damageEntire();
            }
        });
    }

    static void exit() {
        g_onOpen.reset();
        g_onMove.reset();
        g_onReload.reset();
        for (auto* d : std::vector<CDeco*>(g_decos))
            HyprlandAPI::removeWindowDecoration(g_handle, d);
        g_decos.clear();
        g_glyphs.clear();
    }
}
