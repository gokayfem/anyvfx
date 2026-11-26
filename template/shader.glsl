// @NAME@: <one line: subject, setting, what the effect does>. Recreated from the @NF@-frame reference.
// Single pass, no textures. Written against the shader-skills library; build with tools/go.py.
//
// All layout constants are in REFERENCE PIXELS: origin top-left, x right, y down, REF units tall. Read positions
// straight off analysis/grid_*.png and type them in.

#define DEBUG_MODE 0      // 0 final | 1 distance | 2 normals | 3 part / layer ids
#define GIF_STEPPED 0     // 1 = hold each reference frame time, 0 = continuous motion
#define FREEZE_TIME -1.0  // >= 0 freezes the loop at that time in seconds
#define LIGHTMAP 1        // 0 = no painted light map (tools/refit.py renders with this off to fit it)
#define SHAKE 1.0         // camera shake from the effect: 0 = locked camera, 1 = default, 2 = violent
#define PARTICLES 0.25    // strength of the particles riding each strip of light: 0 = strip only, 1 = full overlay

const int NF = @NF@;             // reference frames
const float DT = @DT@;           // seconds per reference frame
const float LOOP = float(NF) * DT;
const float REF = @REF@;

// ---- helpers -----------------------------------------------------------------------------------------------------------
// Palette picks are typed as measured sRGB (tools/probe.py, ANALYSIS.md) and decoded here, so mixing stays linear.
vec3 rgb(float r, float g, float b) { return srgbToLinear(vec3(r, g, b) / 255.0); }

// Linear ramp, clamped. Unlike smoothstep it accepts a > b (a falling ramp); the skill's linter rejects
// smoothstep with decreasing edges, so write ramp(hi, lo, x) or 1.0 - smoothstep(lo, hi, x).
float ramp(float a, float b, float x) { return clamp((x - a) / (b - a), 0.0, 1.0); }
float sq(float x) { return x * x; }     // never pow(x, 2.0): pow of a negative base is undefined in GLSL ES

// ---- liveliness kit: use all of it, a shader without it reads rigid ------------------------------------------------
// Randomness without state: a value that jumps to a new random target `rate` times a second and eases between.
// Multiply every effect envelope by (0.8 + 0.4 * flick(...)), add jitter2 to effect centres and loose objects.
vec2 jitter2(float T, float rate, float seed) {
    float t = T * rate, i = floor(t), u = smoothstep(0.0, 1.0, fract(t));
    return mix(hash22(vec2(i, seed)), hash22(vec2(i + 1.0, seed)), u) * 2.0 - 1.0;
}
float flick(float T, float rate, float seed) { return jitter2(T, rate, seed).x * 0.5 + 0.5; }

// Dense motes: one soft dot per cell of a sheet. Light is drawn as particles, not as a gradient: give the effect an
// envelope (where particles may be) and multiply it by a sum of 3-4 motes() sheets of different cell size, fed with
// coordinates that stream along the effect (u.x = distance along it - speed * T, u.y = signed distance across).
float motes(vec2 u, float cell, float seed, float T) {
    u = rot2(seed * 1.3) * u + 2.5 * sin(u.yx * 0.11 + seed);        // each sheet turned and warped: no lattice shows
    vec2 g = u / cell, id = floor(g);
    vec3 h = hash32(id + seed);
    float r = 0.09 + 0.22 * h.z * h.z;
    vec2 dl = g - id - (0.30 + 0.40 * h.xy);
    float tw = 0.45 + 0.55 * flick(T, 2.0 + floor(4.0 * h.x), floor(h.y * 64.0) + seed);
    return 1.7 * exp(-dot(dl, dl) / (r * r)) * tw * step(0.38, h.z);
}

