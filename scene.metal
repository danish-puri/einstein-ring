#include <metal_stdlib>
using namespace metal;

// Every distance here is in Schwarzschild radii, so the event horizon sits at r = 1.

struct Params {
    float4 a;   // width, height, time (s), loop length (s)
    float4 b;   // unused
};

constant float TAU = 6.2831853;

constant float  FOCAL    = 1.6;
constant float2 TARGET   = float2(0.26, 0.05);   // where the black hole sits on screen
constant float  CAM_DIST = 85.0;
constant float  DISK_IN  = 3.0;                  // innermost stable orbit
constant float  DISK_OUT = 13.0;
constant float  EXPOSURE = 1.0;

// ---------------------------------------------------------------- noise

inline uint hashu(uint x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

inline uint hash3(int3 c, uint seed) {
    uint h = hashu(as_type<uint>(c.x) + seed * 0x9e3779b9u);
    h = hashu(h ^ as_type<uint>(c.y));
    return hashu(h ^ as_type<uint>(c.z));
}

inline float u01(uint h) { return float(h >> 8) * (1.0 / 16777216.0); }

float vnoise(float3 p, uint seed) {
    float3 i = floor(p);
    float3 f = p - i;
    float3 u = f * f * (3.0 - 2.0 * f);
    int3 c = int3(i);
    float n000 = u01(hash3(c, seed));
    float n100 = u01(hash3(c + int3(1, 0, 0), seed));
    float n010 = u01(hash3(c + int3(0, 1, 0), seed));
    float n110 = u01(hash3(c + int3(1, 1, 0), seed));
    float n001 = u01(hash3(c + int3(0, 0, 1), seed));
    float n101 = u01(hash3(c + int3(1, 0, 1), seed));
    float n011 = u01(hash3(c + int3(0, 1, 1), seed));
    float n111 = u01(hash3(c + int3(1, 1, 1), seed));
    return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
               mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}

float fbm(float3 p, int octaves, uint seed) {
    float sum = 0.0, amp = 0.5, norm = 0.0;
    for (int i = 0; i < octaves; i++) {
        sum += amp * vnoise(p, seed + uint(i) * 101u);
        norm += amp;
        p = p * 2.03 + float3(1.7, 9.2, 4.1);
        amp *= 0.5;
    }
    return sum / norm;
}

// ---------------------------------------------------------------- camera

struct Cam { float3 pos, right, up, fwd; };

// The camera drifts on a small closed path, so frame 0 follows the last frame seamlessly.
Cam makeCam(float t, float T) {
    float th = TAU * t / T;
    float yaw   = -0.35 + 0.06 * cos(th);
    float pitch = 0.11 + 0.025 * sin(th);
    float roll  = 0.18;
    float3 pos = CAM_DIST * float3(sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch));
    float3 fwd = normalize(-pos);
    float3 right = normalize(cross(float3(0.0, 1.0, 0.0), fwd));
    float3 up = cross(fwd, right);
    float cr = cos(roll), sr = sin(roll);
    Cam c;
    c.pos = pos;
    c.fwd = fwd;
    c.right = cr * right + sr * up;
    c.up = -sr * right + cr * up;
    return c;
}

// ---------------------------------------------------------------- colour helpers

// Tanner Helland's fit of blackbody colour, returned in linear light.
float3 blackbody(float kelvin) {
    float t = clamp(kelvin, 1000.0, 40000.0) / 100.0;
    float r = t <= 66.0 ? 1.0 : 1.2929362 * pow(t - 60.0, -0.1332048);
    float g = t <= 66.0 ? 0.3900816 * log(t) - 0.6318414 : 1.1298909 * pow(t - 60.0, -0.0755148);
    float b = t >= 66.0 ? 1.0 : (t <= 19.0 ? 0.0 : 0.5432068 * log(t - 10.0) - 1.1962541);
    return pow(saturate(float3(r, g, b)), 2.2);
}

float3 starTint(float u) {
    float3 c = mix(float3(0.62, 0.73, 1.0), float3(0.86, 0.9, 1.0), smoothstep(0.0, 0.2, u));
    c = mix(c, float3(1.0, 0.96, 0.9), smoothstep(0.2, 0.55, u));
    c = mix(c, float3(1.0, 0.82, 0.62), smoothstep(0.6, 0.95, u));
    return c;
}

