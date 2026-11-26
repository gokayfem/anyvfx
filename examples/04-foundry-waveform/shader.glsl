// Foundry waveform: a glowing orange waveform fires along a line in a dark foundry hall: one tall spike, ripples and
// lens-shaped wave lobes to its right, sparks, dust. Recreated from the 12-frame reference.
// Single pass, no textures. Written against the shader-skills library; build with tools/go.py.
//
// All layout constants are in REFERENCE PIXELS: origin top-left, x right, y down, REF units tall. Read positions
// straight off analysis/grid_*.png and type them in.

#define DEBUG_MODE 0      // 0 final | 1 distance | 2 normals | 3 part / layer ids
#define GIF_STEPPED 0     // 1 = hold each reference frame time, 0 = continuous motion
#define FREEZE_TIME -1.0  // >= 0 freezes the loop at that time in seconds
#define LIGHTMAP 1        // 0 = no painted light map (tools/refit.py renders the scene with this off to fit it)
#define SHAKE 1.0         // camera shake from the effect: 0 = locked camera, 1 = default, 2 = violent
#define PARTICLES 0.25    // strength of the particles riding each strip of light: 0 = strip only, 1 = full overlay

const int NF = 12;             // reference frames
const float DT = 0.12;           // seconds per reference frame
const float LOOP = float(NF) * DT;
const float REF = 816.0;

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
// Clamp envelopes after key(): the spline overshoots around sharp attacks.
// The loop is not seamless (frame 12 is the faded wave in dust, frame 1 a fresh small one), so keys do not wrap.
const float K_AMB[NF] = float[NF](0.00, 0.15, 0.27, 0.46, 0.76, 1.00, 0.92, 0.73, 0.60, 0.42, 0.22, 0.15);   // exposure (ANALYSIS.md)
const float K_H[NF]   = float[NF](0.11, 0.33, 0.60, 0.96, 1.00, 1.00, 1.00, 0.95, 0.90, 0.63, 0.38, 0.19);   // spike height / 260 px
const float K_HB[NF]  = float[NF](0.35, 0.60, 0.85, 1.00, 1.00, 1.00, 0.70, 0.55, 0.40, 0.25, 0.15, 0.10);   // spike brightness
const float K_L[NF]   = float[NF](28.0, 40.0, 55.0, 85.0, 120.0, 150.0, 148.0, 143.0, 140.0, 140.0, 135.0, 120.0);  // lobe amplitude, px
const float K_W[NF]   = float[NF](35.0, 45.0, 55.0, 70.0, 90.0, 105.0, 125.0, 140.0, 140.0, 140.0, 140.0, 140.0);  // lobe length, px
const float K_LB[NF]  = float[NF](0.50, 0.60, 0.70, 0.80, 1.00, 1.00, 0.75, 0.58, 0.42, 0.27, 0.15, 0.08);   // wave brightness
const float K_SM[NF]  = float[NF](0.00, 0.05, 0.12, 0.25, 0.40, 0.60, 0.80, 0.90, 0.88, 0.80, 0.70, 0.55);   // dust in the air

float key(float k[NF], float T) {
    float f = clamp(T / DT, 0.0, float(NF) - 0.001);
    int i = int(floor(f));
    float u = fract(f);
    float p0 = k[max(i - 1, 0)], p1 = k[i], p2 = k[min(i + 1, NF - 1)], p3 = k[min(i + 2, NF - 1)];
    return p1 + 0.5 * u * (p2 - p0 + u * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + u * (3.0 * (p1 - p2) + p3 - p0)));
}

const float BASE_Y = 408.0;        // the line the wave rides on
const float SPIKE_X = 250.0;       // the tall spike
const float LOBE_X = 372.0;        // where the lens-shaped lobes start
const float SPIKE_H = 260.0;       // spike height at full strength, px above and below the line

const vec3 E_AMBER = vec3(1.00, 0.30, 0.035);     // linear: the saturated body of the light
const vec3 E_GOLD = vec3(1.00, 0.52, 0.12);
const vec3 E_HOT = vec3(1.00, 0.86, 0.60);        // the white-hot core

// ---- painted light map (generated in scene/ by tools/refit.py) ---------------------------------------------------------
//#include "scene/lightmap.glsl"

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
// It is painted, and its light map fitted, in scene/ (the scene alone, locked camera).
//#include "scene/env.glsl"

vec3 background(vec2 P, float px) {
    return environment(P, px) * lightMap(P);
}

