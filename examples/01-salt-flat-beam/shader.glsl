// Salt-flat beam: three floating faceted stone bowls on a violet salt flat, an energy burst through
// their axis (beam, two expanding rings, debris crown, ground ripples). Recreated from the 12-frame reference
// (816x816, 0.12 s per frame, 1.44 s loop). Single pass, no textures. Build with tools/go.py.
//
// All layout constants are in REFERENCE PIXELS: origin top-left, x right, y down, 816 units tall.

#define DEBUG_MODE 0      // 0 final | 1 bowl distance | 2 bowl normals | 3 layer ids | 5 fx envelope bars
#define GIF_STEPPED 0     // 1 = hold each of the 12 reference frames (8.33 fps), 0 = continuous motion
#define FREEZE_TIME -1.0  // >= 0 freezes the loop at that time in seconds
#define SHAKE 1.0         // camera shake from the burst: 0 = locked camera, 1 = default, 2 = violent
#define PARTICLES 0.25    // strength of the particles riding the strip: 0 = strip only, 1 = the full particle overlay

const float LOOP = 1.44;
const float REF = 816.0;

// ---- palette (sRGB picks measured from the reference, decoded before use) ----
vec3 rgb(float r, float g, float b) { return srgbToLinear(vec3(r, g, b) / 255.0); }

// ---- small helpers -------------------------------------------------------------------------------------------------
float ramp(float a, float b, float x) { return clamp((x - a) / (b - a), 0.0, 1.0); }

// Randomness without state: a value that jumps to a new random target `rate` times a second and eases between.
vec2 jitter2(float T, float rate, float seed) {
    float t = T * rate, i = floor(t), u = smoothstep(0.0, 1.0, fract(t));
    return mix(hash22(vec2(i, seed)), hash22(vec2(i + 1.0, seed)), u) * 2.0 - 1.0;
}
float flick(float T, float rate, float seed) { return jitter2(T, rate, seed).x * 0.5 + 0.5; }

// Piecewise-linear silhouette height through 4 points sorted by x; far below the frame outside their span.
float profile4(float x, vec2 a, vec2 b, vec2 c, vec2 d) {
    if (x < a.x || x > d.x) return 1e4;
    if (x < b.x) return mix(a.y, b.y, ramp(a.x, b.x, x));
    if (x < c.x) return mix(b.y, c.y, ramp(b.x, c.x, x));
    return mix(c.y, d.y, ramp(c.x, d.x, x));
}

// ---- bowls ---------------------------------------------------------------------------------------------------------
// Convex polygon "radius": 1 on the boundary of an irregular n-gon with unit inradius.
float polyRadius(vec2 q, float n, float seed, float jitter) {
    float sec = TAU / n;
    float a = atan(q.y, q.x + 1e-6);
    float id = floor(a / sec);
    float r = 0.0;
    for (int k = -1; k <= 1; k++) {
        float i = mod(id + float(k), n);
        float h = hash11(i + seed);
        float ang = (i + 0.5 + (h - 0.5) * 0.6) * sec;
        float s = 1.0 + jitter * (hash11(i + seed + 17.0) - 0.5);
        r = max(r, dot(q, vec2(cos(ang), sin(ang))) / s);
    }
    return r;
}

// Bowl parameters, set per bowl before marching (a single pass has no state, so these are plain globals).
// gH body height, gRb base radius, gRt rim-edge radius, gHb bevel height, gDi cavity depth, gRf floor radius,
// gTilt rim slope along x (the right side sits higher when positive), fading to zero at the base.
float gH, gRb, gSeed, gRt, gHb, gDi, gRf, gTilt;
float gPart;      // part id the last bowl() call hit at this pixel (0 = none), read by mainImage for beam occlusion

// Bowl in units of its widest radius. The rim edge is the circle y = 0, r = gRt; an outward bevel (the pale lip)
// runs down to r = 1 at y = -gHb; the dark body curves in to the base. Returns (distance, part id):
// 1 body, 2 lip bevel, 3 inner wall, 4 floor.
vec2 bowlMap(vec3 p) {
    float th = atan(p.z, p.x + 1e-6);
    float wob = 0.030 * sin(2.0 * th + gSeed) + 0.022 * sin(3.0 * th + 2.3 * gSeed) + 0.012 * sin(7.0 * th + gSeed);
    float y = p.y - wob - gTilt * p.x * clamp(1.0 + p.y / gH, 0.0, 1.0);
    float rp = polyRadius(p.xz, 17.0, gSeed, 0.05);
    float ro;
    if (y > -gHb) ro = mix(1.0, gRt, clamp((y + gHb) / gHb, 0.0, 1.0));
    else ro = mix(gRb, 1.0, pow(clamp((y + gH) / (gH - gHb), 0.0, 1.0), mix(0.92, 0.52, gRb)));
    float dWall = (rp - ro) * 0.7;
    float d = max(dWall, max(y, -(y + gH)));
    float id = y > -gHb ? 2.0 : 1.0;
    float rq = polyRadius(p.xz, 15.0, gSeed + 5.0, 0.06);
    float ri = mix(gRf, gRt - 0.03, pow(clamp((y + gDi) / gDi, 0.0, 1.0), 1.25)) + 0.5 * max(y, 0.0);
    float dSide = (rq - ri) * 0.7, dFloor = -(y + gDi);
    float dc = max(dSide, dFloor);                   // negative inside the cavity
    if (-dc > d) { d = -dc; id = dSide > dFloor ? 3.0 : 4.0; }
    return vec2(d, id);
}

vec3 bowlNormal(vec3 p) {
    const vec2 e = vec2(0.004, 0.0);
    return normalize(vec3(bowlMap(p + e.xyy).x - bowlMap(p - e.xyy).x,
                          bowlMap(p + e.yxy).x - bowlMap(p - e.yxy).x,
                          bowlMap(p + e.yyx).x - bowlMap(p - e.yyx).x) + 1e-9);
}

