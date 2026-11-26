// Vortex bay: a blue energy vortex on the steel floor of a dark sci-fi bay. It opens as a twisting
// fountain whose ribbon flares out and falls to the floor, becomes an expanding shock ring, and dies back to
// ripples, sparkles and an ember. Recreated from the 12-frame reference. Single pass, no textures.
//
// All layout constants are in REFERENCE PIXELS: origin top-left, x right, y down, REF units tall.
//
// Breakdown (a video model for the order of events, tools for every number):
//   Layers, back to front: bulkhead wall -> steel floor (plates, seams, grime, two amber vents) -> blue light the
//   vortex throws on floor and wall -> floor ripples -> shock ring -> fountain ribbon -> shards and sparkles ->
//   core and flare.
//   Depth: everything lies on the floor plane except the fountain, which rises above it and leans right; nothing
//   passes through a solid. All energy layers are additive, so their order among themselves does not matter.
//   Loop: not seamless. Frame 12 is the dark ember and frame 1 is the full burst, so keys are held, not wrapped.

#define DEBUG_MODE 0      // 0 final | 3 floor polar coordinates | 5 static scene only
#define GIF_STEPPED 0     // 1 = hold each reference frame time, 0 = continuous motion
#define FREEZE_TIME -1.0  // >= 0 freezes the loop at that time in seconds
#define LIGHTMAP 1        // 0 = no painted light map (tools/refit.py renders with this off to fit it)
#define SHAKE 1.0         // camera shake from the blast: 0 = locked camera, 1 = default, 2 = violent
#define PARTICLES 0.25    // strength of the particles riding the strip: 0 = strip only, 1 = the full particle overlay

const int NF = 12;               // reference frames
const float DT = 0.12;           // seconds per reference frame
const float LOOP = float(NF) * DT;
const float REF = 816.0;

const vec2 CORE = vec2(402.0, 416.0);   // vortex centre on the floor
const float FLOOR_K = 0.48;             // a floor circle's height / width on screen

// ---- helpers -----------------------------------------------------------------------------------------------------------
vec3 rgb(float r, float g, float b) { return srgbToLinear(vec3(r, g, b) / 255.0); }
float ramp(float a, float b, float x) { return clamp((x - a) / (b - a), 0.0, 1.0); }
float sq(float x) { return x * x; }     // never pow(x, 2.0): pow of a negative base is undefined in GLSL ES

// Randomness without state: a value that jumps to a new random target `rate` times a second and eases between.
vec2 jitter2(float T, float rate, float seed) {
    float t = T * rate, i = floor(t), u = smoothstep(0.0, 1.0, fract(t));
    return mix(hash22(vec2(i, seed)), hash22(vec2(i + 1.0, seed)), u) * 2.0 - 1.0;
}
float flick(float T, float rate, float seed) { return jitter2(T, rate, seed).x * 0.5 + 0.5; }

// Wall / floor boundary, measured on frame 12: the bay's far corner sits near x = 240; the right wall's foot lies below
// its lit trim strip.
float wallY(float x) {
    if (x < 167.0) return mix(178.0, 123.0, x / 167.0);
    if (x < 246.0) return mix(123.0, 114.0, (x - 167.0) / 79.0);
    return 114.0 + 0.13 * (x - 246.0);                                // along the floor's lip, under centre and right walls
}

float polyline(vec2 p, vec2 a, vec2 b, vec2 c, vec2 d, vec2 e, int n) {
    float r = sdSegment(p, a, b);
    if (n > 2) r = min(r, sdSegment(p, b, c));
    if (n > 3) r = min(r, sdSegment(p, c, d));
    if (n > 4) r = min(r, sdSegment(p, d, e));
    return r;
}

// Signed distance to a quad given in order (exact, so insets and outlines stay even; no seam along a diagonal).
float sdQuad(vec2 p, vec2 a, vec2 b, vec2 c, vec2 d) {
    vec2 v[4] = vec2[4](a, b, c, d);
    float dd = dot(p - a, p - a), s = 1.0;
    for (int i = 0; i < 4; i++) {
        int j = (i + 3) % 4;
        vec2 e = v[j] - v[i], w = p - v[i];
        vec2 q = w - e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
        dd = min(dd, dot(q, q));
        bvec3 cond = bvec3(p.y >= v[i].y, p.y < v[j].y, e.x * w.y > e.y * w.x);
        if (all(cond) || all(not(cond))) s = -s;
    }
    return s * sqrt(dd);
}

// ---- timeline ----------------------------------------------------------------------------------------------------------
// One key per reference frame. The loop pops from the ember straight back to the burst, so the spline holds its
// end keys instead of wrapping.
const float K_GLOW[NF]   = float[NF](0.95, 1.00, 0.62, 0.46, 0.36, 0.32, 0.27, 0.19, 0.10, 0.05, 0.03, 0.00);  // blue wash on the floor
const float K_CORE[NF]   = float[NF](1.00, 1.00, 0.95, 0.92, 0.90, 0.82, 0.74, 0.60, 0.44, 0.34, 0.27, 0.22);
const float K_RIP[NF]    = float[NF](1.00, 1.00, 0.90, 0.80, 0.75, 0.60, 0.42, 0.26, 0.12, 0.06, 0.04, 0.03);
const float K_FOUNT[NF]  = float[NF](1.00, 1.00, 0.45, 0.06, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00);  // fountain ribbon
const float K_FOUNT_H[NF] = float[NF](1.00, 0.95, 0.40, 0.10, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00); // its height
const float K_FOUNT_R[NF] = float[NF](1.00, 1.07, 1.24, 1.32, 1.35, 1.35, 1.35, 1.35, 1.35, 1.35, 1.35, 1.35); // its spread
const float K_RING_R[NF] = float[NF](240.0, 288.0, 376.0, 404.0, 412.0, 418.0, 424.0, 428.0, 430.0, 430.0, 430.0, 430.0);
const float K_RING_I[NF] = float[NF](0.00, 0.30, 1.00, 0.95, 0.55, 0.26, 0.12, 0.04, 0.00, 0.00, 0.00, 0.00);
const float K_ARCS[NF]   = float[NF](0.50, 0.55, 0.45, 0.45, 0.70, 0.80, 0.65, 0.40, 0.14, 0.06, 0.04, 0.03);  // loose arcs on the disc
const float K_SHARD[NF]  = float[NF](1.00, 1.00, 0.85, 0.65, 0.40, 0.25, 0.12, 0.06, 0.04, 0.03, 0.03, 0.03);
const float K_SPARK[NF]  = float[NF](0.20, 0.20, 0.25, 0.35, 0.50, 0.65, 0.80, 0.90, 0.85, 0.70, 0.55, 0.45);
const float K_FLARE[NF]  = float[NF](0.00, 0.00, 0.00, 0.00, 0.00, 0.20, 0.65, 0.70, 0.30, 0.65, 0.60, 0.60);  // horizontal lens streak

