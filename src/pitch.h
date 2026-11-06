/*
 * Real-time pitch shifter: WSOLA time-stretch (x r) followed by
 * resampling (x r). Net effect: pitch x r at the original duration.
 *
 * Pure C, no libc / libm dependency, no integer division, no 64-bit math.
 * Grains are aligned by waveform similarity (normalized cross-correlation on
 * channel 0), which keeps voiced speech phase-coherent and avoids the
 * warbling of simple two-tap delay-line shifters.
 */
#ifndef VCP_PITCH_H
#define VCP_PITCH_H

#include <stdint.h>

#define VCP_NIN 8192
#define VCP_NY 8192
#define VCP_IMASK (VCP_NIN - 1)
#define VCP_YMASK (VCP_NY - 1)
#define VCP_MAXCH 2
#define VCP_MAXL 2304 /* max grain length: 2 * Hs, Hs <= 1152 (96 kHz) */
#define VCP_MAX_RATE 96000

#define VCP_SEMI_MIN (-12)
#define VCP_SEMI_MAX 12

typedef struct {
    float x[VCP_MAXCH][VCP_NIN]; /* input history ring */
    float y[VCP_MAXCH][VCP_NY];  /* stretched overlap-add ring */
    float win[VCP_MAXL];

    uint32_t n_in;   /* total input samples pushed */
    uint32_t R;      /* stretched samples that are final */
    uint32_t S_next; /* stretched start index of the next grain */
    uint32_t pp;     /* input start index of the previous grain */
    uint32_t nom_i;  /* nominal input start of next grain (int part) */
    float nom_f;     /* ... fractional part */
    uint32_t rp_i;   /* resampler read position (int part) */
    float rp_f;      /* ... fractional part */
    int started;

    int Hs, L, D, shift; /* synthesis hop, grain len, search range, log2 stride */
    float ratio, Ha;     /* pitch ratio, analysis hop = Hs / ratio */
} vcp_state;

/* 2^(n/12), n = -12 .. 12 */
static const float vcp_ratio_tab[25] = {
    0.5f,       0.529732f, 0.561231f, 0.594604f, 0.629961f,
    0.667420f,  0.707107f, 0.749154f, 0.793701f, 0.840896f,
    0.890899f,  0.943874f, 1.0f,      1.059463f, 1.122462f,
    1.189207f,  1.259921f, 1.334840f, 1.414214f, 1.498307f,
    1.587401f,  1.681793f, 1.781797f, 1.887749f, 2.0f};

static inline void vcp_init_tables(void) {}

static float vcp_cos(float x) /* x in [0, 2*pi] */
{
    const float pi = 3.14159265f;
    float sign = 1.0f;
    if (x > pi) x = 2.0f * pi - x;
    if (x > 0.5f * pi) {
        x = pi - x;
        sign = -1.0f;
    }
    float x2 = x * x;
    float r = 1.0f - x2 * (0.5f - x2 * (1.0f / 24.0f -
              x2 * (1.0f / 720.0f - x2 * (1.0f / 40320.0f -
              x2 * (1.0f / 3628800.0f)))));
    return sign * r;
}

static int vcp_clamp_semi(int s)
{
    if (s < VCP_SEMI_MIN) return VCP_SEMI_MIN;
    if (s > VCP_SEMI_MAX) return VCP_SEMI_MAX;
    return s;
}

static void vcp_reset(vcp_state *s)
{
    for (int c = 0; c < VCP_MAXCH; c++) {
        for (int i = 0; i < VCP_NIN; i++) s->x[c][i] = 0.0f;
        for (int i = 0; i < VCP_NY; i++) s->y[c][i] = 0.0f;
    }
    s->n_in = s->R = s->S_next = s->pp = 0;
    s->nom_i = s->rp_i = 0;
    s->nom_f = s->rp_f = 0.0f;
    s->started = 0;
}

/* rate in Hz (8000..VCP_MAX_RATE); semitones in -12..12 (0 handled by caller) */
static void vcp_configure(vcp_state *s, uint32_t rate, int semitones)
{
    if (rate > VCP_MAX_RATE) rate = VCP_MAX_RATE;
    if (rate < 8000) rate = 8000;
    int Hs = (int)((float)rate * 0.012f); /* 12 ms hop, 24 ms grain */
    s->Hs = Hs;
    s->L = 2 * Hs;
    s->shift = (rate >= 32000) ? 2 : 1;
    int D = (int)((float)rate * 0.005f); /* +-5 ms alignment search */
    s->D = (D >> s->shift) << s->shift;
    s->ratio = vcp_ratio_tab[vcp_clamp_semi(semitones) - VCP_SEMI_MIN];
    s->Ha = (float)Hs / s->ratio;

    float k = 6.28318531f / (float)s->L;
    for (int i = 0; i < s->L; i++)
        s->win[i] = 0.5f - 0.5f * vcp_cos((float)i * k);
}

/* normalized (squared) cross-correlation score of x[b..] against target x[a..] */
static float vcp_score(const float *x, uint32_t a, uint32_t b, int n, int sh)
{
    float c = 0.0f, e = 0.0f;
    for (int i = 0; i < n; i++) {
        uint32_t o = (uint32_t)i << sh;
        float va = x[(a + o) & VCP_IMASK];
        float vb = x[(b + o) & VCP_IMASK];
        c += va * vb;
        e += vb * vb;
    }
    if (c <= 0.0f) return 0.0f;
    return c * c / (e + 1e-9f);
}