// Orthographic view of one bowl. c = rim center, R = widest radius (px), s = sin(view elevation) = ry / rx.
// shape = (H, Rb, Rt, Hb), cav = (Di, Rf, interior violet amount), lipBand = depth of the pale lip band on the
// (left, right) flank as a fraction of H, then the rim tilt. Returns color and coverage.
vec4 bowl(vec2 P, vec2 c, float R, float s, float seed, vec4 shape, vec3 cav, vec3 lipBand, float glow, float px) {
    vec2 q = (P - c) / R;
    q.y = -q.y;
    gPart = 0.0;
    if (abs(q.x) > 1.12 || q.y > 0.42 || q.y < -(shape.x + 0.42)) return vec4(0.0);
    gH = shape.x; gRb = shape.y; gRt = shape.z; gHb = shape.w; gSeed = seed; gDi = cav.x; gRf = cav.y; gTilt = lipBand.z;
    float cs = sqrt(1.0 - s * s);
    vec3 rd = vec3(0.0, -s, -cs);
    vec3 up = vec3(0.0, cs, -s);
    vec3 ro = vec3(q.x, 0.0, 0.0) + up * q.y - rd * 3.0;
    float t = 1.4, minD = 1e3;
    vec2 h = vec2(1.0, 0.0);
    bool hit = false;
    for (int i = 0; i < 80; i++) {
        h = bowlMap(ro + rd * t);
        minD = min(minD, h.x);
        if (h.x < 0.0012) { hit = true; break; }
        t += h.x * 0.85;
        if (t > 4.8) break;
    }
#if DEBUG_MODE == 1
    return vec4(debugDistance(minD * 4.0), 1.0);
#endif
    // ink outline just outside the silhouette (heavier on the shaded lower right, as painted)
    float lineW = (0.9 + 0.8 * ramp(-0.4, 0.5, q.x - q.y * 2.0)) * px / R;
    float g2 = smoothstep(0.35, 1.0, glow);                               // burst light on the stone
    if (!hit) {
        float a = (1.0 - smoothstep(lineW * 0.4, lineW * 1.5, minD)) * 0.9;
        float halo = exp(-minD * R / 9.0) * (0.10 + 0.55 * g2) * smoothstep(-0.40, 0.05, q.y);   // bloom off the rim
        halo *= (1.0 - smoothstep(0.95, 1.12, abs(q.x))) * (1.0 - smoothstep(0.25, 0.42, q.y));
        return vec4(rgb(34.0, 24.0, 64.0) * a + vec3(0.80, 0.72, 1.0) * halo * (1.0 - a), a);
    }
    vec3 p = ro + rd * t;
    gPart = h.y;
    vec3 n = bowlNormal(p);
#if DEBUG_MODE == 2
    return vec4(debugNormal(n), 1.0);
#elif DEBUG_MODE == 3
    return vec4(debugIdColor(h.y), 1.0);
#endif
    // Painted, not lit: tone zones follow height on the form and which way a wall faces the pale key from the
    // upper left. Voronoi shards hold a flat offset each, which reads as brushed low-poly facets.
    vec3 L = normalize(vec3(-0.60, 0.62, 0.50));
    float nl = dot(n, L);
    float rr = length(p.xz);
    float ang = atan(p.x, p.z + 1e-6);                                    // seam at the far side, hidden
    vec2 su = h.y < 2.5 ? vec2(ang * 2.6, p.y * 7.0) : p.xz * 4.2;
    vec4 vc = voronoi(su + seed * 7.0, 1.0);
    float shard = hash12(vc.zw + seed * 13.0) - 0.5;
    float blot = fbm(su * 0.9 + seed * 3.0, 3);
    float side = p.x / max(rr, 0.2);                                      // -1 left .. +1 right
    vec3 col;
    if (h.y < 2.5) {
        // outside: pale lip band on top, shade below; the band runs deeper on the lit left
        float hgt = clamp(-p.y / gH, 0.0, 1.0);
        float band = mix(lipBand.y, lipBand.x, smoothstep(-0.9, 0.8, -side)) + 0.10 * shard + 0.10 * blot;
        float w = 1.0 - smoothstep(band - 0.05, band + 0.05, hgt);
        vec3 body = mix(rgb(52.0, 45.0, 100.0), rgb(72.0, 61.0, 124.0), smoothstep(-0.3, 0.3, shard + 0.6 * blot + 0.3 * nl));
        body = mix(body, rgb(92.0, 76.0, 148.0), (1.0 - smoothstep(0.35, 0.75, hgt)) * smoothstep(0.2, 0.45, shard + nl * 0.4));
        body += vec3(0.030, 0.012, 0.150) * (0.25 * cav.z + g2) * (0.4 + 0.6 * hgt);   // violet bounce from below
        vec3 lip = mix(rgb(160.0, 138.0, 204.0), rgb(204.0, 184.0, 228.0), smoothstep(-0.25, 0.15, shard + blot + 0.4 * nl));
        float lipHi = (1.0 - smoothstep(0.03, 0.12, hgt - 0.10 * smoothstep(-0.2, 0.9, -side))) * 0.9;
        lip = mix(lip, rgb(240.0, 228.0, 244.0), lipHi * (0.45 + 0.55 * smoothstep(-0.18, 0.12, blot + 0.6 * shard)));   // broken, brushed highlight
        col = mix(body, lip, w);
        // rim-light sliver along the lower left silhouette
        col = mix(col, rgb(190.0, 172.0, 224.0), smoothstep(0.85, 0.97, -n.x) * smoothstep(0.3, 0.6, hgt) * 0.6);
        col = mix(col, rgb(240.0, 230.0, 252.0), g2 * 0.50 * w);
    } else {
        // cavity: pale upper slope (wider on the right, which faces the key), violet below, darker left wall
        float dpt = clamp(-p.y / gDi, 0.0, 1.0);
        vec3 dk = mix(rgb(76.0, 66.0, 136.0), rgb(108.0, 84.0, 182.0), cav.z);
        vec3 md = mix(rgb(93.0, 82.0, 156.0), rgb(154.0, 118.0, 230.0), cav.z);
        vec3 lt = mix(rgb(196.0, 174.0, 224.0), rgb(228.0, 205.0, 241.0), cav.z);
        float sideS = p.x / (rr + 0.25) + 0.25 * fbm(p.xz * 2.5 + seed, 3);      // smooth across facets
        float band = 0.02 + 0.44 * smoothstep(-0.2, 0.9, sideS) + 0.10 * shard + 0.12 * blot;
        float w = 1.0 - smoothstep(band - 0.14, band + 0.10, dpt);
        col = mix(md, dk, smoothstep(-0.1, 0.8, -(side + 0.5 * shard)) * 0.9);
        col = mix(col, lt, w);
        if (h.y > 3.5) col = mix(md, dk, 0.3 + 0.5 * blot + 0.4 * shard);
        // radial brush strokes, a dark seam where the wall meets the floor, glints on the shaded wall
        float stroke = fbm(vec2(atan(p.z, p.x + 1e-6) * 5.0, rr * 2.5) + seed, 3);
        col *= 1.0 + 0.22 * stroke;
        col = mix(col, dk * 0.85, 0.5 * (1.0 - smoothstep(0.0, 0.035, abs(rr - gRf * 0.93))) * step(0.8, dpt));
        vec2 gs = floor(p.xz * 46.0);
        vec3 gh = hash32(gs + seed);
        float glint = step(0.965, gh.z) * (1.0 - smoothstep(0.1, 0.3, length(p.xz * 46.0 - gs - 0.3 - 0.4 * gh.xy)));
        col = mix(col, rgb(244.0, 238.0, 255.0), glint * smoothstep(-0.1, 0.4, -side) * cav.z);
        // violet glow where the beam meets the floor (the beam itself is composited in mainImage)
        col += rgb(150.0, 110.0, 255.0) * (0.20 * cav.z + (0.3 + 0.9 * cav.z) * glow) * exp(-rr * rr * 6.0);
        col = mix(col, rgb(236.0, 222.0, 252.0), g2 * (0.15 + 0.5 * cav.z) * exp(-rr * rr * 4.5));
    }
    // sparse dark grit
    vec2 sg = su * 9.0;
    vec2 sc = floor(sg);
    vec3 sr = hash32(sc + seed);
    float speck = step(0.93, sr.z) * (1.0 - smoothstep(0.10, 0.22, length(sg - sc - 0.25 - 0.5 * sr.xy)));
    col = mix(col, rgb(84.0, 66.0, 134.0), 0.7 * speck * step(0.5, luminance(col)));
    return vec4(col, 1.0);
}

// ---- background ------------------------------------------------------------------------------------------------------
vec3 sky(vec2 P) {
    float y = P.y;
    vec3 c = mix(rgb(51.0, 46.0, 95.0), rgb(60.0, 54.0, 108.0), ramp(10.0, 70.0, y));
    c = mix(c, rgb(69.0, 63.0, 124.0), ramp(60.0, 118.0, y));
    c = mix(c, rgb(88.0, 79.0, 150.0), ramp(110.0, 165.0, y));
    c = mix(c, rgb(92.0, 83.0, 156.0), ramp(165.0, 225.0, y));
    // painted sky: lighter upper left, darker right side near the horizon, soft cloud mottling
    c *= 1.0 + 0.22 * ramp(420.0, 0.0, P.x) * ramp(150.0, 20.0, y) - 0.16 * ramp(480.0, 700.0, P.x) * ramp(90.0, 190.0, y);
    c *= 1.0 + 0.16 * fbm(P * vec2(0.005, 0.013) + 3.0, 4);
    return c;
}

// Distance to a polyline of up to 6 points (n = number of points).
float polyline(vec2 p, vec2 a, vec2 b, vec2 c, vec2 d, vec2 e, vec2 f, int n) {
    float r = sdSegment(p, a, b);
    if (n > 2) r = min(r, sdSegment(p, b, c));
    if (n > 3) r = min(r, sdSegment(p, c, d));
    if (n > 4) r = min(r, sdSegment(p, d, e));
    if (n > 5) r = min(r, sdSegment(p, e, f));
    return r;
}

// Painted light map of the plain. The painting's broad tonal drift is not derivable from the scene, so it is
// measured (tools/refit.py -> lightmap.glsl, grid set in meta.json) and interpolated; everything finer than those
// samples is procedural.
#define LIGHTMAP 1
//#include "lightmap.glsl"

vec3 lightMap(vec2 P) {
#if LIGHTMAP
    return lightMapRaw(P);
#else
    return vec3(1.0);
#endif
}

// Convex quad as the intersection of its four edge half-planes (positive outside; exact enough near the edges).
float sdQuad(vec2 p, vec2 a, vec2 b, vec2 c, vec2 d) {
    vec2 m = 0.25 * (a + b + c + d);
    vec2 n0 = normalize(vec2(b.y - a.y, a.x - b.x)), n1 = normalize(vec2(c.y - b.y, b.x - c.x));
    vec2 n2 = normalize(vec2(d.y - c.y, c.x - d.x)), n3 = normalize(vec2(a.y - d.y, d.x - a.x));
    float s = sign(dot(a - m, n0));                                          // flip the normals for either winding
    return max(max(s * dot(p - a, n0), s * dot(p - b, n1)), max(s * dot(p - c, n2), s * dot(p - d, n3)));
}

// Raised salt slab: a flat plate a-b-c-d (clockwise from top-left, front edge d-c), paler than the plain, with a
// white broken rim along the front edge. A front face hangs h.x (at d) to h.y (at c) below that edge, cut into
// blocks of flat tone by dark vertical joints, and casts a shadow onto the plain. lit: 0 = face turned away and in
// shade (left slabs), 1 = face catching the light (right slabs).
vec3 slab(vec3 col, vec2 P, vec2 a, vec2 b, vec2 c, vec2 d, vec2 h, float lit, float px) {
    vec2 W = P + 2.0 * vec2(fbm(P * 0.08, 2), fbm(P * 0.08 + 5.0, 2));
    vec2 dh = d + vec2(0.0, h.x), ch = c + vec2(0.0, h.y);
    float dTop = sdQuad(W, a, b, c, d) + 0.8 + 2.5 * fbm(P * 0.07 + 3.0, 2);
    float dFace = sdQuad(W, d, c, ch, dh);
    // cast shadow: the face footprint pushed down (and out to the right for the shaded slabs), soft edged
    vec2 so = mix(vec2(16.0, 7.0), vec2(-3.0, 6.0), lit);
    float dSh = min(sdQuad(W - so, d, c, ch, dh), dFace);
    col = mix(col, rgb(42.0, 35.0, 80.0), 0.85 * (1.0 - smoothstep(-3.0, 5.0, dSh)));
    // face: blocks of flat tone between dark joints, darker toward the foot
    float t = clamp((W.x - d.x) / (c.x - d.x), 0.0, 1.0);
    float v = clamp((W.y - mix(d.y, c.y, t)) / mix(h.x, h.y, t), 0.0, 1.0);
    float u = (W.x + 0.4 * v * mix(h.x, h.y, t)) / 17.0;                                         // joints lean a little
    float bt = hash11(floor(u) + 31.0 * lit + floor(a.y));
    float joint = (1.0 - smoothstep(0.4, 1.3, min(fract(u), 1.0 - fract(u)) * 17.0)) * step(0.3, hash11(floor(u) + 7.0));
    vec3 fc = mix(mix(rgb(94.0, 79.0, 146.0), rgb(60.0, 53.0, 112.0), v), mix(rgb(200.0, 176.0, 224.0), rgb(150.0, 126.0, 194.0), v), lit);
    fc *= (0.86 + 0.26 * bt) * (1.0 - 0.35 * joint);
    col = mix(col, fc, fillAA(dFace, px));
    // top: pale crust brushed in two tones, lighter toward its back edge
    vec3 tc = mix(rgb(136.0, 115.0, 184.0), rgb(166.0, 144.0, 206.0), smoothstep(-0.2, 0.25, fbm(P * vec2(0.03, 0.08) + 5.0, 3)));
    tc = mix(tc, rgb(170.0, 148.0, 208.0), 0.5 * (1.0 - smoothstep(1.0, 12.0, sdSegment(W, a, b))));
    // white broken rim along the front edge, fainter round the rest of the outline
    float rimW = 1.2 + 1.4 * smoothstep(-0.2, 0.3, fbm(P * 0.09 + 2.0, 2));
    float rim = max(strokeAA(min(sdSegment(W, d, c), sdSegment(W, b, c) - 0.8), rimW, px), 0.55 * smoothstep(-3.0, -0.5, dTop));
    tc = mix(tc, rgb(234.0, 222.0, 246.0), rim * (0.6 + 0.4 * smoothstep(-0.2, 0.2, fbm(P * 0.13, 2))));
    col = mix(col, tc, fillAA(dTop, px));
    return mix(col, rgb(234.0, 222.0, 246.0), strokeAA(sdSegment(W, d, c), rimW, px) * 0.8);
}