float key(float k[NF], float T) {
    float f = clamp(T / DT, 0.0, float(NF) - 0.001);
    int i = int(floor(f));
    float u = fract(f);
    float p0 = k[max(i - 1, 0)], p1 = k[i], p2 = k[min(i + 1, NF - 1)], p3 = k[min(i + 2, NF - 1)];
    return p1 + 0.5 * u * (p2 - p0 + u * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + u * (3.0 * (p1 - p2) + p3 - p0)));
}

// ---- painted light map (generated; identity until tools/refit.py has run) ---------------------------------------------
//#include "lightmap.glsl"

vec3 lightMap(vec2 P) {
#if LIGHTMAP
    return lightMapRaw(P);
#else
    return vec3(1.0);
#endif
}

// ---- static scene ------------------------------------------------------------------------------------------------------
// Every edge below is a line measured on frame 12 (reference pixels); tones are probe colours, then broken by grime.
vec3 wall(vec2 P, float px) {
    // Bulkhead in perspective: a left wall with stepped lower panels, a column and black recess at the corner, a centre
    // wall with a pale lower panel and a hatch, a dark pillar, and a right wall with a lit window over a trim strip.
    vec2 Q = P + 1.2 * vec2(fbm(P * 0.06, 2), fbm(P * 0.06 + 4.0, 2));      // hand-drawn wobble on every edge
    float x = Q.x, y = Q.y, aa = px * 1.5;
    float dk = 1e5, lt = 1e5;                                             // distance to dark seams / pale bevels

    // left wall: dark top band, upper panels, paler stepped lower panels, a pale base trim, a dark plinth
    float yS = 28.0 - 0.10 * x, yL = 108.0 - 0.24 * x, yB = 165.0 - 0.25 * x;
    vec3 c = mix(rgb(24.0, 41.0, 70.0), rgb(21.0, 35.0, 60.0), ramp(60.0, 150.0, x));
    c = mix(c, rgb(18.0, 26.0, 46.0), fillAA(y - yS, aa));
    float u = x - 0.35 * (y - 110.0);                                     // across the slanted lower panel seams
    vec3 low = u < 22.0 ? rgb(28.0, 49.0, 84.0)
             : (u < 112.0 ? mix(rgb(33.0, 58.0, 98.0), rgb(25.0, 44.0, 76.0), ramp(30.0, 100.0, u)) : rgb(22.0, 36.0, 62.0));
    c = mix(c, low, fillAA(yL - y, aa));
    c = mix(c, rgb(27.0, 46.0, 78.0), fillAA(yB - y, aa));
    c = mix(c, rgb(17.0, 27.0, 46.0), fillAA(yB + 6.0 - y, aa));
    float gL = x - 144.0 - 0.10 * y;                                      // > 0 past the corner column's shadow
    dk = min(dk, max(min(abs(y - yS), abs(y - yL)), gL));
    dk = min(dk, max(abs(x - 60.0), max(yS - y, y - yL)));
    dk = min(dk, max(min(abs(u - 22.0), abs(u - 112.0)), max(yL - y, y - yB)));
    dk = min(dk, max(abs(y - yB - 6.0), gL));
    lt = min(lt, max(min(abs(y - yL - 1.5), abs(y - yB - 1.0)), gL));
    lt = min(lt, max(abs(x - 62.0), max(yS - y, y - yL)));
    lt = min(lt, max(abs(u - 24.0), max(yL - y, y - yB)));

    // corner column: shadowed edge, a pale slanted strip on a base block, then the black recess
    float xs0 = 156.0 + 0.10 * y, xs1 = 179.0 + 0.12 * y;
    c = mix(c, rgb(16.0, 24.0, 42.0), fillAA(xs0 - 12.0 - x, aa));
    c = mix(c, rgb(22.0, 36.0, 62.0), fillAA(max(xs0 - x, y - 112.0), aa));
    c = mix(c, rgb(20.0, 32.0, 55.0), fillAA(max(max(xs0 - x, x - 206.0), abs(y - 119.0) - 7.0), aa));
    c = mix(c, rgb(14.0, 20.0, 35.0), fillAA(max(xs1 - x, y - 112.0), aa * 2.0));
    lt = min(lt, max(abs(x - xs0 - 1.0), y - 126.0));
    dk = min(dk, max(abs(x - xs0 + 1.0), y - 126.0));

    // centre wall: dark upper band paling to the right, lower panel pale beyond x ~ 487, slanted bottom edge, hatch
    float xL = 250.0 - 0.17 * y, y1 = 47.0 + 0.08 * (x - 258.0), yE = 102.0 + 0.115 * (x - 300.0);
    float cx = 636.0 - 0.04 * y - 0.0009 * y * y;                         // pillar's right edge reference
    float gC = max(xL - x, x - cx + 34.0);                                // > 0 off the centre wall
    vec3 cw = mix(rgb(18.0, 27.0, 47.0), rgb(26.0, 46.0, 79.0), ramp(400.0, 545.0, x));
    vec3 cl = mix(rgb(20.0, 31.0, 53.0), rgb(22.0, 36.0, 61.0), ramp(300.0, 460.0, x));
    cl = mix(cl, rgb(26.0, 46.0, 79.0), fillAA(487.0 + 6.0 * fbm(P * 0.04, 2) - x, px * 4.0));
    cw = mix(cw, cl, fillAA(y1 - y, aa));
    cw = mix(cw, mix(rgb(14.0, 20.0, 35.0), rgb(17.0, 25.0, 44.0), ramp(420.0, 500.0, x)), fillAA(yE - y, aa));
    float hatch = sdQuad(Q, vec2(535.0, 106.0), vec2(578.0, 110.0), vec2(578.0, 127.0), vec2(535.0, 123.0));
    cw = mix(cw, rgb(22.0, 38.0, 66.0), fillAA(hatch + 2.0, aa));
    c = mix(c, cw, fillAA(xL - x, aa));
    float onC = step(xL, x);
    dk = min(dk, max(abs(y - y1), gC));
    dk = min(dk, max(abs(y - yE), gC));
    dk = min(dk, max(abs(x - 380.0), max(y1 - y, y - yE)));
    dk = min(dk, max(abs(x - 408.0), max(30.0 - y, y - y1)));
    dk = min(dk, abs(hatch));
    dk = min(dk, max(abs(hatch + 4.0), 123.0 - y) + 1e5 * (1.0 - onC));
    lt = min(lt, max(abs(y - y1 - 1.5), gC));
    lt = min(lt, max(abs(x - xL - 1.5), y - yE));
    lt = min(lt, max(abs(y - yE + 1.5), max(380.0 - x, gC)));

    // pillar: a pale lit face and a dark shadowed strip, both bending left as they come down
    vec3 face = mix(rgb(26.0, 46.0, 78.0), rgb(23.0, 36.0, 61.0), ramp(60.0, 110.0, y));
    c = mix(c, face, fillAA(cx - 34.0 - x, aa));
    c = mix(c, rgb(16.0, 23.0, 41.0), fillAA(cx - 14.0 - x, aa));
    c = mix(c, rgb(15.0, 22.0, 38.0), fillAA(max(cx - 34.0 - x, 136.0 - y), aa));         // its dark base block
    dk = min(dk, abs(x - cx + 34.0));
    lt = min(lt, abs(x - cx + 32.0));

    // right wall: upper panels, a dark module with a louvred panel and the amber window, a lit trim strip below
    float y2 = 28.0 + 0.09 * (x - 640.0), y3 = 85.0 + 0.11 * (x - 640.0), yT = 147.0 + 0.122 * (x - 628.0);
    vec3 cr = mix(rgb(22.0, 35.0, 61.0), mix(rgb(22.0, 37.0, 63.0), rgb(27.0, 47.0, 79.0), ramp(680.0, 780.0, x)), fillAA(y2 - y, aa));
    cr = mix(cr, rgb(17.0, 26.0, 46.0), fillAA(y3 - y, aa));
    float louv = sdQuad(Q, vec2(648.0, 112.0), vec2(702.0, 118.0), vec2(702.0, 140.0), vec2(648.0, 134.0));
    float slat = abs(fract((y - 0.11 * (x - 648.0) - 121.0) / 5.0) - 0.5) * 5.0;
    cr = mix(cr, rgb(20.0, 30.0, 52.0), fillAA(louv + 1.5, aa));
    cr = mix(cr, rgb(13.0, 19.0, 33.0), strokeAA(slat, 0.7, px) * fillAA(louv + 3.0, aa) * step(121.0 + 0.11 * (x - 648.0), y));
    vec3 trim = mix(rgb(36.0, 60.0, 100.0), rgb(46.0, 50.0, 64.0), ramp(690.0, 750.0, x));
    cr = mix(cr, trim, fillAA(max(yT - y, y - yT - 7.0), aa));
    cr = mix(cr, rgb(16.0, 24.0, 42.0), fillAA(yT + 7.0 - y, aa));
    c = mix(c, cr, fillAA(cx + 8.0 - x, aa));
    float onR = step(cx + 8.0, x);
    dk = min(dk, max(abs(y - y2), cx + 8.0 - x));
    dk = min(dk, max(abs(y - y3), cx + 8.0 - x));
    dk = min(dk, abs(louv) + 1e5 * (1.0 - onR));
    dk = min(dk, max(abs(y - yT - 7.5), cx + 8.0 - x));
    lt = min(lt, max(abs(y - y2 - 1.5), cx + 8.0 - x));
    lt = min(lt, max(abs(y - y3 - 1.5), cx + 8.0 - x));
    lt = min(lt, max(abs(y - yT - 1.0), cx + 8.0 - x));

    // grime: broad blotches, rust-dark streaks running down from the seams, fine speckle
    float n = fbm(P * vec2(0.02, 0.05) + 5.0, 4);
    float streak = valueNoise(vec2(P.x * 0.07, P.y * 0.01 + 3.0)) * (0.6 + 0.8 * valueNoise(P * 0.03));
    c *= (1.0 + 0.20 * n) * (1.0 - 0.16 * smoothstep(0.5, 0.9, streak));
    c *= 1.0 - 0.14 * smoothstep(0.25, 0.55, fbm(P * 0.11 + 2.0, 3));
    c = mix(c, c * 0.42, strokeAA(dk, 0.6, px));
    c = mix(c, c * 1.35 + rgb(2.0, 4.0, 7.0), 0.55 * strokeAA(lt, 0.5, px));

    // amber window: grey sky above a hot band, a dark post in front, and its frame
    float win = sdQuad(Q, vec2(723.0, 105.0), vec2(816.0, 111.0), vec2(816.0, 162.0), vec2(712.0, 150.0));
    vec3 wc = mix(rgb(46.0, 48.0, 58.0), rgb(122.0, 92.0, 59.0), ramp(118.0, 146.0, y));
    wc = mix(wc, rgb(152.0, 114.0, 67.0), ramp(735.0, 800.0, x) * ramp(126.0, 150.0, y));
    wc *= 0.9 + 0.2 * fbm(P * 0.07, 3);
    wc = mix(wc, rgb(70.0, 55.0, 50.0), fillAA(max(abs(x - 766.0) - 4.0, 121.0 - y), aa));
    c = mix(c, wc, fillAA(win, aa));
    c = mix(c, rgb(20.0, 22.0, 32.0), strokeAA(win, 0.9, px));
    // light strips: the warm line along the left wall's base and the glow under the right wall's trim
    c += rgb(190.0, 112.0, 45.0) * 0.8 * strokeAA(sdSegment(Q, vec2(62.0, 151.0), vec2(128.0, 133.0)), 0.9, px);
    c += rgb(190.0, 120.0, 50.0) * 0.30 * ramp(650.0, 720.0, x) * exp(-sq((y - yT - 5.5) / 1.6));

    // the dark trim along the foot of the wall
    c = mix(c, rgb(13.0, 19.0, 34.0), 0.5 * (1.0 - smoothstep(0.0, 9.0, wallY(P.x) - P.y)));
    return c;
}