// ---------------------------------------------------------------- sky

// Render a stable star population, selectively thinning crowded desktop edges.
float3 starLayer(float3 d, float scale, float prob, float base, uint seed,
                 float pixAng, float phase, float twinkle, float starRemoval) {
    float3 p = d * scale;
    int3 c0 = int3(floor(p));
    float3 col = float3(0.0);
    for (int z = -1; z <= 1; z++)
    for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++) {
        int3 c = c0 + int3(x, y, z);
        uint h = hash3(c, seed);
        if (u01(h) > prob) continue;
        uint h1 = hashu(h ^ 0x68bc21ebu), h2 = hashu(h1), h3 = hashu(h2), h4 = hashu(h3), h5 = hashu(h4);
        float3 sd = normalize(float3(c) + float3(u01(h1), u01(h2), u01(h3)));
        if (dot(d, sd) < 0.0) continue;
        float3 cr = cross(d, sd);
        float a2 = dot(cr, cr);
        float flux = min(pow(max(u01(h4), 1e-4), -0.6), 40.0);
        // Keep every bright star. Drop about half of the rest and dim them.
        if (flux < 8.0 && u01(hashu(h5 ^ 0x5bd1e995u)) < 0.5) continue;
        // An independent, persistent selection removes up to 18% more of the fainter stars.
        // Bright stars are spared here too, using the same cutoff as the thinning above.
        // Feather the threshold so camera motion never abruptly switches stars off.
        float keep = 1.0;
        if (starRemoval > 0.0 && flux < 8.0) {
            float selection = u01(hashu(h5 ^ 0x74b8a923u));
            keep = smoothstep(0.0, 0.02, selection - starRemoval + 0.01);
            keep = mix(1.0, keep, smoothstep(0.0, 0.02, starRemoval));
        }
        float dim = mix(0.7, 1.0, smoothstep(8.0, 20.0, flux));
        float sig = pixAng * (0.72 + 0.22 * log2(flux));
        float I = base * flux * dim * keep * exp(-a2 / (2.0 * sig * sig));
        if (twinkle > 0.0) {
            float k = float(1u + (h5 % 4u));
            I *= 1.0 + twinkle * sin(k * phase + u01(h5) * TAU);
        }
        col += starTint(u01(hashu(h5))) * I;
    }
    return col;
}

float3 galaxies(float3 d, float pixAng, float avoid) {
    float3 p = d * 16.0;
    int3 c0 = int3(floor(p));
    float3 col = float3(0.0);
    for (int z = -1; z <= 1; z++)
    for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++) {
        int3 c = c0 + int3(x, y, z);
        uint h = hash3(c, 777u);
        if (u01(h) > 0.07) continue;
        uint h1 = hashu(h ^ 0x1234567u), h2 = hashu(h1), h3 = hashu(h2), h4 = hashu(h3), h5 = hashu(h4), h6 = hashu(h5);
        float3 gd = normalize(float3(c) + float3(u01(h1), u01(h2), u01(h3)));
        if (dot(d, gd) < 0.0) continue;
        float3 tu = normalize(cross(gd, float3(0.0, 1.0, 0.0)));
        float3 tv = cross(gd, tu);
        float3 off = d - gd;
        float2 q = float2(dot(off, tu), dot(off, tv));
        float rot = u01(h4) * TAU;
        float cs = cos(rot), sn = sin(rot);
        q = float2(cs * q.x - sn * q.y, sn * q.x + cs * q.y);
        q.y /= mix(0.55, 1.0, u01(h5));
        float size = pixAng * mix(4.5, 13.0, u01(h6) * u01(h6));
        float rr = length(q) / size;
        if (rr > 8.0) continue;
        float bright = mix(0.035, 0.11, u01(hashu(h6)));
        col += (float3(1.0, 0.88, 0.72) * exp(-rr * rr * 3.0) * 0.8
              + float3(0.7, 0.78, 1.0) * exp(-rr * 1.6) * 0.35) * bright;
    }
    return col * (1.0 - avoid);
}

