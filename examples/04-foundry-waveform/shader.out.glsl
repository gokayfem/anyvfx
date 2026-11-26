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

// Library code below is bundled from shader-skills (MIT): https://github.com/gokayfem/shader-skills
// ---- shader-skills library: common ----
const float TAU = 6.28318530717959;
// Squared length.
float dot2(vec2 v) { return dot(v, v); }
float dot2(vec3 v) { return dot(v, v); }
// 2D rotation matrix. `rot2(a) * v` rotates v counter-clockwise by a radians. (cos, sin) is renormalized because GLSL ES leaves trig precision undefined: on SwiftShader and some mobile GPUs a raw cos/sin pair is far enough from unit length that rotations stop preserving distances.
mat2 rot2(float a) {
    vec2 cs = normalize(vec2(cos(a), sin(a)));
    return mat2(cs.x, cs.y, -cs.y, cs.x);
}

// ---- shader-skills library: hash ----
// PCG-style 1D integer hash.
uint pcgHash(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}
// 3D integer hash, three decorrelated outputs.
uvec3 pcg3d(uvec3 v) {
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    return v;
}
// Map a uint to [0,1) using the top 24 bits, so the result can never round up to 1.0.
float uintToUnit(uint h) { return float(h >> 8u) * (1.0 / 16777216.0); }
vec2 uintToUnit(uvec2 h) { return vec2(h >> 8u) * (1.0 / 16777216.0); }
vec3 uintToUnit(uvec3 h) { return vec3(h >> 8u) * (1.0 / 16777216.0); }
vec4 uintToUnit(uvec4 h) { return vec4(h >> 8u) * (1.0 / 16777216.0); }
// Random float in [0,1) for an integer-valued 2D input.
float hash12(vec2 p) {
    uvec2 q = uvec2(ivec2(floor(p)));
    return uintToUnit(pcgHash(q.x + pcgHash(q.y)));
}
// Random vec2 in [0,1)^2 for an integer-valued 2D input.
vec2 hash22(vec2 p) {
    ivec2 q = ivec2(floor(p));
    return uintToUnit(pcg3d(uvec3(q.x, q.y, 0x2545u))).xy;
}
// Random vec3 in [0,1)^3 for an integer-valued 3D input.
vec3 hash33(vec3 p) { return uintToUnit(pcg3d(uvec3(ivec3(floor(p))))); }
// Random vec3 in [0,1)^3 for an integer-valued 2D input.
vec3 hash32(vec2 p) {
    ivec2 q = ivec2(floor(p));
    return uintToUnit(pcg3d(uvec3(q.x, q.y, 0x9E37u)));
}

