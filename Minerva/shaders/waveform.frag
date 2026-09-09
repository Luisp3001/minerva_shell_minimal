#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    // ── Custom uniforms (order must match QML properties) ──
    float u_time;
    float u_rms;
    float u_band0;
    float u_band1;
    float u_band2;
    float u_band3;
    float u_amplitude;
    float u_speed;
    float u_width;
    float u_height;
    float u_tintR;
    float u_tintG;
    float u_tintB;
    float u_tintAmount;
};

// ═══════════════════════════════════════════════════════════════════════════
// Simplex Noise 2D — Stefan Gustavson (Ashima Arts)
// ═══════════════════════════════════════════════════════════════════════════
vec3 mod289_3(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec2 mod289_2(vec2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec3 permute(vec3 x)  { return mod289_3(((x * 34.0) + 1.0) * x); }

float snoise(vec2 v) {
    const vec4 C = vec4( 0.211324865405187,   // (3.0-sqrt(3.0))/6.0
                         0.366025403784439,   // 0.5*(sqrt(3.0)-1.0)
                        -0.577350269189626,   // -1.0 + 2.0 * C.x
                         0.024390243902439);  // 1.0 / 41.0
    vec2 i  = floor(v + dot(v, C.yy));
    vec2 x0 = v - i + dot(i, C.xx);
    vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    vec4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = mod289_2(i);
    vec3 p = permute(permute(i.y + vec3(0.0, i1.y, 1.0))
                              + i.x + vec3(0.0, i1.x, 1.0));
    vec3 m = max(0.5 - vec3(dot(x0, x0), dot(x12.xy, x12.xy),
                             dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    vec3 x_ = 2.0 * fract(p * C.www) - 1.0;
    vec3 h  = abs(x_) - 0.5;
    vec3 ox = floor(x_ + 0.5);
    vec3 a0 = x_ - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    vec3 g;
    g.x  = a0.x * x0.x   + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

// ── Fractal Brownian Motion (3 octaves) ──────────────────────────────────
float fbm(vec2 p) {
    float val = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 3; i++) {
        val += amp * snoise(p);
        p   *= 2.0;
        amp *= 0.5;
    }
    return val;
}

// ═══════════════════════════════════════════════════════════════════════════
// Main
// ═══════════════════════════════════════════════════════════════════════════
void main() {
    vec2 uv = qt_TexCoord0;
    float x = uv.x;
    float y = uv.y;

    float t = u_time;

    // ── Envelope: taper to zero at left/right edges ─────────────────────
    float env = pow(sin(x * 3.14159265), 1.25);

    // ── Audio reactivity ────────────────────────────────────────────────
    // rmsF maps RMS [0,1] → [0.3, 1.0] so idle still shows gentle waves
    float rmsF = 0.3 + 0.7 * u_rms;

    // Per-band factors for each wave
    float bandF0 = 0.5 + 0.5 * u_band0;
    float bandF1 = 0.5 + 0.5 * u_band1;
    float bandF2 = 0.5 + 0.5 * u_band2;
    float bandF3 = 0.5 + 0.5 * u_band3;

    // ── Wave parameters ─────────────────────────────────────────────────
    //                       teal            pink            purple          blue
    const vec3 col0 = vec3(0.161, 0.839, 0.765);
    const vec3 col1 = vec3(1.000, 0.125, 0.431);
    const vec3 col2 = vec3(0.369, 0.208, 0.694);
    const vec3 col3 = vec3(0.161, 0.475, 1.000);

    const float phase0 = 0.0;
    const float phase1 = 1.5708;     // PI/2
    const float phase2 = 3.14159;    // PI
    const float phase3 = 4.71239;    // 3*PI/2

    const float freq0 = 1.0;
    const float freq1 = 1.25;
    const float freq2 = 0.85;
    const float freq3 = 1.45;

    const float yOff0 =  0.00;
    const float yOff1 =  0.035;
    const float yOff2 = -0.035;
    const float yOff3 =  0.02;

    const float wAmp0 = 1.00;
    const float wAmp1 = 0.85;
    const float wAmp2 = 0.78;
    const float wAmp3 = 0.90;

    vec3 finalColor = vec3(0.0);

    // Pixel-space scaling for consistent line widths across resolutions
    float pixScale = u_height;

    // ── Macro to compute one wave (unrolled for performance) ────────────
    #define WAVE(COL, PHASE, FREQ, YOFF, WAMP, BANDF)                      \
    {                                                                       \
        float waveAmp = u_amplitude * WAMP * rmsF * BANDF;                  \
        float yCenter = 0.5 + YOFF;                                        \
                                                                            \
        /* Organic displacement: sine harmonics + Perlin noise */           \
        float noise = fbm(vec2(x * 2.6 + t * 0.4, t * 0.2 + PHASE));      \
        float disp = env * waveAmp * (                                      \
            sin(x * 3.14159 * 3.2 * FREQ + t + PHASE) * 0.45              \
          + sin(x * 3.14159 * 5.2 * FREQ - t * 0.7 + PHASE) * 0.25       \
          + noise * 0.30                                                    \
        );                                                                  \
                                                                            \
        float waveY  = yCenter + disp;                                      \
        float dist   = abs(y - waveY);                                      \
        float distPx = dist * pixScale;                                     \
                                                                            \
        /* Glow: wide soft gaussian falloff */                              \
        float glowW = max(4.0, waveAmp * pixScale * 0.55);                 \
        float glow  = exp(-distPx * distPx / (glowW * glowW * 2.0));       \
                                                                            \
        /* Core: sharp bright center */                                     \
        float coreW = max(1.2, waveAmp * pixScale * 0.16);                 \
        float core  = exp(-distPx * distPx / (coreW * coreW));             \
                                                                            \
        vec3 wCol = COL * (core * 0.92 + glow * 0.22);                     \
                                                                            \
        /* Screen blend: 1 - (1-a)*(1-b) */                                \
        finalColor = 1.0 - (1.0 - finalColor) * (1.0 - wCol);             \
    }

    WAVE(col0, phase0, freq0, yOff0, wAmp0, bandF0)
    WAVE(col1, phase1, freq1, yOff1, wAmp1, bandF1)
    WAVE(col2, phase2, freq2, yOff2, wAmp2, bandF2)
    WAVE(col3, phase3, freq3, yOff3, wAmp3, bandF3)

    // ── Alpha: derived from luminance so empty areas are transparent ────
    // Difuminar los bordes izquierdo y derecho para evitar cortes bruscos
    float edgeFade = smoothstep(0.0, 0.06, x) * smoothstep(1.0, 0.94, x);
    finalColor *= edgeFade;

    // ── Color Tinting (para niveles de urgencia de tareas pendientes) ──
    if (u_tintAmount > 0.001) {
        vec3 tintCol = vec3(u_tintR, u_tintG, u_tintB);
        float l = dot(finalColor, vec3(0.299, 0.587, 0.114));
        vec3 tinted = tintCol * (l * 1.8);
        finalColor = mix(finalColor, tinted, clamp(u_tintAmount, 0.0, 1.0));
    }

    float lum = dot(finalColor, vec3(0.299, 0.587, 0.114));
    fragColor = vec4(finalColor, lum) * qt_Opacity;
}