vec3 vent(vec3 c, vec2 P, vec2 a, vec2 b, vec2 d, vec2 e, vec2 fa, vec2 fb, vec2 fd, vec2 fe, float side, float k, float px) {
    // Recessed floor light: a bevelled steel frame (outer quad a-b-d-e, 5 px wide), the well opening inside it, the
    // lit amber floor of the well (quad fa-fb-fd-fe, measured), side walls catching its light, and spill on the plates.
    float o = sdQuad(P, a, b, d, e), f = sdQuad(P, fa, fb, fd, fe), wl = o + 5.0;
    vec2 m = 0.25 * (fa + fb + fd + fe);
    float sp = exp(-max(o, 0.0) / 24.0) * (0.5 + 0.5 * ramp(m.y - 40.0, m.y + 40.0, P.y));
    c += rgb(200.0, 140.0, 60.0) * 0.10 * k * sp;
    c = mix(c, rgb(16.0, 20.0, 30.0), 0.7 * strokeAA(o - 1.0, 0.8, px));                 // groove round the frame
    vec3 fr = mix(rgb(50.0, 64.0, 92.0), rgb(34.0, 42.0, 60.0), ramp(m.y - 30.0, m.y + 30.0, P.y));
    c = mix(c, fr, fillAA(o, px));
    // well walls: dim brown-grey, warming toward the floor and on the lit left side; a hot rim on the far edge
    float glow = exp(-max(f, 0.0) / 4.0);
    vec3 wc = mix(rgb(56.0, 52.0, 58.0), rgb(86.0, 64.0, 48.0), glow);
    wc = mix(wc, rgb(160.0, 118.0, 60.0), side * ramp(m.x - 10.0, m.x - 40.0, P.x) * (0.5 + 0.5 * glow));
    wc = mix(wc, rgb(190.0, 140.0, 70.0), (1.0 - side) * 0.8 * strokeAA(wl + 4.0, 3.0, px) * ramp(m.y + 10.0, m.y - 25.0, P.y + 0.5 * (P.x - m.x)));
    // the floor: amber, brighter toward the near edge, with a hot near rim
    vec3 fc = mix(rgb(148.0, 110.0, 64.0), rgb(200.0, 150.0, 72.0), ramp(m.y - 18.0, m.y + 14.0, P.y));
    fc *= 0.93 + 0.14 * fbm(P * 0.09, 3);
    fc = mix(fc, rgb(236.0, 184.0, 92.0), 0.7 * strokeAA(f + 2.0, 1.6, px) * ramp(m.y - 5.0, m.y + 15.0, P.y));
    vec3 well = mix(wc, fc, fillAA(f, px));
    well = mix(rgb(38.0, 46.0, 64.0), well, k);
    c = mix(c, well, fillAA(wl, px));
    return mix(c, rgb(18.0, 20.0, 28.0), 0.6 * strokeAA(wl, 0.6, px));                    // dark lip of the opening
}