// One painted horizontal streak: soft band at height y (half thickness h) from x0 to x1 with feathered ends.
float band(vec2 S, float x0, float x1, float y, float h) {
    return smoothstep(0.0, 22.0, min(S.x - x0, x1 - S.x)) * (1.0 - smoothstep(0.45 * h, h, abs(S.y - y)));
}

// A loose stone at s.xy, radius s.z, squashed vertically by sq: lit from the upper left, with a contact shadow.
vec3 stone(vec3 c, vec2 P, vec3 s, float sq, vec3 hi, vec3 lo, float px) {
    vec2 q = (P - s.xy) * vec2(1.0, sq);
    float r = s.z * (1.0 + 0.12 * sin(atan(q.y, q.x) * 3.0 + s.x) + 0.07 * sin(atan(q.y, q.x) * 5.0 + s.y));
    c = mix(c, c * 0.55, 0.7 * fillAA(length(q - vec2(1.5, 2.5 * sq)) - r, px * 2.0));
    vec3 sc = mix(hi, lo, smoothstep(-0.6, 0.6, (q.x + 1.4 * q.y) / r));
    return mix(c, sc, fillAA(length(q) - r, px));
}

vec3 ground(vec2 P, float px) {
    float yh = 228.0;
    float d = max(P.y - yh, 2.0);
    vec2 g = vec2((P.x - 408.0) / d, 300.0 / d) * 2.2; // perspective ground coordinates
    float y = P.y;
    vec2 W = P + 5.0 * vec2(fbm(P * 0.03, 3), fbm(P * 0.03 + 11.0, 3));   // hand-drawn wobble

    // broad tone: mid violet, lighter on the left half, darker right middle distance
    vec3 c = mix(rgb(72.0, 63.0, 123.0), rgb(84.0, 72.0, 135.0), ramp(245.0, 300.0, y));
    c = mix(c, rgb(98.0, 82.0, 148.0), ramp(330.0, 440.0, y));
    c = mix(c, rgb(122.0, 97.0, 165.0), ramp(440.0, 560.0, y));
    c = mix(c, rgb(116.0, 89.0, 156.0), ramp(640.0, 760.0, y));
    c *= 1.0 + 0.22 * ramp(520.0, 60.0, P.x) * ramp(300.0, 480.0, y);
    c *= 1.0 - 0.28 * ramp(430.0, 640.0, P.x) * ramp(250.0, 300.0, y) * ramp(470.0, 400.0, y);
    float m = fbm(g * 1.6 + 7.0, 5);
    c *= 1.0 + (0.36 * m + 0.10 * fbm(P * 0.02, 3)) * (1.0 - 0.75 * ramp(400.0, 260.0, y));

    // far field: horizontal sheets of pale salt and dark wet ground, placed from the reference, plus a faint
    // finer streak texture so the sheets are brushed rather than ruled
    float far = ramp(430.0, 250.0, y);
    vec2 S = P + vec2(18.0 * fbm(vec2(P.y * 0.15, 4.0), 2), 1.5 * fbm(vec2(P.x * 0.025, 9.0), 3));
    float streak = fbm(vec2(P.x * 0.006, 300.0 / d) + 1.7, 3);
    c *= 1.0 + 0.10 * far * streak;
    float pale = band(S, 130.0, 245.0, 252.0, 3.0) * 0.45 + band(S, 140.0, 270.0, 268.0, 3.0) * 0.5
               + band(S, 38.0, 118.0, 277.0, 3.0) + band(S, -20.0, 175.0, 304.0, 5.0) * 0.35
               + band(S, 80.0, 240.0, 393.0, 6.0) * 0.35
               + band(S, 590.0, 720.0, 245.0, 2.0) * 0.5 + band(S, 690.0, 840.0, 250.0, 3.0) * 0.7
               + band(S, 580.0, 700.0, 264.0, 4.0) + band(S, 660.0, 840.0, 270.0, 2.5) * 0.8
               + band(S, 765.0, 840.0, 276.0, 2.5) * 0.7 + band(S, 725.0, 840.0, 284.0, 4.0) * 0.8
               + band(S, 595.0, 690.0, 292.0, 2.5) * 0.7 + band(S, 718.0, 765.0, 293.0, 2.0) * 0.6;
    float dark = band(S, -40.0, 270.0, 261.0, 4.0) * 0.8 + band(S, -40.0, 300.0, 286.0, 5.0) * 0.6
               + band(S, 500.0, 760.0, 278.0, 4.0) * 0.6;
    c = mix(c, rgb(118.0, 101.0, 174.0), clamp(pale, 0.0, 1.0) * 0.85);
    c = mix(c, rgb(58.0, 52.0, 106.0), clamp(dark, 0.0, 1.0) * 0.7);
    // the bright streak running right from the upper-left slab, and the darker blue-violet right-middle distance
    c = mix(c, rgb(140.0, 120.0, 188.0), band(S, 90.0, 225.0, 318.0, 9.0) * 0.9);
    c = mix(c, rgb(62.0, 56.0, 112.0), 0.6 * ramp(500.0, 580.0, P.x) * ramp(292.0, 300.0, y) * ramp(352.0, 340.0, y));

    // pale wet sheen left of the stack: a broad glow and a bright diagonal streak (measured) running into the base
    float sheen = exp(-dot2((P - vec2(240.0, 505.0)) / vec2(100.0, 40.0)));
    c = mix(c, rgb(176.0, 150.0, 204.0), 0.4 * sheen * smoothstep(-0.2, 0.3, m + 0.2));
    float shs = sdSegment(W + 4.0 * vec2(fbm(P * 0.04 + 3.0, 2), 0.0), vec2(180.0, 495.0), vec2(240.0, 540.0)) - 13.0;
    c = mix(c, rgb(206.0, 182.0, 222.0), 0.75 * (1.0 - smoothstep(-16.0, 14.0, shs)));

    // cast shadow of the stack: under the bottom bowl and a wedge running off to the right
    float sn = 10.0 * fbm(P * 0.02 + 4.0, 3);
    float sh = sdEllipse(P - vec2(440.0, 668.0), vec2(205.0, 48.0)) + sn;
    float wedgeTop = P.x < 700.0 ? 588.0 + 0.32 * (P.x - 603.0) : 619.0 + 0.267 * (P.x - 700.0);   // measured edge
    float wedgeBot = 724.0 - 0.03 * (P.x - 600.0);
    float wedge = max(max(wedgeTop - P.y, P.y - wedgeBot), 540.0 - P.x) + sn;
    sh = min(sh, wedge);
    c = mix(c, rgb(45.0, 38.0, 87.0) * (1.0 + 0.3 * m), 0.92 * (1.0 - smoothstep(-8.0, 10.0, sh)));

    // thin pale arcs drawn on the ground round the base (concentric ellipses, broken up), and painterly two-tone patches
    vec2 rq = (P - vec2(408.0, 662.0)) / vec2(1.0, 0.30);
    float rl0 = length(rq);
    float rgrad = length(vec2(rq.x, rq.y / 0.30)) / max(rl0, 1.0);                // turns arc spacing back into pixels
    float rl = rl0 + 14.0 * fbm(P * 0.012, 3);
    float fr = fract(rl / 24.0);
    float arcs = (1.0 - smoothstep(0.6, 1.8, min(fr, 1.0 - fr) * 24.0 / rgrad)) * ramp(195.0, 215.0, rl) * ramp(300.0, 270.0, rl);
    arcs *= ramp(140.0, 190.0, abs(P.x - 408.0)) * ramp(720.0, 690.0, P.y);                   // only out to the sides
    c = mix(c, rgb(176.0, 154.0, 214.0), 0.4 * arcs * smoothstep(-0.05, 0.2, fbm(P * 0.03 + 8.0, 2)));
    c *= 1.0 + 0.13 * (smoothstep(-0.04, 0.04, fbm(g * 3.1 + 2.0, 4)) - 0.5) * (1.0 - 0.8 * far);
    // crust plates: flat tone per plate, hairline joints, loose dark grit in the foreground
    vec2 gw = g * 0.85 + 0.35 * vec2(fbm(g * 0.7, 3), fbm(g * 0.7 + 4.0, 3));
    vec4 plate = voronoi(gw + 3.0, 0.9);
    c *= 1.0 + 0.20 * (hash12(plate.zw) - 0.5);
    float joint = (1.0 - smoothstep(0.0, 0.035, plate.y - plate.x)) * ramp(250.0, 420.0, y);
    c = mix(c, c * 0.7, 0.22 * joint);
    vec2 gc = floor(P / 7.0);
    vec3 gr = hash32(gc);
    float grit = step(0.955, gr.z) * (1.0 - smoothstep(0.8, 2.0, length(P - (gc + 0.2 + 0.6 * gr.xy) * 7.0)));
    c = mix(c, c * 0.5, grit * ramp(380.0, 560.0, y) * 0.7);

    // dark hairline cracks
    float ck = polyline(W, vec2(-5.0, 606.0), vec2(40.0, 605.0), vec2(99.0, 601.0), vec2(146.0, 583.0), vec2(203.0, 584.0), vec2(0.0), 5);
    ck = min(ck, polyline(W, vec2(619.0, 564.0), vec2(700.0, 560.0), vec2(762.0, 554.0), vec2(0.0), vec2(0.0), vec2(0.0), 3));
    ck = min(ck, polyline(W, vec2(30.0, 540.0), vec2(105.0, 532.0), vec2(150.0, 548.0), vec2(0.0), vec2(0.0), vec2(0.0), 3));
    ck = min(ck, polyline(W, vec2(442.0, 726.0), vec2(470.0, 742.0), vec2(520.0, 762.0), vec2(0.0), vec2(0.0), vec2(0.0), 3));
    c = mix(c, rgb(44.0, 34.0, 80.0), 0.85 * strokeAA(ck, 0.9, px));

    // white salt ridges (measured): a white crest with a thin shadow under it. Foreground ridges are fat and
    // bright, the far ones thinner and fainter.
    float rd = polyline(W, vec2(-5.0, 603.0), vec2(20.0, 600.0), vec2(40.0, 596.0), vec2(70.0, 594.0), vec2(85.0, 598.0), vec2(100.0, 600.0), 6);
    rd = min(rd, polyline(W, vec2(33.0, 608.0), vec2(43.0, 620.0), vec2(60.0, 630.0), vec2(68.0, 634.0), vec2(72.0, 650.0), vec2(80.0, 660.0), 6));
    rd = min(rd, polyline(W, vec2(80.0, 660.0), vec2(97.0, 668.0), vec2(117.0, 672.0), vec2(120.0, 680.0), vec2(127.0, 690.0), vec2(137.0, 693.0), 6));
    rd = min(rd, polyline(W, vec2(88.0, 706.0), vec2(105.0, 702.0), vec2(125.0, 697.0), vec2(160.0, 686.0), vec2(220.0, 679.0), vec2(273.0, 667.0), 6));
    rd = min(rd, polyline(W, vec2(440.0, 780.0), vec2(500.0, 760.0), vec2(549.0, 748.0), vec2(583.0, 742.0), vec2(609.0, 738.0), vec2(0.0), 5));
    rd = min(rd, polyline(W, vec2(500.0, 760.0), vec2(530.0, 780.0), vec2(520.0, 806.0), vec2(0.0), vec2(0.0), vec2(0.0), 3));
    float rw = 1.2 + 1.2 * smoothstep(-0.3, 0.3, fbm(P * 0.09, 2));
    float rd2 = polyline(W, vec2(80.0, 462.0), vec2(110.0, 457.0), vec2(150.0, 453.0), vec2(200.0, 449.0), vec2(240.0, 445.0), vec2(285.0, 440.0), 6) - 1.6 * ramp(220.0, 90.0, P.x);
    float rd3 = polyline(W, vec2(540.0, 440.0), vec2(580.0, 443.0), vec2(620.0, 450.0), vec2(660.0, 456.0), vec2(700.0, 463.0), vec2(758.0, 479.0), 6) - 3.5 * ramp(620.0, 740.0, P.x) - 0.5;
    rd2 = min(rd2, rd3);
    rd2 = min(rd2, polyline(W, vec2(565.0, 339.0), vec2(610.0, 343.0), vec2(660.0, 348.0), vec2(692.0, 350.0), vec2(742.0, 360.0), vec2(0.0), 5) - 0.8 * ramp(600.0, 690.0, P.x));
    rd2 = min(rd2, polyline(W, vec2(690.0, 516.0), vec2(720.0, 508.0), vec2(760.0, 503.0), vec2(0.0), vec2(0.0), vec2(0.0), 3) + 0.6);
    float faint = polyline(W, vec2(683.0, 612.0), vec2(729.0, 607.0), vec2(763.0, 605.0), vec2(816.0, 600.0), vec2(0.0), vec2(0.0), 4);
    faint = min(faint, min(sdSegment(W, vec2(703.0, 580.0), vec2(723.0, 593.0)), sdSegment(W, vec2(743.0, 590.0), vec2(763.0, 605.0))));
    faint = min(faint, polyline(W, vec2(600.0, 355.0), vec2(660.0, 362.0), vec2(700.0, 365.0), vec2(0.0), vec2(0.0), vec2(0.0), 3));
    c = mix(c, rgb(150.0, 128.0, 196.0), 0.5 * strokeAA(faint, 1.0, px));
    float ridge = min(rd - rw, rd2 - 0.75 * rw);
    float ridgeSh = min(min(polyline(W - vec2(1.0, 4.0), vec2(33.0, 608.0), vec2(43.0, 620.0), vec2(60.0, 630.0), vec2(68.0, 634.0), vec2(72.0, 650.0), vec2(80.0, 660.0), 6),
                            polyline(W - vec2(1.0, 4.0), vec2(80.0, 660.0), vec2(97.0, 668.0), vec2(117.0, 672.0), vec2(120.0, 680.0), vec2(127.0, 690.0), vec2(137.0, 693.0), 6)),
                        polyline(W - vec2(0.0, 5.0), vec2(88.0, 706.0), vec2(105.0, 702.0), vec2(125.0, 697.0), vec2(160.0, 686.0), vec2(220.0, 679.0), vec2(273.0, 667.0), 6)) - rw;
    c = mix(c, rgb(42.0, 33.0, 80.0), 0.85 * fillAA(ridgeSh, px * 2.0));
    c = mix(c, rgb(50.0, 40.0, 92.0), 0.45 * fillAA(rd2 - 0.75 * rw - 1.6, px * 2.0));             // dark lip round far ridges
    c = mix(c, rgb(214.0, 198.0, 236.0), fillAA(ridge, px * 1.5));

    // raised salt slabs at the frame edges (plate corners and face heights measured)
    c = slab(c, P, vec2(-20.0, 311.0), vec2(60.0, 312.0), vec2(101.0, 326.0), vec2(-20.0, 330.0), vec2(16.0, 12.0), 0.0, px);
    c = slab(c, P, vec2(-20.0, 420.0), vec2(25.0, 421.0), vec2(78.0, 458.0), vec2(-20.0, 468.0), vec2(14.0, 12.0), 0.0, px);
    c = slab(c, P, vec2(688.0, 344.0), vec2(840.0, 346.0), vec2(840.0, 360.0), vec2(741.0, 364.0), vec2(8.0, 28.0), 1.0, px);
    c = slab(c, P, vec2(758.0, 477.0), vec2(840.0, 452.0), vec2(840.0, 488.0), vec2(756.0, 483.0), vec2(17.0, 24.0), 1.0, px);

    // small pile of pale rocks behind the top bowl (measured stones)
    if (abs(P.x - 533.0) < 40.0 && abs(P.y - 317.0) < 24.0) {
        const vec3 PILE[11] = vec3[11](vec3(512.0, 303.0, 5.5), vec3(522.0, 308.0, 6.5), vec3(537.0, 313.0, 5.5), vec3(515.0, 318.0, 6.5),
                                       vec3(528.0, 321.0, 5.5), vec3(545.0, 322.0, 5.0), vec3(509.0, 325.0, 4.5), vec3(553.0, 328.0, 4.5),
                                       vec3(561.0, 331.0, 3.5), vec3(540.0, 330.0, 4.5), vec3(524.0, 330.0, 4.0));
        for (int i = 0; i < 11; i++) c = stone(c, P, PILE[i], 1.15, rgb(136.0, 120.0, 188.0), rgb(84.0, 74.0, 138.0), px);
    }

    // salt mound, bottom right: lumpy pale crust under a bright scalloped rim, two clusters of dark pebbles
    float mh = min(profile4(P.x, vec2(585.0, 830.0), vec2(599.0, 773.0), vec2(609.0, 737.0), vec2(626.0, 722.0)),
                   profile4(P.x, vec2(626.0, 722.0), vec2(639.0, 712.0), vec2(656.0, 707.0), vec2(669.0, 704.0)));
    mh = min(mh, min(profile4(P.x, vec2(669.0, 704.0), vec2(696.0, 712.0), vec2(729.0, 706.0), vec2(769.0, 712.0)),
                     profile4(P.x, vec2(769.0, 712.0), vec2(789.0, 713.0), vec2(816.0, 715.0), vec2(830.0, 716.0))));
    float md = mh - P.y + 3.0 * fbm(P * 0.06 + 2.0, 3) - 3.5 * abs(sin(P.x * 0.16 + 2.0 * fbm(P * 0.02, 2)));
    float lump = fbm(P * 0.028 + 9.0, 4);
    vec3 mc = mix(rgb(132.0, 110.0, 180.0), rgb(170.0, 147.0, 208.0), smoothstep(-0.25, 0.25, lump));
    mc = mix(mc, rgb(112.0, 92.0, 160.0), 0.55 * smoothstep(0.04, 0.2, fbm(P * 0.028 + vec2(9.0, 8.75), 4) - lump)); // shade under lumps
    float crust = smoothstep(-16.0, -4.0, md) * (0.7 + 0.3 * smoothstep(-0.2, 0.2, fbm(P * 0.09, 3)));
    mc = mix(mc, rgb(228.0, 208.0, 238.0), max(crust, 0.8 * smoothstep(0.22, 0.34, lump)));
    mc *= 1.0 - 0.2 * ramp(760.0, 816.0, P.y);
    c = mix(c, rgb(44.0, 36.0, 84.0), 0.5 * (1.0 - smoothstep(0.0, 10.0, md)));
    c = mix(c, mc, fillAA(md, px));
    if (P.x > 660.0 && P.y > 728.0) {
        const vec3 PEB[9] = vec3[9](vec3(676.0, 752.0, 8.5), vec3(691.0, 748.0, 7.0), vec3(704.0, 744.0, 7.0), vec3(717.0, 738.0, 7.0),
                                    vec3(675.0, 776.0, 8.0), vec3(689.0, 771.0, 6.5), vec3(769.0, 752.0, 8.5), vec3(773.0, 769.0, 6.5),
                                    vec3(776.0, 786.0, 6.0));
        for (int i = 0; i < 9; i++) c = stone(c, P, PEB[i], 1.25, rgb(110.0, 92.0, 160.0), rgb(48.0, 38.0, 86.0), px);
    }

    // dark foreground rock, bottom left: a lit top facet over a dark body, lighter toward its right flank
    float rh = min(profile4(P.x, vec2(-10.0, 666.0), vec2(40.0, 688.0), vec2(70.0, 700.0), vec2(100.0, 712.0)),
                   profile4(P.x, vec2(100.0, 712.0), vec2(120.0, 730.0), vec2(135.0, 746.0), vec2(150.0, 770.0)));
    rh = min(rh, profile4(P.x, vec2(150.0, 770.0), vec2(165.0, 786.0), vec2(175.0, 805.0), vec2(185.0, 830.0)));
    float rk = rh - P.y + 3.0 * fbm(P * 0.04, 3);
    vec3 rc = mix(rgb(54.0, 42.0, 89.0), rgb(64.0, 50.0, 102.0), ramp(40.0, 100.0, P.x) * ramp(790.0, 745.0, P.y));
    rc = mix(rc, rgb(38.0, 31.0, 73.0), ramp(765.0, 800.0, P.y));
    rc *= 1.0 + 0.15 * smoothstep(-0.15, 0.2, fbm(P * vec2(0.03, 0.05) + 1.0, 3));
    float facet = P.y - rh - mix(44.0, 20.0, ramp(0.0, 80.0, P.x)) + 4.0 * fbm(P * 0.05 + 7.0, 2);
    rc = mix(rc, rgb(79.0, 62.0, 120.0), fillAA(facet, px * 2.0) * ramp(118.0, 95.0, P.x));
    c = mix(c, rc, fillAA(rk, px));
    c = mix(c, rgb(30.0, 22.0, 60.0), 0.8 * strokeAA(rk, 0.8, px));

    // loose white stone and the dark grit scattered round it
    if (abs(P.x - 185.0) < 45.0 && abs(P.y - 754.0) < 16.0) {
        const vec3 GRIT[5] = vec3[5](vec3(157.0, 750.0, 2.5), vec3(165.0, 753.0, 3.0), vec3(175.0, 748.0, 2.5), vec3(190.0, 745.0, 2.0), vec3(183.0, 760.0, 2.0));
        for (int i = 0; i < 5; i++) c = stone(c, P, GRIT[i], 1.3, rgb(80.0, 64.0, 128.0), rgb(40.0, 32.0, 76.0), px);
        c = stone(c, P, vec3(214.0, 758.0, 10.5), 1.9, rgb(226.0, 210.0, 240.0), rgb(170.0, 150.0, 206.0), px);
    }
    return c * lightMap(P);
}

