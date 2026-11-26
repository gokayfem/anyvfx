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