// Plate seams traced from frame 12. x: every seam; y: the seams whose edge catches the light strongly.
vec2 floorSeams(vec2 W) {
    float s = polyline(W, vec2(348.0, 460.0), vec2(150.0, 697.0), vec2(43.0, 818.0), vec2(0.0), vec2(0.0), 3);
    s = min(s, polyline(W, vec2(-2.0, 643.0), vec2(150.0, 697.0), vec2(293.0, 741.0), vec2(400.0, 777.0), vec2(523.0, 818.0), 5));
    s = min(s, polyline(W, vec2(574.0, 571.0), vec2(709.0, 608.0), vec2(818.0, 634.0), vec2(0.0), vec2(0.0), 3));
    s = min(s, polyline(W, vec2(-2.0, 336.0), vec2(143.0, 368.0), vec2(313.0, 409.0), vec2(0.0), vec2(0.0), 3));
    s = min(s, polyline(W, vec2(70.0, 237.0), vec2(174.0, 259.0), vec2(261.0, 277.0), vec2(0.0), vec2(0.0), 3));
    s = min(s, polyline(W, vec2(565.0, 235.0), vec2(652.0, 170.0), vec2(0.0), vec2(0.0), vec2(0.0), 2));
    s = min(s, polyline(W, vec2(683.0, 263.0), vec2(818.0, 285.0), vec2(0.0), vec2(0.0), vec2(0.0), 2));
    s = min(s, polyline(W, vec2(626.0, 424.0), vec2(730.0, 446.0), vec2(818.0, 468.0), vec2(0.0), vec2(0.0), 3));
    s = min(s, polyline(W, vec2(748.0, 346.0), vec2(818.0, 368.0), vec2(0.0), vec2(0.0), vec2(0.0), 2));
    s = min(s, polyline(W, vec2(-2.0, 207.0), vec2(64.0, 211.0), vec2(64.0, 224.0), vec2(-2.0, 222.0), vec2(0.0), 4));
    s = min(s, polyline(W, vec2(110.0, 577.0), vec2(235.0, 477.0), vec2(0.0), vec2(0.0), vec2(0.0), 2));
    s = min(s, polyline(W, vec2(-2.0, 259.0), vec2(196.0, 192.0), vec2(226.0, 181.0), vec2(0.0), vec2(0.0), 3));
    float l = polyline(W, vec2(16.0, 640.0), vec2(110.0, 577.0), vec2(0.0), vec2(0.0), vec2(0.0), 2);
    l = min(l, polyline(W, vec2(709.0, 608.0), vec2(635.0, 764.0), vec2(626.0, 818.0), vec2(0.0), vec2(0.0), 3));
    s = min(s, polyline(W, vec2(617.0, 211.0), vec2(818.0, 250.0), vec2(0.0), vec2(0.0), vec2(0.0), 2));
    l = min(l, polyline(W, vec2(20.0, 650.0), vec2(150.0, 697.0), vec2(0.0), vec2(0.0), vec2(0.0), 2));
    return vec2(s, l);
}