// ---- the waveform ----------------------------------------------------------------------------------------------------
// The spike alone: a narrow peak. Drawn mirrored above and below the line it makes the spindle.
float spikeSig(float x, float H) {
    return H * (1.0 - pow(min(abs(x - SPIKE_X) / (5.0 + 0.062 * H), 1.0), 0.85));
}

// The wave is two curves, y = ripple(x) +- sig(x). sig is the part that is mirrored about the line: the spike (a
// spindle) and the lens-shaped lobes of length W to its right. ripple is the single wavy line both ride on: tight
// ripples dying away on both sides of the spike.
float sig(float x, float H, float A, float W) {
    float s = spikeSig(x, H);
    float u = (x - LOBE_X) / W;
    if (u > 0.0) {
        float n = floor(u);
        s += A * abs(sin(3.14159 * u)) * exp(-0.22 * n * n);
    }
    return s;
}
float ripple(float x, float H, float T) {
    float dx = x - SPIKE_X;
    float xr = max(dx - 10.0, 0.0), xl = max(-dx - 8.0, 0.0);
    float r = 0.24 * H * exp(-xr / 95.0) * sin(xr * 6.2832 / 44.0 - T * 3.0) * smoothstep(0.0, 16.0, xr) * (1.0 - 0.75 * smoothstep(LOBE_X - 20.0, LOBE_X + 70.0, x));
    return r + 0.16 * H * exp(-xl / 34.0) * sin(xl * 6.2832 / 20.0 + T * 4.0) * smoothstep(0.0, 10.0, xl);
}

// Distance in px from P to the nearer of the two curves (x = distance, y = signed: negative between them). Each is
// walked as a short polyline round P, so the near-vertical flanks of the spike measure true.
vec2 waveDist(vec2 P, float H, float A, float W, float T) {
    float y = P.y - BASE_Y, best = 1e9;
    float s0 = sig(P.x - 10.0, H, A, W), r0 = ripple(P.x - 10.0, H, T);
    vec2 pa = vec2(-10.0, r0 + s0), pb = vec2(-10.0, r0 - s0);
    for (int k = 1; k <= 5; k++) {
        float o = -10.0 + 4.0 * float(k);
        float s = sig(P.x + o, H, A, W), r = ripple(P.x + o, H, T);
        vec2 ca = vec2(o, r + s), cb = vec2(o, r - s);
        best = min(best, min(sdSegment(vec2(0.0, y), pa, ca), sdSegment(vec2(0.0, y), pb, cb)));
        pa = ca; pb = cb;
    }
    return vec2(best, best * sign(abs(y - ripple(P.x, H, T)) - sig(P.x, H, A, W)));
}