// ---- timeline --------------------------------------------------------------------------------------------------------
// One key per reference frame (0.12 s apart), measured from the GIF; evaluated with a cyclic Catmull-Rom spline so
// the shader passes through every measured frame and stays smooth in between.
const float K_TOP_DY[12]  = float[12](0.0, -6.5, -17.5, -24.5, -66.5, -80.0, -81.5, -81.5, -53.0, -30.0, -19.5, -5.5);
const float K_MID_DY[12]  = float[12](0.0, -5.0, -7.0, -11.0, -51.0, -46.0, -52.0, -52.0, -20.0, -11.0, -10.0, -5.0);
const float K_TOP_SC[12]  = float[12](1.0, 1.02, 1.03, 1.06, 1.07, 1.07, 1.05, 1.04, 1.04, 1.04, 1.03, 1.02);
const float K_MID_SC[12]  = float[12](1.0, 1.0, 0.98, 0.97, 0.94, 0.95, 0.96, 0.97, 0.98, 1.0, 1.0, 1.0);
const float K_AMB[12]     = float[12](0.0, 0.17, 0.29, 0.58, 0.86, 1.0, 0.96, 0.70, 0.45, 0.35, 0.28, 0.27);
const float K_BEAM[12]    = float[12](0.30, 0.40, 0.65, 0.85, 1.0, 1.0, 0.90, 0.70, 0.50, 0.42, 0.36, 0.32);
const float K_RA_I[12]    = float[12](0.0, 0.0, 0.22, 1.0, 1.0, 1.0, 0.85, 0.30, 0.0, 0.0, 0.0, 0.0);
const float K_RA_RX[12]   = float[12](200.0, 205.0, 222.0, 225.0, 232.0, 280.0, 290.0, 300.0, 305.0, 305.0, 200.0, 200.0);
const float K_RA_CY[12]   = float[12](340.0, 340.0, 340.0, 325.0, 330.0, 335.0, 340.0, 340.0, 340.0, 340.0, 340.0, 340.0);
const float K_RB_I[12]    = float[12](0.0, 0.0, 0.10, 1.0, 1.0, 0.90, 0.35, 0.12, 0.0, 0.0, 0.0, 0.0);
const float K_RB_RX[12]   = float[12](200.0, 205.0, 212.0, 220.0, 230.0, 242.0, 315.0, 330.0, 335.0, 335.0, 200.0, 200.0);
const float K_DEB_A[12]   = float[12](0.22, 0.45, 0.75, 1.0, 1.0, 1.0, 0.70, 0.24, 0.20, 0.20, 0.22, 0.22);
const float K_DEB_S[12]   = float[12](0.10, 0.18, 0.40, 0.72, 1.0, 1.0, 1.0, 0.95, 0.60, 0.30, 0.20, 0.14);
const float K_BITS[12]    = float[12](0.0, 0.25, 0.60, 1.0, 1.0, 1.0, 0.70, 0.40, 0.25, 0.08, 0.0, 0.0);

