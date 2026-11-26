// Forest geysers: a sunlit mossy clearing with four glowing blue rings on the grass; water-energy bursts
// out of them in turn (lower left, centre, then a big one on the right that throws a wide curved sheet up out of
// frame), each leaving ripples, droplets and a thin arcing streamer. Recreated from the 12-frame reference.
// Single pass, no textures. Written against the shader-skills library; build with tools/go.py.
//
// All layout constants are in REFERENCE PIXELS: origin top-left, x right, y down, REF units tall.
//
// Breakdown (a video model for the order of events and depth, frame measurements for where each burst is):
//   Layers, back to front: hazy forest -> two trunks -> dappled grass, moss mounds, rock -> blue light spilled on
//   the grass -> ground rings and ripples -> geyser spikes and the curved sheet -> droplets and leaf specks.
//   Depth: nothing passes through a solid; every effect is in open air in front of the scene, rings flat on the
//   ground behind the bursts. The rings are additive light; the water is alpha-blended over the scene.
//   Keys: one intensity table per burst and per ring; the loop is close to seamless so the spline wraps.

#define DEBUG_MODE 0      // 0 final | 1 distance | 2 normals | 3 part / layer ids
#define GIF_STEPPED 0     // 1 = hold each reference frame time, 0 = continuous motion
#define FREEZE_TIME -1.0  // >= 0 freezes the loop at that time in seconds
#define LIGHTMAP 1        // 0 = no painted light map (tools/refit.py renders with this off to fit it)
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
// Random float in [0,1) for an integer-valued input.
float hash11(float p) { return uintToUnit(pcgHash(uint(int(floor(p))))); }
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
// Exact distance to Voronoi cell borders, found in two passes: nearest point, then nearest bisector. Returns vec3(borderDistance, vectorToNearestPoint). Unlike F2-F1, the border distance is a true distance, so lines have constant width.
vec3 voronoiBorder(vec2 p, float jitter) {
    vec2 ip = floor(p), fp = fract(p);
    vec2 mg = vec2(0.0), mr = vec2(0.0);
    float md = 8.0;
    for (int j = -1; j <= 1; j++)
    for (int i = -1; i <= 1; i++) {
        vec2 g = vec2(float(i), float(j));
        vec2 r = g + jitter * hash22(ip + g) - fp;
        float d = dot(r, r);
        if (d < md) { md = d; mr = r; mg = g; }
    }
    md = 8.0;
    for (int j = -2; j <= 2; j++)
    for (int i = -2; i <= 2; i++) {
        vec2 g = mg + vec2(float(i), float(j));
        vec2 r = g + jitter * hash22(ip + g) - fp;
        if (dot2(mr - r) > 1e-5) {
            md = min(md, dot(0.5 * (mr + r), normalize(r - mr)));
        }
    }
    return vec3(md, mr);
}

// ---- shader-skills library: sdf2d ----
// Unsigned distance to segment a-b. Subtract a width to get a stroke.
float sdSegment(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}
// Ellipse with semi-axes r. A fast approximation: exact zero set, a bound outside up to about 2:1 aspect, gradient above 1 inside and for flatter ellipses. Fine for fills and strokes; avoid for exact offsets.
float sdEllipse(vec2 p, vec2 r) {
    float k0 = length(p / r);
    float k1 = length(p / (r * r));
    if (k1 < 1e-8) return -min(r.x, r.y);
    return k0 * (k0 - 1.0) / k1;
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
// Antialiased fill of a 2D SDF: 1 inside, 0 outside, box-filtered across one pixel. Uses screen derivatives, so call it outside non-uniform branches and loops. For a fixed pixel size use fillAA(d, px).
float fillAA(float d) {
    float w = length(vec2(dFdx(d), dFdy(d)));
    return clamp(0.5 - d / max(w, 1e-6), 0.0, 1.0);
}
// Antialiased fill with an explicit pixel size px (e.g. 2.0 / iResolution.y for the standard uv). Safe in loops and branches.
float fillAA(float d, float px) { return clamp(0.5 - d / px, 0.0, 1.0); }
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
const float K_AMB[NF] = float[NF](0.00, 0.20, 0.32, 0.25, 0.17, 0.23, 0.58, 1.00, 0.38, 0.20, 0.17, 0.18);

float key(float k[NF], float T) {
    float f = T / DT;
    int i = int(floor(f)) % NF;
    float u = fract(f);
    float p0 = k[(i + NF - 1) % NF], p1 = k[i], p2 = k[(i + 1) % NF], p3 = k[(i + 2) % NF];
    return p1 + 0.5 * u * (p2 - p0 + u * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + u * (3.0 * (p1 - p2) + p3 - p0)));
}

