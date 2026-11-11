// hypr-liquid-glass: swaps Hyprland's blurred-background pass for a liquid glass
// shader. The background is still Hyprland's own (cached) blur; we only change
// how it is sampled, so the cost is a few ALU ops + 1-3 texture reads per pixel.
//
// Hook layout:
//   renderTextureWithBlurInternal  -> remember data.blurredBG, call original
//   renderTextureInternal          -> if asked to draw that exact texture, draw
//                                     it with the glass shader instead
// The original keeps doing stencil/discard setup, so shaped (ignore_alpha)
// layer surfaces only get glass under their opaque parts.

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/Shader.hpp>
#include <hyprland/src/render/Texture.hpp>
#include <hyprland/src/render/pass/Pass.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/config/values/types/FloatValue.hpp>
#include <hyprland/src/config/values/types/BoolValue.hpp>
#include <hyprland/src/config/values/types/IntValue.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/state/MonitorState.hpp>

#include <cmath>
#include <map>
#include <format>
#include <optional>

using namespace Render;
using namespace Render::GL;

using STexData = CHyprOpenGLImpl::STextureRenderData;

using FnBlur = void (*)(CHyprOpenGLImpl*, SP<ITexture>, const CBox&, const STexData&);
using FnTex  = void (*)(CHyprOpenGLImpl*, SP<ITexture>, const CBox&, const STexData&);

static HANDLE         g_handle    = nullptr;
static CFunctionHook* g_hookBlur  = nullptr;
static CFunctionHook* g_hookTex   = nullptr;
static CFunctionHook* g_hookRadius = nullptr;
static ITexture*      g_pendingBG = nullptr;  // the blurredBG the current blur pass is about to draw
static SP<ITexture>   g_pendingShape;          // surface texture whose alpha defines the glass shape (full-screen layers)
static float          g_pendingCut = 0.F;
static SP<CShader>    g_shader;
static bool           g_shaderFailed = false;
// Draw counts for `hyprctl liquidglass`, per outcome and surface. A layer's
// namespace is whatever its client says it is, so the keys are a client's to
// make up: the map only ever holds STATS_MAX of them, each with at most
// STATS_NAME_MAX bytes of namespace, and the rest are counted together.
static constexpr size_t                STATS_MAX      = 64;
static constexpr size_t                STATS_NAME_MAX = 48;
static std::map<std::string, uint64_t> g_stats;
static uint64_t                        g_statsOther = 0, g_statsUnmatched = 0, g_statsDrawn = 0;
static SP<SHyprCtlCommand>             g_ctlCmd;

static struct {
    GLint uvTL, uvBR, boxSize, radius, alpha, bezel, refraction, dispersion, specular, lightDir, brightness, saturation, shapeMode, surf, alphaCut;
} g_loc;

static struct {
    SP<Config::Values::CBoolValue>  enabled, windows, layers, shapeLayers;
    SP<Config::Values::CFloatValue> bezel, refraction, dispersion, specular, lightAngle, brightness, saturation;
    SP<Config::Values::CIntValue>   blurSize, blurPasses;
} g_cfg;

// The glass reads best over a nearly sharp background, so while the plugin is
// loaded it turns Hyprland's blur down, and gives the user's own back on unload.
// A config reload restores the file's values, so they're re-saved and overridden.
static std::optional<std::pair<Config::INTEGER, Config::INTEGER>> g_userBlur;  // size, passes
static bool                                                        g_settingBlur = false;
static CHyprSignalListener                                         g_reloadListener;
static UP<SEventLoopDoLaterLock>                                   g_applyLater;

static const char* VERT = R"GLSL(#version 300 es
uniform mat3 proj;
in vec2 pos;
in vec2 texcoord;
out vec2 v_texcoord;
void main() {
    gl_Position = vec4(proj * vec3(pos, 1.0), 1.0);
    v_texcoord = texcoord;
}
)GLSL";

static const char* FRAG =
#include "glass.frag.inc"
    ;