// Strands: particles that keep the feel of a brushed strip. They run in thin lanes along the flow (u.x along,
// u.y across), each a short dash, every lane sliding at its own speed, so the eye joins them into streaks while
// each one is still a separate particle. Fill the effect's crisp shape (with its stroke gaps) with 3 strands()
// sheets; use motes() only for the loose grains shed outside it.
float strands(vec2 u, float lane, float len, float speed, float seed, float T) {
    float ly = floor(u.y / lane);
    vec2 lh = hash22(vec2(ly, seed));
    // Long dashes, moderate speed, lanes nearly in step: a dash moves less than its own length in one reference
    // frame, so the flow stays readable even at GIF frame rate instead of boiling.
    len *= 2.6;
    float x = (u.x - T * speed * 0.42 * (0.85 + 0.30 * lh.x)) / len + floor(lh.y * 97.0) + lh.y;
    float ix = floor(x);
    vec3 h = hash32(vec2(ix, ly + seed * 17.0));
    float dx = max(abs(x - ix - 0.5) - (0.18 + 0.30 * h.x), 0.0) * len;        // px past the dash's ends
    float dy = (u.y / lane - ly - (0.35 + 0.30 * h.y)) * lane;
    float w = 0.55 + 0.9 * h.z;
    float tw = 0.55 + 0.45 * flick(T, 2.0 + floor(3.0 * h.y), floor(h.x * 64.0) + seed);
    return 1.5 * exp(-dx * dx * 0.5 - dy * dy / (w * w)) * tw * step(0.22, h.z);
}

// Piecewise-linear silhouette height through 4 points sorted by x; far below the frame outside their span.
// Use fillAA(profile4(...) - P.y, px) for a hill; min() two of them for longer outlines.
float profile4(float x, vec2 a, vec2 b, vec2 c, vec2 d) {
    if (x < a.x || x > d.x) return 1e4;
    if (x < b.x) return mix(a.y, b.y, ramp(a.x, b.x, x));
    if (x < c.x) return mix(b.y, c.y, ramp(b.x, c.x, x));
    return mix(c.y, d.y, ramp(c.x, d.x, x));
}

// Distance to a polyline of up to 6 points (n = number of points): cracks, ridges, drawn lines.
float polyline(vec2 p, vec2 a, vec2 b, vec2 c, vec2 d, vec2 e, vec2 f, int n) {
    float r = sdSegment(p, a, b);
    if (n > 2) r = min(r, sdSegment(p, b, c));
    if (n > 3) r = min(r, sdSegment(p, c, d));
    if (n > 4) r = min(r, sdSegment(p, d, e));
    if (n > 5) r = min(r, sdSegment(p, e, f));
    return r;
}

// ---- timeline ----------------------------------------------------------------------------------------------------------
// One key per reference frame, measured (tools/track.py for motion, ANALYSIS.md for exposure, probes for the rest),
// joined by a cyclic Catmull-Rom spline: the shader passes through every measured frame and is smooth in between.
// Clamp envelopes after key(): the spline overshoots around sharp attacks. If the clip does not loop seamlessly
// (ANALYSIS.md, loop seam), do not wrap: clamp the indices instead, as examples/02-vortex-bay does.
const float K_AMB[NF] = float[NF](@K_AMB@);

float key(float k[NF], float T) {
    float f = T / DT;
    int i = int(floor(f)) % NF;
    float u = fract(f);
    float p0 = k[(i + NF - 1) % NF], p1 = k[i], p2 = k[(i + 1) % NF], p3 = k[(i + 2) % NF];
    return p1 + 0.5 * u * (p2 - p0 + u * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + u * (3.0 * (p1 - p2) + p3 - p0)));
}

// ---- painted light map (generated; identity until tools/refit.py has run) ---------------------------------------------
//#include "@SCENE@lightmap.glsl"

vec3 lightMap(vec2 P) {
#if LIGHTMAP
    return lightMapRaw(P);
#else
    return vec3(1.0);
#endif
}

// ---- layers ------------------------------------------------------------------------------------------------------------
// One function per layer, back to front. Static layers take (P, px); animated ones also take T and their keys.