// One nearer spiral galaxy, still only a thumbnail across.
float3 spiralGalaxy(float3 d, float3 center, float3 upHint, float pixAng) {
    if (dot(d, center) < 0.0) return float3(0.0);
    float3 tu = normalize(cross(center, upHint));
    float3 tv = cross(center, tu);
    float3 off = d - center;
    float2 q = float2(dot(off, tu), dot(off, tv)) / (pixAng * 32.0);
    float rot = 0.6, cs = cos(rot), sn = sin(rot);
    q = float2(cs * q.x - sn * q.y, sn * q.x + cs * q.y);
    q.y /= 0.38;
    float r = length(q);
    if (r > 4.0) return float3(0.0);
    float theta = atan2(q.y, q.x);
    float arms = 0.5 + 0.5 * cos(2.0 * (theta - 2.2 * log(r + 0.05)));
    float disk = exp(-r * 2.2) * (0.35 + 0.65 * arms * smoothstep(0.1, 0.4, r));
    float core = exp(-r * r * 30.0);
    return (float3(0.72, 0.8, 1.0) * disk * 0.12 + float3(1.0, 0.88, 0.7) * core * 0.35);
}

// Compose the sky; only ordinary stars receive the selective removal mask.
float3 sky(float3 d, float t, float T, float pixAng, Cam c0, float edgeFade, float starRemoval) {
    float phase = TAU * t / T;

    // A faint midnight blue instead of pure black.
    float3 col = float3(0.0024, 0.0044, 0.012) * (0.7 + 0.6 * fbm(d * 1.8 + 7.0, 3, 41u));

    // Milky Way: a soft band with dark dust lanes along its middle.
    float3 n = normalize(c0.right * -0.55 + c0.up * 0.83 + c0.fwd * 0.12);
    float lat = dot(d, n);
    float band = exp(-lat * lat / (2.0 * 0.15 * 0.15));
    float narrow = exp(-lat * lat / (2.0 * 0.045 * 0.045));
    // Squash the noise across the band so its clouds stretch along it.
    float3 q = d * 2.5 + n * (lat * 7.0);
    float clouds = fbm(q + 3.1, 6, 5u);
    float dust = fbm(q * 2.1 + 11.7, 6, 9u);
    float glow = band * (0.15 + 1.3 * clouds * clouds);
    glow *= 1.0 - 0.8 * smoothstep(0.42, 0.72, dust) * (0.35 + 0.65 * narrow);
    float3 mwCol = mix(float3(0.55, 0.6, 0.78), float3(1.0, 0.86, 0.7), narrow * 0.9);
    col += mwCol * glow * 0.055;

    // The pale blue dot. A small clear patch around it lets it stand alone.
    float3 dotDir = normalize(c0.right * (-0.50 - TARGET.x) + c0.up * (-0.18 - TARGET.y) + c0.fwd * FOCAL);
    float clear = smoothstep(0.008, 0.045, length(d - dotDir));

    float3 stars = starLayer(d, 50.0, 0.10, 0.5, 1u, pixAng, phase, 0.25, starRemoval)
                 + starLayer(d, 150.0, 0.075, 0.07, 2u, pixAng, phase, 0.0, starRemoval)
                 + starLayer(d, 400.0, 0.06 * (1.0 + 4.0 * band), 0.022, 3u, pixAng, phase, 0.0, starRemoval);
    col += stars * clear * edgeFade;
    col += galaxies(d, pixAng, band) * clear * edgeFade;
    col += spiralGalaxy(d, normalize(c0.right * (-0.58 - TARGET.x) + c0.up * (0.3 - TARGET.y) + c0.fwd * FOCAL),
                        c0.up, pixAng);

    if (dot(d, dotDir) > 0.0) {
        float3 cr = cross(d, dotDir);
        float a2 = dot(cr, cr);
        float sig = pixAng * 1.35;
        float glowSig = pixAng * 7.0;
        col += float3(0.5, 0.78, 1.0) * 2.4 * exp(-a2 / (2.0 * sig * sig));
        col += float3(0.25, 0.7, 0.9) * 0.045 * exp(-a2 / (2.0 * glowSig * glowSig));
        float3 bt = normalize(c0.up + c0.right * 0.3);
        bt = normalize(bt - dotDir * dot(bt, dotDir));
        float3 bn = cross(dotDir, bt);
        float across = dot(d, bn);
        float along = dot(d - dotDir, bt);
        col += float3(1.0, 0.9, 0.78) * 0.012
             * exp(-across * across / (2.0 * 0.022 * 0.022))
             * exp(-along * along / (2.0 * 0.22 * 0.22));
    }
    return col;
}