// ---- shader-skills library: noise ----
// Quintic fade 6t^5 - 15t^4 + 10t^3: C2-continuous interpolation weights for lattice noise.
vec2 quinticFade(vec2 f) { return f * f * f * (f * (f * 6.0 - 15.0) + 10.0); }
vec3 quinticFade(vec3 f) { return f * f * f * (f * (f * 6.0 - 15.0) + 10.0); }
// Derivative of quinticFade: 30 t^2 (t - 1)^2.
vec2 quinticFadeDeriv(vec2 f) { return 30.0 * f * f * (f * (f - 2.0) + 1.0); }
vec3 quinticFadeDeriv(vec3 f) { return 30.0 * f * f * (f * (f - 2.0) + 1.0); }
// Unit gradient for a 2D lattice point.
vec2 latticeGradient(vec2 cell) {
    float a = TAU * hash12(cell);
    return vec2(cos(a), sin(a));
}
// 2D gradient (Perlin-style) noise with analytic derivatives. Returns vec3(value, d/dx, d/dy). Gradient noise has less grid-aligned blockiness than value noise. Prefer it for fBm.
vec3 gradientNoiseD(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = quinticFade(f), du = quinticFadeDeriv(f);
    vec2 ga = latticeGradient(i);
    vec2 gb = latticeGradient(i + vec2(1.0, 0.0));
    vec2 gc = latticeGradient(i + vec2(0.0, 1.0));
    vec2 gd = latticeGradient(i + vec2(1.0, 1.0));
    float va = dot(ga, f);
    float vb = dot(gb, f - vec2(1.0, 0.0));
    float vc = dot(gc, f - vec2(0.0, 1.0));
    float vd = dot(gd, f - vec2(1.0, 1.0));
    float k = va - vb - vc + vd;
    float value = va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * k;
    vec2 deriv = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd)
               + du * (vec2(vb - va, vc - va) + u.yx * k);
    return vec3(value, deriv);
}
// 2D gradient noise.
float gradientNoise(vec2 p) { return gradientNoiseD(p).x; }
// Dot product of a hashed 3D gradient with the offset to its lattice corner.
float latticeGradDot(vec3 cell, vec3 corner, vec3 f) {
    vec3 g = hash33(cell + corner) * 2.0 - 1.0;
    return dot(g, f - corner);
}
// 3D gradient noise.
float gradientNoise(vec3 p) {
    vec3 i = floor(p), f = fract(p);
    vec3 u = quinticFade(f);
    return mix(mix(mix(latticeGradDot(i, vec3(0, 0, 0), f), latticeGradDot(i, vec3(1, 0, 0), f), u.x),
                   mix(latticeGradDot(i, vec3(0, 1, 0), f), latticeGradDot(i, vec3(1, 1, 0), f), u.x), u.y),
               mix(mix(latticeGradDot(i, vec3(0, 0, 1), f), latticeGradDot(i, vec3(1, 0, 1), f), u.x),
                   mix(latticeGradDot(i, vec3(0, 1, 1), f), latticeGradDot(i, vec3(1, 1, 1), f), u.x), u.y), u.z);
}
// 3D gradient noise with analytic derivatives. Returns vec4(value, d/dx, d/dy, d/dz); value equals gradientNoise(p). The trilinear blend is expanded as a polynomial in the fade weights, so the gradient is the same blend of the corner gradients plus the chain-rule term of the fade.
vec4 gradientNoiseD(vec3 p) {
    vec3 i = floor(p), f = fract(p);
    vec3 u = quinticFade(f), du = quinticFadeDeriv(f);
    vec3 g000 = hash33(i) * 2.0 - 1.0;
    vec3 g100 = hash33(i + vec3(1, 0, 0)) * 2.0 - 1.0;
    vec3 g010 = hash33(i + vec3(0, 1, 0)) * 2.0 - 1.0;
    vec3 g110 = hash33(i + vec3(1, 1, 0)) * 2.0 - 1.0;
    vec3 g001 = hash33(i + vec3(0, 0, 1)) * 2.0 - 1.0;
    vec3 g101 = hash33(i + vec3(1, 0, 1)) * 2.0 - 1.0;
    vec3 g011 = hash33(i + vec3(0, 1, 1)) * 2.0 - 1.0;
    vec3 g111 = hash33(i + vec3(1, 1, 1)) * 2.0 - 1.0;
    float v000 = dot(g000, f);
    float v100 = dot(g100, f - vec3(1, 0, 0));
    float v010 = dot(g010, f - vec3(0, 1, 0));
    float v110 = dot(g110, f - vec3(1, 1, 0));
    float v001 = dot(g001, f - vec3(0, 0, 1));
    float v101 = dot(g101, f - vec3(1, 0, 1));
    float v011 = dot(g011, f - vec3(0, 1, 1));
    float v111 = dot(g111, f - vec3(1, 1, 1));
    // value = v000 + kx u.x + ky u.y + kz u.z + kxy u.x u.y + kyz u.y u.z + kzx u.z u.x + kxyz u.x u.y u.z
    float kx = v100 - v000, ky = v010 - v000, kz = v001 - v000;
    float kxy = v000 - v100 - v010 + v110;
    float kyz = v000 - v010 - v001 + v011;
    float kzx = v000 - v100 - v001 + v101;
    float kxyz = -v000 + v100 + v010 - v110 + v001 - v101 - v011 + v111;
    float value = v000 + kx * u.x + ky * u.y + kz * u.z
                + kxy * u.x * u.y + kyz * u.y * u.z + kzx * u.z * u.x + kxyz * u.x * u.y * u.z;
    vec3 grad = g000 + (g100 - g000) * u.x + (g010 - g000) * u.y + (g001 - g000) * u.z
              + (g000 - g100 - g010 + g110) * u.x * u.y
              + (g000 - g010 - g001 + g011) * u.y * u.z
              + (g000 - g100 - g001 + g101) * u.z * u.x
              + (-g000 + g100 + g010 - g110 + g001 - g101 - g011 + g111) * u.x * u.y * u.z
              + du * vec3(kx + kxy * u.y + kzx * u.z + kxyz * u.y * u.z,
                          ky + kxy * u.x + kyz * u.z + kxyz * u.x * u.z,
                          kz + kyz * u.y + kzx * u.x + kxyz * u.x * u.y);
    return vec4(value, grad);
}
const int FBM_MAX_OCTAVES = 12;
// Fractional Brownian motion over 2D gradient noise. Each octave is rotated to hide lattice alignment. persistence 0.5 is the classic look (H = 1). Lower is smoother, higher is rougher.
float fbm(vec2 p, int octaves, float lacunarity, float persistence) {
    const mat2 octaveRotation = mat2(0.8, 0.6, -0.6, 0.8);
    float sum = 0.0, amp = 1.0, norm = 0.0;
    for (int i = 0; i < FBM_MAX_OCTAVES; i++) {
        if (i >= octaves) break;
        sum += amp * gradientNoise(p);
        norm += amp;
        amp *= persistence;
        p = lacunarity * (octaveRotation * p) + vec2(17.13, -3.71);
    }
    return 1.4 * sum / norm;
}
// 2D fBm with the usual defaults (lacunarity 2.01 so octave peaks never re-align, persistence 0.5).
float fbm(vec2 p, int octaves) { return fbm(p, octaves, 2.01, 0.5); }
// fBm over 3D gradient noise.
float fbm(vec3 p, int octaves, float lacunarity, float persistence) {
    const mat3 octaveRotation = mat3(0.00, 0.80, 0.60,
                                     -0.80, 0.36, -0.48,
                                     -0.60, -0.48, 0.64);
    float sum = 0.0, amp = 1.0, norm = 0.0;
    for (int i = 0; i < FBM_MAX_OCTAVES; i++) {
        if (i >= octaves) break;
        sum += amp * gradientNoise(p);
        norm += amp;
        amp *= persistence;
        p = lacunarity * (octaveRotation * p) + vec3(17.13, -3.71, 5.29);
    }
    return sum / norm;
}
// Cellular (Worley/Voronoi) noise. Returns vec4(F1, F2, nearestCell.xy). F1 = distance to nearest feature point, F2 = second nearest. nearestCell is integer-valued, so hash it for per-cell randomness. jitter in [0,1] (0 = regular grid). Searches 3x3 cells. F2 can be slightly off at jitter 1.
vec4 voronoi(vec2 p, float jitter) {
    vec2 ip = floor(p), fp = fract(p);
    float f1 = 8.0, f2 = 8.0;
    vec2 nearest = vec2(0.0);
    for (int j = -1; j <= 1; j++)
    for (int i = -1; i <= 1; i++) {
        vec2 g = vec2(float(i), float(j));
        vec2 r = g + jitter * hash22(ip + g) - fp;
        float d = dot(r, r);
        if (d < f1) { f2 = f1; f1 = d; nearest = ip + g; }
        else if (d < f2) { f2 = d; }
    }
    return vec4(sqrt(f1), sqrt(f2), nearest);
}