float key(float k[12], float T) {
    float f = T / 0.12;
    int i = int(floor(f)) % 12;
    float u = fract(f);
    float p0 = k[(i + 11) % 12], p1 = k[i], p2 = k[(i + 1) % 12], p3 = k[(i + 2) % 12];
    return p1 + 0.5 * u * (p2 - p0 + u * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + u * (3.0 * (p1 - p2) + p3 - p0)));
}

// ---- energy effects --------------------------------------------------------------------------------------------------
const vec3 FX_VIOLET = vec3(0.30, 0.16, 0.95);     // linear
const vec3 FX_WHITE = vec3(0.92, 0.86, 1.0);

// Dense motes: one soft dot per cell of a sheet, each with its own size, brightness and twinkle. Summing sheets of
// different cell size and drift reads as a cloud of separate particles, where a gradient reads as a strip of light.
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
// each one is still a separate particle.
float strands(vec2 u, float lane, float len, float speed, float seed, float T) {
    float ly = floor(u.y / lane);
    vec2 lh = hash22(vec2(ly, seed));
    // Long dashes, moderate speed, lanes nearly in step: a dash moves less than its own length in 0.12 s, so the
    // flow stays readable even at the reference's 8.33 fps instead of boiling.
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

// Flat energy ring seen at the stack's elevation, made of particles streaming round it. Returns additive light;
// `arc` > 0 keeps the near (lower) arc, < 0 the far arc. The three hand-drawn strokes are kept as the shape and
// filled with dashes running in lanes round the ring; round grains are shed outward; a violet halo and a pale disc.
vec3 ring(vec2 P, vec2 c, vec2 r, float I, float seed, float T, float arc) {
    if (I <= 0.001) return vec3(0.0);
    vec2 q = (P - c) / r;
    float d = length(q);
    if (d > 1.5) return vec3(0.0);
    float side = smoothstep(-0.04, 0.04, q.y * arc);
    float ang = atan(q.y, q.x + 1e-6);
    vec2 an = vec2(cos(ang), sin(ang)) * 1.6;
    float wob = 0.075 * fbm(an * 1.5 + seed + T * 2.0, 3) + 0.014 * fbm(an * 5.0 + seed * 3.0 - T * 3.0, 2);
    float grad = length(q / r) / max(d, 1e-3);
    float dp = (d - 1.0 - wob) / grad;                       // signed pixels from the ring line
    float dp2 = (d - 0.93 - 1.6 * wob) / grad;
    float broken = smoothstep(-0.25, 0.15, fbm(an * 2.2 + seed * 5.0 + T * 2.0, 3));
    float thick = (1.7 + 2.2 * smoothstep(-0.2, 0.9, q.y / max(d, 1e-3))) * (0.6 + 0.6 * broken);
    float dp3 = (d - 0.86 - 2.4 * wob) / grad;                // third, faintest stroke: the ring is drawn, not ruled
    // the drawn ring: three continuous glowing strokes (the strip), and wider bands round them where the
    // particles run. Both are used: the strokes give the ring its body, the dashes give it grain and motion.
    float core = exp(-dp * dp / (thick * thick)) + 0.5 * broken * exp(-dp2 * dp2 / 5.0) + 0.28 * (1.0 - broken) * exp(-dp3 * dp3 / 4.0);
    float band = exp(-dp * dp / (thick * thick * 2.4)) + 0.5 * broken * exp(-dp2 * dp2 / 14.0) + 0.28 * (1.0 - broken) * exp(-dp3 * dp3 / 11.0);
    float shed = 0.30 * exp(-max(dp, 0.0) / 26.0) * step(0.0, dp) + 0.12 * exp(-abs(dp) / 18.0);
    vec2 u = vec2(ang * r.x, dp);
    float dirn = seed > 3.0 ? -1.0 : 1.0;
    float p = strands(u, 2.2, 14.0, 230.0 * dirn, seed, T) + strands(u + vec2(0.0, 1.1), 3.2, 24.0, 380.0 * dirn, seed + 7.0, T)
            + 0.6 * strands(u, 5.0, 40.0, 160.0 * dirn, seed + 13.0, T);
    float grains = motes(u * vec2(1.0, 0.7) + vec2(T * 150.0 * dirn, 3.0), 8.0, seed + 19.0, T) + motes(u + vec2(T * 90.0 * dirn, 17.0), 14.0, seed + 23.0, T);
    float halo = exp(-abs(dp) / 14.0) * 0.6 + exp(-abs(dp) / 40.0) * 0.12;
    float disc = (1.0 - smoothstep(0.92, 1.0, d)) * (0.07 + 0.10 * fbm(an * 3.0 * d + seed, 3) + 0.22 * d * d * d);
    vec3 ink = vec3(0.42, 0.30, 1.0);                                                    // blue-violet, not white
    float pk = PARTICLES;
    return (FX_WHITE * (core * 0.45 + pk * band * p * 0.55) + ink * (core * 1.0 + pk * (band * p * 1.3 + shed * grains * 1.8)) + FX_VIOLET * halo * 1.4
          + vec3(0.46, 0.38, 0.85) * disc) * I * side;
}

// Light column on the stack axis: a continuous violet shaft with its brighter bands (the strip), and riding in it
// dashes rushing upward in thin vertical lanes plus round grains spilling out of its sides (the particles).
vec3 beam(vec2 P, float I, float T, float yTop, float yBot) {
    float xs = P.x - 407.0 - 7.0 * jitter2(T, 11.0, 31.0).x * I + 6.0 * sin(P.y * 0.03 + T * 9.0);
    float x = abs(xs);
    float streak = 0.35 + 0.65 * smoothstep(-0.10, 0.30, fbm(vec2(P.x * 0.10, P.y * 0.007 + T * 5.0), 4));   // the shaft's bands
    float body = (1.0 - smoothstep(20.0, 44.0, x)) * streak;
    float fringe = 0.25 * exp(-x / 55.0);
    float v = smoothstep(yTop - 40.0, yTop + 10.0, P.y) * (1.0 - smoothstep(yBot - 30.0, yBot, P.y));
    vec2 u = vec2(-P.y, xs);                                                              // along = up
    float p = strands(u, 2.6, 20.0, 760.0, 3.0, T) + strands(u + vec2(0.0, 1.3), 3.6, 34.0, 1100.0, 5.0, T) + 0.7 * strands(u, 6.0, 60.0, 560.0, 9.0, T);
    float grains = motes(vec2(P.x, P.y + 420.0 * T), 7.0, 11.0, T) + motes(vec2(P.x + 9.0, P.y + 300.0 * T), 13.0, 15.0, T);
    vec3 shaft = vec3(0.26, 0.14, 1.0) * body * 0.95 + FX_WHITE * body * streak * 0.12 * I * I;         // the strip
    vec3 dust = (vec3(0.30, 0.18, 1.0) * 1.25 + FX_WHITE * (0.15 + 0.40 * I)) * (body * p * 1.05 + fringe * grains);   // the particles
    vec3 c = shaft + dust * PARTICLES;
    return c * I * v;
}

// One faceted chunk. Returns (coverage, shade 0..1).
vec2 chunk(vec2 p, float size, float seed, float spin, float px) {
    float r = polyRadius(rot2(seed * 2.4 + spin) * p * vec2(1.0, 1.0 + 0.5 * fract(seed * 0.37)), 7.0, seed, 0.35) / size;
    float a = 1.0 - smoothstep(1.0 - px / size, 1.0 + px / size, r);
    float facet = 0.5 + 0.5 * dot(normalize(p + 1e-4), vec2(-0.6, -0.8));     // lit from the upper left
    return vec2(a, facet * (0.6 + 0.4 * r));
}

// Debris thrown out around the top bowl. `layer` 0 = clouds of pale chunks beside the bowl, 1 = dark pebble belt
// under it, 2 = small bits flung above it.
vec4 debris(vec2 P, float T, float topDy, float px, int layer) {
    float A = clamp(key(K_DEB_A, T), 0.0, 1.0), S = clamp(key(K_DEB_S, T), 0.0, 1.0), B = clamp(key(K_BITS, T), 0.0, 1.0);
    vec3 col = vec3(0.0);
    float cov = 0.0;
    int n = layer == 0 ? 130 : (layer == 1 ? 20 : 34);
    for (int i = 0; i < n; i++) {
        float fi = float(i) + 31.0 * float(layer);
        vec3 h = hash32(vec2(fi, 3.0)), g = hash32(vec2(fi, 9.0));
        vec2 c;
        float size, alpha, dark, spin = 0.0;
        if (layer == 0) {
            // the blast: every chunk leaves the gap under the top bowl on its own heading and speed, slows in the
            // air, falls, and stays wherever it lands on the plain until the loop clears it
            float sgn = i % 2 == 0 ? -1.0 : 1.0;
            float age = T - (0.20 + 0.16 * g.z);
            float a = max(age, 0.0);
            float th = mix(-1.45, 0.40, h.y);                                       // up and out, a few low and flat
            float travel = (150.0 + 820.0 * g.x * g.x) * (1.0 - exp(-1.8 * a)) / 1.8;
            c = vec2(408.0 + sgn * (95.0 + 70.0 * h.x), 312.0 - 30.0 * h.y) + vec2(sgn * cos(th), sin(th)) * travel + vec2(0.0, 330.0 * a * a);
            float groundY = 430.0 + 330.0 * h.z;                                    // where on the plain this one comes down
            float landed = step(groundY, c.y);
            c.y = min(c.y, groundY);
            spin = (1.0 - landed) * a * 14.0 * (g.z - 0.5);
            size = 2.0 + 14.0 * g.y * g.y * g.y;
            alpha = smoothstep(0.0, 0.03, age) * (1.0 - smoothstep(1.14, 1.40, T)) * mix(1.0, 0.8, landed) * max(A, 0.6);
            dark = step(0.80, h.z);
        } else if (layer == 1) {
            c = vec2(300.0 + 220.0 * h.x, 345.0 + 0.72 * topDy + 22.0 * (h.y - 0.5) + 8.0 * sin(T * 5.0 + fi)) + jitter2(T, 7.0, fi) * 12.0 * B;
            size = 3.0 + 6.0 * g.y;
            alpha = B * smoothstep(0.0, 0.25, B - 0.6 * g.z);
            dark = 1.0;
        } else {
            float tt = clamp(T - 0.16 - 0.10 * g.z, 0.0, 2.0);
            c = vec2(408.0 + (h.x - 0.5) * (150.0 + 900.0 * tt * g.x), 190.0 + topDy - (220.0 + 520.0 * h.y) * tt + 430.0 * tt * tt);
            spin = tt * 20.0 * (g.z - 0.5);
            size = 1.5 + 4.5 * g.y * g.y;
            alpha = B * step(0.001, tt);
            dark = 0.0;
        }
        vec2 p = P - c;
        if (alpha < 0.01 || dot2(p) > 12.0 * size * size + 900.0) continue;
        vec2 k = chunk(p, size, fi, spin, px);
        vec3 pale = mix(vec3(0.42, 0.34, 0.70), vec3(0.93, 0.89, 0.98), smoothstep(0.2, 0.5, k.y));
        vec3 dk = mix(vec3(0.035, 0.025, 0.11), vec3(0.20, 0.15, 0.40), smoothstep(0.45, 0.75, k.y));
        vec3 cc = mix(pale, dk, dark);
        float glowA = (1.0 - dark) * alpha * 0.14 * exp(-dot2(p) / (size * size * 3.0));     // soft bloom on pale chunks
        col = col * (1.0 - k.x * alpha) + cc * k.x * alpha + FX_WHITE * glowA * (1.0 - k.x);
        cov = cov + (k.x * alpha) * (1.0 - cov);
    }
    return vec4(col, cov);
}

// Sparks: hot streaks spat out of the stack in every direction as it bursts, each on its own arc under gravity,
// dying in flight. Drawn as the short path covered in the last 1/30 s, so fast ones are long.
vec3 sparks(vec2 P, float T) {
    vec3 col = vec3(0.0);
    for (int i = 0; i < 100; i++) {
        float fi = float(i);
        vec3 h = hash32(vec2(fi, 23.0)), g = hash32(vec2(fi, 29.0));
        float life = 0.55 + 0.60 * g.y;
        float age = T - (0.16 + 0.42 * h.z * h.z);
        if (age < 0.0 || age > life) continue;
        float a = -1.5708 + (h.x - 0.5) * 4.6, v = 220.0 + 620.0 * g.x;           // mostly upward, some flat and down
        vec2 o = vec2(408.0 + (g.z - 0.5) * 150.0, 250.0 + 160.0 * h.y), dir = vec2(cos(a), sin(a));
        float a0 = max(age - 0.085, 0.0);                                         // a long tail: readable frame to frame
        vec2 p1 = o + dir * v * age * (1.0 - 0.4 * age / life) + vec2(0.0, 520.0 * age * age);
        vec2 p0 = o + dir * v * a0 * (1.0 - 0.4 * a0 / life) + vec2(0.0, 520.0 * a0 * a0);
        float d = sdSegment(P, p0, p1);
        float fade = 1.0 - age / life;
        col += ((FX_WHITE * 0.45 + vec3(0.42, 0.30, 1.0)) * exp(-d * d / (0.6 + 1.5 * fade)) + FX_VIOLET * 0.6 * exp(-d / 6.0)) * fade;
    }
    return col;
}

// Small four-point glints near the rims.
vec3 glints(vec2 P, float T, float topDy, float midDy, float I) {
    vec3 col = vec3(0.0);
    for (int i = 0; i < 9; i++) {
        float fi = float(i);
        vec3 h = hash32(vec2(fi, 21.0));
        float top = step(0.5, h.z);
        vec2 c = mix(vec2(411.0 + (h.x - 0.5) * 300.0, 352.0 + midDy + 10.0 * h.y),
                     vec2(405.0 + (h.x - 0.5) * 240.0, 200.0 + topDy + 14.0 * h.y), top);
        vec2 p = abs(P - c);
        float tw = 0.5 + 0.5 * sin(T * (9.0 + 6.0 * h.y) + fi * 2.1);
        float s = (2.0 + 4.0 * h.y) * (0.5 + tw);
        float star = exp(-dot2(p) / (s * s)) + 0.6 * exp(-(p.x * p.y * 3.0 + p.x + p.y) / s);
        col += FX_WHITE * star * tw * (0.35 + 0.65 * I);
    }
    return col;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    float scale = REF / iResolution.y;
    vec2 P = vec2(fragCoord.x - 0.5 * iResolution.x, iResolution.y - fragCoord.y) * scale + vec2(0.5 * REF, 0.0);
    float px = scale;

    float T = FREEZE_TIME >= 0.0 ? FREEZE_TIME : mod(iTime, LOOP);
#if GIF_STEPPED
    T = floor(T / 0.12) * 0.12;
#endif
    // camera shake: the burst kicks the frame about (fast rattle on a slower sway, a hair of roll), settling as it
    // dies; and the whole drawing boils a little, redrawn twelve times a second
    float kick = clamp(key(K_AMB, T), 0.0, 1.2);
    P += jitter2(T, 18.0, 5.0) * (0.8 + SHAKE * 13.0 * kick) + jitter2(T, 7.0, 6.0) * (1.2 + SHAKE * 10.0 * kick);
    P = vec2(408.0, 450.0) + rot2(0.020 * SHAKE * kick * jitter2(T, 11.0, 7.0).x) * (P - vec2(408.0, 450.0));
    float boilSeed = floor(T * 12.0) * 3.7;
    P += 1.3 * vec2(fbm(P * 0.03 + boilSeed, 2), fbm(P * 0.03 + 7.0 + boilSeed, 2));

    // ---- sky and distant land ----
    vec3 col = sky(P);
    float edgeN = 1.5 * fbm(vec2(P.x * 0.08, 2.0), 3);
    // far hills: pale, low-contrast shapes in the haze (measured silhouettes)
    float hFarC = profile4(P.x, vec2(330.0, 216.0), vec2(385.0, 190.0), vec2(520.0, 193.0), vec2(560.0, 216.0));
    col = mix(col, rgb(86.0, 77.0, 147.0), fillAA(hFarC - P.y, px) * 0.8);
    float hFarL = min(profile4(P.x, vec2(80.0, 214.0), vec2(98.0, 196.0), vec2(170.0, 195.0), vec2(275.0, 211.0)),
                      profile4(P.x, vec2(180.0, 214.0), vec2(216.0, 199.0), vec2(250.0, 203.0), vec2(300.0, 220.0))) + edgeN;
    vec3 hillL = mix(rgb(76.0, 65.0, 130.0), rgb(72.0, 61.0, 125.0), ramp(195.0, 220.0, P.y));
    hillL *= 1.0 + 0.06 * smoothstep(-0.1, 0.2, fbm(P * vec2(0.03, 0.08) + 6.0, 3));                // soft brushed facets
    col = mix(col, hillL, fillAA(hFarL - P.y, px));
    float hFarR = min(profile4(P.x, vec2(500.0, 214.0), vec2(540.0, 193.0), vec2(590.0, 187.0), vec2(603.0, 187.0)),
                      profile4(P.x, vec2(603.0, 187.0), vec2(625.0, 192.0), vec2(660.0, 197.0), vec2(700.0, 215.0))) + edgeN;
    vec3 hillR = mix(rgb(68.0, 60.0, 120.0), rgb(64.0, 56.0, 116.0), ramp(190.0, 225.0, P.y));
    hillR *= 1.0 - 0.10 * smoothstep(0.0, 0.25, fbm(P * vec2(0.04, 0.1) + 2.0, 3));                // shaded gullies
    hillR *= 1.0 - 0.16 * smoothstep(-2.0, 6.0, P.x - 597.0 - 0.4 * (P.y - 188.0));                 // shaded side right of the peak
    col = mix(col, hillR, fillAA(hFarR - P.y, px));

    // distant flats between the hills and the plain: a dark wet band with pale salt streaks (measured)
    float flatM = fillAA(219.0 - P.y, px * 2.0);
    vec2 Fw = P + vec2(0.0, 1.2 * fbm(vec2(P.x * 0.03, 1.0), 2));
    vec3 flatC = mix(rgb(60.0, 51.0, 108.0), rgb(78.0, 66.0, 132.0), ramp(100.0, 260.0, P.x) * ramp(820.0, 480.0, P.x));
    float fp = max(ramp(105.0, 130.0, Fw.x) * ramp(270.0, 240.0, Fw.x) * (1.0 - smoothstep(2.0, 4.0, abs(Fw.y - 223.0))),
                   ramp(180.0, 200.0, Fw.x) * ramp(300.0, 260.0, Fw.x) * (1.0 - smoothstep(4.0, 7.0, abs(Fw.y - 230.0))));
    fp = max(fp, ramp(530.0, 560.0, Fw.x) * (1.0 - smoothstep(2.5, 4.5, abs(Fw.y - 239.0))));
    flatC = mix(flatC, rgb(103.0, 83.0, 155.0), fp * (0.8 + 0.2 * smoothstep(-0.2, 0.2, fbm(P * vec2(0.05, 0.3), 2))));
    col = mix(col, flatC, flatM);

    // near mesas (drawn over the far plain)
    // left: flat top, steep right flank, a low dark shelf running out along the horizon
    float hL = min(profile4(P.x, vec2(-10.0, 176.0), vec2(45.0, 177.0), vec2(62.0, 188.0), vec2(82.0, 203.0)),
                   profile4(P.x, vec2(82.0, 203.0), vec2(100.0, 211.0), vec2(112.0, 221.0), vec2(125.0, 226.0)));
    hL = min(hL, profile4(P.x, vec2(125.0, 226.0), vec2(170.0, 229.0), vec2(195.0, 234.0), vec2(218.0, 242.0))) + edgeN * 0.6;
    float mL = fillAA(hL - P.y, px);
    vec3 mesaL = mix(rgb(47.0, 41.0, 91.0), rgb(52.0, 45.0, 99.0), ramp(185.0, 238.0, P.y));
    mesaL *= 1.0 + 0.12 * smoothstep(-0.1, 0.25, fbm(P * vec2(0.025, 0.06), 3)) * ramp(60.0, 0.0, P.x - 20.0);
    mesaL = mix(mesaL, rgb(64.0, 55.0, 112.0), 0.5 * (1.0 - smoothstep(0.0, 2.5, P.y - hL)) * step(120.0, P.x)); // lit shelf lip
    col = mix(col, mesaL, mL);
    // right: flat top near y 141, lit pink-violet face cut by dark vertical gullies, foot ending at y ~234
    float hR = min(profile4(P.x, vec2(530.0, 225.0), vec2(600.0, 223.0), vec2(630.0, 214.0), vec2(650.0, 204.0)),
                   profile4(P.x, vec2(650.0, 204.0), vec2(670.0, 192.0), vec2(690.0, 165.0), vec2(712.0, 143.0)));
    hR = min(hR, profile4(P.x, vec2(712.0, 143.0), vec2(740.0, 141.0), vec2(790.0, 140.0), vec2(830.0, 141.0))) + edgeN * 0.7;
    float mR = fillAA(hR - P.y, px) * fillAA(P.y - 234.5 - 1.5 * fbm(vec2(P.x * 0.05, 3.0), 2), px);
    vec3 mesa = mix(rgb(84.0, 63.0, 119.0), rgb(80.0, 61.0, 116.0), ramp(150.0, 232.0, P.y));
    mesa *= 1.0 + 0.08 * smoothstep(-0.15, 0.2, fbm(P * vec2(0.05, 0.02) + 1.0, 3));                   // brushed light
    vec2 Mw = P + vec2(5.0 * fbm(P * vec2(0.05, 0.09), 3), 0.0);
    float gul = sdSegment(Mw, vec2(738.0, 147.0), vec2(718.0, 212.0)) - mix(1.5, 9.0, ramp(212.0, 147.0, P.y));
    gul = min(gul, sdSegment(Mw, vec2(770.0, 147.0), vec2(748.0, 208.0)) - mix(1.0, 6.5, ramp(208.0, 147.0, P.y)));
    gul = min(gul, sdSegment(Mw, vec2(814.0, 147.0), vec2(800.0, 215.0)) - mix(1.5, 10.0, ramp(215.0, 147.0, P.y)));
    gul = min(gul, sdSegment(Mw, vec2(710.0, 153.0), vec2(672.0, 205.0)) - 1.2);                           // flank crease
    gul = min(gul, sdSegment(Mw, vec2(752.0, 150.0), vec2(744.0, 175.0)) - 1.5);
    gul = min(gul, sdSegment(Mw, vec2(723.0, 184.0), vec2(717.0, 200.0)) - 2.0);
    gul = min(gul, sdSegment(Mw, vec2(706.0, 204.0), vec2(711.0, 212.0)) - 2.0);
    gul = min(gul, sdSegment(Mw, vec2(600.0, 230.0), vec2(612.0, 226.0)) - 2.0);
    gul = min(gul, sdSegment(Mw, vec2(628.0, 218.0), vec2(640.0, 226.0)) - 2.0);
    gul = min(gul, sdSegment(Mw, vec2(548.0, 228.0), vec2(578.0, 228.0)) - 1.5);
    gul = min(gul, sdSegment(Mw, vec2(698.0, 221.0), vec2(704.0, 220.0)) - 1.5);
    gul = min(gul, sdSegment(Mw, vec2(728.0, 223.0), vec2(734.0, 225.0)) - 1.5);
    mesa = mix(mesa, rgb(44.0, 35.0, 80.0), 0.9 * fillAA(gul, px * 1.5));
    mesa = mix(mesa, rgb(62.0, 49.0, 102.0), 0.35 * (1.0 - smoothstep(-1.0, 4.0, gul)));                 // soft halo round each gully
    col = mix(col, mesa, mR);

    // the plain
    col = mix(col, ground(P, px), fillAA(244.0 - 0.004 * P.x - P.y, px * 2.0));

    // ---- timeline ----
    // every envelope breathes on its own random flicker, and the loose bowls and rings rattle in the blast
    float topDy = key(K_TOP_DY, T), midDy = key(K_MID_DY, T);
    float amb = clamp(key(K_AMB, T), 0.0, 1.2) * (0.90 + 0.20 * flick(T, 6.0, 1.0));
    float bI = clamp(key(K_BEAM, T), 0.0, 1.2) * (0.86 + 0.24 * flick(T, 7.0, 2.0));
    float raI = clamp(key(K_RA_I, T), 0.0, 1.0) * (0.85 + 0.25 * flick(T, 6.0, 3.0));
    float rbI = clamp(key(K_RB_I, T), 0.0, 1.0) * (0.85 + 0.25 * flick(T, 5.0, 4.0));
    vec2 jTop = jitter2(T, 11.0, 41.0) * 6.0 * kick, jMid = jitter2(T, 9.0, 42.0) * 4.0 * kick;
    topDy += jTop.y;
    midDy += jMid.y;
    float raR = key(K_RA_RX, T) * (1.0 + 0.035 * jitter2(T, 14.0, 43.0).x), rbR = key(K_RB_RX, T) * (1.0 + 0.035 * jitter2(T, 12.0, 44.0).x);
    vec2 raC = vec2(408.0, key(K_RA_CY, T)) + jitter2(T, 14.0, 45.0) * vec2(9.0, 5.0), rbC = vec2(408.0, 460.0) + jitter2(T, 12.0, 46.0) * vec2(9.0, 5.0);
    vec2 raRad = vec2(raR, raR * (0.18 + 0.02 * jitter2(T, 10.0, 47.0).x)), rbRad = vec2(rbR, rbR * (0.22 + 0.02 * jitter2(T, 10.0, 48.0).x));

    // the burst lights the plain and the air around the stack: violet light added, strongest low and to the right
    float near = exp(-dot2((P - vec2(470.0, 600.0)) / vec2(520.0, 330.0)));
    col += vec3(0.08, 0.034, 0.21) * amb * (0.12 + 0.88 * near * smoothstep(225.0, 300.0, P.y));
    // shock ripples running out over the plain from the base
    float rl = length((P - vec2(408.0, 676.0)) / vec2(1.0, 0.30)) + 14.0 * fbm(P * 0.015, 3);
    float wave = smoothstep(0.72, 1.0, sin(rl * 0.07 - T * 13.0)) * ramp(205.0, 250.0, rl) * ramp(450.0, 290.0, rl);
    wave *= smoothstep(-0.15, 0.25, fbm(P * 0.018 + 5.0, 3));
    col += (FX_WHITE * 0.10 + FX_VIOLET * 0.12) * wave * amb * step(246.0, P.y);
    // glow in the air along the stack axis
    float axisD = length(vec2(P.x - 404.0, max(abs(P.y - (395.0 + 0.5 * topDy)) - (205.0 - 0.5 * topDy), 0.0)));
    col += FX_VIOLET * amb * 0.14 * exp(-axisD / 80.0) + FX_WHITE * amb * amb * 0.06 * exp(-axisD / 45.0);

    // ---- far halves of the rings, bowls back to front ----
    // The beam runs on the stack axis, THROUGH the bowls: it rises from each bowl's floor centre in front of that
    // bowl's far wall, and is hidden only where a bowl's outer wall is in front of the axis. `vis` tracks that.
    col += ring(P, raC, raRad, raI, 1.0, T, -1.0) + ring(P, rbC, rbRad, rbI, 5.0, T, -1.0);

    float glow = bI, vis = 1.0, R, floorY;
    vec4 b;
    vec4 dbr = debris(P, T, topDy, px, 1);
    col = col * (1.0 - dbr.a) + dbr.rgb;
    R = 166.0 * key(K_MID_SC, T);
    b = bowl(P, vec2(411.0 + jMid.x, 389.0 + midDy), R, 0.27, 4.0, vec4(0.55, 0.39, 0.82, 0.16), vec3(0.38, 0.38, 0.45), vec3(0.42, 0.22, -0.02), glow, px);
    col = col * (1.0 - b.a) + b.rgb;
    floorY = 389.0 + midDy + 0.38 * 0.963 * R;
    if (gPart > 2.5) vis = 1.0 - smoothstep(floorY - 5.0, floorY + 5.0, P.y); else if (gPart > 0.5) vis = 0.0;
    b = bowl(P, vec2(408.0, 548.0), 208.0, 0.30, 7.0, vec4(0.44, 0.74, 0.86, 0.11), vec3(0.30, 0.46, 1.0), vec3(0.40, -0.02, 0.08), glow, px);
    col = col * (1.0 - b.a) + b.rgb;
    floorY = 548.0 + 0.30 * 0.954 * 208.0;
    if (gPart > 2.5) vis = 1.0 - smoothstep(floorY - 5.0, floorY + 5.0, P.y); else if (gPart > 0.5) vis = 0.0;
    col += ring(P, rbC, rbRad, rbI, 5.0, T, 1.0) + ring(P, raC, raRad, raI, 1.0, T, 1.0);
    dbr = debris(P, T, topDy, px, 0);
    col = col * (1.0 - dbr.a) + dbr.rgb;
    R = 127.0 * key(K_TOP_SC, T);
    b = bowl(P, vec2(405.0 + jTop.x, 224.0 + topDy), R, 0.25, 1.0, vec4(0.63, 0.28, 0.80, 0.17), vec3(0.42, 0.34, 0.0), vec3(0.40, 0.12, 0.03), glow, px);
    col = col * (1.0 - b.a) + b.rgb;
    floorY = 224.0 + topDy + 0.42 * 0.968 * R;
    if (gPart > 2.5) vis = 1.0 - smoothstep(floorY - 5.0, floorY + 5.0, P.y); else if (gPart > 0.5) vis = 0.0;
    col += beam(P, bI, T, floorY, 614.0) * vis;       // starts inside the top bowl, ends on the bottom bowl's floor
    dbr = debris(P, T, topDy, px, 2);
    col = col * (1.0 - dbr.a) + dbr.rgb;
    col += glints(P, T, topDy, midDy, amb);
    col += sparks(P, T);

    // highlight roll-off: the burst eases into white the way the reference does instead of clipping
    col = min(col, vec3(0.7)) + 0.3 * (1.0 - exp(-max(col - 0.7, 0.0) / 0.3));

    col = linearToSrgb(clamp(col, 0.0, 1.0)) + ditherTPDF(fragCoord, iFrame);
    fragColor = vec4(col, 1.0);
}