vec3 floorStatic(vec2 P, float px) {
    float d = P.y - 60.0;                                             // distance below the vanishing band
    vec2 g = vec2((P.x - 408.0) / d, 300.0 / d) * 2.0;                // perspective plate coordinates
    vec3 c = mix(rgb(20.0, 32.0, 56.0), rgb(27.0, 47.0, 82.0), ramp(150.0, 340.0, P.y));
    c = mix(c, rgb(38.0, 60.0, 96.0), ramp(380.0, 560.0, P.y));
    c = mix(c, rgb(44.0, 56.0, 82.0), ramp(580.0, 760.0, P.y));
    // far floor by the wall: darker, with a soft sheen reflecting the pale centre panel
    float wy = wallY(P.x), nearW = 1.0 - smoothstep(0.0, 80.0, P.y - wy);
    c *= 1.0 - 0.22 * nearW * ramp(420.0, 640.0, P.x);
    c = mix(c, rgb(27.0, 48.0, 84.0), 0.7 * nearW * ramp(430.0, 490.0, P.x) * ramp(600.0, 540.0, P.x) * (0.8 + 0.4 * fbm(P * vec2(0.08, 0.02), 2)));
    // the pale lip of the floor along the foot of the centre and right walls, warm under the window
    vec3 lipC = mix(rgb(32.0, 54.0, 92.0), rgb(66.0, 52.0, 46.0), ramp(680.0, 760.0, P.x));
    c = mix(c, lipC, 0.7 * strokeAA(P.y - wy - 2.5, 1.2, px) * ramp(300.0, 350.0, P.x));
    c = mix(c, rgb(14.0, 20.0, 34.0), 0.5 * strokeAA(P.y - wy - 5.5, 1.2, px) * ramp(300.0, 350.0, P.x));

    // brushed steel in flat worn zones: soft-edged per-cell tone offsets, streaks along the plates, wear blotches
    vec4 vc = voronoi(P * vec2(0.011, 0.022), 1.0);
    c *= 1.0 + 0.20 * (hash12(vc.zw) - 0.5) * smoothstep(0.0, 0.25, vc.y - vc.x);
    c *= 1.0 + 0.14 * fbm(g * vec2(1.2, 5.0) + 3.0, 4) + 0.14 * fbm(P * 0.018, 4);
    c *= 1.0 + 0.07 * (valueNoise(vec2(P.x * 0.05 + P.y * 0.03, P.y * 0.5)) - 0.5);
    float scuff = smoothstep(0.2, 0.45, fbm(P * vec2(0.02, 0.045) + 11.0, 4));
    c = mix(c, c * 0.6, 0.6 * scuff * ramp(250.0, 450.0, P.y));
    // rusty amber grime where the vents light the floor: bottom right, and a darker band along the bottom left
    float grime = smoothstep(-0.15, 0.25, fbm(P * 0.02 + 2.0, 4)) * smoothstep(-0.3, 0.2, fbm(P * 0.07 + 4.0, 3));
    float rustN = 0.8 + 0.4 * fbm(P * vec2(0.12, 0.2) + 6.0, 3);
    float rustM = smoothstep(0.0, 1.0, ramp(735.0, 790.0, P.y + 25.0 * fbm(P * 0.03 + 1.0, 3)) * ramp(650.0, 710.0, P.x + 30.0 * fbm(P * 0.03 + 8.0, 3)));
    c = mix(c, rgb(92.0, 74.0, 70.0) * (0.92 + 0.16 * fbm(P * vec2(0.12, 0.2) + 6.0, 3)), 0.9 * rustM);
    c = mix(c, rgb(70.0, 62.0, 68.0) * rustN, 0.6 * grime * ramp(640.0, 760.0, P.y) * ramp(560.0, 680.0, P.x) * (1.0 - rustM));
    c = mix(c, rgb(40.0, 41.0, 53.0) * rustN, 0.65 * grime * ramp(690.0, 790.0, P.y) * ramp(20.0, 140.0, P.x) * ramp(480.0, 330.0, P.x));

    // scratches: one short pale stroke in some cells, mostly along the plates
    vec2 si = floor(P / vec2(46.0, 30.0));
    vec3 sh = hash32(si);
    vec2 sp0 = (si + 0.2 + 0.6 * sh.xy) * vec2(46.0, 30.0);
    float sa = -0.4 + 0.8 * sh.z;
    vec2 sdir = vec2(cos(sa), 0.5 * sin(sa)) * (5.0 + 14.0 * fract(sh.x * 7.31));
    c = mix(c, c * 1.4, 0.55 * strokeAA(sdSegment(P, sp0 - sdir, sp0 + sdir), 0.45, px) * step(0.5, sh.y) * ramp(200.0, 320.0, P.y));
    // small dark debris and stains
    vec4 vd = voronoi(P * vec2(0.035, 0.06), 1.0);
    float hd = hash12(vd.zw), rd = 0.06 + 0.14 * fract(hd * 13.7);
    c = mix(c, rgb(14.0, 18.0, 28.0), 0.7 * (1.0 - smoothstep(rd * 0.6, rd, vd.x)) * step(0.965, hd) * ramp(380.0, 520.0, P.y));

    // plate seams traced from frame 12: dark hairlines, each with a pale lit edge on its near side
    vec2 W = P + 1.5 * vec2(fbm(P * 0.04, 2), fbm(P * 0.04 + 7.0, 2));
    vec2 s = floorSeams(W), e = floorSeams(W - vec2(1.0, 1.7));      // e: the same lines moved to their near side
    float sAll = min(s.x, s.y), eAll = min(e.x, e.y);
    float edgeN = smoothstep(-0.1, 0.3, fbm(P * 0.03 + 9.0, 2)), near = ramp(250.0, 700.0, P.y);
    vec3 pale = rgb(86.0, 104.0, 140.0);
    c = mix(c, pale, (0.10 + 0.25 * edgeN) * near * strokeAA(eAll, 0.6, px));
    c = mix(c, pale, 0.75 * strokeAA(e.y, 1.0, px));
    c = mix(c, rgb(12.0, 18.0, 32.0), (0.5 + 0.35 * near) * strokeAA(sAll, mix(0.5, 1.0, near), px));

    c = vent(c, P, vec2(259.0, 666.0), vec2(333.0, 693.0), vec2(294.0, 739.0), vec2(213.0, 711.0),
             vec2(254.0, 694.0), vec2(310.0, 709.0), vec2(292.0, 742.0), vec2(224.0, 718.0), 1.0, 1.0, px);
    c = vent(c, P, vec2(526.0, 735.0), vec2(639.0, 768.0), vec2(630.0, 830.0), vec2(491.0, 799.0),
             vec2(532.0, 770.0), vec2(613.0, 788.0), vec2(600.0, 830.0), vec2(505.0, 806.0), 0.25, 1.0, px);
    c = vent(c, P, vec2(-40.0, 352.0), vec2(46.0, 380.0), vec2(2.0, 407.0), vec2(-80.0, 380.0),
             vec2(-40.0, 366.0), vec2(36.0, 383.0), vec2(0.0, 401.0), vec2(-60.0, 386.0), 0.0, 0.12, px);
    return c;
}

// ---- energy ------------------------------------------------------------------------------------------------------------
const vec3 E_DEEP = vec3(0.020, 0.130, 0.700);     // linear: saturated blue glow
const vec3 E_CYAN = vec3(0.130, 0.540, 0.950);     // ribbon body
const vec3 E_WHITE = vec3(0.800, 0.960, 1.000);    // hot core

// Thin concentric ripples on the floor, each broken into arcs that drift round.
vec3 ripples(float r, float ang, float T, float I, float arcs) {
    vec3 col = vec3(0.0);
    for (int i = 0; i < 7; i++) {
        float fi = float(i);
        float rad = 26.0 * pow(1.52, fi) * (1.0 + 0.10 * T);                       // 26, 40, 60, 91, 139, 211, 320
        float brk = fbm(vec2(cos(ang + T * (1.5 - 0.2 * fi) + fi), sin(ang + T * (1.5 - 0.2 * fi) + fi)) * 1.7 + fi * 3.0, 3);
        float inner = ramp(170.0, 60.0, rad);                                       // inner rings are steady, outer are loose arcs
        float on = mix(smoothstep(0.02, 0.16, brk), 1.0, inner * 0.85);
        float w = 0.9 + 0.012 * rad;
        float line = exp(-sq((r - rad) / w)) * on;
        line += 0.25 * exp(-abs(r - rad) / (4.0 * w)) * on;                          // soft bloom round each line
        col += (E_CYAN * 1.1 + E_WHITE * 0.5 * inner) * line * mix(arcs, I, inner);
        // the dark trough just outside each ring gives the pool its stepped look
        col -= vec3(0.010, 0.022, 0.050) * exp(-sq((r - rad * 1.18) / (w * 3.0))) * I * inner;
    }
    return col;
}

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