static bool ensureShader() {
    if (g_shader)
        return true;
    if (g_shaderFailed)
        return false;

    auto shader = makeShared<CShader>();
    if (!shader->createProgram(VERT, FRAG)) {
        g_shaderFailed = true;
        HyprlandAPI::addNotification(g_handle, "[liquidglass] shader failed to compile, falling back to plain blur", CHyprColor{1.0, 0.3, 0.3, 1.0}, 8000);
        return false;
    }

    const GLuint prog = shader->program();
    auto         loc  = [prog](const char* n) { return glGetUniformLocation(prog, n); };
    g_loc             = {loc("uvTL"),   loc("uvBR"),       loc("boxSize"),  loc("radius"),   loc("alpha"),      loc("bezel"),
                         loc("refraction"), loc("dispersion"), loc("specular"), loc("lightDir"), loc("brightness"), loc("saturation"),
                         loc("shapeMode"),  loc("surf"),       loc("alphaCut")};
    g_shader          = shader;
    return true;
}

static bool wantsGlass(const STexData& data) {
    if (!g_cfg.enabled->value())
        return false;
    // the shader-blend path composites blur inside the window shader; leave it alone
    static auto PBLEND = CConfigValue<Config::INTEGER>("render:use_shader_blur_blend");
    if (*PBLEND)
        return false;
    return data.currentLS.lock() ? g_cfg.layers->value() : g_cfg.windows->value();
}

static void setBlur(Config::INTEGER size, Config::INTEGER passes) {
    g_settingBlur = true;
    HyprlandAPI::invokeHyprctlCommand("eval", std::format("hl.config({{ decoration = {{ blur = {{ size = {}, passes = {} }} }} }})", size, passes));
    g_settingBlur = false;
}

// Puts the blur where it belongs for the current settings: ours while the glass
// is on, the user's while it's off. -1 leaves that one value as configured.
static void applyBlur() {
    static auto PSIZE   = CConfigValue<Config::INTEGER>("decoration:blur:size");
    static auto PPASSES = CConfigValue<Config::INTEGER>("decoration:blur:passes");
    if (!g_userBlur)
        g_userBlur = {*PSIZE, *PPASSES};

    auto [size, passes] = *g_userBlur;
    if (g_cfg.enabled->value()) {
        if (g_cfg.blurSize->value() >= 0)
            size = g_cfg.blurSize->value();
        if (g_cfg.blurPasses->value() >= 1)
            passes = g_cfg.blurPasses->value();
    }
    if (size != *PSIZE || passes != *PPASSES)
        setBlur(size, passes);
}

static void restoreBlur() {
    if (g_userBlur)
        setBlur(g_userBlur->first, g_userBlur->second);
    g_userBlur.reset();
}