// ---------------------------------------------------------------- accretion disk

float diskPattern(float r, float ang) {
    float lr = log(r);
    float n = fbm(float3(cos(ang) * 2.0, sin(ang) * 2.0, lr * 10.0), 5, 21u);
    float fine = vnoise(float3(cos(ang) * 7.0, sin(ang) * 7.0, lr * 34.0), 33u);
    return 0.7 * n + 0.3 * fine;
}

float4 diskEmission(float3 pd, float3 dir, float r, float t, float T) {
    float ang = atan2(pd.z, pd.x);

    // Inner rings orbit faster. Blending two copies of the pattern keeps the loop seamless.
    float omega = 0.32 * pow(r / DISK_IN, -1.5);
    float w = t / T;
    float n = mix(diskPattern(r, ang - omega * t), diskPattern(r, ang - omega * (t - T)), w);
    n = 0.5 + (n - 0.5) / sqrt((1.0 - w) * (1.0 - w) + w * w);

    float edge = smoothstep(DISK_IN - 0.2, DISK_IN + 0.6, r) * (1.0 - smoothstep(DISK_OUT * 0.55, DISK_OUT, r));
    float dens = edge * smoothstep(0.2, 0.85, n);
    float prof = pow(DISK_IN / r, 0.7);

    // Doppler shift and gravitational redshift: the side coming toward us is brighter and bluer.
    float beta = clamp(sqrt(0.5 / max(r - 1.0, 0.5)), 0.0, 0.75);
    float gam = rsqrt(1.0 - beta * beta);
    float3 vdir = normalize(float3(-pd.z, 0.0, pd.x));
    float g = sqrt(1.0 - 1.0 / r) / (gam * (1.0 - beta * dot(vdir, -dir)));

    float3 col = blackbody(4700.0 * prof * pow(g, 0.6));
    float I = 2.0 * pow(prof, 1.6) * pow(g, 1.8) * (0.5 + 0.8 * n);
    return float4(col * I, clamp(dens * 1.1, 0.0, 0.96));
}

// ---------------------------------------------------------------- ray tracing

// Photon paths in Schwarzschild spacetime follow x'' = -1.5 h^2 x / r^5.
// Carry the screen-space star mask to the sky without changing photon paths.
float3 trace(float3 ro, float3 rd, float t, float T, float pixAng, Cam c0, float edgeFade, float starRemoval) {
    float3 p = ro, v = rd;
    float3 L = cross(p, v);
    float h2 = dot(L, L);
    float3 acc = float3(0.0);
    float trans = 1.0;
    bool escaped = false;

    for (int i = 0; i < 420; i++) {
        float r = length(p);
        if (r < 1.0) { trans = 0.0; break; }
        if (r > 300.0 && dot(p, v) > 0.0) { escaped = true; break; }

        float dt = max(r * mix(0.03, 0.12, smoothstep(10.0, 50.0, r)), 0.01);
        float3 vh = v - 0.75 * dt * h2 * p / pow(r, 5.0);
        float3 np = p + dt * vh;
        float nr = length(np);
        float3 nv = vh - 0.75 * dt * h2 * np / pow(nr, 5.0);

        if (p.y * np.y < 0.0) {
            float s = p.y / (p.y - np.y);
            float3 pd = mix(p, np, s);
            float rDisk = length(pd.xz);
            if (rDisk > DISK_IN - 0.2 && rDisk < DISK_OUT) {
                float4 e = diskEmission(pd, normalize(mix(v, nv, s)), rDisk, t, T);
                acc += trans * e.rgb * e.a;
                trans *= 1.0 - e.a;
                if (trans < 0.01) { trans = 0.0; break; }
            }
        }
        p = np;
        v = nv;
    }
    if (escaped && trans > 0.0) acc += trans * sky(normalize(v), t, T, pixAng, c0, edgeFade, starRemoval);
    return acc;
}