// Expanding shock ring, made of particles: dashes streaming round a crisp bright front, radial dashes thrown ahead
// of it where the flame tongues were, loose grains beyond, and only a thin blue haze holding it together.
vec3 shockRing(vec2 P, float R, float I, float T) {
    if (I < 0.003) return vec3(0.0);
    vec2 q = (P - CORE - vec2(8.0, 0.030 * R)) / vec2(1.0, FLOOR_K);
    float r = length(q), ang = atan(q.y, q.x + 1e-6);
    vec2 an = vec2(cos(ang), sin(ang));
    // an uneven, lopsided front: slow lobes, fast ripple, and a bulge that wanders round the ring
    float wob = 20.0 * fbm(an * 1.4 + T * 2.5, 3) + 8.0 * fbm(an * 7.0 - T * 5.0, 2) + 14.0 * cos(ang - 4.0 * T);
    float d = (r - R - wob) * mix(FLOOR_K, 1.0, an.x * an.x);                        // roughly screen pixels across the line
    float brk = smoothstep(-0.30, 0.10, fbm(an * 2.6 + 9.0 + T, 3) + 0.9 * I - 0.55); // fragments as it fades
    float line = exp(-d * d / 9.0) * brk;                                             // the continuous hot edge (the strip)
    float edge = exp(-d * d / 24.0) * brk;                                            // the narrow band its particles run in
    float tongues = exp(-max(d, 0.0) / (5.0 + 22.0 * max(fbm(an * 9.0 + T * 6.0, 3), 0.0))) * step(0.0, d) * brk;
    float band = exp(-max(-d, 0.0) / 36.0) * step(d, 0.0);
    float halo = exp(-abs(d) / 34.0);
    vec2 u = vec2(ang * R, d);
    float p = strands(u, 2.4, 15.0, 260.0, 1.0, T) + strands(u + vec2(0.0, 1.2), 3.4, 26.0, 420.0, 2.0, T) + 0.6 * strands(u, 5.5, 44.0, 180.0, 3.0, T);
    float spray = strands(u.yx, 3.2, 17.0, 240.0, 4.0, T) + 0.7 * strands(u.yx + vec2(0.0, 1.6), 5.0, 30.0, 380.0, 5.0, T);   // lanes run outward
    float grains = motes(u * vec2(1.0, 0.7) + vec2(T * 200.0, 3.0), 9.0, 19.0, T);
    // strip and particles together: a solid edge, flame tongues and inner band, with dashes streaming round the
    // edge, radial dashes riding the tongues and a few grains beyond
    float pk = PARTICLES;
    return (E_WHITE * (line * 0.40 + pk * edge * p * 0.50) + E_CYAN * (line * 0.95 + pk * edge * p * 1.25)
          + E_CYAN * (0.55 * tongues + pk * 1.5 * tongues * spray + 0.45 * band * brk * (0.7 + pk * 0.6 * p) + pk * 0.12 * exp(-abs(d) / 30.0) * grains)
          + E_DEEP * 0.55 * halo) * I;
}

// The fountain: a ribbon that winds up out of the core in tight coils, flares out, and falls back to the floor as
// a wide spiral. Parametric curve, sampled; brightness and width grow along it.
vec3 fountain(vec2 P, float T, float I, float hScale, float rScale) {
    if (I < 0.003) return vec3(0.0);
    vec3 col = vec3(0.0);
    const int N = 150;
    const float A = 0.45, B = 0.60;                 // curve fractions: coils | flare-out | floor spiral
    float rot = 1.1 * T;
    for (int arm = 0; arm < 2; arm++) {
        float fa = float(arm);
        float best = 1e9, bestS = 0.0, bestPhi = 0.0, along = 0.0, sideSign = 1.0;
        vec2 prev = CORE;
        for (int i = 1; i <= N; i++) {
            float s = float(i) / float(N);
            float R, H, phi;
            if (s < A) {                             // five coils, widening as they climb
                float u = s / A;
                H = 150.0 * u;
                R = 4.0 + 64.0 * u;
                phi = -1.5708 + 31.416 * (u - 1.0);
            } else if (s < B) {                      // the ribbon flares out and drops toward the floor
                float u = (s - A) / (B - A);
                H = mix(150.0, 60.0, u);                                  // leaves the column level, sinking as it widens
                R = mix(68.0, 285.0, pow(u, 1.15));
                phi = -1.5708 + 1.9 * u;
            } else {                                 // three quarters of a turn round the disc, hovering just off the floor
                float u = (s - B) / (1.0 - B);
                H = mix(60.0, 24.0, smoothstep(0.0, 0.45, u));
                R = mix(285.0, 308.0, u);
                phi = 0.33 + (3.0 - 0.9 * fa) * u;
            }
            R *= mix(1.0, rScale * (1.0 + 0.11 * fa), smoothstep(A, B, s));
            // the ribbon whips: its radius and angle shiver along its length, differently every instant
            R *= 1.0 + smoothstep(0.1, 0.6, s) * (0.022 * sin(s * 31.0 + T * 23.0 + fa) + 0.012 * sin(s * 67.0 - T * 37.0));
            H *= hScale * (1.0 + 0.05 * sin(s * 29.0 - T * 31.0));
            phi += rot - 0.22 * fa + 0.05 * sin(s * 17.0 + T * 19.0);
            vec2 pt = CORE + vec2(R * cos(phi) + 0.50 * H, FLOOR_K * R * sin(phi) - H);
            vec2 pa = P - prev, ba = pt - prev;
            float hh = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
            float dd = length(pa - ba * hh);
            if (dd < best && (arm == 0 || s > A)) {
                best = dd; bestS = s; bestPhi = phi;
                along = (float(i - 1) + hh) / float(N);                                   // continuous position along the curve
                sideSign = ba.x * pa.y - ba.y * pa.x < 0.0 ? -1.0 : 1.0;
            }
            prev = pt;
        }
        // a brushed band made of particles: the strip's shape and its separate strokes are kept as the envelope,
        // and inside it dashes stream along the path in lanes; round grains are thrown wide of it
        float ua = ramp(A, 1.0, bestS);
        float w = mix(2.4, 19.0 * pow(max(sin(3.14159 * (0.08 + 0.92 * ua)), 0.0), 0.6) + 2.5, smoothstep(A * 0.9, A + 0.4 * (B - A), bestS)) * (1.0 - 0.3 * fa);
        float strokes = mix(1.0, smoothstep(-0.55, -0.15, sin(best / w * 4.2 + bestS * 22.0 + 2.0 * fa)), smoothstep(A, B, bestS));
        float body = mix(exp(-best * best / (w * w)), 1.0 - smoothstep(0.80, 1.05, best / w), smoothstep(A, B, bestS)) * strokes;
        float hotLane = exp(-best * best / (w * w * 0.05));                                // only a thin spine runs pale
        float loose = 0.09 * exp(-best / (w * 1.6 + 6.0));
        vec2 u = vec2(along * 2600.0, sideSign * best + 40.0 * fa);
        float p = strands(u, 2.5, 17.0, 900.0, 31.0 + fa, T) + strands(u + vec2(0.0, 1.3), 3.5, 28.0, 1300.0, 37.0 + fa, T)
                + 0.6 * strands(u, 5.5, 46.0, 700.0, 41.0 + fa, T);
        float grains = motes(u * vec2(0.9, 0.8) + vec2(-T * 800.0, 3.0), 8.0, 43.0 + fa, T) + motes(u + vec2(-T * 500.0, 21.0), 15.0, 47.0 + fa, T);
        float fade = smoothstep(0.0, 0.04, bestS) * (1.0 - smoothstep(0.90, 1.0, bestS));
        // only the near half of each coil reads: the far half is behind the column's own glow
        fade *= mix(0.25 + 0.75 * smoothstep(-0.35, 0.45, sin(bestPhi)), 1.0, smoothstep(A * 0.9, A * 1.1, bestS));
        // strip and particles together: the continuous brushed band with its white-hot spine, and dashes streaming
        // through it, brightest where the band is; loose grains outside
        vec3 strip = (E_CYAN * 0.70 + E_DEEP * 1.10) * body + E_WHITE * hotLane * 0.20;      // blue body, a hairline of white
        vec3 dust = (E_CYAN * 1.15 + E_DEEP * 0.70 + E_WHITE * (0.06 + 0.40 * hotLane)) * body * p * 1.05 + (E_CYAN + E_DEEP) * 1.5 * loose * grains;
        col += (strip + dust * PARTICLES) * fade * (1.0 - 0.35 * fa) + E_DEEP * exp(-best / 30.0) * 0.42 * (1.0 - 0.5 * fa);
    }
    // loose accents thrown clear of the ribbon: a crescent low right, one high left, each trailing dashes
    vec2 q = (P - CORE) / vec2(1.0, FLOOR_K);
    float r = length(q) / rScale, ang = atan(q.y, q.x + 1e-6) - rot;
    for (int k = 0; k < 2; k++) {
        float a0 = k == 0 ? 0.78 : -2.10, R0 = k == 0 ? 388.0 : 432.0;
        float da = mod(ang - a0 + 3.14159, 6.2832) - 3.14159;                     // angle past the crescent's head
        float head = exp(-sq(da / 0.13)) * exp(-sq((r - R0) / (2.0 + 7.0 * exp(-sq(da / 0.08)))));
        float dash = ramp(0.20, 0.28, da) * ramp(0.70, 0.55, da) * step(0.2, sin(da * 34.0)) * exp(-sq((r - R0 - 22.0) / 3.0));
        col += (E_CYAN * 1.6 + E_WHITE * 0.7) * head + (E_CYAN + E_WHITE * 0.4) * dash * 0.8;
    }
    return col * I;
}