// Mirrors CHyprOpenGLImpl::renderTextureInternal, minus colour management, with our shader.
static void drawGlass(CHyprOpenGLImpl* gl, SP<ITexture> tex, const CBox& box, const STexData& data, SP<ITexture> shapeTex, float cut) {
    auto& rd = g_pHyprRenderer->m_renderData;
    if (!data.damage || data.damage->empty())
        return;

    CBox newBox = box;
    rd.renderModif.applyToBox(newBox);

    const auto MONITOR_INVERTED = Math::wlTransformToHyprutils(Math::invertTransform(rd.pMonitor->m_transform));
    auto       TRANSFORM        = tex->m_transform;
    if (g_pHyprRenderer->monitorTransformEnabled())
        TRANSFORM = Math::composeTransform(MONITOR_INVERTED, TRANSFORM);
    const auto glMatrix = g_pHyprRenderer->projectBoxToTarget(newBox, TRANSFORM);

    glActiveTexture(GL_TEXTURE0);
    tex->bind();
    tex->setTexParameter(GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    tex->setTexParameter(GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    tex->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    tex->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);

    auto shader = gl->useShader(g_shader);
    shader->setUniformMatrix3fv(SHADER_PROJ, 1, GL_TRUE, glMatrix.getMatrix());
    shader->setUniformInt(SHADER_TEX, 0);

    const Vector2D uv0 = data.primarySurfaceUVTopLeft;
    const Vector2D uv1 = data.primarySurfaceUVBottomRight;
    const float    deg = g_cfg.lightAngle->value() * (float)M_PI / 180.F;

    glUniform2f(g_loc.uvTL, uv0.x, uv0.y);
    glUniform2f(g_loc.uvBR, uv1.x, uv1.y);
    glUniform2f(g_loc.boxSize, newBox.width, newBox.height);
    glUniform1f(g_loc.radius, data.round);
    glUniform1f(g_loc.alpha, data.a);
    const float scale = rd.pMonitor->m_scale;
    glUniform1f(g_loc.bezel, g_cfg.bezel->value() * scale);
    glUniform1f(g_loc.refraction, g_cfg.refraction->value() * scale);
    glUniform1f(g_loc.dispersion, g_cfg.dispersion->value());
    glUniform1f(g_loc.specular, g_cfg.specular->value());
    glUniform2f(g_loc.lightDir, std::cos(deg), std::sin(deg));
    glUniform1f(g_loc.brightness, g_cfg.brightness->value());
    glUniform1f(g_loc.saturation, g_cfg.saturation->value());
    glUniform1i(g_loc.shapeMode, shapeTex ? 1 : 0);
    glUniform1i(g_loc.surf, 1);
    glUniform1f(g_loc.alphaCut, cut);
    if (shapeTex) {
        glActiveTexture(GL_TEXTURE1);
        shapeTex->bind();
        shapeTex->setTexParameter(GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        shapeTex->setTexParameter(GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glActiveTexture(GL_TEXTURE0);
    }

    glBindVertexArray(shader->getUniformLocation(SHADER_SHADER_VAO));

    // custom UVs: the box maps onto its own region of the monitor-sized blur texture
    glBindBuffer(GL_ARRAY_BUFFER, shader->getUniformLocation(SHADER_SHADER_VBO));
    auto verts = fullVerts;
    verts[0].u = uv0.x, verts[0].v = uv0.y;
    verts[1].u = uv0.x, verts[1].v = uv1.y;
    verts[2].u = uv1.x, verts[2].v = uv0.y;
    verts[3].u = uv1.x, verts[3].v = uv1.y;
    glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts.data(), GL_DYNAMIC_DRAW);
    shader->setUsesCustomUV(true);

    auto drawRects = [&](const CRegion& region) {
        region.forEachRect([&](const auto& RECT) {
            gl->scissor(&RECT, rd.transformDamage);
            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        });
    };

    if (!rd.clipBox.empty() || !data.clipRegion.empty()) {
        CRegion damageClip = rd.clipBox;
        if (!data.clipRegion.empty()) {
            if (rd.clipBox.empty())
                damageClip = data.clipRegion;
            else
                damageClip.intersect(data.clipRegion);
        }
        if (!damageClip.empty())
            drawRects(damageClip);
    } else
        drawRects(*data.damage);

    glBindVertexArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    if (shapeTex) {
        glActiveTexture(GL_TEXTURE1);
        shapeTex->unbind();
        glActiveTexture(GL_TEXTURE0);
    }
    tex->unbind();
}

static std::string surfaceLabel(const STexData& data) {
    if (const auto ls = data.currentLS.lock())
        return "layer:" + ls->m_namespace.substr(0, STATS_NAME_MAX);
    return "window";
}

static void countStat(std::string key) {
    if (const auto it = g_stats.find(key); it != g_stats.end())
        it->second++;
    else if (g_stats.size() < STATS_MAX)
        g_stats.emplace(std::move(key), 1);
    else
        g_statsOther++;
}

// A layer that covers its monitor (menus, panels with scrims) draws a card
// somewhere inside it; its rect edges are the screen edges, not the card's.
static bool coversMonitor(const STexData& data, const CBox& box) {
    if (!data.currentLS.lock())
        return false;
    const auto px = g_pHyprRenderer->m_renderData.pMonitor->m_pixelSize;
    return box.width >= px.x * 0.9 && box.height >= px.y * 0.9;
}

static void hkRenderTextureWithBlurInternal(CHyprOpenGLImpl* thisptr, SP<ITexture> tex, const CBox& box, const STexData& data) {
    bool glass = data.blurredBG && wantsGlass(data) && ensureShader();
    g_pendingShape.reset();
    if (glass && coversMonitor(data, box)) {
        // shape from alpha needs a plain 2D RGBA texture; otherwise keep stock blur
        if (g_cfg.shapeLayers->value() && tex->m_type == TEXTURE_RGBA) {
            g_pendingShape = tex;
            g_pendingCut   = (data.discardMode & DISCARD_ALPHA) ? data.discardOpacity : 0.05F;
        } else
            glass = false;
    }
    countStat((glass ? (g_pendingShape ? "shape " : "glass ") : (data.blurredBG ? "skip " : "nobg ")) + surfaceLabel(data));
    if (glass)
        g_pendingBG = data.blurredBG.get();
    ((FnBlur)g_hookBlur->m_original)(thisptr, tex, box, data);
    if (g_pendingBG)
        g_statsUnmatched++;  // the original never drew blurredBG through renderTextureInternal
    g_pendingBG = nullptr;
    g_pendingShape.reset();
}

static void hkRenderTextureInternal(CHyprOpenGLImpl* thisptr, SP<ITexture> tex, const CBox& box, const STexData& data) {
    if (g_pendingBG && tex.get() == g_pendingBG) {
        g_pendingBG = nullptr;  // only the background pass, never the window itself
        g_statsDrawn++;
        drawGlass(thisptr, tex, box, data, g_pendingShape, g_pendingCut);
        return;
    }
    ((FnTex)g_hookTex->m_original)(thisptr, tex, box, data);
}

// Hyprland re-blurs only a margin of oneBlurRadius() around what changed. The
// lens reads up to refraction * (1 + dispersion) px away, which with a small
// blur is far past that margin, so it would pick up stale pixels: widen it.
using FnRadius = float (*)(Render::CRenderPass*);
static float hkOneBlurRadius(Render::CRenderPass* thisptr) {
    const float orig = ((FnRadius)g_hookRadius->m_original)(thisptr);
    if (!g_cfg.enabled->value())
        return orig;
    float scale = 1.F;
    for (const auto& m : State::monitorState()->monitors())
        scale = std::max(scale, m->m_scale);
    const float reach = std::abs(g_cfg.refraction->value()) * (1.F + std::max(0.F, g_cfg.dispersion->value())) * scale;
    return std::max(orig, std::ceil(reach) + 2.F);
}

static CFunctionHook* hookMember(const std::string& name, void* dest, const std::string& cls = "CHyprOpenGLImpl") {
    for (auto& fn : HyprlandAPI::findFunctionsByName(g_handle, name)) {
        if (fn.demangled.find(cls + "::" + name + "(") == std::string::npos)
            continue;
        auto hook = HyprlandAPI::createFunctionHook(g_handle, fn.address, dest);
        if (hook && hook->hook())
            return hook;
    }
    throw std::runtime_error("[liquidglass] failed to hook " + name);
}

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    g_handle = handle;

    if (std::string{__hyprland_api_get_hash()} != __hyprland_api_get_client_hash()) {
        HyprlandAPI::addNotification(handle, "[liquidglass] built against a different Hyprland, rebuild it", CHyprColor{1.0, 0.3, 0.3, 1.0}, 8000);
        throw std::runtime_error("[liquidglass] version mismatch");
    }

    using namespace Config::Values;
    auto addB = [&](const char* n, const char* d, bool def) {
        auto v = makeShared<CBoolValue>(n, d, def);
        HyprlandAPI::addConfigValueV2(handle, v);
        return v;
    };
    auto addF = [&](const char* n, const char* d, float def) {
        auto v = makeShared<CFloatValue>(n, d, def);
        HyprlandAPI::addConfigValueV2(handle, v);
        return v;
    };
    auto addI = [&](const char* n, const char* d, Config::INTEGER def) {
        auto v = makeShared<CIntValue>(n, d, def, SIntValueOptions{.min = -1});
        HyprlandAPI::addConfigValueV2(handle, v);
        return v;
    };

    g_cfg.enabled    = addB("plugin:liquidglass:enabled", "turn the glass pass on/off", true);
    g_cfg.windows    = addB("plugin:liquidglass:windows", "apply to blurred windows", true);
    g_cfg.layers     = addB("plugin:liquidglass:layers", "apply to blurred layer surfaces", true);
    g_cfg.shapeLayers = addB("plugin:liquidglass:shape_layers", "full-screen layers: follow the card's alpha outline (false = plain blur)", true);
    g_cfg.bezel      = addF("plugin:liquidglass:bezel", "rim width, logical px", 40.F);
    g_cfg.refraction = addF("plugin:liquidglass:refraction", "max edge displacement, logical px (negative = outward)", 45.F);
    g_cfg.dispersion = addF("plugin:liquidglass:dispersion", "chromatic split, 0..1", 0.25F);
    g_cfg.specular   = addF("plugin:liquidglass:specular", "rim highlight strength", 0.16F);
    g_cfg.lightAngle = addF("plugin:liquidglass:light_angle", "highlight direction, degrees (225 = top-left)", 225.F);
    g_cfg.brightness = addF("plugin:liquidglass:brightness", "glass body brightness multiplier", 1.04F);
    g_cfg.saturation = addF("plugin:liquidglass:saturation", "glass body saturation", 1.15F);
    g_cfg.blurSize   = addI("plugin:liquidglass:blur_size", "decoration:blur:size while loaded (-1 = leave as configured)", 3);
    g_cfg.blurPasses = addI("plugin:liquidglass:blur_passes", "decoration:blur:passes while loaded (-1 = leave as configured)", 1);

    g_hookBlur = hookMember("renderTextureWithBlurInternal", (void*)&hkRenderTextureWithBlurInternal);
    g_hookTex  = hookMember("renderTextureInternal", (void*)&hkRenderTextureInternal);
    g_hookRadius = hookMember("oneBlurRadius", (void*)&hkOneBlurRadius, "Render::CRenderPass");

    // A reload puts the file's blur back: that's the user's now, so save it and
    // override it again — after the reload is done, not from inside it.
    g_reloadListener = Event::bus()->m_events.config.reloaded.listen([] {
        if (g_settingBlur)
            return;
        g_userBlur.reset();
        g_applyLater = g_pEventLoopManager->doLaterLock(applyBlur);
    });
    g_applyLater = g_pEventLoopManager->doLaterLock(applyBlur);

    g_ctlCmd = HyprlandAPI::registerHyprCtlCommand(handle, SHyprCtlCommand{.name = "liquidglass", .exact = true, .fn = [](eHyprCtlOutputFormat, std::string) {
        applyBlur();  // pick up blur_size / blur_passes / enabled changes
        for (const auto& m : State::monitorState()->monitors())
            g_pHyprRenderer->damageMonitor(m);  // config changes don't damage; repaint so tweaks show
        std::string out = std::format("shader: {}\n", g_shader ? "ok" : (g_shaderFailed ? "FAILED" : "not built yet"));
        out += std::format("{:>10}  drawn\n{:>10}  unmatched\n", g_statsDrawn, g_statsUnmatched);
        for (const auto& [k, v] : g_stats)
            out += std::format("{:>10}  {}\n", v, k);
        if (g_statsOther)
            out += std::format("{:>10}  (other surfaces, past the first {})\n", g_statsOther, STATS_MAX);
        return out;
    }});

    return {"liquidglass", "Liquid glass refraction for blurred surfaces", "quokecola", "0.1"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    g_applyLater.reset();
    g_reloadListener.reset();
    restoreBlur();
    g_pendingBG = nullptr;
    g_stats.clear();
    if (g_shader)
        g_shader->destroy();
    g_shader.reset();
}