// Trace one camera sample with the edge treatment shared by its pixel.
float3 shade(float2 uv, Cam cam, Cam c0, float t, float T, float pixAng, float edgeFade, float starRemoval) {
    float3 rd = normalize(cam.right * (uv.x - TARGET.x) + cam.up * (uv.y - TARGET.y) + cam.fwd * FOCAL);
    return trace(cam.pos, rd, t, T, pixAng, c0, edgeFade, starRemoval);
}

// Render the scene while protecting the black hole and its curved star trails.
kernel void scene(texture2d<float, access::write> hdr [[texture(0)]],
                  constant Params& P [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= hdr.get_width() || gid.y >= hdr.get_height()) return;
    float2 res = P.a.xy;
    float t = P.a.z, T = P.a.w;
    Cam cam = makeCam(t, T);
    Cam c0 = makeCam(0.0, T);
    float mn = min(res.x, res.y);
    float pixAng = 1.0 / (mn * FOCAL);
    float2 frag = float2(float(gid.x) + 0.5, res.y - float(gid.y) - 0.5);
    float2 uv = (frag - 0.5 * res) / mn;

    // Calmer star field behind the menu bar and the Dock.
    float vy = frag.y / res.y;
    float edgeFade = mix(0.3, 1.0, smoothstep(0.0, 0.16, vy) * smoothstep(0.0, 0.13, 1.0 - vy));

    // Thin the bottom third and far-right edge by 18%, with gradual boundaries.
    // Use max rather than addition so the lower-right corner is not thinned twice.
    float bottomCrowding = 1.0 - smoothstep(0.28, 0.38, vy);
    float rightCrowding = smoothstep(0.84, 0.94, frag.x / res.x);
    float outsideTrails = smoothstep(0.29, 0.37, length(uv - TARGET));
    float starRemoval = 0.18 * max(bottomCrowding, rightCrowding) * outsideTrails;

    float3 col = float3(0.0);
    if (length(uv - TARGET) < 0.24) {
        // Four samples per pixel near the black hole, where lensing stretches the stars.
        const float2 o[4] = { float2(-0.125, -0.375), float2(0.375, -0.125),
                              float2(0.125, 0.375), float2(-0.375, 0.125) };
        for (int k = 0; k < 4; k++) col += shade(uv + o[k] / mn, cam, c0, t, T, pixAng, edgeFade, starRemoval);
        col *= 0.25;
    } else {
        col = shade(uv, cam, c0, t, T, pixAng, edgeFade, starRemoval);
    }
    hdr.write(float4(col, 1.0), gid);
}

// ---------------------------------------------------------------- post

kernel void downsample(texture2d<float, access::read> hdr [[texture(0)]],
                       texture2d<float, access::write> small [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= small.get_width() || gid.y >= small.get_height()) return;
    float3 s = float3(0.0);
    for (uint j = 0; j < 4; j++)
        for (uint i = 0; i < 4; i++)
            s += hdr.read(gid * 4 + uint2(i, j)).rgb;
    small.write(float4(max(s / 16.0 - 0.02, 0.0), 1.0), gid);
}

float3 aces(float3 x) {
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

float3 toSRGB(float3 c) {
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, 12.92 * c, c <= 0.0031308);
}

kernel void composite(texture2d<float, access::read> hdr [[texture(0)]],
                      texture2d<float, access::sample> bloomA [[texture(1)]],
                      texture2d<float, access::sample> bloomB [[texture(2)]],
                      texture2d<float, access::write> out [[texture(3)]],
                      constant Params& P [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 res = P.a.xy;
    float2 st = (float2(gid) + 0.5) / res;
    float3 c = hdr.read(gid).rgb + 0.12 * bloomA.sample(s, st).rgb + 0.10 * bloomB.sample(s, st).rgb;
    float2 v = (st - 0.5) * float2(res.x / res.y, 1.0);
    c *= 1.0 - 0.28 * smoothstep(0.35, 1.0, length(v));
    c = toSRGB(aces(c * EXPOSURE));
    uint h = hashu(gid.x * 7919u + gid.y * 104729u);
    float dith = (u01(h) + u01(hashu(h)) - 1.0) / 255.0;
    out.write(float4(saturate(c + dith), 1.0), gid);
}