// Metal shards blown out of the core: each one is thrown along the floor with its own speed, dragged round by the
// vortex, hops once and skids to rest wherever it ends up, well outside the ring.
vec3 shards(vec3 col, vec2 P, float T, float I, float px) {
    float age = T + 0.20;                                              // the blast is already under way at frame 1
    for (int i = 0; i < 72; i++) {
        float fi = float(i);
        vec3 h = hash32(vec2(fi, 5.0)), g = hash32(vec2(fi, 11.0));
        float travel = (140.0 + 1000.0 * h.y * h.y) * (1.0 - exp(-2.4 * age)) / 2.4;
        float a = 6.2832 * h.x + (0.5 + 1.2 * g.y) * (1.0 - exp(-2.0 * age));
        float hop = max((70.0 + 300.0 * g.x) * age - 520.0 * age * age, 0.0);
        vec2 c = CORE + vec2(cos(a), FLOOR_K * sin(a)) * (30.0 + 60.0 * h.z + travel) - vec2(0.0, hop);
        float spin = hop > 0.0 ? age * 26.0 * (g.z - 0.5) : 2.0 * (g.z - 0.5);
        vec2 p = rot2(6.2832 * g.y + spin) * (P - c);
        float len = 3.0 + 15.0 * g.x * g.x;
        float alpha = max(I, 0.42) * step(g.z, 0.30 + 0.8 * I);                // a third of them stay where they fell
        if (alpha < 0.01 || dot2(p) > 500.0) continue;
        float d = sdRhombus(p, vec2(len, 1.2 + 0.22 * len));
        vec3 sc = mix(rgb(70.0, 92.0, 128.0), rgb(214.0, 226.0, 240.0), smoothstep(-1.0, 1.0, p.y));
        col = mix(col, rgb(8.0, 12.0, 22.0), 0.45 * fillAA(d - 1.5, px * 2.0) * alpha * step(hop, 0.5));   // contact shadow
        col = mix(col, sc, fillAA(d, px) * alpha);
    }
    return col;
}

// Sparks: hot streaks spat out in every direction, born through the first half second, each arcing up off the
// floor and dying in flight. Drawn as the short path it covered in the last 1/30 s.
vec3 sparks(vec2 P, float T) {
    vec3 col = vec3(0.0);
    for (int i = 0; i < 90; i++) {
        float fi = float(i);
        vec3 h = hash32(vec2(fi, 23.0)), g = hash32(vec2(fi, 29.0));
        float life = 0.50 + 0.55 * g.y;
        float age = T + 0.10 - 0.60 * h.z * h.z;
        if (age < 0.0 || age > life) continue;
        float a = 6.2832 * h.x, v = 260.0 + 560.0 * g.x, vz = 220.0 + 720.0 * g.z;   // thrown well up off the floor
        vec2 dir = vec2(cos(a), FLOOR_K * sin(a));
        float a0 = max(age - 0.085, 0.0);                                         // a long tail: readable frame to frame
        vec2 p1 = CORE + dir * (40.0 + v * age * (1.0 - 0.45 * age / life)) - vec2(0.0, max(vz * age - 950.0 * age * age, 0.0));
        vec2 p0 = CORE + dir * (40.0 + v * a0 * (1.0 - 0.45 * a0 / life)) - vec2(0.0, max(vz * a0 - 950.0 * a0 * a0, 0.0));
        float d = sdSegment(P, p0, p1);
        float fade = 1.0 - age / life;
        col += (E_WHITE * 0.40 + E_CYAN * 1.15) * exp(-d * d / (0.6 + 1.4 * fade)) * fade * 1.4 + E_DEEP * exp(-d / 6.0) * fade * 0.6;
    }
    return col;
}

// Stray arcs of lightning that crack across the disc, redrawn somewhere new twelve times a second.
vec3 crackle(vec2 P, float T, float I, float reachR) {
    if (I < 0.02) return vec3(0.0);
    vec3 col = vec3(0.0);
    float tick = floor(T * 12.0);
    for (int i = 0; i < 7; i++) {
        vec3 h = hash32(vec2(float(i) + 40.0, tick)), g = hash32(vec2(float(i) + 60.0, tick));
        float a = 6.2832 * h.x, rad = (0.25 + 0.85 * h.y) * reachR;
        vec2 c = CORE + vec2(cos(a), FLOOR_K * sin(a)) * rad;
        vec2 t = vec2(-sin(a), FLOOR_K * cos(a)) * (14.0 + 40.0 * h.z);          // runs round the disc, kinked twice
        vec2 k1 = c + t * 0.33 + (g.xy - 0.5) * 16.0, k2 = c + t * 0.66 + (g.yz - 0.5) * 16.0;
        float d = min(sdSegment(P, c, k1), min(sdSegment(P, k1, k2), sdSegment(P, k2, c + t)));
        col += (E_WHITE * exp(-d * d / 1.6) + E_CYAN * 0.5 * exp(-d / 5.0)) * step(h.z, 0.25 + I);
    }
    return col * I;
}