// The static scene lives in scene/env.glsl: vec3 environment(vec2 P, float px), linear colour before the light map.
// It is painted, and its light map fitted, in scene/ (the scene alone, locked camera), in parallel with the effect.
//#include "@SCENE@env.glsl"

vec3 background(vec2 P, float px) {
    return environment(P, px) * lightMap(P);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    float scale = REF / iResolution.y;
    vec2 P = vec2(fragCoord.x - 0.5 * iResolution.x, iResolution.y - fragCoord.y) * scale + vec2(0.5 * REF, 0.0);
    float px = scale;

    float T = FREEZE_TIME >= 0.0 ? FREEZE_TIME : mod(iTime, LOOP);
#if GIF_STEPPED
    T = floor(T / DT) * DT;
#endif
//@effect-begin
    // Envelopes flicker slowly (5-8 Hz, about +-12%): faster reads as strobing.
    float amb = clamp(key(K_AMB, T), 0.0, 1.2) * (0.90 + 0.20 * flick(T, 6.0, 1.0));

    // camera shake scaled by the effect's energy (rattle on a slower sway, a hair of roll), and line boil: the
    // drawing redrawn twelve times a second. Do this before anything reads P. Peaks near 13 px at full energy;
    // measure the reference's own shake first and scale to it (examples/04-foundry-waveform's camera is nearly still).
    const vec2 PIVOT = vec2(0.5 * REF);
    float kick = clamp(key(K_AMB, T), 0.0, 1.2);
    P += jitter2(T, 18.0, 5.0) * (0.8 + SHAKE * 13.0 * kick) + jitter2(T, 7.0, 6.0) * (1.2 + SHAKE * 10.0 * kick);
    P = PIVOT + rot2(0.020 * SHAKE * kick * jitter2(T, 11.0, 7.0).x) * (P - PIVOT);
    float boilSeed = floor(T * 12.0) * 3.7;
    P += 1.3 * vec2(fbm(P * 0.03 + boilSeed, 2), fbm(P * 0.03 + 7.0 + boilSeed, 2));
//@effect-end

    // 1. static scene
    vec3 col = background(P, px);

    // 2. light the effect throws on the scene (measure it: probe the same points at rest and at the peak frame)

    // 3. hero objects and effects, back to front. Decide the depth order from the reference BEFORE writing this:
    //    for every effect, what is it in front of and what hides it? An effect that passes through an object is
    //    composited after it with a visibility mask, not before it.
    //
    //    First decide what each effect is MADE OF. Water is not light: it is alpha-blended bodies, fans of tongues,
    //    ballistic streams and many beads (copy water(), geyser(), droplets(), beadArc() from examples/03-forest-geysers).
    //    ENERGY (beam, ring, ribbon, magic light) is drawn as strip + particles:
    //        float body  = <the strip's crisp shape, with its stroke gaps>;      // keep it THIN
    //        float spine = <a hairline along its centre>;
    //        vec2  u     = vec2(<px along the flow>, <signed px across>);
    //        float p     = strands(u, 2.5, 17.0, 900.0, 1.0, T) + strands(u + vec2(0.0, 1.3), 3.5, 28.0, 1300.0, 2.0, T)
    //                    + 0.6 * strands(u, 5.5, 46.0, 700.0, 3.0, T);
    //        vec3 strip  = HUE * body + WHITE * spine * 0.2;                     // saturated hue; white only on the spine
    //        vec3 dust   = (HUE * 1.2 + WHITE * 0.4 * spine) * body * p + HUE * 1.5 * <loose falloff> * motes(...);
    //        col += (strip + dust * PARTICLES) * envelope;
    //    Debris, shards and sparks are separate: ballistic, own heading and speed, they land and stay.

    // 4. finish: ease highlights into white, encode once, dither
    col = min(col, vec3(0.7)) + 0.3 * (1.0 - exp(-max(col - 0.7, 0.0) / 0.3));
    col = linearToSrgb(clamp(col, 0.0, 1.0)) + ditherTPDF(fragCoord, iFrame);
    fragColor = vec4(col, 1.0);
}