// ---- shader-skills library: sdf2d ----
// Unsigned distance to segment a-b. Subtract a width to get a stroke.
float sdSegment(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

// ---- shader-skills library: color ----
// Exact sRGB decode (EOTF): encoded [0,1] -> linear.
vec3 srgbToLinear(vec3 c) {
    c = max(c, 0.0);
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}
// Exact sRGB encode (OETF): linear -> display [0,1]. Apply exactly once, after tonemapping. pow(c, 1/2.2) is visibly wrong near black (0.001 encodes to 0.013 here vs 0.043 with 2.2).
vec3 linearToSrgb(vec3 c) {
    c = max(c, 0.0);
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

// ---- shader-skills library: post ----
// Triangular-PDF dither of +-1 LSB for 8-bit output. Add AFTER linearToSrgb, right before writing fragColor.
vec3 ditherTPDF(vec2 fragCoord, int frame) {
    vec2 r = hash22(vec2(floor(fragCoord) + 7919.0 * float(frame % 1024)));
    return vec3((r.x + r.y - 1.0) / 255.0);
}

// ---- shader ----
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
// Generated by tools/fitmap.py from frame 1. 17 x 17 linear-RGB gains over x 0..816, y 0..816.
const vec3 LM[289] = vec3[289](
    vec3(0.99, 1.00, 1.01), vec3(0.98, 0.98, 0.99), vec3(1.03, 1.04, 1.05), vec3(1.00, 1.01, 1.01), vec3(1.08, 1.05, 1.06), vec3(0.99, 1.00, 1.05), vec3(0.85, 0.89, 0.99), vec3(0.99, 1.00, 1.08), vec3(1.16, 1.15, 1.19), vec3(1.17, 1.20, 1.24), vec3(1.13, 1.13, 1.16), vec3(1.12, 1.12, 1.17), vec3(1.13, 1.20, 1.42), vec3(1.02, 1.08, 1.29), vec3(1.05, 1.03, 1.05), vec3(1.00, 1.01, 1.08), vec3(1.02, 1.04, 1.13),
    vec3(1.01, 1.02, 1.02), vec3(1.00, 0.99, 0.99), vec3(1.04, 1.04, 1.05), vec3(1.01, 1.01, 1.01), vec3(1.14, 1.11, 1.14), vec3(1.06, 1.08, 1.18), vec3(0.86, 0.91, 1.03), vec3(1.01, 1.03, 1.11), vec3(1.11, 1.12, 1.16), vec3(1.19, 1.24, 1.29), vec3(1.25, 1.21, 1.21), vec3(1.14, 1.13, 1.17), vec3(1.05, 1.14, 1.41), vec3(1.02, 1.06, 1.26), vec3(1.07, 1.04, 1.05), vec3(1.02, 0.98, 1.00), vec3(1.06, 1.00, 1.02),
    vec3(0.91, 0.88, 0.87), vec3(0.90, 0.87, 0.86), vec3(0.96, 0.94, 0.94), vec3(1.00, 1.01, 1.02), vec3(1.17, 1.19, 1.30), vec3(1.04, 1.14, 1.35), vec3(0.89, 0.96, 1.13), vec3(1.10, 1.10, 1.17), vec3(1.16, 1.15, 1.15), vec3(1.19, 1.14, 1.09), vec3(1.22, 1.09, 0.98), vec3(1.04, 0.98, 0.92), vec3(0.93, 0.97, 1.11), vec3(0.82, 0.81, 0.94), vec3(0.90, 0.86, 0.92), vec3(0.92, 0.86, 0.88), vec3(0.89, 0.79, 0.82),
    vec3(0.95, 0.91, 0.90), vec3(1.00, 0.98, 0.98), vec3(1.08, 1.07, 1.09), vec3(1.01, 1.01, 1.02), vec3(0.91, 0.96, 1.05), vec3(0.86, 0.93, 1.11), vec3(0.96, 1.01, 1.15), vec3(1.16, 1.12, 1.12), vec3(1.18, 1.07, 0.96), vec3(1.12, 0.96, 0.79), vec3(1.15, 0.97, 0.77), vec3(0.96, 0.92, 0.84), vec3(0.94, 0.93, 1.00), vec3(0.87, 0.81, 0.89), vec3(0.91, 0.81, 0.86), vec3(1.01, 0.91, 0.83), vec3(1.03, 1.01, 0.90),
    vec3(1.03, 1.01, 1.01), vec3(1.06, 1.06, 1.09), vec3(1.04, 1.06, 1.09), vec3(1.03, 1.03, 1.05), vec3(0.77, 0.84, 0.96), vec3(0.75, 0.80, 0.97), vec3(0.93, 0.98, 1.10), vec3(1.19, 1.22, 1.29), vec3(1.36, 1.34, 1.34), vec3(1.23, 1.18, 1.13), vec3(1.22, 1.18, 1.14), vec3(1.04, 1.08, 1.17), vec3(0.93, 0.89, 0.98), vec3(0.83, 0.66, 0.77), vec3(0.79, 0.54, 0.59), vec3(0.98, 0.77, 0.69), vec3(1.05, 0.94, 0.82),
    vec3(1.18, 1.22, 1.35), vec3(1.03, 1.08, 1.17), vec3(0.93, 0.97, 1.01), vec3(1.09, 1.10, 1.13), vec3(1.10, 1.11, 1.17), vec3(0.94, 0.95, 1.02), vec3(0.96, 1.00, 1.09), vec3(1.37, 1.43, 1.58), vec3(1.45, 1.54, 1.75), vec3(1.38, 1.48, 1.74), vec3(1.31, 1.43, 1.76), vec3(0.93, 1.02, 1.32), vec3(0.86, 0.81, 0.93), vec3(0.82, 0.61, 0.68), vec3(0.86, 0.56, 0.53), vec3(1.02, 0.85, 0.80), vec3(1.05, 1.10, 1.18),
    vec3(0.86, 0.95, 1.17), vec3(0.73, 0.81, 0.97), vec3(0.85, 0.90, 0.98), vec3(1.07, 1.06, 1.04), vec3(1.12, 1.08, 0.98), vec3(1.19, 1.12, 0.99), vec3(1.23, 1.22, 1.22), vec3(1.69, 1.73, 1.85), vec3(1.46, 1.57, 1.81), vec3(1.37, 1.49, 1.76), vec3(1.28, 1.43, 1.81), vec3(0.76, 0.86, 1.19), vec3(0.79, 0.81, 1.04), vec3(0.91, 0.79, 1.09), vec3(0.94, 0.73, 0.93), vec3(1.01, 0.94, 1.04), vec3(1.02, 1.13, 1.32),
    vec3(0.93, 1.02, 1.21), vec3(0.82, 0.86, 0.91), vec3(1.03, 1.01, 0.94), vec3(1.29, 1.19, 1.00), vec3(1.25, 1.13, 0.92), vec3(1.30, 1.16, 0.91), vec3(1.31, 1.18, 0.95), vec3(1.47, 1.40, 1.27), vec3(1.62, 1.54, 1.42), vec3(1.44, 1.43, 1.38), vec3(1.17, 1.24, 1.33), vec3(1.03, 1.14, 1.33), vec3(1.34, 1.40, 1.53), vec3(1.40, 1.53, 1.75), vec3(0.90, 1.05, 1.27), vec3(0.68, 0.78, 0.93), vec3(0.68, 0.78, 0.93),
    vec3(1.04, 1.10, 1.24), vec3(0.98, 0.99, 1.00), vec3(1.18, 1.11, 0.95), vec3(1.31, 1.17, 0.92), vec3(1.40, 1.24, 0.96), vec3(1.27, 1.13, 0.88), vec3(1.31, 1.17, 0.88), vec3(2.19, 1.72, 1.10), vec3(2.18, 1.68, 1.13), vec3(1.65, 1.38, 1.07), vec3(1.54, 1.31, 1.06), vec3(1.71, 1.49, 1.26), vec3(1.59, 1.56, 1.53), vec3(1.43, 1.50, 1.58), vec3(1.18, 1.33, 1.49), vec3(0.80, 0.88, 0.97), vec3(0.76, 0.84, 0.93),
    vec3(0.98, 1.04, 1.18), vec3(1.08, 1.09, 1.11), vec3(1.10, 1.05, 0.90), vec3(0.99, 0.93, 0.77), vec3(1.06, 0.97, 0.79), vec3(1.08, 0.98, 0.79), vec3(1.14, 1.05, 0.84), vec3(2.15, 1.64, 1.06), vec3(2.18, 1.70, 1.16), vec3(1.44, 1.21, 0.98), vec3(1.33, 1.15, 0.98), vec3(1.26, 1.11, 0.95), vec3(1.16, 1.07, 0.96), vec3(0.92, 0.89, 0.83), vec3(0.92, 1.02, 1.10), vec3(0.86, 0.93, 0.99), vec3(0.95, 0.99, 1.03),
    vec3(1.30, 1.34, 1.43), vec3(1.23, 1.22, 1.19), vec3(0.94, 0.94, 0.87), vec3(0.86, 0.86, 0.80), vec3(0.93, 0.92, 0.82), vec3(0.95, 0.93, 0.83), vec3(0.97, 0.95, 0.88), vec3(1.12, 1.02, 0.90), vec3(1.34, 1.19, 1.01), vec3(1.22, 1.14, 1.05), vec3(1.13, 1.04, 0.94), vec3(0.96, 0.86, 0.73), vec3(0.82, 0.77, 0.65), vec3(0.88, 0.85, 0.77), vec3(0.78, 0.92, 1.03), vec3(0.72, 0.85, 0.97), vec3(0.83, 0.95, 1.07),
    vec3(1.18, 1.11, 1.05), vec3(1.00, 0.95, 0.90), vec3(1.00, 0.96, 0.87), vec3(1.01, 0.97, 0.84), vec3(1.08, 1.03, 0.88), vec3(1.18, 1.13, 0.98), vec3(1.09, 1.02, 0.87), vec3(1.08, 1.02, 0.94), vec3(1.12, 1.10, 1.06), vec3(1.09, 1.11, 1.13), vec3(1.16, 1.17, 1.18), vec3(1.27, 1.28, 1.28), vec3(1.10, 1.13, 1.16), vec3(1.00, 1.07, 1.13), vec3(0.97, 1.03, 1.10), vec3(0.95, 0.98, 1.03), vec3(0.91, 0.98, 1.06),
    vec3(1.04, 0.90, 0.77), vec3(1.23, 1.04, 0.84), vec3(1.36, 1.15, 0.87), vec3(1.39, 1.26, 0.92), vec3(1.65, 1.58, 1.07), vec3(1.92, 1.68, 1.04), vec3(1.68, 1.25, 0.80), vec3(1.20, 0.98, 0.76), vec3(1.04, 0.92, 0.80), vec3(0.99, 0.92, 0.86), vec3(0.98, 0.97, 0.96), vec3(1.00, 1.03, 1.06), vec3(1.02, 1.04, 1.07), vec3(0.93, 0.95, 0.97), vec3(0.97, 0.94, 0.93), vec3(1.11, 1.02, 0.92), vec3(1.09, 1.02, 0.95),
    vec3(1.10, 0.93, 0.74), vec3(1.24, 1.05, 0.81), vec3(1.23, 1.17, 0.99), vec3(1.04, 1.14, 1.28), vec3(1.19, 1.48, 1.77), vec3(1.62, 1.96, 1.73), vec3(2.11, 1.69, 0.99), vec3(1.57, 1.20, 0.83), vec3(1.11, 0.93, 0.76), vec3(0.91, 0.84, 0.75), vec3(0.80, 0.79, 0.76), vec3(0.73, 0.77, 0.79), vec3(0.86, 0.88, 0.90), vec3(0.91, 0.90, 0.89), vec3(0.96, 0.90, 0.83), vec3(1.08, 0.95, 0.79), vec3(1.11, 0.97, 0.79),
    vec3(0.75, 0.70, 0.65), vec3(0.80, 0.72, 0.62), vec3(0.95, 0.86, 0.71), vec3(1.04, 1.04, 0.95), vec3(1.10, 1.19, 1.31), vec3(1.51, 1.69, 1.47), vec3(1.76, 1.49, 1.05), vec3(1.46, 1.25, 1.02), vec3(1.04, 1.00, 0.96), vec3(0.90, 0.91, 0.91), vec3(0.89, 0.92, 0.96), vec3(0.92, 0.98, 1.03), vec3(1.00, 1.03, 1.07), vec3(1.04, 1.02, 1.00), vec3(1.08, 1.00, 0.91), vec3(1.12, 0.98, 0.82), vec3(1.07, 0.96, 0.82),
    vec3(0.66, 0.69, 0.74), vec3(0.77, 0.76, 0.74), vec3(1.01, 0.88, 0.72), vec3(1.36, 1.11, 0.81), vec3(1.51, 1.48, 1.20), vec3(1.93, 1.68, 1.07), vec3(1.44, 1.14, 0.84), vec3(1.03, 0.98, 0.93), vec3(0.85, 0.91, 0.95), vec3(0.75, 0.83, 0.90), vec3(0.79, 0.89, 0.97), vec3(0.88, 0.96, 1.04), vec3(0.98, 1.02, 1.06), vec3(1.00, 0.98, 0.97), vec3(1.07, 0.99, 0.92), vec3(1.16, 1.02, 0.87), vec3(1.19, 1.07, 0.95),
    vec3(0.67, 0.73, 0.80), vec3(0.80, 0.82, 0.84), vec3(1.01, 0.92, 0.82), vec3(1.32, 1.08, 0.81), vec3(1.78, 1.60, 1.16), vec3(2.19, 1.67, 1.00), vec3(1.53, 1.23, 0.96), vec3(1.02, 1.04, 1.04), vec3(0.85, 0.95, 1.02), vec3(0.75, 0.84, 0.91), vec3(0.64, 0.72, 0.79), vec3(0.61, 0.68, 0.75), vec3(0.71, 0.76, 0.80), vec3(0.77, 0.76, 0.73), vec3(0.86, 0.77, 0.67), vec3(0.93, 0.79, 0.64), vec3(0.88, 0.79, 0.70)
);

vec3 lightMapRaw(vec2 P) {
    vec2 g = clamp((P - vec2(0.0, 0.0)) / vec2(51.0000, 51.0000), vec2(0.0), vec2(15.999, 15.999));
    ivec2 i = ivec2(floor(g));
    vec2 f = fract(g);
    int k = i.y * 17 + i.x;
    return mix(mix(LM[k], LM[k + 1], f.x), mix(LM[k + 17], LM[k + 18], f.x), f.y);
}

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
// Foundry waveform, static scene: a foundry hall seen low over the floor. Linear colour before the light map.
// Landmarks (measured on frame 1, reference pixels, colours from probe.py / block means):
//   1. back wall y < ~272: sooty window frame at top left (x 0-92), black opening (x 92-215), furnace-lit orange panel
//      (x 215-816) with a horizontal seam (y ~96, x > 470), a vertical seam (x ~678, above it), a hot core at the
//      right (790, 215) and a row of embers on its bottom edge (x 630-800, y 256-272).
//   2. the concrete block y 272-528: lit left section (x < ~300), dark right section, black lip under the panel,
//      a hole at (54, 324), stains and drips.
//   3. base strip y 528-584: black recess at left (x < 92) and right (x > 520), a pale slab x 96-330, rubble line.
//   4. floor y > 584: grey-brown concrete, warm gloss on the left (x 120-300) and right (x > 700), a long crack
//      (0,672)-(330,702) continuing soft to (816,727), a dark seam (440,615)-(816,636), grit, soft foreground.

// Piecewise-linear curve through 8 points (xa.xyzw, xb.xyzw ascending), clamped at the ends.
float pl8(float x, vec4 xa, vec4 xb, vec4 ya, vec4 yb) {
    float r = ya.x;
    r += (ya.y - ya.x) * ramp(xa.x, xa.y, x);
    r += (ya.z - ya.y) * ramp(xa.y, xa.z, x);
    r += (ya.w - ya.z) * ramp(xa.z, xa.w, x);
    r += (yb.x - ya.w) * ramp(xa.w, xb.x, x);
    r += (yb.y - yb.x) * ramp(xb.x, xb.y, x);
    r += (yb.z - yb.y) * ramp(xb.y, xb.z, x);
    r += (yb.w - yb.z) * ramp(xb.z, xb.w, x);
    return r;
}

// Soft band: 1 inside [a, b], easing out over s on both sides.
float bandS(float x, float a, float b, float s) { return smoothstep(a - s, a + s, x) * (1.0 - smoothstep(b - s, b + s, x)); }

// Furnace palette in sRGB 0-255 keyed by the red level r (measured along the panel); r > 250 pushes into yellow.
vec3 fire(float r) {
    vec3 c = vec3(21.0, 10.0, 5.0);
    c = mix(c, vec3(28.0, 13.0, 6.0), ramp(21.0, 28.0, r));
    c = mix(c, vec3(60.0, 29.0, 14.0), ramp(28.0, 60.0, r));
    c = mix(c, vec3(100.0, 45.0, 17.0), ramp(60.0, 100.0, r));
    c = mix(c, vec3(140.0, 61.0, 21.0), ramp(100.0, 140.0, r));
    c = mix(c, vec3(200.0, 92.0, 30.0), ramp(140.0, 200.0, r));
    c = mix(c, vec3(240.0, 132.0, 40.0), ramp(200.0, 240.0, r));
    c = mix(c, vec3(248.0, 150.0, 48.0), ramp(240.0, 250.0, r));
    c = mix(c, vec3(250.0, 190.0, 90.0), ramp(250.0, 300.0, r));
    return c;
}

vec3 lin255(vec3 c) { return srgbToLinear(clamp(c, 0.0, 255.0) / 255.0); }

// ---- 1. back wall ------------------------------------------------------------------------------------------------
vec3 backWall(vec2 P, float px) {
    vec2 Q = P + 2.0 * vec2(fbm(P * 0.05, 2), fbm(P * 0.05 + 7.0, 2));     // soft, slightly wobbly edges (far DOF)
    float x = Q.x, y = Q.y;
    float n1 = fbm(P * vec2(0.022, 0.03), 4), n2 = fbm(P * 0.07 + 3.0, 3);

    // furnace panel: red level above and below the horizontal seam, then palette
    float ySeam = pl8(x, vec4(400.0, 470.0, 560.0, 640.0), vec4(700.0, 760.0, 810.0, 900.0),
                      vec4(119.0, 116.0, 107.0, 100.5), vec4(97.0, 92.0, 88.0, 82.0));
    float rA = pl8(x, vec4(210.0, 230.0, 380.0, 470.0), vec4(560.0, 665.0, 692.0, 720.0),
                   vec4(26.0, 28.0, 52.0, 63.0), vec4(84.0, 100.0, 128.0, 134.0));
    rA += 12.0 * ramp(720.0, 770.0, x) - 10.0 * ramp(790.0, 830.0, x);
    rA *= 0.86 + 0.14 * ramp(0.0, 60.0, y);
    float rB = pl8(x, vec4(210.0, 230.0, 330.0, 420.0), vec4(520.0, 600.0, 680.0, 800.0),
                   vec4(30.0, 35.0, 42.0, 62.0), vec4(80.0, 120.0, 180.0, 236.0));
    rB += 18.0 * ramp(130.0, 160.0, y) * ramp(560.0, 640.0, x) * ramp(780.0, 700.0, x);
    rB += 40.0 * ramp(170.0, 240.0, y) * ramp(520.0, 600.0, x) * ramp(800.0, 700.0, x);
    rB += 25.0 * ramp(150.0, 200.0, y) * ramp(400.0, 320.0, x);                       // lit lower left of the panel
    rB += 70.0 * exp(-sq((x - 790.0) / 45.0) - sq((y - 215.0) / 38.0));               // hot core: yellow
    float below = smoothstep(ySeam - 2.0, ySeam + 6.0, y);
    float r = mix(rA, rB, below);
    r *= 1.0 + 0.16 * n1 + 0.07 * n2;                                                 // mottled soot
    vec4 sv = voronoi(Q * 0.065 + 0.3 * n2, 1.0);                                      // round soot blotches, lit rims
    float bub = (1.0 - smoothstep(0.15, 0.6, sv.x)) * (hash12(sv.zw) - 0.45) + 0.05 * smoothstep(0.55, 0.8, sv.x);
    r *= 1.0 + 0.16 * bub;
    // seams: horizontal (fades in from x 470) and the vertical one above it at x ~678
    float seamH = exp(-sq((y - ySeam) / 4.0)) * ramp(450.0, 580.0, x);
    float seamS = bandS(y - ySeam, 4.0, 22.0, 6.0) * ramp(450.0, 500.0, x) * ramp(640.0, 560.0, x);   // soot under it
    float seamV = exp(-sq((x - 682.0) / 4.0)) * (1.0 - below);
    r *= 1.0 - mix(0.3, 0.55, ramp(660.0, 740.0, x)) * seamH - 0.12 * seamS - 0.22 * seamV;
    r *= 1.0 + 0.16 * bandS(x, 656.0, 674.0, 4.0) * (1.0 - below) * ramp(0.0, 50.0, y);   // paler band left of the joint
    r *= 1.0 - 0.15 * ramp(806.0, 818.0, x) * (1.0 - below);                          // shadowed right edge
    // embers along the bottom edge
    float emb = 0.0;
    emb += 1.0 * exp(-sq((x - 639.0) / 7.0) - sq((y - 269.0) / 5.0));
    emb += 1.0 * exp(-sq((x - 697.0) / 6.0) - sq((y - 267.0) / 6.0));
    emb += 0.9 * exp(-sq((x - 758.0) / 14.0) - sq((y - 264.0) / 6.0));
    emb += 0.6 * exp(-sq((x - 795.0) / 7.0) - sq((y - 261.0) / 6.0));
    r += 70.0 * emb;
    vec3 c = fire(r);
    // grey soot haze over the middle of the panel
    float haze = ramp(300.0, 380.0, x) * ramp(600.0, 520.0, x) * ramp(230.0, 150.0, y);
    c.gb = mix(c.gb, c.r * vec2(0.6, 0.43), haze * 0.85);

    // left: sooty window frame (x < 92) over the black opening (x 92-215)
    vec3 w = vec3(21.0, 10.0, 5.0);
    vec3 pane = vec3(44.0, 28.0, 22.0), pale = vec3(51.0, 37.0, 30.0);
    float yBar = 92.0 + 0.17 * x;                                                    // dark sloping bar between panes
    vec3 fr = mix(pane, pale, bandS(x, 62.0, 88.0, 2.5) * (1.0 - 0.6 * bandS(y, 58.0, 68.0, 3.0)));
    vec3 low = mix(pale, pane, bandS(x, 42.0, 56.0, 3.0) * 0.7);
    fr = mix(fr, low, smoothstep(yBar + 4.0, yBar + 12.0, y));
    fr = mix(fr, vec3(22.0, 11.0, 6.0) + vec3(14.0, 10.0, 8.0) * ramp(50.0, 90.0, x), bandS(y, yBar - 4.0, yBar + 4.0, 3.0));
    fr = mix(fr, vec3(34.0, 18.0, 11.0), smoothstep(156.0, 166.0, y));
    fr *= 1.0 + 0.07 * n2 + 0.05 * n1;                                               // blotchy grime on the panes
    fr = mix(fr, w, smoothstep(170.0, 180.0, y));
    w = mix(w, fr, 1.0 - smoothstep(86.0, 100.0, x));
    // frame post in the dark below, lamp glint at (27, 247), thin pole x ~122
    w = mix(w, vec3(45.0, 22.0, 12.0), bandS(x, 70.0, 80.0, 2.0) * smoothstep(182.0, 192.0, y));
    w = mix(w, vec3(52.0, 26.0, 13.0), exp(-sq((x - 27.0) / 5.0) - sq((y - 247.0) / 5.0)));
    w = mix(w, vec3(28.0, 13.0, 6.0), bandS(x, 118.0, 128.0, 2.0) * bandS(y, 100.0, 186.0, 4.0) * 0.8);
    // dim lit lower part of the opening
    w = mix(w, vec3(28.0, 13.0, 6.0), bandS(x, 106.0, 212.0, 3.0) * smoothstep(182.0, 192.0, y));
    w = mix(w, vec3(36.0, 17.0, 9.0) * (1.0 + 0.15 * n2), ramp(238.0, 272.0, y) * ramp(40.0, 140.0, x));   // dust at the foot
    // panel takes over from x ~215
    c = mix(w, c, smoothstep(210.0, 220.0, x));
    return lin255(c);
}

// ---- 2./3. block and base strip -----------------------------------------------------------------------------------
vec3 block(vec2 P, float px) {
    vec2 Q = P + 1.2 * vec2(fbm(P * 0.06, 2), fbm(P * 0.06 + 5.0, 2));
    float x = Q.x, y = Q.y;
    float n1 = fbm(P * vec2(0.025, 0.02), 4), n2 = fbm(P * 0.06 + 9.0, 3);
    // lit left section fades to the dark right section around x 290-350
    float lit = 1.0 - smoothstep(280.0, 350.0, x + 20.0 * n1);
    float rL = 88.0 + 8.0 * ramp(290.0, 320.0, y) - 4.0 * ramp(460.0, 520.0, y);
    float rR = 40.0 - 8.0 * bandS(x, 500.0, 680.0, 30.0) * ramp(420.0, 470.0, y);
    rR += 8.0 * ramp(700.0, 760.0, x);
    float r = mix(rR, rL, lit);
    // concrete: broad blotches, smaller soft stains (cells with their own tone), a few runs down the face
    vec4 v = voronoi(Q * vec2(0.045, 0.06), 0.9);
    float cellT = hash12(v.zw) - 0.5;
    r *= 1.0 + 0.13 * n1 + 0.06 * n2 + 0.08 * cellT * (1.0 - smoothstep(0.3, 0.8, v.x));
    float st = fbm(Q * vec2(0.009, 0.012) + 0.6 * vec2(n2, n1) + 4.0, 3);             // soot and damp patches
    float dk = fbm(Q * vec2(0.022, 0.03) + 12.0, 3);
    r *= (0.85 + 0.3 * smoothstep(-0.35, 0.35, st)) * (1.0 - 0.2 * smoothstep(0.15, 0.5, dk));
    float run = 0.0;
    run += exp(-sq((x - 25.0) / 3.5)) * bandS(y, 440.0, 492.0, 8.0);
    run += 0.6 * exp(-sq((x - 172.0) / 4.0)) * bandS(y, 300.0, 380.0, 15.0);
    run += 0.7 * exp(-sq((x - 262.0 - 0.05 * (y - 300.0)) / 5.0)) * bandS(y, 280.0, 520.0, 20.0);
    run += 0.5 * exp(-sq((x - 455.0) / 6.0)) * bandS(y, 300.0, 470.0, 20.0);
    run += 0.5 * exp(-sq((x - 640.0) / 7.0)) * bandS(y, 290.0, 520.0, 20.0);
    r *= 1.0 - 0.22 * run * (0.6 + 0.8 * n2);
    vec3 c = mix(vec3(r, r * 0.47, r * 0.21), vec3(r, r * 0.53, r * 0.34), (1.0 - lit) * ramp(300.0, 380.0, y));
    // black lip under the panel (right), darker under-edge shadow (left)
    float lip = (1.0 - smoothstep(282.0, 300.0, y)) * ramp(310.0, 340.0, x);
    c = mix(c, mix(vec3(30.0, 14.0, 7.0), vec3(52.0, 25.0, 13.0), ramp(720.0, 760.0, x)), lip);
    c *= mix(0.42, 1.0, smoothstep(276.0, 302.0, y)) * (1.0 - ramp(310.0, 340.0, x)) + ramp(310.0, 340.0, x);
    // pits: the hole at (54, 324) and smaller ones
    c = mix(c, vec3(28.0, 13.0, 6.0), 1.0 - smoothstep(0.6, 1.2, length((Q - vec2(54.0, 324.0)) / vec2(6.0, 9.0))));
    c = mix(c, c * 0.55, 1.0 - smoothstep(0.5, 1.2, length((Q - vec2(8.0, 358.0)) / 3.5)));
    c = mix(c, c * 0.6, 1.0 - smoothstep(0.5, 1.2, length((Q - vec2(73.0, 494.0)) / vec2(4.0, 5.0))));
    c = mix(c, c * 0.6, 1.0 - smoothstep(0.5, 1.2, length((Q - vec2(28.0, 518.0)) / 3.0)));
    c = mix(c, c * 0.7, 1.0 - smoothstep(0.5, 1.2, length((Q - vec2(118.0, 470.0)) / 3.0)));
    // pitting: small dark dimples scattered over the face
    vec4 pv = voronoi(Q * 0.11, 1.0);
    vec3 ph = hash32(pv.zw + 3.0);
    c *= 1.0 - 0.2 * (1.0 - smoothstep(0.1, 0.3, pv.x)) * step(0.97, ph.x);
    return lin255(c);
}

vec3 baseStrip(vec2 P, float px) {
    vec2 Q = P + 1.5 * vec2(fbm(P * 0.07, 2), fbm(P * 0.07 + 2.0, 2));
    float x = Q.x, y = Q.y;
    float n = fbm(P * vec2(0.05, 0.08) + 4.0, 3);
    vec3 blk = vec3(21.0, 10.0, 5.0);
    // the slab under the block: black recess left of x 97, pale slab to x ~330, dimmer to 520, black beyond
    float rs = pl8(x, vec4(92.0, 100.0, 200.0, 300.0), vec4(340.0, 420.0, 480.0, 530.0),
                   vec4(21.0, 60.0, 68.0, 75.0), vec4(46.0, 38.0, 48.0, 21.0));
    rs *= 1.0 + 0.2 * n;
    vec3 c = vec3(rs, rs * 0.48, rs * 0.25);
    c = mix(c, vec3(32.0, 15.0, 8.0), ramp(538.0, 556.0, y) * (1.0 - ramp(88.0, 98.0, x)));   // recess floor catches light
    // its lower edge is chipped: dark irregular blotches near y 555-570
    c *= 1.0 - 0.45 * smoothstep(0.1, 0.5, fbm(Q * vec2(0.06, 0.12) + 7.0, 3)) * bandS(y, 552.0, 572.0, 4.0) * ramp(90.0, 110.0, x);
    c = mix(c, vec3(24.0, 12.0, 6.0), ramp(520.0, 540.0, x));
    c = mix(c, vec3(43.0, 22.0, 13.0), bandS(x, 750.0, 760.0, 2.5) * bandS(y, 532.0, 562.0, 3.0));   // little post
    // rubble line at the foot: out-of-focus lumps, pale where lit, dark gaps between
    float l = fbm(vec2(x * 0.045, (y - 568.0) * 0.13) + 3.0, 3), l2 = fbm(vec2(x * 0.03, 7.0), 2);
    float rr = mix(36.0, 60.0, smoothstep(-0.45, 0.5, l));
    vec3 rubC = vec3(rr, rr * 0.6, rr * 0.45);
    rubC = mix(rubC, vec3(84.0, 40.0, 18.0) * (0.75 + 0.5 * smoothstep(-0.4, 0.4, l)), bandS(x, 180.0, 270.0, 25.0));
    rubC = mix(rubC, vec3(40.0, 20.0, 11.0) * (0.8 + 0.5 * smoothstep(-0.4, 0.4, l)), bandS(x, 96.0, 175.0, 12.0));
    rubC = mix(rubC, vec3(68.0, 36.0, 21.0) * (0.6 + 0.7 * smoothstep(-0.3, 0.4, l + 0.3 * l2)), 1.0 - ramp(76.0, 96.0, x));
    float rT = mix(557.0, 562.0, ramp(90.0, 330.0, x));
    float rub = bandS(y, rT, rT + 17.0, 3.0);
    c = mix(c, rubC, rub);
    c = mix(c, vec3(30.0, 14.0, 7.0), bandS(y, 576.0, 586.0, 2.0) * ramp(110.0, 60.0, x));
    return lin255(c);
}

float blob(vec2 p, vec2 c, vec2 r) { return exp(-dot((p - c) / r, (p - c) / r)); }

// ---- 4. floor -----------------------------------------------------------------------------------------------------
vec3 floorStatic(vec2 P, float px) {
    float dof = ramp(700.0, 816.0, P.y);                                              // blur grows toward the camera
    vec2 Q = P + 1.0 * vec2(fbm(P * 0.04, 2), fbm(P * 0.04 + 6.0, 2));
    float x = Q.x, y = Q.y;
    vec2 F = vec2(x, (y - 560.0) * 3.0);                                             // perspective: squashed vertically
    float n1 = fbm(F * 0.012, 4), n2 = fbm(F * vec2(0.03, 0.05) + 3.0, 3 - int(2.0 * dof));
    float str = fbm(vec2(x * 0.006, y * 0.09) + 1.0, 3);                              // horizontal striations of the slab
    float r = 74.0 + 6.0 * ramp(590.0, 610.0, y) - 10.0 * ramp(700.0, 760.0, y) * ramp(500.0, 380.0, x);
    r += 15.0 * ramp(640.0, 780.0, x) * ramp(640.0, 680.0, y);
    r -= 24.0 * ramp(632.0, 600.0, y) * ramp(360.0, 260.0, x);                       // far left floor in the block's shadow
    r *= 1.0 + 0.12 * bandS(y, 587.0, 600.0, 3.0) * ramp(520.0, 580.0, x);            // lit far strip behind the rubble
    r *= 1.0 - 0.1 * ramp(796.0, 816.0, y);                                           // nearest floor falls into shade
    float far = ramp(640.0, 600.0, y);
    r *= 1.0 + 0.12 * n1 + 0.07 * n2 + (0.10 + 0.10 * far) * str + 0.10 * far * fbm(vec2(x * 0.004, y * 0.22) + 8.0, 2);
    vec3 c = vec3(r, r * 0.58, r * 0.40);
    // warm gloss: the pool between the far edge and the crack, its broken reflection below the crack, right sheen
    float yC = pl8(x, vec4(-40.0, 0.0, 52.0, 140.0), vec4(220.0, 280.0, 450.0, 860.0),
                   vec4(668.0, 672.0, 678.0, 684.5), vec4(690.0, 696.0, 708.0, 732.0));
    float sx = x - 215.0;
    float pool = exp(-sq(sx / (sx < 0.0 ? 135.0 : 72.0))) * smoothstep(604.0, 664.0, y);
    pool *= 0.8 + 0.4 * fbm(vec2(x * 0.012, y * 0.09) + 2.0, 3);                      // streaked like the slab
    pool *= 1.0 - smoothstep(yC, yC + 4.0, y);
    // below the crack: the reflection breaks into soft horizontal glints, traced from the frame (centre, radii, level)
    vec2 q = Q;
    float col = 0.15 * exp(-sq((x - 215.0) / 50.0)) * (1.0 - 0.5 * ramp(700.0, 816.0, y));
    col += 1.00 * blob(q, vec2(226.0, 699.0), vec2(26.0, 4.0));
    col += 0.85 * blob(q, vec2(205.0, 694.0), vec2(28.0, 3.0));
    col += 0.70 * blob(q, vec2(288.0, 708.0), vec2(20.0, 4.0));
    col += 0.75 * blob(q, vec2(222.0, 709.0), vec2(62.0, 4.0));
    col += 0.90 * blob(q, vec2(216.0, 717.0), vec2(32.0, 5.0));
    col += 0.62 * blob(q, vec2(214.0, 727.0), vec2(48.0, 5.0));
    col += 0.48 * blob(q, vec2(212.0, 735.0), vec2(30.0, 4.0));
    col += 0.45 * blob(q, vec2(220.0, 741.0), vec2(10.0, 5.0));
    col += 0.30 * blob(q, vec2(250.0, 757.0), vec2(35.0, 6.0));
    col += 0.75 * blob(q, vec2(218.0, 771.0), vec2(16.0, 7.0));
    col += 0.35 * blob(q, vec2(196.0, 795.0), vec2(25.0, 8.0));
    col += 0.40 * blob(q, vec2(222.0, 806.0), vec2(12.0, 8.0));
    col += 0.30 * exp(-sq((x - 135.0) / 45.0)) * bandS(y, yC + 3.0, 712.0, 4.0);         // dimmer glints left of it
    col *= smoothstep(yC + 1.0, yC + 4.0, y) * (0.75 + 0.5 * smoothstep(-0.35, 0.35, fbm(vec2(x * 0.05, y * 0.12) + 4.0, 3)));
    float g = pool + col;
    c = mix(c, fire(r + 175.0 * g), clamp(g * 1.5, 0.0, 1.0));
    float scr = sdSegment(Q, vec2(165.0, 663.0), vec2(300.0, 645.0));                  // pale scratch across the pool
    c *= 1.0 + 0.15 * (1.0 - smoothstep(0.4, 1.6, scr)) * pool;
    float gr = 0.4 * ramp(640.0, 760.0, x) * bandS(y, 668.0, 712.0, 10.0) * (0.6 + 0.8 * smoothstep(-0.3, 0.4, fbm(F * 0.015 + 6.0, 3)));
    c = mix(c, vec3(110.0, 58.0, 33.0), gr);
    // far left dark strip, dark seam on the right (measured path) with a warm lit strip just beyond it
    c *= 1.0 - 0.3 * bandS(y, 574.0, 598.0, 5.0) * ramp(80.0, 20.0, x);
    float ySe = pl8(x, vec4(300.0, 360.0, 500.0, 550.0), vec4(640.0, 700.0, 760.0, 860.0),
                    vec4(650.0, 649.0, 645.0, 630.0), vec4(633.0, 639.0, 635.0, 630.0));
    c = mix(c, vec3(112.0, 57.0, 31.0), 0.5 * exp(-sq((y - ySe + 25.0) / 6.0)) * ramp(650.0, 730.0, x));
    c *= 1.0 - pl8(x, vec4(300.0, 360.0, 420.0, 500.0), vec4(560.0, 640.0, 720.0, 800.0),
                   vec4(0.0, 0.14, 0.24, 0.26), vec4(0.3, 0.35, 0.5, 0.62)) * exp(-sq((y - ySe) / 8.0));
    c *= 1.0 - 0.13 * exp(-sq((y - ySe - 11.0) / 7.0)) * ramp(540.0, 600.0, x);         // its shadow spreads toward us
    // the crack: sharp on the left, soft beyond x ~330 with pale beads along it
    float rt = ramp(320.0, 480.0, x);
    float core = exp(-sq((y - yC) / mix(1.6, 3.5, rt)));
    c = mix(c, mix(vec3(40.0, 19.0, 9.0), c * 0.6, rt), core * mix(0.95, 1.0, rt));
    c *= 1.0 + 0.25 * exp(-sq((y - yC + 3.0) / 1.5)) * ramp(330.0, 250.0, x);           // lit upper lip of the crack
    c *= 1.0 - 0.28 * bandS(y - yC, 3.0, 32.0, 5.0) * ramp(270.0, 310.0, x);          // shadowed band below on the right
    vec4 bv = voronoi(vec2(x * 0.06, 0.5), 0.8);
    float bead = (1.0 - smoothstep(0.1, 0.5, bv.x)) * step(0.3, hash12(bv.zw));
    c = mix(c, vec3(118.0, 92.0, 72.0), 0.55 * bead * exp(-sq((y - yC + 4.0) / 4.5)) * bandS(x, 410.0, 640.0, 20.0));
    // grit and pebbles on the mid floor: sparse dark chips with a lit top, pale grains
    vec4 v = voronoi(F * 0.09, 1.0);
    vec3 h = hash32(v.zw);
    float rad = 0.05 + 0.10 * h.z * h.z;
    float sp = (1.0 - smoothstep(rad, rad + 0.07, v.x)) * step(0.9, h.x) * ramp(770.0, 700.0, y) * ramp(595.0, 615.0, y);
    c = mix(c, h.y > 0.75 ? c * 0.45 : c * (1.3 + 1.0 * g) + 14.0, sp * 0.8);
    c = mix(c, c * 0.35, (1.0 - smoothstep(4.0, 7.0, length((Q - vec2(491.0, 641.0)) * vec2(1.1, 1.0)))));  // the big pebble
    c = mix(c, c * 0.45, (1.0 - smoothstep(2.0, 4.0, length(Q - vec2(130.0, 690.0)))));
    return lin255(c);
}

// Dust specks and fine grain over the whole frame (static part).
vec3 grain(vec3 c, vec2 P) {
    vec4 v = voronoi(P * 0.11, 1.0);
    vec3 h = hash32(v.zw + 21.0);
    float sp = (1.0 - smoothstep(0.05, 0.14, v.x)) * step(0.97, h.x);
    c += sp * vec3(0.04, 0.02, 0.008) * (0.4 + h.y);
    float g = hash12(floor(P)) - 0.5;
    return c * (1.0 + 0.06 * g);
}

vec3 environment(vec2 P, float px) {
    float yTop = pl8(P.x, vec4(-40.0, 200.0, 300.0, 335.0), vec4(640.0, 680.0, 720.0, 800.0),
                     vec4(279.0, 280.0, 278.0, 272.5), vec4(274.0, 271.0, 269.5, 268.0));
    float yBase = 528.0 - 4.0 * ramp(0.0, 100.0, P.x) + 2.0 * fbm(vec2(P.x * 0.05, 1.0), 2);
    float yFloor = mix(583.0, 586.0, ramp(300.0, 400.0, P.x));
    float sT = mix(2.5, 4.0, ramp(300.0, 360.0, P.x));                               // the panel's lower edge is soft
    vec3 c;
    if (P.y < yTop - 8.0) c = backWall(P, px);
    else if (P.y < yTop + 8.0) c = mix(backWall(P, px), block(P, px), smoothstep(yTop - sT, yTop + sT, P.y));
    else if (P.y < yBase - 5.0) c = block(P, px);
    else if (P.y < yBase + 5.0) c = mix(block(P, px), baseStrip(P, px), smoothstep(yBase - 2.0, yBase + 2.0, P.y));
    else if (P.y < yFloor - 6.0) c = baseStrip(P, px);
    else if (P.y < yFloor + 6.0) c = mix(baseStrip(P, px), floorStatic(P, px), smoothstep(yFloor - 5.0, yFloor + 5.0, P.y));
    else c = floorStatic(P, px);
    return grain(c, P);
}

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