vec3 sparkles(vec2 P, float T, float I) {
    vec3 col = vec3(0.0);
    for (int i = 0; i < 60; i++) {
        float fi = float(i);
        vec3 h = hash32(vec2(fi, 17.0));
        float a = 6.2832 * h.x + 0.35 * T, rad = 60.0 + 400.0 * h.y;              // scattered right across the floor
        vec2 p = P - (CORE + vec2(cos(a), FLOOR_K * sin(a)) * rad) + jitter2(T, 6.0, fi) * 3.0;
        float tw = flick(T, 9.0 + 9.0 * h.z, fi + 3.0);
        float s = 1.1 + 2.0 * h.z * h.z;
        col += (E_WHITE * 0.8 + E_CYAN) * exp(-dot2(p) / (s * s)) * tw * tw * 1.6 * step(h.z, 0.35 + 0.65 * I);
    }
    return col * I;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    float scale = REF / iResolution.y;
    vec2 P = vec2(fragCoord.x - 0.5 * iResolution.x, iResolution.y - fragCoord.y) * scale + vec2(0.5 * REF, 0.0);
    float px = scale;

    float T = FREEZE_TIME >= 0.0 ? FREEZE_TIME : mod(iTime, LOOP);
#if GIF_STEPPED
    T = floor(T / DT) * DT;
#endif
    // unsteady light: every envelope breathes on its own random flicker
    float glow = clamp(key(K_GLOW, T), 0.0, 1.1) * (0.86 + 0.28 * flick(T, 6.0, 1.0));
    float core = clamp(key(K_CORE, T), 0.0, 1.0) * (0.90 + 0.10 * flick(T, 8.0, 2.0));
    float rip = clamp(key(K_RIP, T), 0.0, 1.0), arcs = clamp(key(K_ARCS, T), 0.0, 1.0) * (0.7 + 0.6 * flick(T, 5.0, 3.0));
    float ringI = clamp(key(K_RING_I, T), 0.0, 1.0) * (0.85 + 0.25 * flick(T, 7.0, 4.0)), ringR = key(K_RING_R, T);
    float fI = clamp(key(K_FOUNT, T), 0.0, 1.0), fH = clamp(key(K_FOUNT_H, T), 0.0, 1.0), fR = key(K_FOUNT_R, T);

    // camera shake: the blast kicks the frame about (fast rattle on a slower sway, a hair of roll), settling as
    // it dies; and the whole drawing boils a little, redrawn twelve times a second
    float kick = max(glow, ringI);
    P += jitter2(T, 18.0, 5.0) * (1.0 + SHAKE * 12.0 * kick) + jitter2(T, 7.0, 6.0) * (1.5 + SHAKE * 9.0 * kick);
    P = CORE + rot2(0.020 * SHAKE * kick * jitter2(T, 11.0, 7.0).x) * (P - CORE);
    float boilSeed = floor(T * 12.0) * 3.7;
    P += 1.4 * vec2(fbm(P * 0.03 + boilSeed, 2), fbm(P * 0.03 + 7.0 + boilSeed, 2));

    // 1. static scene
    float onFloor = fillAA(wallY(P.x) - P.y, px * 2.0);
    vec3 col = mix(wall(P, px), floorStatic(P, px), onFloor) * lightMap(P);
#if DEBUG_MODE == 5
    fragColor = vec4(linearToSrgb(col), 1.0);
    return;
#endif

    // floor polar coordinates around the core
    vec2 q = (P - CORE) / vec2(1.0, FLOOR_K);
    float r = length(q), ang = atan(q.y, q.x + 1e-6);
#if DEBUG_MODE == 3
    fragColor = vec4(fract(r / 100.0), fract(ang / 6.2832 + 0.5), onFloor, 1.0);
    return;
#endif

    // 2. light the vortex throws: the steel takes a blue sheen (stronger on the plates than the wall), and the
    //    plates' own texture shows through it
    float reach = exp(-r / 330.0);
    float sheen = 0.75 + 0.5 * fbm(P * vec2(0.01, 0.03) + 4.0, 3);
    col += E_DEEP * glow * (0.42 * reach * sheen * onFloor + 0.05 * (1.0 - onFloor) * ramp(0.0, 180.0, P.y));
    col += E_CYAN * glow * 0.10 * exp(-r / 150.0) * onFloor;
    col += E_DEEP * (0.05 + 0.10 * core) * exp(-r / 90.0) * onFloor;             // the pool never goes fully dark

    // 3. energy on the floor plane, then the fountain above it (all additive)
    col += ripples(r, ang, T, rip, arcs) * onFloor;
    col += shockRing(P, ringR, ringI, T);
    col += fountain(P, T, fI, fH, fR);
    col += crackle(P, T, max(glow, 0.5 * arcs), ringR + 30.0);
    col = shards(col, P, T, clamp(key(K_SHARD, T), 0.0, 1.0), px);
    col += sparks(P, T);
    col += sparkles(P, T, clamp(key(K_SPARK, T), 0.0, 1.0)) * onFloor;

    // core: white-hot point, cyan bloom, short rays while the fountain is up, a lens streak once it has gone
    vec2 cp = P - CORE;
    float cr = length(cp * vec2(1.0, 1.6));
    col += E_WHITE * (1.6 * exp(-cr * cr / (30.0 + 260.0 * core * core)) * (0.45 + 0.55 * core));
    col += E_CYAN * (0.25 + 0.75 * core) * exp(-cr / (12.0 + 26.0 * core));
    col += E_DEEP * 0.9 * exp(-cr / 40.0);                                         // the ember's blue halo outlasts the burst
    float rays = pow(abs(sin(atan(cp.y, cp.x + 1e-6) * 4.0 + 0.6)), 40.0) * exp(-length(cp) / 34.0);
    col += E_WHITE * rays * fI * 0.8;
    col += (E_WHITE * 0.7 + E_CYAN) * clamp(key(K_FLARE, T), 0.0, 1.0) * exp(-abs(cp.y) / 1.6) * exp(-abs(cp.x) / 70.0);

    // 4. finish: ease highlights into white, encode once, dither
    col = max(col, 0.0);
    col = min(col, vec3(0.7)) + 0.3 * (1.0 - exp(-max(col - 0.7, 0.0) / 0.3));
    col = linearToSrgb(clamp(col, 0.0, 1.0)) + ditherTPDF(fragCoord, iFrame);
    fragColor = vec4(col, 1.0);
}
