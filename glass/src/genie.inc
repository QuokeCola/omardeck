// The genie: a window poured into its dock icon as it is minimized, and back out
// as it is restored. Part of main.cpp (included there).
//
// Hyprland draws a window that has a "transformer" on a buffer of its own first,
// decorations and all, hands that buffer to the transformer, and draws what it
// gives back, with the blur behind following the same shape. So this bends the
// window itself, live and at its own pixels, and there is no picture of it to
// swap in and out.
//
//   hyprctl genie out <address> <sinkLeft> <sinkRight> <sinkY> <ms>
//       pour the window into the icon; when it is in, the event
//       `genie>>out,<address>` says so and the window stays unseen until it is
//       moved off its workspace (or a second and a half has passed).
//   hyprctl genie in <address> <sinkLeft> <sinkRight> <sinkY> <ms>
//       arm a window that is about to be put back: unseen until Hyprland first
//       draws it, then poured out of the icon.
//   hyprctl genie cancel <address>
// The sink is in logical pixels from the monitor's top left corner.

#include <hyprland/src/render/transformer/Transformer.hpp>
#include <hyprland/src/render/Framebuffer.hpp>
#include <hyprland/src/output/MonitorResources.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/managers/EventManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/animation/WorkspaceAnimationController.hpp>

#include <sstream>
#include <vector>

static uint64_t g_rerouted = 0;

namespace Genie {

    static const char* FRAG =
#include "genie.frag.inc"
        ;

    static SP<CShader> g_shader;
    static bool        g_shaderFailed = false;
    static struct {
        GLint win, sink, sinkY, bend, slide, flipY;
    } g_loc;

    static bool ensureShader() {
        if (g_shader)
            return true;
        if (g_shaderFailed)
            return false;
        auto shader = makeShared<CShader>();
        if (!shader->createProgram(VERT_PLAIN, FRAG, true)) {
            g_shaderFailed = true;
            return false;
        }
        const GLuint prog = shader->program();
        auto         loc  = [prog](const char* n) { return glGetUniformLocation(prog, n); };
        g_loc             = {loc("win"), loc("sink"), loc("sinkY"), loc("bend"), loc("slide"), loc("flipY")};
        g_shader          = shader;
        return true;
    }

    // y of a cubic bezier from (0,0) to (1,1) with control points (x1,y1) (x2,y2), at x.
    static float bezier(float x1, float y1, float x2, float y2, float x) {
        auto  at = [](float a, float b, float t) { return 3.F * a * (1.F - t) * (1.F - t) * t + 3.F * b * (1.F - t) * t * t + t * t * t; };
        float lo = 0.F, hi = 1.F, t = x;
        for (int i = 0; i < 24; i++) {
            t = (lo + hi) / 2.F;
            (at(x1, x2, t) < x ? lo : hi) = t;
        }
        return at(y1, y2, t);
    }

    class CTransformer;
    static std::vector<CTransformer*> g_live;
    static SP<CEventLoopTimer>        g_tick;
    static void                       arm();

    class CTransformer : public Render::IWindowTransformer {
      public:
        PHLWINDOWREF                   window;
        bool                           out = true;
        float                          sinkL = 0, sinkR = 0, sinkY = 0; // logical, monitor-local
        float                          ms = 500;
        std::optional<Time::steady_tp> start;   // when the animation began
        Time::steady_tp                made = Time::steadyNow();
        std::optional<Time::steady_tp> landed;  // out: when the window was all in
        bool                           said = false;
        bool                           held = false; // in: the windows a maximized one hides are being kept on
        int                            call = 0; // transform() calls for this frame: the window, then its blur matte

        CTransformer() {
            g_live.push_back(this);
        }
        virtual ~CTransformer() {
            std::erase(g_live, this);
        }

        // 0 the window in place .. 1 gone into the icon
        float p() const {
            if (!start)
                return out ? 0.F : 1.F;
            const float t = std::clamp(std::chrono::duration<float, std::milli>(Time::steadyNow() - *start).count() / std::max(ms, 1.F), 0.F, 1.F);
            // Out eases in: the window leaves slowly and is quickest as it goes into
            // the icon. In eases out: quick out of the icon, slow into place.
            return out ? bezier(0.8F, 0.F, 0.8F, 1.F, t) : 1.F - bezier(0.5F, 0.F, 0.2F, 1.F, t);
        }
        bool over() const {
            return start && std::chrono::duration<float, std::milli>(Time::steadyNow() - *start).count() >= ms;
        }