// ---- painted light map (generated; identity until tools/refit.py has run) ---------------------------------------------
// Generated by tools/fitmap.py from frame 12. 17 x 17 linear-RGB gains over x 0..816, y 0..816.
const vec3 LM[289] = vec3[289](
    vec3(1.24, 1.20, 1.26), vec3(1.14, 1.11, 0.90), vec3(1.11, 1.08, 0.84), vec3(1.18, 1.15, 1.14), vec3(1.66, 1.56, 1.57), vec3(1.09, 1.09, 1.21), vec3(0.67, 0.70, 0.75), vec3(0.69, 0.71, 0.74), vec3(0.74, 0.75, 0.74), vec3(1.02, 1.06, 1.41), vec3(1.37, 1.42, 1.95), vec3(1.18, 1.09, 1.20), vec3(0.96, 0.96, 0.99), vec3(1.02, 1.02, 0.99), vec3(1.16, 1.10, 0.98), vec3(1.03, 0.95, 0.88), vec3(0.89, 0.88, 0.88),
    vec3(2.09, 1.92, 2.39), vec3(1.34, 1.29, 1.33), vec3(1.17, 1.16, 1.09), vec3(1.11, 1.10, 1.10), vec3(1.00, 0.99, 1.00), vec3(1.20, 1.20, 1.41), vec3(1.10, 1.10, 1.30), vec3(0.94, 0.96, 1.12), vec3(0.82, 0.84, 0.85), vec3(0.74, 0.78, 0.90), vec3(0.82, 0.86, 1.06), vec3(0.88, 0.85, 1.10), vec3(0.97, 0.97, 1.04), vec3(1.03, 1.01, 0.99), vec3(1.16, 1.11, 0.99), vec3(1.03, 0.98, 0.92), vec3(0.94, 0.96, 0.97),
    vec3(1.43, 1.39, 1.43), vec3(1.21, 1.20, 1.17), vec3(1.28, 1.29, 1.24), vec3(1.14, 1.12, 1.08), vec3(0.83, 0.84, 0.83), vec3(1.23, 1.19, 1.28), vec3(1.33, 1.29, 1.39), vec3(0.96, 0.97, 1.03), vec3(0.96, 0.94, 0.89), vec3(0.87, 0.88, 0.90), vec3(0.79, 0.81, 1.14), vec3(0.83, 0.85, 1.22), vec3(1.03, 0.99, 1.04), vec3(1.21, 1.12, 1.10), vec3(1.19, 1.14, 1.03), vec3(1.00, 0.96, 0.89), vec3(0.94, 0.95, 0.95),
    vec3(1.19, 1.14, 1.05), vec3(1.48, 1.41, 1.25), vec3(1.52, 1.50, 1.35), vec3(1.25, 1.21, 1.12), vec3(1.04, 0.97, 0.79), vec3(1.52, 1.45, 1.41), vec3(1.56, 1.53, 1.71), vec3(1.02, 1.04, 1.22), vec3(0.83, 0.88, 1.13), vec3(0.86, 0.92, 1.11), vec3(0.59, 0.69, 1.13), vec3(0.67, 0.78, 1.20), vec3(1.19, 1.22, 1.53), vec3(1.53, 1.48, 1.78), vec3(1.07, 1.11, 1.16), vec3(0.84, 0.83, 0.84), vec3(0.90, 0.93, 0.97),
    vec3(1.06, 0.92, 0.79), vec3(1.81, 1.64, 1.55), vec3(1.25, 1.26, 1.56), vec3(1.10, 1.17, 0.93), vec3(0.88, 0.87, 0.77), vec3(1.15, 1.10, 1.24), vec3(1.46, 1.40, 1.70), vec3(0.82, 0.85, 1.07), vec3(0.81, 0.87, 0.78), vec3(1.67, 1.61, 1.30), vec3(1.11, 1.19, 1.32), vec3(1.09, 1.20, 1.64), vec3(1.33, 1.42, 2.04), vec3(1.55, 1.55, 2.07), vec3(1.50, 1.44, 1.96), vec3(1.04, 1.12, 1.64), vec3(1.00, 1.22, 1.94),
    vec3(0.96, 0.95, 0.95), vec3(1.34, 1.33, 1.33), vec3(1.02, 1.03, 1.08), vec3(0.97, 0.97, 0.83), vec3(0.88, 0.87, 0.75), vec3(0.75, 0.70, 0.67), vec3(0.70, 0.65, 0.63), vec3(0.56, 0.58, 0.63), vec3(0.61, 0.63, 0.33), vec3(1.13, 1.17, 0.91), vec3(1.22, 1.31, 1.41), vec3(1.46, 1.51, 1.68), vec3(1.54, 1.57, 1.76), vec3(1.55, 1.57, 1.78), vec3(2.10, 1.89, 2.41), vec3(1.61, 1.59, 2.03), vec3(1.14, 1.32, 2.23),
    vec3(1.60, 1.35, 0.89), vec3(1.33, 1.23, 1.00), vec3(1.25, 1.24, 1.49), vec3(1.20, 1.17, 1.26), vec3(1.19, 1.16, 1.11), vec3(1.12, 1.10, 1.13), vec3(0.93, 0.94, 0.89), vec3(0.98, 0.97, 0.92), vec3(1.09, 1.10, 0.85), vec3(1.24, 1.27, 0.98), vec3(1.38, 1.42, 1.42), vec3(1.62, 1.62, 1.69), vec3(1.45, 1.49, 1.44), vec3(1.34, 1.36, 1.30), vec3(1.30, 1.27, 1.34), vec3(1.26, 1.20, 1.36), vec3(1.27, 1.24, 1.60),
    vec3(1.30, 1.24, 1.08), vec3(1.27, 1.21, 1.06), vec3(1.12, 1.11, 1.24), vec3(1.26, 1.25, 1.28), vec3(1.34, 1.33, 1.65), vec3(1.19, 1.20, 1.49), vec3(0.85, 0.91, 0.92), vec3(0.82, 0.88, 0.82), vec3(0.96, 1.02, 0.94), vec3(1.05, 1.14, 1.21), vec3(1.38, 1.46, 1.86), vec3(2.48, 2.23, 1.89), vec3(2.50, 2.23, 1.71), vec3(2.04, 1.87, 1.34), vec3(1.89, 1.79, 1.44), vec3(1.80, 1.69, 1.62), vec3(1.39, 1.33, 1.49),
    vec3(1.29, 1.25, 1.28), vec3(1.30, 1.27, 1.15), vec3(1.12, 1.14, 0.99), vec3(1.14, 1.17, 1.04), vec3(1.37, 1.35, 1.52), vec3(1.13, 1.16, 1.33), vec3(0.90, 0.95, 0.91), vec3(0.83, 0.89, 0.76), vec3(1.01, 1.07, 1.02), vec3(0.83, 0.94, 1.28), vec3(1.17, 1.33, 2.28), vec3(1.82, 1.84, 1.78), vec3(2.39, 2.13, 1.58), vec3(2.27, 1.95, 1.14), vec3(2.01, 1.76, 0.97), vec3(1.82, 1.66, 1.06), vec3(1.41, 1.41, 1.22),
    vec3(0.89, 0.93, 0.99), vec3(1.04, 1.04, 1.06), vec3(1.05, 1.07, 1.12), vec3(1.08, 1.12, 1.24), vec3(1.07, 1.10, 1.25), vec3(0.98, 1.02, 0.97), vec3(0.89, 0.93, 0.77), vec3(0.91, 0.95, 0.71), vec3(1.21, 1.24, 0.95), vec3(0.77, 0.87, 0.94), vec3(0.80, 0.94, 1.53), vec3(1.00, 1.13, 1.57), vec3(1.09, 1.21, 1.59), vec3(1.02, 1.11, 1.01), vec3(1.03, 1.08, 0.75), vec3(1.02, 1.02, 0.59), vec3(1.05, 1.07, 0.89),
    vec3(0.77, 0.81, 0.77), vec3(0.90, 0.94, 0.89), vec3(0.86, 0.91, 0.92), vec3(0.91, 0.95, 0.99), vec3(0.89, 0.95, 1.03), vec3(0.78, 0.83, 0.90), vec3(0.85, 0.89, 0.65), vec3(0.96, 0.99, 0.62), vec3(0.83, 0.88, 0.55), vec3(0.55, 0.64, 0.70), vec3(0.63, 0.75, 1.13), vec3(0.84, 0.93, 1.24), vec3(0.87, 0.94, 1.07), vec3(0.73, 0.80, 0.73), vec3(0.57, 0.64, 0.58), vec3(0.52, 0.62, 0.47), vec3(0.59, 0.72, 0.70),
    vec3(0.31, 0.37, 0.36), vec3(0.54, 0.60, 0.53), vec3(0.67, 0.73, 0.63), vec3(0.71, 0.77, 0.68), vec3(0.70, 0.78, 0.91), vec3(0.68, 0.77, 0.96), vec3(0.63, 0.73, 0.86), vec3(0.70, 0.79, 0.93), vec3(0.90, 0.97, 0.94), vec3(0.88, 0.95, 0.99), vec3(0.76, 0.84, 0.94), vec3(0.81, 0.89, 0.92), vec3(0.82, 0.89, 0.84), vec3(0.79, 0.86, 0.77), vec3(0.69, 0.76, 0.75), vec3(0.62, 0.69, 0.68), vec3(0.51, 0.58, 0.59),
    vec3(0.42, 0.54, 0.63), vec3(0.73, 0.80, 0.64), vec3(0.95, 0.98, 0.60), vec3(0.82, 0.87, 0.62), vec3(0.72, 0.80, 0.80), vec3(0.62, 0.71, 0.80), vec3(0.53, 0.63, 0.76), vec3(0.66, 0.75, 0.92), vec3(0.80, 0.87, 0.85), vec3(0.96, 1.00, 0.95), vec3(0.94, 0.97, 0.96), vec3(0.82, 0.83, 0.72), vec3(0.86, 0.86, 0.99), vec3(1.06, 1.08, 1.16), vec3(1.46, 1.49, 1.44), vec3(1.40, 1.39, 1.26), vec3(0.97, 1.00, 0.85),
    vec3(1.01, 1.03, 0.81), vec3(1.25, 1.21, 0.74), vec3(1.28, 1.20, 0.65), vec3(0.97, 0.94, 0.56), vec3(0.86, 0.84, 0.45), vec3(1.01, 0.98, 0.54), vec3(0.89, 0.94, 0.71), vec3(0.64, 0.71, 0.72), vec3(0.56, 0.61, 0.55), vec3(0.71, 0.77, 0.66), vec3(1.17, 1.20, 1.10), vec3(1.66, 1.57, 1.38), vec3(1.32, 1.30, 1.52), vec3(1.35, 1.31, 1.45), vec3(1.58, 1.39, 1.14), vec3(1.65, 1.55, 0.95), vec3(1.41, 1.50, 0.95),
    vec3(0.93, 0.81, 0.51), vec3(1.23, 1.12, 0.72), vec3(1.08, 1.05, 0.78), vec3(0.78, 0.79, 0.61), vec3(0.91, 0.90, 0.70), vec3(1.02, 0.94, 0.74), vec3(1.17, 1.06, 0.70), vec3(1.04, 1.02, 0.73), vec3(0.47, 0.53, 0.47), vec3(0.61, 0.66, 0.52), vec3(0.97, 1.00, 0.87), vec3(0.97, 0.97, 0.81), vec3(0.80, 0.80, 0.79), vec3(1.03, 1.02, 0.85), vec3(2.01, 1.67, 0.90), vec3(2.01, 1.77, 0.98), vec3(2.01, 2.05, 1.26),
    vec3(1.39, 1.27, 0.98), vec3(1.38, 1.17, 0.85), vec3(1.00, 0.93, 0.82), vec3(0.76, 0.72, 0.72), vec3(0.94, 0.91, 0.87), vec3(0.96, 0.93, 0.89), vec3(0.82, 0.86, 0.57), vec3(1.26, 1.21, 0.78), vec3(1.04, 1.09, 0.80), vec3(0.95, 0.93, 0.59), vec3(0.95, 0.93, 0.65), vec3(0.92, 0.93, 0.69), vec3(1.06, 1.06, 0.99), vec3(1.02, 1.02, 0.96), vec3(1.71, 1.57, 1.15), vec3(2.39, 1.96, 1.08), vec3(2.50, 2.10, 1.10),
    vec3(1.64, 1.52, 1.14), vec3(1.60, 1.44, 1.06), vec3(1.03, 0.88, 0.84), vec3(0.74, 0.63, 0.67), vec3(0.92, 0.88, 0.88), vec3(1.04, 1.01, 1.04), vec3(0.89, 0.89, 0.78), vec3(0.97, 0.92, 0.78), vec3(1.06, 0.91, 0.65), vec3(0.94, 0.78, 0.54), vec3(0.79, 0.69, 0.53), vec3(0.98, 0.86, 0.61), vec3(1.34, 1.17, 0.77), vec3(1.11, 1.02, 0.95), vec3(1.34, 1.22, 1.17), vec3(1.31, 1.21, 1.16), vec3(1.56, 1.42, 1.42)
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

const vec2 RING_A = vec2(650.0, 415.0), RING_B = vec2(502.0, 457.0), RING_C = vec2(370.0, 540.0), RING_D = vec2(184.0, 642.0);
const vec2 BURST_3 = vec2(566.0, 428.0);            // the big burst rises between rings A and B

// Ring glow and burst strength, one key per reference frame.
const float K_RA[NF] = float[NF](1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.4, 0.4, 0.5, 1.0, 1.0, 1.0);
const float K_RB[NF] = float[NF](0.9, 0.6, 0.5, 0.4, 0.3, 0.2, 0.0, 0.0, 0.0, 0.2, 0.3, 0.4);
const float K_RC[NF] = float[NF](1.0, 0.6, 0.3, 0.2, 0.0, 0.0, 0.4, 0.4, 0.5, 0.4, 0.4, 0.5);
const float K_RD[NF] = float[NF](1.0, 0.0, 0.0, 0.2, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0);
const float K_B1[NF] = float[NF](0.0, 1.0, 1.0, 0.55, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);   // at ring D
const float K_B2[NF] = float[NF](0.0, 0.0, 0.0, 0.0, 0.80, 0.85, 0.12, 0.0, 0.0, 0.0, 0.0, 0.0);  // at ring C
const float K_B3[NF] = float[NF](0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.85, 1.0, 0.30, 0.04, 0.0, 0.0);  // between A and B

const vec3 E_BLUE = vec3(0.10, 0.36, 0.95);        // linear: the saturated body of the water-light
const vec3 E_SKY = vec3(0.32, 0.62, 1.00);         // paler blue of the sheet
const vec3 E_WHITE = vec3(0.85, 0.95, 1.00);

// ---- static scene ------------------------------------------------------------------------------------------------------
// Placed from frame-12 measurements: outlines are polygons typed off tools/crop.py, tones are probed sRGB. The fitted
// light map trims the broad tone afterwards; the code here supplies the shapes and the leaf-scale structure.

// Signed distance to a closed polygon of n (<= 12) measured points, negative inside; unused slots are ignored.
float sdPoly(vec2 p, vec2 v[12], int n) {
    float d = dot2(p - v[0]), s = 1.0;
    for (int i = 0; i < 12; i++) {
        if (i >= n) break;
        int j = i == 0 ? n - 1 : i - 1;
        vec2 e = v[j] - v[i], w = p - v[i];
        vec2 b = w - e * clamp(dot(w, e) / max(dot(e, e), 1e-6), 0.0, 1.0);
        d = min(d, dot(b, b));
        bvec3 c = bvec3(p.y >= v[i].y, p.y < v[j].y, e.x * w.y > e.y * w.x);
        if (all(c) || all(not(c))) s = -s;
    }
    return s * sqrt(d);
}

// Pools of sunlight on the clearing floor, traced off the reference (luminance above ~140, frame 12).
const vec2 SUN_A1[12] = vec2[12](vec2(67.0, 303.0), vec2(200.0, 311.0), vec2(287.0, 333.0), vec2(400.0, 358.0), vec2(527.0, 393.0), vec2(515.0, 410.0),
                                 vec2(400.0, 402.0), vec2(385.0, 535.0), vec2(200.0, 535.0), vec2(193.0, 400.0), vec2(160.0, 367.0), vec2(100.0, 347.0));
const vec2 SUN_A2[12] = vec2[12](vec2(240.0, 405.0), vec2(240.0, 515.0), vec2(-60.0, 507.0), vec2(-60.0, 450.0), vec2(67.0, 447.0), vec2(160.0, 433.0),
                                 vec2(0.0), vec2(0.0), vec2(0.0), vec2(0.0), vec2(0.0), vec2(0.0));
const vec2 SUN_B[12] = vec2[12](vec2(-60.0, 505.0), vec2(385.0, 500.0), vec2(400.0, 470.0), vec2(600.0, 473.0), vec2(667.0, 500.0), vec2(880.0, 558.0),
                                vec2(880.0, 628.0), vec2(733.0, 613.0), vec2(600.0, 587.0), vec2(220.0, 598.0), vec2(40.0, 598.0), vec2(-60.0, 565.0));
const vec2 SUN_C[12] = vec2[12](vec2(227.0, 570.0), vec2(500.0, 570.0), vec2(540.0, 692.0), vec2(600.0, 708.0), vec2(667.0, 722.0), vec2(700.0, 745.0),
                                vec2(690.0, 775.0), vec2(560.0, 772.0), vec2(467.0, 745.0), vec2(400.0, 720.0), vec2(360.0, 670.0), vec2(230.0, 652.0));
const vec2 SUN_BK[12] = vec2[12](vec2(232.0, 135.0), vec2(330.0, 128.0), vec2(410.0, 140.0), vec2(430.0, 175.0), vec2(400.0, 215.0), vec2(330.0, 228.0),
                                 vec2(262.0, 215.0), vec2(235.0, 190.0), vec2(0.0), vec2(0.0), vec2(0.0), vec2(0.0));
// The big tree: trunk and the flare of its roots.
const vec2 TRUNK[12] = vec2[12](vec2(89.0, -60.0), vec2(234.0, -60.0), vec2(224.0, 100.0), vec2(220.0, 140.0), vec2(240.0, 182.0), vec2(262.0, 205.0),
                                vec2(240.0, 235.0), vec2(60.0, 235.0), vec2(48.0, 188.0), vec2(58.0, 155.0), vec2(66.0, 120.0), vec2(72.0, 60.0));
const vec2 ROOTS[12] = vec2[12](vec2(-60.0, 236.0), vec2(28.0, 214.0), vec2(48.0, 188.0), vec2(262.0, 205.0), vec2(292.0, 222.0), vec2(325.0, 234.0),
                                vec2(372.0, 246.0), vec2(330.0, 258.0), vec2(250.0, 256.0), vec2(170.0, 272.0), vec2(100.0, 268.0), vec2(-60.0, 262.0));
// Moss mound and the pale angular rock in front of it (lit face and shadowed face), lower right.
const vec2 MOUND[12] = vec2[12](vec2(480.0, 640.0), vec2(482.0, 612.0), vec2(500.0, 592.0), vec2(540.0, 578.0), vec2(600.0, 576.0), vec2(650.0, 584.0),
                                vec2(682.0, 600.0), vec2(694.0, 625.0), vec2(660.0, 662.0), vec2(600.0, 670.0), vec2(540.0, 668.0), vec2(500.0, 654.0));
const vec2 ROCK_LIT[12] = vec2[12](vec2(598.0, 658.0), vec2(612.0, 642.0), vec2(645.0, 628.0), vec2(690.0, 621.0), vec2(702.0, 624.0), vec2(688.0, 640.0),
                                   vec2(655.0, 662.0), vec2(642.0, 684.0), vec2(630.0, 700.0), vec2(605.0, 690.0), vec2(0.0), vec2(0.0));
const vec2 ROCK_DARK[12] = vec2[12](vec2(702.0, 624.0), vec2(722.0, 640.0), vec2(736.0, 664.0), vec2(732.0, 690.0), vec2(700.0, 706.0), vec2(645.0, 702.0),
                                    vec2(642.0, 684.0), vec2(655.0, 662.0), vec2(688.0, 640.0), vec2(0.0), vec2(0.0), vec2(0.0));
// Dark corners: the shaded stump at bottom left, the mossy rise at bottom right.
const vec2 CORNER_L[12] = vec2[12](vec2(-60.0, 684.0), vec2(30.0, 696.0), vec2(65.0, 706.0), vec2(95.0, 728.0), vec2(112.0, 760.0), vec2(120.0, 880.0),
                                   vec2(-60.0, 880.0), vec2(0.0), vec2(0.0), vec2(0.0), vec2(0.0), vec2(0.0));
const vec2 CORNER_R[12] = vec2[12](vec2(620.0, 880.0), vec2(655.0, 802.0), vec2(690.0, 778.0), vec2(740.0, 759.0), vec2(790.0, 754.0), vec2(880.0, 762.0),
                                   vec2(880.0, 880.0), vec2(0.0), vec2(0.0), vec2(0.0), vec2(0.0), vec2(0.0));

// Leaf-shaped soft spots, one at most per cell of a jittered grid, foreshortened (wider than tall). Coverage 0..1.
float leafSpots(vec2 P, vec2 cell, float dens, float seed) {
    vec2 id = floor(P / cell);
    vec3 h = hash32(id + vec2(seed, 2.0 * seed));
    vec2 c = (id + 0.5 + (h.xy - 0.5) * 0.3) * cell;
    vec2 q = rot2((h.z - 0.5) * 1.2) * (P - c);
    float r = min(cell.x, cell.y) * (0.16 + 0.14 * h.y);
    float d = sdEllipse(q, vec2(1.6 * r, 0.75 * r));
    return (1.0 - smoothstep(-1.2, 1.2, d)) * step(1.0 - dens, hash12(id + vec2(7.0 * seed, 3.0)));
}

// Sun on the floor, 0 (shade) .. 1 (full sun): the traced pools with leafy, lobed outlines and half-shade islands.
float sunField(vec2 P) {
    vec2 q = P + 14.0 * vec2(fbm(P * 0.018 + 3.1, 2), fbm(P * 0.018 + 8.7, 2));
    float lobe = 12.0 * fbm(q * vec2(0.040, 0.070) + 1.3, 3) + 5.0 * (voronoi(q * vec2(0.050, 0.085), 1.0).x - 0.4);   // leafy lobes
    float d = min(min(sdPoly(q, SUN_A1, 12), sdPoly(q, SUN_A2, 6)), min(sdPoly(q, SUN_B, 12), sdPoly(q, SUN_C, 12)));
    float s = 1.0 - smoothstep(-24.0, 24.0, d + lobe);                                           // wide feathered edge
    s = max(s, 0.7 * (1.0 - smoothstep(-26.0, 26.0, sdPoly(q, SUN_BK, 8) + lobe)));                 // softer sun at the back
    // the back of the clearing: dapples foreshortened into long horizontal bands
    s = max(s, 0.4 * smoothstep(0.0, 0.35, fbm(vec2(q.x * 0.010, q.y * 0.045) + 4.0, 2)) * ramp(225.0, 300.0, P.x) * ramp(130.0, 150.0, P.y) * ramp(270.0, 235.0, P.y) * ramp(600.0, 480.0, P.x));
    float isl = min(sdSegment(q, vec2(165.0, 540.0), vec2(350.0, 512.0)) - 10.0, sdEllipse(q - vec2(330.0, 632.0), vec2(28.0, 34.0)));
    return s * (1.0 - 0.38 * (1.0 - smoothstep(-8.0, 8.0, isl + lobe)));
}

// Short brushed grass blades rising from a jittered grid, bigger toward the viewer. Coverage 0..1.
float grassBlades(vec2 P) {
    float k = 0.55 + 0.75 * clamp(P.y / REF, 0.0, 1.0);
    vec2 q = P / k, cell = vec2(14.0, 10.0);
    float m = 0.0;
    for (int r = 0; r < 2; r++) {
        vec2 id = floor(q / cell) + vec2(0.0, float(r));
        vec3 h = hash32(id + 40.0);
        if (h.z < 0.45) continue;
        vec2 base = (id + vec2(0.3 + 0.4 * h.x, 0.9)) * cell;
        for (int b = 0; b < 3; b++) {
            vec3 g = hash32(id * 3.0 + vec2(float(b), 11.0));
            vec2 tip = vec2((g.x - 0.5) * 4.0 + (float(b) - 1.0) * 5.0, -(6.0 + 9.0 * g.y));
            float t = clamp(dot(q - base, tip) / dot(tip, tip), 0.0, 1.0);
            float hw = 0.3 + 1.3 * (1.0 - t);
            m = max(m, 1.0 - smoothstep(hw - 0.5, hw + 0.5, length(q - base - tip * t)));
        }
    }
    return m;
}

// A small stone: lit on top, shaded below, with a soft contact shadow.
vec3 stone(vec3 c, vec2 P, vec2 o, vec2 r, float a, vec3 lit, vec3 dark, float px) {
    vec2 q = rot2(a) * (P - o);
    if (abs(q.x) > r.x + 8.0 || abs(q.y) > r.y + 8.0) return c;
    float d = sdEllipse(q, r) + 0.10 * min(r.x, r.y) * fbm(q * 0.15 + o, 2);
    c *= 1.0 - 0.35 * (1.0 - smoothstep(0.0, 5.0, sdEllipse(q - vec2(1.5, 2.5), r)));
    vec3 sc = mix(dark, lit, 1.0 - smoothstep(-0.45, 0.35, q.y / r.y));
    return mix(c, sc, fillAA(d, px));
}

// The hazy forest behind the clearing.
vec3 forestBand(vec2 P) {
    float vx = P.x + 10.0 * fbm(vec2(P.y * 0.012, 2.0), 2);
    // left and centre: pale sunlit haze broken into bright gaps and soft vertical trunks
    float gap = smoothstep(-0.10, 0.30, fbm(vec2(vx * 0.022, P.y * 0.017) + 1.0, 3));
    vec3 c = mix(rgb(128.0, 144.0, 108.0), rgb(178.0, 194.0, 158.0), gap);
    c = mix(c, rgb(214.0, 222.0, 188.0), 0.7 * smoothstep(0.30, 0.45, fbm(P * 0.035 + 9.0, 2)) * ramp(150.0, 60.0, P.y));   // bokeh of sky through leaves
    c = mix(c, rgb(206.0, 206.0, 142.0), 0.65 * exp(-sq((P.x - 285.0) / 60.0) - sq((P.y - 112.0) / 26.0)));   // sun on the far grass
    // top left: out-of-focus foliage hanging in front of the haze, a burst of sun below it
    float fol = length((P - vec2(18.0, 38.0)) / vec2(1.0, 1.4)) - 46.0 + 16.0 * fbm(P * 0.04 + 2.0, 2);
    c = mix(c, mix(rgb(80.0, 94.0, 48.0), rgb(112.0, 124.0, 70.0), smoothstep(-0.1, 0.4, fbm(P * 0.05, 2))), 1.0 - smoothstep(-8.0, 8.0, fol));
    c = mix(c, rgb(246.0, 242.0, 205.0), 0.85 * exp(-dot2((P - vec2(30.0, 140.0)) / vec2(22.0, 16.0))));
    float tr = max(1.0 - smoothstep(6.0, 15.0, abs(vx - 376.0)), 1.0 - smoothstep(8.0, 20.0, abs(vx - 444.0)));
    tr = max(tr, 0.45 * (1.0 - smoothstep(4.0, 10.0, abs(vx - 322.0))));
    c = mix(c, rgb(108.0, 124.0, 98.0), tr * (1.0 - smoothstep(60.0, 140.0, P.y)));
    // right: cool deep shade, two big dark trunks, a few blue-grey glints of sky between leaves
    vec3 sh = rgb(57.0, 78.0, 66.0);
    sh = mix(sh, rgb(48.0, 62.0, 50.0), 1.0 - smoothstep(30.0, 46.0, abs(vx - 557.0)));
    sh = mix(sh, rgb(45.0, 55.0, 45.0), 1.0 - smoothstep(32.0, 48.0, abs(vx - 730.0)));
    sh *= 0.9 + 0.2 * smoothstep(0.1, 0.4, fbm(P * vec2(0.02, 0.03) + 6.0, 3));
    sh = mix(sh, rgb(74.0, 98.0, 92.0), 0.4 * smoothstep(0.05, 0.45, fbm(P * vec2(0.04, 0.05) + 13.0, 2)));        // blue-grey patches of light
    sh = mix(sh, rgb(68.0, 88.0, 74.0), 0.5 * smoothstep(110.0, 170.0, P.y));                                      // cool haze low down
    // the mossy rise climbing from behind the tree to the right, with a sunlit lip of moss
    float rise = P.y - (130.0 - 0.56 * (P.x - 380.0)) + 10.0 * fbm(vec2(P.x * 0.02, 4.0), 2);
    float riseM = smoothstep(-5.0, 5.0, rise) * ramp(320.0, 370.0, P.x) * ramp(600.0, 540.0, P.x);
    float dark = max(smoothstep(470.0, 530.0, vx), riseM);
    vec3 moss = mix(rgb(62.0, 76.0, 42.0), rgb(128.0, 138.0, 66.0), exp(-sq(rise - 6.0) / 30.0) * ramp(560.0, 420.0, P.x));
    return mix(c, mix(sh, moss, riseM), dark);
}

// The clearing floor: sun pools and shade, leaf dapple, flat painted patches, brushed grass.
vec3 clearing(vec2 P) {
    float s = sunField(P);
    vec2 pp = P / (0.55 + 0.75 * clamp(P.y / REF, 0.0, 1.0));                   // foreshortened: smaller toward the back
    float f1 = smoothstep(0.20, 0.45, fbm(pp * vec2(0.060, 0.100) + 11.0, 2));    // soft flecks of sun in the shade
    float f2 = smoothstep(0.20, 0.45, fbm(pp * vec2(0.065, 0.110) + 23.0, 2));    // soft leaf shadows in the sun
    s = clamp(s + 0.18 * f1 * (1.0 - s) - 0.18 * f2 * s, 0.0, 1.0);
    // across the feathered pool edges the light breaks into leaf-sized dapples on both sides
    float dap = smoothstep(-0.2, 0.2, fbm(pp * vec2(0.060, 0.095) + 41.0, 2));
    s = clamp(s + 0.45 * (dap - 0.5) * (1.0 - abs(2.0 * s - 1.0)), 0.0, 1.0);
    vec3 c = mix(mix(rgb(60.0, 72.0, 40.0), rgb(136.0, 139.0, 60.0), smoothstep(0.0, 0.5, s)), rgb(206.0, 199.0, 92.0), smoothstep(0.5, 1.0, s));
    // flat painted patches: per-cell tone and hue offsets in leaf-sized warped cells
    vec2 w = P + 7.0 * vec2(fbm(P * 0.045, 2), fbm(P * 0.045 + 4.0, 2));
    vec4 v = voronoi(w * vec2(0.05, 0.08), 0.9);
    vec3 h = hash32(v.zw + 5.0);
    c *= (0.90 + 0.20 * h.x) * mix(vec3(1.0), vec3(1.05, 1.02, 0.78), h.y * s);
    c *= 0.93 + 0.14 * fbm(rot2(0.12) * P * vec2(0.07, 0.24) + 3.0, 3);          // horizontal brush strokes
    // grass: faint blades everywhere, gathered into brighter tufts here and there
    float tuft = smoothstep(0.20, 0.42, fbm(P * vec2(0.035, 0.05) + 31.0, 2));
    float b = grassBlades(P) * (0.05 + 0.55 * tuft);
    c = mix(c, mix(rgb(96.0, 114.0, 46.0), rgb(228.0, 224.0, 140.0), s), b);
    float fw = leafSpots(pp, vec2(12.0, 9.0), 0.025, 5.0);                      // small pale flowers
    return mix(c, rgb(226.0, 222.0, 168.0), 0.8 * fw);
}

// A moss surface: fluffy dabs of light over darker hollows. t = 0 shade .. 1 light.
vec3 mossy(vec2 P, float t, vec3 dark, vec3 lit) {
    vec2 w = P + 5.0 * vec2(fbm(P * 0.05, 2), fbm(P * 0.05 + 3.0, 2));
    float dab = smoothstep(-0.25, 0.35, fbm(w * vec2(0.12, 0.15), 3));
    float dome = 1.0 - smoothstep(0.0, 0.85, voronoi(w * vec2(0.08, 0.10), 1.0).x);
    return mix(dark, lit, clamp(t * (0.40 + 0.80 * dab) * (0.80 + 0.25 * dome), 0.0, 1.0));
}

// Bark of the big tree; u runs 0 at the sunlit left edge to 1 at the shaded right edge.
vec3 bark(vec2 P) {
    float yy = clamp(P.y, -60.0, 229.0);
    float xl = profile4(yy, vec2(-60.0, 89.0), vec2(60.0, 72.0), vec2(120.0, 66.0), vec2(229.0, 30.0));
    float xr = profile4(yy, vec2(-60.0, 234.0), vec2(100.0, 224.0), vec2(150.0, 222.0), vec2(229.0, 260.0));
    float u = (P.x - xl) / max(xr - xl, 1.0);
    vec4 v = voronoi(vec2(P.x * 0.06, P.y * 0.009), 0.9);                     // long bark plates
    float plate = hash12(v.zw + 3.0);
    vec3 c = mix(rgb(86.0, 74.0, 42.0), rgb(60.0, 51.0, 33.0), smoothstep(0.12, 0.5, u + 0.12 * (plate - 0.5)));
    c = mix(c, rgb(54.0, 68.0, 54.0), smoothstep(0.82, 0.96, u));             // cool reflected light on the right
    float rim = (1.0 - smoothstep(0.07, 0.17, u + 0.08 * fbm(vec2(P.x * 0.05, P.y * 0.03), 2))) * smoothstep(-0.50, -0.30, fbm(vec2(P.x * 0.04, P.y * 0.02) + 5.0, 2));
    c = mix(c, rgb(238.0, 210.0, 140.0), rim);                                // warm sun on the left edge
    c *= 0.92 + 0.16 * plate;
    float ridge = abs(fbm(vec2(P.x * 0.045, P.y * 0.006) + 2.0, 3));          // long meandering ridges down the bark
    c *= 0.6 + 0.4 * smoothstep(0.0, 0.06, ridge);
    c = mix(c, rgb(50.0, 55.0, 34.0), 0.6 * smoothstep(140.0, 210.0, P.y) * smoothstep(0.2, 0.4, u));   // the shaded, greening base
    return c * mix(1.0, 0.8, smoothstep(150.0, 225.0, P.y));
}

vec3 tree(vec3 c, vec2 P, float px) {
    // branch on the left, crossing in front of the trunk; branch and leaves on the right
    float dbl = polyline(P, vec2(8.0, -48.0), vec2(32.0, -5.0), vec2(60.0, 44.0), vec2(100.0, 74.0), vec2(114.0, 84.0), vec2(0.0), 5) - 2.5 - 0.03 * max(P.y, 0.0);
    dbl = min(dbl, sdSegment(P, vec2(-50.0, 62.0), vec2(48.0, 44.0)) - 2.0);
    float dbr = polyline(P, vec2(214.0, 66.0), vec2(250.0, 10.0), vec2(258.0, -5.0), vec2(276.0, -50.0), vec2(0.0), vec2(0.0), 4) - 6.0;
    dbr = min(dbr, polyline(P, vec2(246.0, 20.0), vec2(275.0, 12.0), vec2(305.0, 14.0), vec2(0.0), vec2(0.0), vec2(0.0), 3) - 2.0);
    float lv = leafSpots(P + vec2(3.0, 0.0), vec2(20.0, 15.0), 1.0, 9.0) * (1.0 - smoothstep(22.0, 40.0, length((P - vec2(295.0, 15.0)) / vec2(1.7, 1.0))));
    lv = max(lv, leafSpots(P + vec2(10.0, 7.0), vec2(20.0, 15.0), 0.9, 13.0) * (1.0 - smoothstep(18.0, 34.0, length((P - vec2(300.0, 18.0)) / vec2(1.7, 1.0)))));
    lv = max(lv, leafSpots(P, vec2(15.0, 12.0), 0.7, 11.0) * (1.0 - smoothstep(15.0, 35.0, length((P - vec2(20.0, 10.0)) / vec2(1.4, 1.0)))));
    c = mix(c, rgb(55.0, 70.0, 42.0), lv);
    c = mix(c, rgb(52.0, 57.0, 37.0), fillAA(dbr, px));
    // trunk and root flare
    float wob = 3.0 * fbm(P * vec2(0.02, 0.05) + 1.7, 2);
    float dT = min(sdPoly(P, TRUNK, 12), sdPoly(P, ROOTS, 12)) + wob;
    if (dT < 2.0) {
        vec3 b = bark(P);
        // moss on the lower left of the trunk and over the roots: bright where the sun reaches it
        float mn = fbm(P * vec2(0.035, 0.022) + 2.3, 2);
        float moss = smoothstep(-0.05, 0.10, 0.5 * mn + 0.9 * ramp(125.0, 200.0, P.y + 0.6 * (P.x - 60.0)) * ramp(170.0, 90.0, P.x) + 0.6 * ramp(205.0, 240.0, P.y) * ramp(200.0, 120.0, P.x) - 0.55);
        float mlit = clamp(ramp(115.0, 45.0, P.x) * ramp(225.0, 170.0, P.y) + 0.45 * ramp(190.0, 230.0, P.y) * ramp(170.0, 90.0, P.x) + 0.4 * fbm(P * 0.03 + 7.0, 2), 0.0, 1.0);
        vec3 mc = mossy(P, mlit, rgb(56.0, 60.0, 22.0), rgb(176.0, 172.0, 56.0));
        float dab = smoothstep(0.0, 0.4, fbm(P * vec2(0.12, 0.15) + 17.0, 3));
        mc = mix(mc, rgb(238.0, 230.0, 112.0), 0.9 * ramp(105.0, 55.0, P.x) * ramp(240.0, 195.0, P.y) * dab);   // sun on the moss at the lit edge
        b = mix(b, mc, moss);
        b = mix(b, rgb(40.0, 43.0, 23.0), 0.6 * ramp(225.0, 265.0, P.y) * (1.0 - moss));    // roots sink into shadow
        c = mix(c, b, fillAA(dT, px * 1.5));
    }
    c = mix(c, mix(rgb(58.0, 49.0, 32.0), rgb(110.0, 92.0, 54.0), ramp(60.0, 20.0, P.x)), fillAA(dbl, px));
    return c;
}

vec3 landmarks(vec3 c, vec2 P, float px) {
    // left: blue-grey boulder at the edge, bright mossy bump, flat pale rock, pebbles
    c = stone(c, P, vec2(22.0, 328.0), vec2(46.0, 24.0), 0.12, rgb(86.0, 108.0, 88.0), rgb(48.0, 64.0, 48.0), px);
    float db = sdEllipse(P - vec2(34.0, 403.0), vec2(52.0, 28.0)) + 4.0 * fbm(P * 0.08, 2);
    if (db < 6.0) {
        vec3 mc = mossy(P, ramp(425.0, 382.0, P.y + 0.3 * (P.x - 30.0)), rgb(78.0, 88.0, 34.0), rgb(214.0, 206.0, 84.0));
        c = mix(c * 0.7, c, smoothstep(0.0, 6.0, db));
        c = mix(c, mc, fillAA(db, px * 2.0));
    }
    c = stone(c, P, vec2(180.0, 394.0), vec2(56.0, 15.0), -0.08, rgb(182.0, 166.0, 114.0), rgb(92.0, 100.0, 78.0), px);
    c = stone(c, P, vec2(232.0, 403.0), vec2(12.0, 6.0), 0.0, rgb(222.0, 212.0, 176.0), rgb(150.0, 140.0, 110.0), px);
    c = stone(c, P, vec2(88.0, 418.0), vec2(9.0, 6.0), 0.2, rgb(200.0, 196.0, 170.0), rgb(110.0, 116.0, 96.0), px);
    c = stone(c, P, vec2(162.0, 311.0), vec2(12.0, 5.0), -0.2, rgb(220.0, 196.0, 170.0), rgb(140.0, 130.0, 110.0), px);
    c = stone(c, P, vec2(325.0, 768.0), vec2(20.0, 11.0), 0.15, rgb(180.0, 186.0, 168.0), rgb(90.0, 100.0, 84.0), px);
    // fallen red-brown leaves (measured patches)
    float lf = min(min(sdEllipse(rot2(0.1) * (P - vec2(340.0, 690.0)), vec2(28.0, 6.0)), sdEllipse(rot2(-0.25) * (P - vec2(405.0, 755.0)), vec2(32.0, 8.0))),
                   sdEllipse(rot2(-0.1) * (P - vec2(218.0, 405.0)), vec2(17.0, 3.0)));
    c = mix(c, rgb(110.0, 70.0, 40.0), 0.75 * fillAA(lf + 2.0 * fbm(P * 0.2, 2), px * 2.0));
    // moss banks: the lit cushions in front of the mound and along the right edge (a tone modulation of the floor)
    float bank = 1.0 - smoothstep(-10.0, 10.0, min(sdEllipse(P - vec2(560.0, 735.0), vec2(150.0, 38.0)), sdEllipse(P - vec2(770.0, 625.0), vec2(80.0, 28.0))) + 10.0 * fbm(P * 0.04, 2));
    c *= mix(vec3(1.0), mossy(P, 0.7, vec3(0.70, 0.74, 0.62), vec3(1.18, 1.16, 1.05)), bank);
    // moss mound, lower right: a heap of round cushions lit from above, dark underside, cast shadow on the grass
    float dm0 = sdPoly(P, MOUND, 12);
    if (dm0 < 40.0) {
        vec2 w = P + 4.0 * vec2(fbm(P * 0.06, 2), fbm(P * 0.06 + 5.0, 2));
        vec3 cu = voronoiBorder(w * vec2(0.042, 0.058), 1.0);                 // x: border distance, yz: to the cushion's centre (cell units)
        float dm = dm0 + 5.0 * fbm(P * 0.09, 3) - 6.0 * smoothstep(0.0, 0.2, cu.x);   // cushions bulge the outline
        c *= 1.0 - 0.45 * (1.0 - smoothstep(-4.0, 14.0, sdPoly(P - vec2(-4.0, 10.0), MOUND, 12))) * step(-2.0, dm);   // cast shadow below
        if (dm < 6.0) {
            float top = ramp(668.0, 586.0, P.y + 0.25 * (P.x - 560.0));       // the heap is lit on top
            float bulge = smoothstep(-0.35, 0.35, cu.z);                       // each cushion lit on its upper side
            float crev = smoothstep(0.0, 0.30, cu.x);
            float under = ramp(0.0, -16.0, dm) * 0.6 + 0.4;                   // darker round the lower rim
            float t = (0.1 + 1.1 * top) * (0.55 + 0.55 * bulge) * (0.75 + 0.25 * crev) * mix(under, 1.0, top);
            vec3 mc = mossy(P, 1.2 * t, rgb(40.0, 50.0, 16.0), rgb(212.0, 206.0, 76.0));
            c = mix(c, mc, fillAA(dm, px * 2.0));
        }
    }
    // the pale angular rock: lit face, shadowed face, crisp ridge between them, a pale lip along the top
    float dl = sdPoly(P, ROCK_LIT, 10), dd = sdPoly(P, ROCK_DARK, 9), dr = min(dl, dd);
    if (dr < 10.0) {
        c *= 1.0 - 0.45 * (1.0 - smoothstep(0.0, 9.0, sdPoly(P - vec2(4.0, 6.0), ROCK_DARK, 9)));
        vec3 lc = mix(rgb(214.0, 197.0, 140.0), rgb(168.0, 152.0, 104.0), ramp(640.0, 700.0, P.y));
        lc *= 0.93 + 0.14 * smoothstep(-0.3, 0.3, fbm(P * vec2(0.08, 0.14), 2));                  // weathered surface
        lc *= 1.0 - 0.25 * (1.0 - smoothstep(0.0, 1.5, sdSegment(P, vec2(652.0, 652.0), vec2(628.0, 696.0))));   // a crease down the lit face
        vec3 dc = mix(rgb(84.0, 92.0, 62.0), rgb(58.0, 68.0, 44.0), ramp(640.0, 700.0, P.y)) * (0.92 + 0.16 * fbm(P * 0.1, 2));
        vec3 rc = dl < dd ? lc : dc;
        rc = mix(rc, rgb(238.0, 228.0, 186.0), 0.7 * (1.0 - smoothstep(0.0, 2.5, abs(sdSegment(P, vec2(612.0, 642.0), vec2(700.0, 622.0))))));
        rc *= 1.0 - 0.35 * (1.0 - smoothstep(0.0, 1.4, abs(dl - dd)));
        c = mix(c, rc, fillAA(dr, px));
    }
    c = stone(c, P, vec2(505.0, 640.0), vec2(10.0, 7.0), 0.1, rgb(196.0, 188.0, 160.0), rgb(100.0, 104.0, 86.0), px);
    c = stone(c, P, vec2(563.0, 655.0), vec2(15.0, 9.0), -0.2, rgb(196.0, 188.0, 160.0), rgb(100.0, 104.0, 86.0), px);
    c = stone(c, P, vec2(585.0, 683.0), vec2(13.0, 8.0), 0.1, rgb(196.0, 188.0, 160.0), rgb(100.0, 104.0, 86.0), px);
    c = stone(c, P, vec2(562.0, 697.0), vec2(14.0, 8.0), 0.0, rgb(196.0, 188.0, 160.0), rgb(100.0, 104.0, 86.0), px);
    c = stone(c, P, vec2(617.0, 703.0), vec2(11.0, 5.0), 0.1, rgb(214.0, 208.0, 186.0), rgb(120.0, 120.0, 100.0), px);
    c = stone(c, P, vec2(643.0, 708.0), vec2(7.0, 5.0), 0.0, rgb(214.0, 208.0, 186.0), rgb(120.0, 120.0, 100.0), px);
    // red-brown boulder at the right edge
    c = stone(c, P, vec2(812.0, 688.0), vec2(42.0, 33.0), 0.0, rgb(150.0, 118.0, 66.0), rgb(92.0, 72.0, 44.0), px);
    // dark corners: shaded stump bottom left, mossy rise bottom right with a faint lit lip
    float dcl = sdPoly(P, CORNER_L, 7) + 5.0 * fbm(P * 0.04, 2);
    c = mix(c, mix(rgb(34.0, 42.0, 30.0), rgb(26.0, 34.0, 28.0), ramp(700.0, 816.0, P.y)), fillAA(dcl, px * 3.0));
    float dcr = sdPoly(P, CORNER_R, 7) + 4.0 * fbm(P * 0.05, 2);
    if (dcr < 6.0) {
        vec3 mc = mossy(P, 0.35 * (1.0 - smoothstep(0.0, 14.0, -dcr)), rgb(48.0, 54.0, 36.0), rgb(110.0, 114.0, 62.0));
        c = mix(c, mc, fillAA(dcr, px * 2.0));
    }
    return c;
}

// A small plant: seven leaves fanning up from its base, each lit on one half of its midrib. Coverage; t = tone 0..1.
// soft = edge blur in px (out of focus in the haze).
float plant(vec2 P, vec2 base, float size, float seed, float soft, out float t) {
    float m = 0.0;
    t = 0.0;
    if (dot2(P - base - vec2(0.0, -0.5 * size)) > size * size) return 0.0;
    for (int k = 0; k < 7; k++) {
        vec3 h = hash32(vec2(float(k), seed));
        float a = (float(k) - 3.0) * 0.36 + (h.x - 0.5) * 0.3;                         // 0 = straight up
        vec2 dir = vec2(sin(a), -cos(a));
        float L = size * (0.55 + 0.45 * h.y) * (1.0 - 0.10 * abs(float(k) - 3.0));
        vec2 q = P - base - dir * L * 0.55;
        q = vec2(dot(q, vec2(-dir.y, dir.x)), dot(q, dir));
        float cov = 1.0 - smoothstep(-soft, soft, sdEllipse(q, vec2(0.15 * L, 0.47 * L)));
        if (cov > m) { m = cov; t = 0.35 * h.z + 0.65 * step(0.0, q.x); }
    }
    return m;
}

// Plants at measured spots: pale ones in the haze left of the tree, dark ones on the sunlit back edge, one at right.
vec3 plants(vec3 c, vec2 P) {
    float t, m;
    m = plant(P, vec2(22.0, 222.0), 58.0, 1.0, 5.0, t);
    c = mix(c, mix(rgb(118.0, 136.0, 88.0), rgb(176.0, 190.0, 136.0), t), 0.8 * m);
    m = plant(P, vec2(40.0, 170.0), 40.0, 2.0, 5.0, t);
    c = mix(c, mix(rgb(124.0, 142.0, 96.0), rgb(190.0, 200.0, 150.0), t), 0.8 * m);
    m = plant(P, vec2(282.0, 202.0), 46.0, 3.0, 1.2, t);
    c = mix(c, mix(rgb(40.0, 52.0, 30.0), rgb(70.0, 88.0, 44.0), t), m);
    m = plant(P, vec2(305.0, 204.0), 26.0, 4.0, 1.2, t);
    c = mix(c, mix(rgb(40.0, 52.0, 30.0), rgb(70.0, 88.0, 44.0), t), m);
    m = plant(P, vec2(40.0, 302.0), 34.0, 5.0, 1.5, t);
    c = mix(c, mix(rgb(70.0, 90.0, 44.0), rgb(150.0, 165.0, 90.0), t), m);
    m = plant(P, vec2(130.0, 302.0), 28.0, 6.0, 1.5, t);
    c = mix(c, mix(rgb(70.0, 90.0, 44.0), rgb(150.0, 165.0, 90.0), t), m);
    m = plant(P, vec2(780.0, 645.0), 56.0, 7.0, 1.0, t);
    c = mix(c, mix(rgb(52.0, 68.0, 34.0), rgb(120.0, 140.0, 70.0), t), m);
    // grass tufts in the clearing (measured): a pale one in the sun at left, a dark fern below it, one by the rock
    m = plant(P, vec2(57.0, 462.0), 32.0, 8.0, 0.8, t);
    c = mix(c, mix(rgb(170.0, 178.0, 80.0), rgb(236.0, 232.0, 150.0), t), 0.85 * m);
    m = plant(P, vec2(35.0, 582.0), 34.0, 9.0, 0.8, t);
    c = mix(c, mix(rgb(40.0, 54.0, 26.0), rgb(78.0, 96.0, 40.0), t), m);
    m = plant(P, vec2(530.0, 700.0), 30.0, 10.0, 0.8, t);
    c = mix(c, mix(rgb(110.0, 130.0, 60.0), rgb(200.0, 210.0, 140.0), t), 0.85 * m);
    return c;
}

vec3 background(vec2 P, float px) {
    vec3 c = forestBand(P);
    // where the floor begins: behind the plants left of the tree, then the back edge of the clearing
    float hz = P.x < 230.0 ? profile4(max(P.x, -60.0), vec2(-60.0, 225.0), vec2(60.0, 200.0), vec2(150.0, 165.0), vec2(230.0, 135.0))
                           : profile4(min(P.x, 880.0), vec2(230.0, 135.0), vec2(500.0, 140.0), vec2(650.0, 172.0), vec2(880.0, 197.0));
    float fl = smoothstep(hz - 22.0, hz + 22.0, P.y + 8.0 * fbm(vec2(P.x * 0.03, 1.3), 2));
    if (fl > 0.0) c = mix(c, clearing(P), fl);
    c = landmarks(c, P, px);
    c = plants(c, P);
    // the tree is painted in measured tones and kept out of the light-map fit (meta.json box)
    return tree(c * lightMap(P), P, px);
}

// ---- energy ------------------------------------------------------------------------------------------------------------
// A glowing ring lying on the grass: thin blue strip with a pale hairline, dashes streaming round it.
vec3 groundRing(vec2 P, vec2 c, vec2 r, float I, float seed, float T) {
    if (I < 0.01) return vec3(0.0);
    vec2 q = (P - c) / r;
    float d = length(q), ang = atan(q.y, q.x + 1e-6);
    if (d > 1.6) return vec3(0.0);
    float wob = 0.03 * fbm(vec2(cos(ang), sin(ang)) * 1.5 + seed + T * 1.5, 2);
    float dp = (d - 1.0 - wob) / (length(q / r) / max(d, 1e-3));                     // px from the ring line
    float body = exp(-dp * dp / 5.0), spine = exp(-dp * dp / 0.8);
    float p = strands(vec2(ang * r.x, dp), 2.2, 12.0, 160.0, seed, T);
    vec3 strip = E_BLUE * 1.1 * body + E_WHITE * 0.35 * spine;
    vec3 dust = (E_SKY * 1.2 + E_WHITE * 0.3) * exp(-dp * dp / 12.0) * p;
    // the halo and the wash inside are kept faint: on shaded grass a wider blue reads as a slab of blue shadow
    return (strip + dust * PARTICLES + E_BLUE * 0.07 * exp(-abs(dp) / 8.0) + E_BLUE * 0.015 * (1.0 - smoothstep(0.7, 1.0, d))) * I;
}

// Water is not light. It is a pale translucent body laid over the scene: thin where you see through it, deeper
// blue where it is thick, white foam at its edges and tips, and thin bright glints running along the flow.
vec3 water(vec3 col, float body, float thick, float foam, float glint) {
    vec3 tint = mix(rgb(176.0, 218.0, 244.0), rgb(86.0, 150.0, 222.0), clamp(thick, 0.0, 1.0));
    col = mix(col, tint, body * (0.62 + 0.30 * clamp(thick, 0.0, 1.0)));
    col = mix(col, rgb(240.0, 248.0, 255.0), body * clamp(foam, 0.0, 1.0) * 0.9);
    return col + (E_WHITE * glint * 0.6 + E_SKY * 0.22) * body;          // glints, and the glow of sunlit water
}

// A geyser of water. Each jet is a stream of water thrown from `base` over a short spell starting at t0: every bit
// of it flies its own ballistic path, so the stream rises, bends outward, curls over and falls back, and the root
// lets go once the throwing stops. tp is the time to the top; H the height it reaches. Froth at the root, spray
// above, ripples on the grass.
vec3 geyser(vec3 col, vec2 P, vec2 base, float H, float I, float t0, float tp, float seed, float T) {
    float age = T - t0;
    if (I < 0.01 && (age < 0.0 || age > 3.0 * tp + 0.3)) return col;
    vec2 p = P - base;
    float up = -p.y;
    float r = length(p * vec2(1.0, 0.72)), a = atan(p.x, up + 1e-6);                  // a = 0 straight up
    // ripples on the grass round the base (wet highlights, drawn first so the water covers them)
    vec2 q = p / vec2(1.0, 0.36);
    float rl = length(q) + 6.0 * fbm(P * 0.03 + seed, 2);
    float rip = smoothstep(0.75, 1.0, sin(rl * 0.11 - T * 16.0)) * ramp(0.75 * H, 0.2 * H, rl) * smoothstep(0.0, 0.1 * H, rl);
    col += (E_SKY * 0.6 + E_WHITE * 0.4) * rip * 0.7 * I;
    if (up > -30.0 && r < 1.5 * H) {
        // the splash itself: two overlapping fans of thick tongues, wide at the sides (the crown), tall in the
        // middle. They are not fixed spikes: as the burst ages every tongue leans further out and droops.
        float droop = clamp(age / (2.5 * tp), 0.0, 1.0);
        float ab = atan(p.x * (1.0 - 0.35 * droop * r / H), up + 0.55 * droop * r * r / H + 1e-6);
        for (int k = 0; k < 2; k++) {
            float fk = float(k);
            float lanes = 3.4 + 2.6 * fk, sd = seed * 3.7 + 1.9 * fk;
            float la = ab * lanes + sd + 0.10 * sin(r * 0.03 - T * 6.0 + fk);
            float id = floor(la), f = la - id - 0.5;
            float ac = (id + 0.5 - sd) / lanes;
            float hgt = mix(0.55, 1.0, 1.0 - smoothstep(0.30, 1.50, abs(ac)));
            float len = H * hgt * (0.50 + 0.50 * hash11(id + seed * 13.0 + 7.0 * fk)) * (1.0 - 0.28 * fk) * I;
            float rr = r / max(len, 1.0);
            float wv = 0.52 * pow(max(1.0 - rr, 0.0), 0.50) * smoothstep(0.0, 0.10, rr + 0.04);
            float tornTip = smoothstep(-0.1, 0.15, fbm(vec2(la * 3.0, r * 0.03 - T * 5.0), 2) + 0.6 - 0.8 * rr);   // tips break into beads
            float body = (1.0 - smoothstep(wv - 0.12, wv, abs(f))) * step(rr, 1.0) * tornTip;
            float thick = (1.0 - abs(f) / max(wv, 0.02)) * (1.0 - rr);
            float foam = smoothstep(0.60, 1.0, rr) + 0.8 * smoothstep(0.50, 0.95, abs(f) / max(wv, 0.02)) + (1.0 - smoothstep(0.10, 0.45, rr));
            float glint = smoothstep(0.28, 0.46, fbm(vec2(la * 7.0, r * 0.016 - T * 5.0), 2) + 0.25) * (1.0 - smoothstep(0.5, 0.9, rr));
            col = water(col, body, thick, foam, glint);
        }
        // and a few long streams thrown clear of it, each bit of water on its own ballistic path: they rise, curl
        // over and fall back to the grass
        float v = 2.0 * H / tp, g = 2.0 * H / (tp * tp), spell = 1.5 * tp;
        if (age > 0.0) {
            for (int j = 0; j < 6; j++) {
                vec3 h = hash32(vec2(float(j), seed * 11.0));
                float th = (h.x - 0.5) * 2.5;                                           // launch heading, 0 = straight up
                float sp = (0.55 + 0.45 * h.y) * mix(1.0, 0.62, smoothstep(0.5, 1.3, abs(th)));
                vec2 vel = v * sp * vec2(0.62 * sin(th), -cos(th));
                float land = 2.0 * sp * cos(th) * v / g;                                // when this stream's water comes down
                float tauA = max(age - spell, 0.0), tauB = min(age, land);
                if (tauB <= tauA) continue;
                float best = 1e9, bu = 0.0;
                vec2 prev = base + vel * tauA + vec2(0.0, 0.5 * g * tauA * tauA);
                for (int k = 1; k <= 14; k++) {
                    float u = float(k) / 14.0, tau = mix(tauA, tauB, u);
                    vec2 pt = base + vel * tau + vec2(0.0, 0.5 * g * tau * tau);
                    vec2 pa = P - prev, ba = pt - prev;
                    float hh = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
                    float dd = length(pa - ba * hh);
                    if (dd < best) { best = dd; bu = (float(k - 1) + hh) / 9.0; }
                    prev = pt;
                }
                // thick where it has just left the root, thinning to a foaming, breaking head
                bu *= 9.0 / 14.0;
                float w = H * (0.022 + 0.026 * h.z) * (1.0 - 0.70 * bu) * smoothstep(0.0, 0.06, bu + 0.03);
                float breakup = smoothstep(-0.10, 0.15, fbm(vec2(bu * 9.0 - T * 6.0, float(j) * 3.0), 2) + 0.60 - 0.75 * bu);
                float body = (1.0 - smoothstep(w - 2.0, w, best)) * breakup;
                float thick = (1.0 - best / max(w, 1.0)) * (1.0 - bu);
                float foam = smoothstep(0.55, 1.0, bu) + 0.8 * smoothstep(0.5, 0.95, best / max(w, 1.0));
                float glint = smoothstep(0.30, 0.46, fbm(vec2(float(j) * 5.0 + best * 0.3, bu * 6.0 - T * 5.0), 2) + 0.26);
                col = water(col, body, thick, foam, glint);
            }
        }
        // a white boiling mass at the root rising into the column, a soft glow round it, fine spray over the crown
        float froth = exp(-r * r / (0.045 * H * H)) + 0.8 * exp(-sq(p.x) / (0.012 * H * H) - sq(max(up, 0.0)) / (0.16 * H * H));
        col = mix(col, rgb(242.0, 249.0, 255.0), min(froth, 1.0) * 0.9 * smoothstep(0.0, 0.3, I));
        col += E_SKY * 0.30 * exp(-r / (0.45 * H)) * I;
        float mist = exp(-r / (0.55 * H)) * (1.0 - smoothstep(0.4, 1.4, abs(a)));
        col += E_WHITE * mist * (0.10 + 0.9 * PARTICLES * motes(P + vec2(0.0, T * 220.0), 6.0, seed + 3.0, T)) * 0.35 * I;
    }
    return col;
}

// The curved sheet of water a burst throws up and to the right: a wide tearing crescent for the big burst, a thin
// rope for the small ones. t runs 0..1 up from the base; wk scales its width.
vec3 sheet(vec3 col, vec2 P, vec2 base, float size, float wk, float I, float seed, float T) {
    if (I < 0.01) return col;
    vec2 q = (P - base) / size;
    float t = -q.y;
    if (t < -0.02 || t > 1.25) return col;
    float tc = clamp(t, 0.0, 1.25);
    float xc = 0.005 + 0.04 * tc + 0.42 * tc * tc + 0.012 * sin(tc * 9.0 + T * 7.0);
    float hw = wk * (0.040 + 0.055 * tc + 0.12 * tc * tc) * (1.0 - 0.5 * smoothstep(0.95, 1.25, tc)) + 0.004;
    float x = (q.x - xc) / hw;                                                         // -1..1 across the sheet
    float ax = abs(x);
    // the sheet tears into holes and ragged edges as it thins toward the top
    float tear = smoothstep(-0.05, 0.20, fbm(vec2(x * 2.6 + seed, tc * 6.0 - T * 2.5), 3) + 0.62 - 0.50 * tc * tc * (0.3 + ax));
    float edge = 0.86 + 0.14 * fbm(vec2(tc * 14.0 - T * 4.0, seed + sign(x) * 3.0), 2);    // ragged outline
    float body = (1.0 - smoothstep(edge - 0.10, edge, ax)) * mix(1.0, tear, smoothstep(0.02, 0.10, hw)) * smoothstep(-0.02, 0.05, t) * I;
    float thick = (1.0 - ax) * (1.0 - 0.5 * tc);
    float foam = smoothstep(0.55, 0.92, ax) + smoothstep(0.85, 1.2, tc) + (1.0 - smoothstep(0.02, 0.06, hw));
    float glint = smoothstep(0.26, 0.44, fbm(vec2(x * 9.0 + seed, tc * 2.4 - T * 2.2), 2) + 0.24);  // long streaks down the flow
    col = water(col, body, thick, foam, glint);
    // beads breaking off the edges
    float fringe = exp(-max(ax - 1.0, 0.0) * hw * size / 16.0) * step(1.0, ax) * smoothstep(0.05, 0.2, t) * I;
    col = mix(col, rgb(214.0, 236.0, 252.0), 0.8 * fringe * PARTICLES * 2.0 * min(motes(P + vec2(-T * 60.0, T * 260.0), 9.0, seed + 11.0, T), 1.0));
    return col;
}

// Droplets and torn leaf specks thrown out by a burst at time t0: ballistic, each its own, they fall back and lie.
vec3 droplets(vec3 col, vec2 P, vec2 base, float t0, float power, float seed, float T, float px) {
    float age0 = T - t0;
    if (age0 < 0.0) return col;
    for (int i = 0; i < 180; i++) {
        float fi = float(i);
        vec3 h = hash32(vec2(fi, seed)), g = hash32(vec2(fi, seed + 7.0));
        float age = age0 - 0.14 * g.z;                                                  // thrown all through the burst
        if (age < 0.0) continue;
        float a = -1.5708 + (h.x - 0.5) * 3.3;                                          // a wide fan, some nearly flat
        float v = power * (500.0 + 1900.0 * h.y * h.y);
        vec2 c = base + vec2(cos(a), sin(a)) * v * (1.0 - exp(-3.0 * age)) / 3.0 + vec2(0.0, 1500.0 * age * age);
        float groundY = base.y - 30.0 + 120.0 * g.x;
        float landed = step(groundY, c.y);
        c.y = min(c.y, groundY);
        float life = 1.0 - smoothstep(0.55, 0.95, age) * mix(1.0, 0.55, landed);
        float dark = step(0.80, g.y);                                                   // a share are leaf and soil specks
        float s = (1.4 + 4.6 * g.x * g.x * g.x + 1.2 * step(0.9, h.z)) * (1.0 - 0.4 * landed);      // mostly fine, a few fat beads
        // a teardrop: stretched back along the path it has just covered (same trajectory, a moment earlier)
        float ag2 = max(age - 0.010, 0.0);
        vec2 c2 = base + vec2(cos(a), sin(a)) * v * (1.0 - exp(-3.0 * ag2)) / 3.0 + vec2(0.0, 1500.0 * ag2 * ag2);
        c2 = mix(vec2(c2.x, min(c2.y, groundY)), c, landed);
        c2 = c + (c2 - c) * min(1.0, 14.0 / max(length(c2 - c), 1e-3));                 // a bead with a short tail, never a stick
        vec2 lo = min(c, c2) - (s + 1.0), hi = max(c, c2) + (s + 1.0);
        if (P.x < lo.x || P.y < lo.y || P.x > hi.x || P.y > hi.y) continue;
        float d = sdSegment(P, c, c2);
        float m = (1.0 - smoothstep(s - 1.0, s, d)) * life;
        col = mix(col, rgb(40.0, 46.0, 26.0), dark * m * 0.85);
        // a bead of water: pale blue body, darker rim, a white catch-light on its upper left
        col = mix(col, mix(rgb(120.0, 176.0, 226.0), rgb(206.0, 232.0, 250.0), 1.0 - smoothstep(0.0, s, d + 1.0)), m * 0.85 * (1.0 - dark));
        col += E_WHITE * 0.8 * exp(-dot2(P - c + vec2(0.35, 0.35) * s) / (0.12 * s * s)) * life * (1.0 - dark);
    }
    return col;
}

// A string of beads flung up and over on one arc: what a thin jet becomes once it breaks up. It stands where the
// reference has a thin arcing streak, without ever being a solid line.
vec3 beadArc(vec3 col, vec2 P, vec2 base, float t0, vec2 reach, float tp, float seed, float T) {
    vec2 vel = vec2(reach.x / tp, -2.0 * reach.y / tp);
    float g = 2.0 * reach.y / (tp * tp);
    for (int i = 0; i < 22; i++) {
        float fi = float(i);
        vec3 h = hash32(vec2(fi, seed));
        float age = T - t0 - 0.010 * fi;                                // launched one after another
        if (age < 0.0 || age > 2.4 * tp) continue;
        vec2 c = base + (vel * (0.92 + 0.16 * h.x)) * age + vec2(0.0, 0.5 * g * age * age) + (h.yz - 0.5) * 7.0;
        float s = (2.6 - 0.08 * fi) * (0.7 + 0.6 * h.y);
        float d = length(P - c);
        if (d > 12.0) continue;
        float life = 1.0 - smoothstep(1.5 * tp, 2.4 * tp, age);
        float m = (1.0 - smoothstep(s - 1.0, s, d)) * life;
        col = mix(col, mix(rgb(120.0, 176.0, 226.0), rgb(206.0, 232.0, 250.0), 1.0 - smoothstep(0.0, s, d + 1.0)), m * 0.85);
        col += E_WHITE * 0.8 * exp(-dot2(P - c + vec2(0.35, 0.35) * s) / (0.12 * s * s)) * life;
    }
    return col;
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
    float b1 = clamp(key(K_B1, T), 0.0, 1.0) * (0.88 + 0.24 * flick(T, 6.0, 1.0));
    float b2 = clamp(key(K_B2, T), 0.0, 1.0) * (0.88 + 0.24 * flick(T, 7.0, 2.0));
    float b3 = clamp(key(K_B3, T), 0.0, 1.0) * (0.88 + 0.24 * flick(T, 5.0, 3.0));

    // camera shake scaled by the bursts (the big one hits hardest), and line boil. Before anything reads P.
    const vec2 PIVOT = vec2(0.5 * REF);
    float kick = max(max(0.55 * b1, 0.45 * b2), b3);
    P += jitter2(T, 18.0, 5.0) * (0.8 + SHAKE * 13.0 * kick) + jitter2(T, 7.0, 6.0) * (1.2 + SHAKE * 10.0 * kick);
    P = PIVOT + rot2(0.020 * SHAKE * kick * jitter2(T, 11.0, 7.0).x) * (P - PIVOT);
    float boilSeed = floor(T * 12.0) * 3.7;
    P += 1.3 * vec2(fbm(P * 0.03 + boilSeed, 2), fbm(P * 0.03 + 7.0 + boilSeed, 2));

    // 1. static scene
    vec3 col = background(P, px);

    // 2. blue light each burst spills on the grass round its base
    float onGround = smoothstep(200.0, 250.0, P.y);
    col += E_BLUE * onGround * (0.30 * b1 * exp(-length((P - RING_D) / vec2(1.0, 0.45)) / 130.0)
                              + 0.25 * b2 * exp(-length((P - RING_C) / vec2(1.0, 0.45)) / 110.0)
                              + 0.45 * b3 * exp(-length((P - BURST_3) / vec2(1.0, 0.45)) / 190.0));

    // 3. rings flat on the grass, then the bursts in open air in front of everything (nothing passes through)
    col += groundRing(P, RING_A + jitter2(T, 6.0, 21.0) * 2.0, vec2(86.0, 28.0), clamp(key(K_RA, T), 0.0, 1.0), 1.0, T);
    col += groundRing(P, RING_B + jitter2(T, 6.0, 22.0) * 2.0, vec2(73.0, 28.0), clamp(key(K_RB, T), 0.0, 1.0), 2.0, T);
    col += groundRing(P, RING_C + jitter2(T, 6.0, 23.0) * 2.0, vec2(94.0, 38.0), clamp(key(K_RC, T), 0.0, 1.0), 3.0, T);
    col += groundRing(P, RING_D + jitter2(T, 6.0, 24.0) * 2.0, vec2(105.0, 40.0), clamp(key(K_RD, T), 0.0, 1.0), 4.0, T);
    col = geyser(col, P, RING_D + vec2(14.0, -16.0), 285.0, b1, 0.05, 0.12, 1.0, T);
    col = geyser(col, P, RING_C + vec2(10.0, -14.0), 160.0, b2, 0.42, 0.10, 2.0, T);
    col = geyser(col, P, BURST_3, 230.0, b3, 0.65, 0.12, 3.0, T);
    col = sheet(col, P, BURST_3 + vec2(14.0, -6.0), 432.0, 2.3, b3, 3.0, T);
    col = droplets(col, P, RING_D + vec2(14.0, -24.0), 0.05, 0.85, 31.0, T, px);
    col = droplets(col, P, RING_C + vec2(10.0, -20.0), 0.42, 0.62, 37.0, T, px);
    col = droplets(col, P, BURST_3 + vec2(0.0, -14.0), 0.65, 1.10, 41.0, T, px);
    col = beadArc(col, P, RING_D + vec2(20.0, -40.0), 0.07, vec2(210.0, 250.0), 0.15, 51.0, T);
    col = beadArc(col, P, RING_C + vec2(14.0, -30.0), 0.44, vec2(150.0, 170.0), 0.13, 53.0, T);
    col = beadArc(col, P, BURST_3 + vec2(-30.0, -30.0), 0.67, vec2(-120.0, 200.0), 0.14, 57.0, T);

    // 4. finish: ease highlights into white, encode once, dither
    col = min(col, vec3(0.7)) + 0.3 * (1.0 - exp(-max(col - 0.7, 0.0) / 0.3));
    col = linearToSrgb(clamp(col, 0.0, 1.0)) + ditherTPDF(fragCoord, iFrame);
    fragColor = vec4(col, 1.0);
}