// Sparks: thrown out of the spike and up from where it meets the floor. Ballistic, each its own; drawn as the path
// covered in the last moment, so they read as streaks.
vec2 sparkPos(vec2 o, vec2 dir, float v, float age) {
    return o + dir * v * (1.0 - exp(-3.0 * age)) / 3.0 + vec2(0.0, 380.0 * age * age);
}
vec3 sparks(vec2 P, float T) {
    vec3 acc = vec3(0.0);
    for (int i = 0; i < 900; i++) {
        float fi = float(i);
        vec3 h = hash32(vec2(fi, 3.0)), g = hash32(vec2(fi, 9.0));
        bool low = g.x < 0.40;                                              // from the floor contact, fanned upward
        float t0 = low ? 0.33 + 0.42 * h.x : 0.12 + 0.66 * h.x;             // the floor only sparks once the spike reaches it
        float age = T - t0;
        float life = 0.32 + 0.75 * g.z;
        if (age < 0.0 || age > life) continue;
        float h0 = SPIKE_H * clamp(key(K_H, t0), 0.0, 1.0);                 // how tall the spike was when this one left it
        vec2 o = low ? vec2(SPIKE_X + (h.y - 0.5) * 14.0, BASE_Y + 0.90 * SPIKE_H)
                     : vec2(SPIKE_X + (h.y - 0.5) * 10.0, BASE_Y + (g.y * 2.0 - 1.0) * 0.85 * h0);
        float a = low ? -1.5708 + (h.z - 0.5) * 2.4 : (h.z < 0.5 ? 3.14159 : 0.0) + (g.y - 0.5) * 2.6 - 0.5 * (h.z < 0.5 ? -1.0 : 1.0);
        vec2 dir = vec2(cos(a), sin(a));
        float v = (low ? 1150.0 : 820.0) * (0.25 + 1.3 * h.y * h.y);
        bool big = fract(g.y * 7.0) < 0.25;                                 // long hot streaks among the ember dust
        vec2 c = sparkPos(o, dir, v, age), c2 = sparkPos(o, dir, v, max(age - (big ? 0.045 : 0.014), 0.0));
        vec2 lo = min(c, c2) - 6.0, hi = max(c, c2) + 6.0;
        if (P.x < lo.x || P.y < lo.y || P.x > hi.x || P.y > hi.y) continue;
        float d = sdSegment(P, c, c2);
        float u = age / life, heat = 1.0 - u;
        float w = big ? 1.5 : 0.55 + 0.6 * g.x * g.x;
        float m = exp(-d * d / (w * w)) * (1.0 - u * u) * (0.6 + 0.4 * flick(T, 6.0, fi));
        acc += mix(E_AMBER, E_HOT, heat * heat) * m * 1.6 + E_AMBER * 0.25 * exp(-d / 4.0) * heat;
    }
    return acc;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    float scale = REF / iResolution.y;
    vec2 P = vec2(fragCoord.x - 0.5 * iResolution.x, iResolution.y - fragCoord.y) * scale + vec2(0.5 * REF, 0.0);
    float px = scale;

    float T = FREEZE_TIME >= 0.0 ? FREEZE_TIME : mod(iTime, LOOP);
#if GIF_STEPPED
    T = floor(T / DT) * DT;
#endif
    // Envelopes flicker slowly (5-8 Hz, about +-12%): faster reads as strobing.
    float amb = clamp(key(K_AMB, T), 0.0, 1.2) * (0.90 + 0.20 * flick(T, 6.0, 1.0));
    float Hn = clamp(key(K_H, T), 0.0, 1.05), H = SPIKE_H * Hn * (0.96 + 0.08 * flick(T, 7.0, 2.0));
    float hb = clamp(key(K_HB, T), 0.0, 1.0) * (0.88 + 0.24 * flick(T, 6.0, 3.0));
    float A = max(key(K_L, T), 0.0), W = max(key(K_W, T), 20.0);
    float lb = clamp(key(K_LB, T), 0.0, 1.0) * (0.88 + 0.24 * flick(T, 5.0, 4.0));
    float sm = clamp(key(K_SM, T), 0.0, 1.0);

    // camera shake scaled by the effect's energy, and line boil. Before anything reads P. The reference camera
    // jitters a little at the peak, so this is about half the usual strength.
    const vec2 PIVOT = vec2(0.5 * REF);
    float kick = clamp(key(K_AMB, T), 0.0, 1.2);
    P += jitter2(T, 18.0, 5.0) * (0.4 + SHAKE * 7.5 * kick) + jitter2(T, 7.0, 6.0) * (0.6 + SHAKE * 5.5 * kick);
    P = PIVOT + rot2(0.008 * SHAKE * kick * jitter2(T, 11.0, 7.0).x) * (P - PIVOT);
    float boilSeed = floor(T * 12.0) * 3.7;
    P += 0.8 * vec2(fbm(P * 0.03 + boilSeed, 2), fbm(P * 0.03 + 7.0 + boilSeed, 2));

    // 1. static scene
    vec3 col = background(P, px);
    vec2 foot = vec2(SPIKE_X, BASE_Y + 0.93 * H);                       // where the spike meets the floor

    // 2. light the wave throws on the scene: the whole hall lifts, most round the spike; a glossy streak runs down
    //    the floor from the contact point toward the camera
    col *= 1.0 + amb * (0.28 + 1.9 * exp(-dot2((P - vec2(SPIKE_X + 60.0, BASE_Y + 40.0)) / vec2(360.0, 300.0))));
    float floorM = smoothstep(585.0, 640.0, P.y);
    float streak = exp(-sq((P.x - SPIKE_X) / (26.0 + 0.45 * max(P.y - 640.0, 0.0)))) * floorM;
    // broken by the rough concrete: patchy, with dark gaps, not a wet smear
    float gloss = clamp(0.55 + 1.3 * fbm(P * vec2(0.011, 0.040), 3), 0.0, 1.4);          // blotchy dusty concrete, no ripples
    col += (E_GOLD * 0.55 + E_HOT * 0.25) * streak * gloss * hb * Hn;
    col += E_AMBER * 0.30 * exp(-dot2((P - vec2(SPIKE_X + 150.0, 700.0)) / vec2(330.0, 70.0))) * floorM * lb * (0.7 + 0.3 * gloss);

    // 3. dust the spike kicks up: not light, a pale brown haze laid over the scene and lit by the wave
    float dens;
    vec3 dustCol;
    {
        vec2 q = P * 0.0075 + vec2(-T * 0.14, T * 0.42);                                  // it rises
        float n = fbm(q + 0.7 * vec2(fbm(q * 1.9 + 3.0 + T * 0.3, 2), fbm(q * 1.9 + 9.0, 2)), 4);
        float n2 = fbm(P * 0.024 + vec2(T * 0.5, T * 0.8) + 1.5 * n, 3);                  // finer billows inside the puffs
        float puffs = smoothstep(-0.50, 0.50, n) * clamp(0.90 + 0.35 * n2, 0.0, 1.2);     // soft clouds; fbm is signed, about +-0.7
        // where it hangs: a low bank round the foot spreading right, a cloud behind the ripples, a column on the spike
        float low = exp(-sq((P.x - 330.0) / 250.0)) * smoothstep(470.0, 600.0, P.y) * (1.0 - smoothstep(650.0, 720.0, P.y));
        float mid = exp(-sq((P.x - 430.0) / 230.0)) * exp(-sq((P.y - 450.0) / 170.0));
        float colm = exp(-sq((P.x - SPIKE_X - 10.0) / 95.0)) * smoothstep(100.0, 260.0, P.y) * (1.0 - smoothstep(600.0, 690.0, P.y));
        dens = clamp(sm * (1.5 * low + 1.15 * mid + 1.3 * colm * smoothstep(0.35, 0.8, sm)) * puffs, 0.0, 1.0);
        float lit = clamp(0.20 + 0.95 * amb, 0.0, 1.0) * exp(-length(P - vec2(SPIKE_X + 30.0, BASE_Y + 90.0)) / 330.0);
        dustCol = mix(rgb(88.0, 58.0, 40.0), rgb(236.0, 172.0, 112.0), lit);
        col = mix(col, dustCol, dens * 0.60);
    }


    // 4. the waveform: energy, so strip and particles together. The strip is the mirrored pair of thin curves;
    //    dashes run along them in lanes; the spindle of the spike is filled white-hot.
    {
        // the line is not ruled: the whole wave is pushed about by turbulence, more the further right, and it
        // breaks up along its length
        float far = smoothstep(SPIKE_X + 40.0, 700.0, P.x);
        vec2 Pw = P + vec2(0.0, 1.0) * ((2.0 + 8.0 * far) * fbm(vec2(P.x * 0.030 - T * 1.2, P.y * 0.02 + T * 0.7), 3)
                                      + (0.5 + 2.5 * far) * fbm(vec2(P.x * 0.11 + T * 2.0, P.y * 0.07), 2));
        vec2 wd = waveDist(Pw, H, A, W, T);
        // a second, ragged strand of smaller lobes out of step with the first: torn filaments, not a pattern
        vec2 Pw2 = P + vec2(0.0, 1.0) * 16.0 * fbm(vec2(P.x * 0.022 + T * 0.9, P.y * 0.03 - T * 0.5) + 7.0, 3);
        vec2 wd2 = waveDist(Pw2 - vec2(0.31 * W, 0.0), 0.0, 0.52 * A, 0.86 * W, T);
        float rightB = smoothstep(LOBE_X, LOBE_X + 40.0, P.x) * (1.0 - smoothstep(LOBE_X + 1.8 * W, LOBE_X + 3.0 * W, P.x));
        float torn = smoothstep(-0.05, 0.30, fbm(vec2(P.x * 0.035 - T * 1.1, P.y * 0.035) + 3.0, 2));
        col += (E_AMBER * 0.9 * exp(-wd2.x * wd2.x / 5.0) + E_AMBER * 0.25 * exp(-wd2.x / 12.0)) * 0.6 * lb * rightB * torn;
        float right = smoothstep(SPIKE_X + 20.0, LOBE_X, P.x);                           // 0 near the spike, 1 on the lobes
        float nl = floor(max(P.x - LOBE_X, 0.0) / W);                                    // each lobe further out is fainter
        float I = mix(hb, lb, right) * (nl < 1.0 ? 1.0 : nl < 2.0 ? 0.62 : nl < 3.0 ? 0.16 : 0.0);
        I *= 1.0 - 0.6 * smoothstep(0.2, 0.7, fbm(P * 0.02 + T * 0.8, 2)) * right * (1.0 - lb);   // late: broken up by the dust
        I *= mix(1.0, clamp(0.80 + 1.2 * fbm(vec2(P.x * 0.05 - T * 1.5, P.y * 0.05), 2), 0.40, 1.6), 0.35 + 0.65 * right);   // uneven along its length, with hot knots
        float wLine = mix(3.0, 2.6, right) * clamp(0.90 + 0.9 * fbm(P * 0.045 + 5.0, 2), 0.55, 1.7);
        float body = exp(-wd.x * wd.x / (wLine * wLine)), spine = exp(-wd.x * wd.x / 0.6) * (1.0 - 0.85 * right);
        float halo = exp(-wd.x / 13.0);
        vec2 u = vec2(P.x + 0.6 * P.y, wd.y);
        float p = strands(u, 2.2, 14.0, 520.0, 1.0, T) + strands(u + vec2(0.0, 1.3), 3.2, 24.0, 760.0, 2.0, T);
        vec3 strip = mix(E_GOLD, E_AMBER, 0.55 * right) * 1.35 * body + E_HOT * 0.55 * spine + E_AMBER * 0.36 * halo;
        vec3 dust = (E_GOLD * 1.4 + E_HOT * 0.3) * exp(-wd.x * wd.x / 20.0) * p;
        col += (strip + dust * PARTICLES) * I;
        // the faint sheath inside each lobe
        col += E_AMBER * 0.10 * (1.0 - smoothstep(-6.0, 0.0, wd.y)) * right * lb;

        // the spindle: white-hot inside, gold at its edge, streaked along its length
        float sp = spikeSig(P.x, H) - abs(P.y - BASE_Y);
        float hw = (5.0 + 0.062 * H) * pow(max(1.0 - abs(P.y - BASE_Y) / max(H, 1.0), 0.0), 1.18);   // its half-width at this height
        float fill = smoothstep(0.0, 0.75, 1.0 - abs(P.x - SPIKE_X) / max(hw, 0.5)) * step(0.5, hw) * hb * smoothstep(0.45, 0.85, hb);   // hollow once it dies
        float grain = 0.75 + 0.5 * fbm(vec2(P.x * 0.35, P.y * 0.012 - T * 2.0), 2);
        col += (E_HOT * 1.5 * fill + E_GOLD * 0.9 * smoothstep(-10.0, 6.0, sp) * hb * smoothstep(0.30, 0.80, hb)) * grain;
        // a ghost of the spike beside it once it starts to die
        float gh = (1.0 - hb) * Hn;
        float g1 = abs(spikeSig(P.x + 26.0, H * 0.72) - abs(P.y - BASE_Y)) * 0.12, g2 = abs(spikeSig(P.x - 15.0, H * 0.55) - abs(P.y - BASE_Y)) * 0.12;
        col += E_GOLD * 0.7 * gh * (exp(-g1 * g1) * step(abs(P.x + 26.0 - SPIKE_X), 22.0) + exp(-g2 * g2) * step(abs(P.x - 15.0 - SPIKE_X), 20.0));

        // the needle feeding it from the left edge, the thin line running on to the right, and the core bloom
        float dyb = abs(P.y - BASE_Y);
        float wn = 1.0 + 5.0 * exp((min(P.x, SPIKE_X) - SPIKE_X) / 70.0) * (0.4 + 0.6 * Hn);
        float needle = exp(-dyb * dyb / (wn * wn)) * (1.0 - smoothstep(SPIKE_X - 10.0, SPIKE_X + 20.0, P.x)) * smoothstep(-40.0, 120.0, P.x);
        col += (E_HOT * 0.9 + E_GOLD * 0.8) * needle * (0.45 + 0.55 * hb) + E_AMBER * 0.35 * exp(-dyb / 10.0) * needle;
        col += E_GOLD * 0.30 * exp(-dyb * dyb / 1.2) * smoothstep(SPIKE_X, SPIKE_X + 60.0, P.x) * (0.35 + 0.65 * lb) * (0.6 + 0.4 * strands(vec2(P.x, dyb), 3.0, 30.0, 400.0, 5.0, T));
        vec2 bq = (P - vec2(SPIKE_X - 8.0, BASE_Y)) / vec2(95.0, 60.0);
        col += (E_HOT * 1.3 + E_GOLD * 0.6) * (exp(-dot2(bq) * 2.2) + 0.5 * exp(-dot2(bq * vec2(0.45, 3.0)))) * amb * hb;
        col += E_GOLD * 0.9 * exp(-dot2((P - foot) / vec2(46.0, 16.0))) * hb * Hn;      // hot spot on the floor
    }
    // some of the dust hangs in front of the wave: late on the lines sink into it
    col = mix(col, dustCol, dens * 0.36 * smoothstep(0.4, 0.9, sm));

    // 5. sparks, in front of everything
    col += sparks(P, T);

    // 4. finish: ease highlights into white, encode once, dither
    col = min(col, vec3(0.7)) + 0.3 * (1.0 - exp(-max(col - 0.7, 0.0) / 0.3));
    col = linearToSrgb(clamp(col, 0.0, 1.0)) + ditherTPDF(fragCoord, iFrame);
    fragColor = vec4(col, 1.0);
}