        // Decorations that miss the window's own buffer.
        //
        // While the window is drawn to its buffer, Hyprland sends what is drawn to
        // that buffer's pass. A decoration that adds itself to the main pass by
        // name, as Omarchy's titlebar does, lands on the screen instead: the bar
        // stayed where it was while the window under it was poured away. So what
        // the main pass has gained between these two calls, which Hyprland makes
        // before and after the window's own drawing, is brought over.
        Render::CRenderPass* nested = nullptr;
        size_t               mainCount = 0;

        virtual void preWindowRender(CSurfacePassElement::SRenderData*) {
            call      = 0;
            nested    = &g_pHyprRenderer->currentPass();
            mainCount = g_pHyprRenderer->m_renderPass.m_passElements.size();
            if (nested == &g_pHyprRenderer->m_renderPass)
                nested = nullptr;
        }

        virtual void amendTransformedRenderData(const CBox&, SMotionBlurData*) {
            auto& main = g_pHyprRenderer->m_renderPass.m_passElements;
            if (nested && main.size() > mainCount) {
                for (size_t i = mainCount; i < main.size(); i++) {
                    nested->m_passElements.emplace_back(std::move(main[i]));
                    g_rerouted++;
                }
                main.erase(main.begin() + mainCount, main.end());
            }
            nested = nullptr;
        }