static void vcp_place_grain(vcp_state *s, int ch, uint32_t q)
{
    const int Hs = s->Hs, L = s->L;
    const uint32_t S = s->S_next;
    for (int c = 0; c < ch; c++) {
        const float *xi = s->x[c];
        float *yo = s->y[c];
        for (int i = 0; i < L; i++) {
            float v = xi[(q + (uint32_t)i) & VCP_IMASK] * s->win[i];
            uint32_t pos = (S + (uint32_t)i) & VCP_YMASK;
            if (i < Hs) yo[pos] += v;
            else yo[pos] = v;
        }
    }
    s->pp = q;
    s->S_next = S + (uint32_t)Hs;
    s->R = S + (uint32_t)Hs; /* first half is now complete */
}

static void vcp_advance_nom(vcp_state *s)
{
    float f = s->nom_f + s->Ha;
    int carry = (int)f;
    s->nom_i += (uint32_t)carry;
    s->nom_f = f - (float)carry;
}

/* returns 0 if not enough input is buffered yet */
static int vcp_make_grain(vcp_state *s, int ch)
{
    const int Hs = s->Hs, D = s->D, sh = s->shift;
    const uint32_t q0 = s->nom_i;

    if ((int32_t)(s->n_in - (q0 + (uint32_t)D + (uint32_t)s->L)) < 0)
        return 0;

    const float *x0 = s->x[0];
    const uint32_t tgt = s->pp + (uint32_t)Hs; /* natural continuation */
    const int stride = 1 << sh;
    const int K = D >> sh;
    int bestd = 0;
    float best = -1.0f;

    /* coarse search, candidates ordered by |d| so ties prefer no shift */
    for (int k = 0; k <= K; k++) {
        for (int sgn = 0; sgn < 2; sgn++) {
            if (k == 0 && sgn == 1) continue;
            int d = sgn ? -k * stride : k * stride;
            float sc = vcp_score(x0, tgt, q0 + (uint32_t)(int32_t)d,
                                 Hs >> sh, sh);
            if (sc > best) {
                best = sc;
                bestd = d;
            }
        }
    }

    /* fine search around the coarse optimum at full resolution */
    {
        int lo = bestd - (stride - 1), hi = bestd + (stride - 1);
        int bd = bestd;
        float fb = -1.0f;
        if (lo < -D) lo = -D;
        if (hi > D) hi = D;
        for (int d = lo; d <= hi; d++) {
            float sc = vcp_score(x0, tgt, q0 + (uint32_t)(int32_t)d, Hs, 0);
            if (sc > fb) {
                fb = sc;
                bd = d;
            }
        }
        bestd = bd;
    }

    vcp_place_grain(s, ch, q0 + (uint32_t)(int32_t)bestd);
    vcp_advance_nom(s);
    return 1;
}

static inline float vcp_load(const void *p, int fmt, uint32_t idx)
{
    if (fmt == 5) return ((const float *)p)[idx];
    return (float)((const int16_t *)p)[idx] * (1.0f / 32768.0f);
}

static inline void vcp_store(void *p, int fmt, uint32_t idx, float v, int acc)
{
    if (fmt == 5) {
        float *o = (float *)p;
        o[idx] = acc ? o[idx] + v : v;
    } else {
        float t = v * 32768.0f;
        if (acc) t += (float)((int16_t *)p)[idx];
        if (t > 32767.0f) t = 32767.0f;
        if (t < -32768.0f) t = -32768.0f;
        ((int16_t *)p)[idx] = (int16_t)t;
    }
}

/* fmt: 1 = int16, 5 = float. ch: 1..VCP_MAXCH. in/out may alias. */
static void vcp_run(vcp_state *s, int ch, int fmt, const void *in, void *out,
                    uint32_t frames, int acc)
{
    for (uint32_t f = 0; f < frames; f++) {
        uint32_t ni = s->n_in;
        for (int c = 0; c < ch; c++)
            s->x[c][ni & VCP_IMASK] =
                vcp_load(in, fmt, f * (uint32_t)ch + (uint32_t)c);
        s->n_in = ni + 1u;

        float o[VCP_MAXCH] = {0.0f, 0.0f};

        if (!s->started &&
            (int32_t)(s->n_in - (uint32_t)(s->L + s->D + 64)) >= 0) {
            vcp_place_grain(s, ch, 0u); /* first grain: no alignment */
            vcp_advance_nom(s);
            s->started = 1;
        }

        if (s->started) {
            while ((int32_t)(s->R - s->rp_i) < 2)
                if (!vcp_make_grain(s, ch)) break;
            if ((int32_t)(s->R - s->rp_i) >= 2) {
                uint32_t i0 = s->rp_i;
                for (int c = 0; c < ch; c++) {
                    float y0 = s->y[c][i0 & VCP_YMASK];
                    float y1 = s->y[c][(i0 + 1u) & VCP_YMASK];
                    o[c] = y0 + (y1 - y0) * s->rp_f;
                }
                float rf = s->rp_f + s->ratio;
                int carry = (int)rf;
                s->rp_i += (uint32_t)carry;
                s->rp_f = rf - (float)carry;
            }
        }

        for (int c = 0; c < ch; c++)
            vcp_store(out, fmt, f * (uint32_t)ch + (uint32_t)c, o[c], acc);
    }
}

#endif /* VCP_PITCH_H */