        virtual SP<Render::IFramebuffer> transform(SP<Render::IFramebuffer> in) {
            call++;
            const auto PWINDOW  = window.lock();
            const auto PMONITOR = g_pHyprRenderer->m_renderData.pMonitor.lock();
            if (!PWINDOW || !PMONITOR || !in || !in->getTexture() || g_pHyprRenderer->m_bRenderingSnapshot)
                return in;
            if (!start) {
                start = Time::steadyNow();
                arm();
            }
            const float P = p();
            if (P <= 0.F)
                return in; // in place: the window as drawn
            if (!ensureShader())
                return in;
            const auto OUT = PMONITOR->resources()->getUnusedWorkBuffer();
            if (!OUT || OUT == in)
                return in;

            const Vector2D px = PMONITOR->m_pixelSize;
            CBox           box = PWINDOW->getFullWindowBoundingBox();
            box.translate(-PMONITOR->m_position).scale(PMONITOR->m_scale);
            const float k = PMONITOR->m_scale;
            const float b = std::clamp(P / 0.5F, 0.F, 1.F);

            auto        guard = g_pHyprRenderer->bindTempFB(OUT);
            auto*       gl    = g_pHyprOpenGL.get();
            gl->blend(false);
            gl->scissor((const pixman_box32*)nullptr);
            glViewport(0, 0, px.x, px.y);

            auto shader = gl->useShader(g_shader);
            glActiveTexture(GL_TEXTURE0);
            auto tex = in->getTexture();
            tex->bind();
            tex->setTexParameter(GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            tex->setTexParameter(GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            tex->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            tex->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            shader->setUniformInt(SHADER_TEX, 0);
            glUniform4f(g_loc.win, box.x / px.x, box.y / px.y, (box.x + box.width) / px.x, (box.y + box.height) / px.y);
            glUniform2f(g_loc.sink, sinkL * k / px.x, sinkR * k / px.x);
            glUniform1f(g_loc.sinkY, sinkY * k / px.y);
            glUniform1f(g_loc.bend, b * b * (3.F - 2.F * b));
            glUniform1f(g_loc.slide, std::clamp((P - 0.12F) / 0.88F, 0.F, 1.F));
            glUniform1f(g_loc.flipY, g_cfg.genieFlip->value() ? 1.F : 0.F);
            glBindVertexArray(shader->getUniformLocation(SHADER_SHADER_VAO));
            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
            glBindVertexArray(0);
            tex->unbind();
            gl->blend(true);
            return OUT;
        }
    };

    static PHLWINDOW windowAt(const std::string& address) {
        uintptr_t addr = 0;
        try {
            addr = std::stoull(address, nullptr, 16);
        } catch (...) { return nullptr; }
        for (auto const& w : Desktop::windowState()->windows())
            if (rc<uintptr_t>(w.get()) == addr)
                return w;
        return nullptr;
    }

    static void drop(CTransformer* t) {
        const auto PWINDOW = t->window.lock();
        if (!PWINDOW) {
            std::erase(g_live, t);
            return;
        }
        const auto PMONITOR = PWINDOW->m_monitor.lock();
        std::erase_if(PWINDOW->m_transformers, [t](auto const& x) { return x.get() == t; });
        if (PMONITOR)
            g_pHyprRenderer->damageMonitor(PMONITOR);
    }

    static void dropFor(PHLWINDOW w) {
        for (auto* t : std::vector<CTransformer*>(g_live))
            if (t->window.lock() == w)
                drop(t);
    }

    // While a window is on its way: a frame every tick, and each one's end seen to.
    static void tick() {
        for (auto* t : std::vector<CTransformer*>(g_live)) {
            const auto PWINDOW = t->window.lock();
            if (!PWINDOW || !PWINDOW->m_isMapped) {
                drop(t);
                continue;
            }
            const auto  NOW = Time::steadyNow();
            const float age = std::chrono::duration<float, std::milli>(NOW - t->made).count();
            if (const auto PMONITOR = PWINDOW->m_monitor.lock())
                g_pHyprRenderer->damageMonitor(PMONITOR);
            if (t->out) {
                // Never drawn (its workspace is not showing): nothing to play.
                if (!t->start && age > 250.F)
                    t->start = NOW - std::chrono::milliseconds(sc<int>(t->ms) + 1);
                if (t->over() && !t->said) {
                    t->said   = true;
                    t->landed = NOW;
                    g_pEventManager->postEvent(SHyprIPCEvent{.event = "genie", .data = std::format("out,0x{:x}", rc<uintptr_t>(PWINDOW.get()))});
                }
                const bool away = PWINDOW->m_workspace && PWINDOW->m_workspace->m_isSpecialWorkspace;
                if (t->said && (away || std::chrono::duration<float, std::milli>(NOW - *t->landed).count() > 1500.F))
                    drop(t);
            } else {
                // Back to being maximized: Hyprland starts fading the windows it
                // hides as soon as it is placed, and they would be gone before it
                // has come out of the icon. They stay until it has, then go.
                const bool MAX = PWINDOW->m_workspace && Fullscreen::controller()->isFullscreen(PWINDOW);
                // Said on every tick: focusing the window, which follows its being
                // placed, has Hyprland start the fade over again.
                if (t->start && MAX && !t->over()) {
                    t->held = true;
                    Animation::Workspace::overrideFullscreenFadeAmount(PWINDOW->m_workspace, 1.F, PWINDOW);
                }
                if (t->over()) {
                    if (t->held && MAX)
                        Animation::Workspace::overrideFullscreenFadeAmount(PWINDOW->m_workspace, 0.F, PWINDOW);
                    g_pEventManager->postEvent(SHyprIPCEvent{.event = "genie", .data = std::format("in,0x{:x}", rc<uintptr_t>(PWINDOW.get()))});
                    drop(t);
                } else if (!t->start && age > 2000.F)
                    drop(t); // armed, and the window never came
            }
        }
    }

    static void arm() {
        if (!g_tick) {
            g_tick = makeShared<CEventLoopTimer>(
                std::nullopt,
                [](SP<CEventLoopTimer> self, void*) {
                    tick();
                    if (!g_live.empty())
                        self->updateTimeout(std::chrono::milliseconds(6));
                },
                nullptr);
            g_pEventLoopManager->addTimer(g_tick);
        }
        if (!g_tick->armed())
            g_tick->updateTimeout(std::chrono::milliseconds(6));
    }

    static std::string command(const std::string& request) {
        std::istringstream in(request);
        std::string        name, verb, address;
        in >> name >> verb >> address;
        if (verb == "status") {
            std::string out = std::format("live: {}\nbrought into a window's buffer: {}\n", g_live.size(), g_rerouted);
            for (auto* t : g_live) {
                const auto W = t->window.lock();
                out += std::format("  {:x} {} started={} p={:.2f} held={} max={} ws={}\n", W ? rc<uintptr_t>(W.get()) : 0, t->out ? "out" : "in", t->start.has_value(), t->p(), t->held,
                                   W && Fullscreen::controller()->isFullscreen(W), W && W->m_workspace ? W->m_workspace->m_name : "?");
            }
            return out;
        }
        if (!g_cfg.genie->value())
            return "off";
        const auto PWINDOW = windowAt(address);
        if (!PWINDOW || !PWINDOW->m_isMapped)
            return "no window";
        if (verb == "cancel") {
            dropFor(PWINDOW);
            return "ok";
        }
        if (verb != "out" && verb != "in")
            return "unknown";
        float l = 0, r = 0, y = 0, ms = 500;
        if (!(in >> l >> r >> y))
            return "usage: genie out|in <address> <sinkLeft> <sinkRight> <sinkY> [ms]";
        in >> ms;
        if (!ensureShader())
            return "no shader";
        const auto PMONITOR = PWINDOW->m_monitor.lock();
        if (verb == "out" && (!PMONITOR || !PWINDOW->m_workspace || !PWINDOW->m_workspace->isVisible()))
            return "not showing";

        dropFor(PWINDOW);
        auto t    = makeUnique<CTransformer>();
        t->window = PWINDOW;
        t->out    = verb == "out";
        t->sinkL  = l;
        t->sinkR  = r;
        t->sinkY  = y;
        t->ms     = std::clamp(ms, 1.F, 5000.F);
        // Out from under a maximized window come the ones it hid, as it leaves and
        // not after: Hyprland would only bring them back once it is gone.
        if (t->out && Fullscreen::controller()->isFullscreen(PWINDOW))
            Animation::Workspace::overrideFullscreenFadeAmount(PWINDOW->m_workspace, 1.F, PWINDOW);
        PWINDOW->m_transformers.emplace_back(std::move(t));
        arm();
        if (PMONITOR)
            g_pHyprRenderer->damageMonitor(PMONITOR);
        return "ok";
    }

    static void exit() {
        for (auto* t : std::vector<CTransformer*>(g_live))
            drop(t);
        g_live.clear();
        if (g_tick) {
            g_pEventLoopManager->removeTimer(g_tick);
            g_tick.reset();
        }
        if (g_shader)
            g_shader->destroy();
        g_shader.reset();
    }
}

// Windows under a maximized or fullscreen one.
//
// Hyprland fades them out as the window takes the screen, but 0.56 skips a
// fading window in both of its drawing passes, so they vanish at once: plain to
// see through a see-through window. These two put the fading windows back in the
// first pass, under the window that hides them, and keep them out of the second,
// which draws over it.
using FnWinBool = bool (*)(Desktop::View::CWindow*);
static CFunctionHook* g_hookFading = nullptr;
static CFunctionHook* g_hookOver   = nullptr;

static bool hkIsFadingOutUnderFullscreen(Desktop::View::CWindow* thisptr) {
    if (!g_cfg.fade->value() || !g_hookOver)
        return ((FnWinBool)g_hookFading->m_original)(thisptr);
    return false;
}

// A floating window that hangs off its screen is nudged by Hyprland as its
// desktop slides (CWindow::onWorkspaceAnimUpdate), by as much as it overhangs,
// and the nudge stays for as long as the desktop is off to one side. A capture
// of the window alone is drawn with that nudge too, so the picture comes back
// with the window pushed out of its own frame and an empty band where it was.
// A capture is of the window, wherever it is: drawn without the nudge.
using FnFrame = void (*)(void*);
static CFunctionHook* g_hookCapture = nullptr;

static void hkCaptureRenderWindow(void* thisptr) {
    std::vector<std::pair<PHLWINDOW, Vector2D>> nudged;
    for (auto const& w : Desktop::windowState()->windows()) {
        if (!w || w->m_floatingOffset == Vector2D{})
            continue;
        nudged.emplace_back(w, w->m_floatingOffset);
        w->m_floatingOffset = Vector2D{};
    }
    ((FnFrame)g_hookCapture->m_original)(thisptr);
    for (auto& [w, was] : nudged)
        w->m_floatingOffset = was;
}

static bool hkShouldRenderOverFullscreen(Desktop::View::CWindow* thisptr) {
    if (!g_cfg.fade->value())
        return ((FnWinBool)g_hookOver->m_original)(thisptr);
    return thisptr->isAllowedOverFullscreen();
}
