#include "VoiceTone.h"

#include <math.h>

#define LOWEST_VOICE 60.0f
#define HIGHEST_VOICE 500.0f
#define ANALYSIS_RATE 12000.0f
#define MAX_DECIMATED 1024
#define MAX_LAG 256

#define SEMITONES_FOR_FULL_LIFT 5.0f
#define OCTAVES_FOR_FULL_TONE 0.7f
#define OCTAVE_JUMP 0.75f

static float clamp(float value) { return value < -1 ? -1 : value > 1 ? 1 : value; }

static float approach(float value, float target, float dt, float seconds) {
  return value + (target - value) * (1 - expf(-dt / seconds));
}

void voice_tone_reset(VoiceTone *state) { *state = (VoiceTone){.floor = -70}; }

float voice_tone_f0(const float *samples, int count, float rate, float *clarity) {
  *clarity = 0;
  int step = rate > 16000 ? (int)lroundf(rate / ANALYSIS_RATE) : 1;
  float fs = rate / step;
  int n = count / step;
  if (n > MAX_DECIMATED) n = MAX_DECIMATED;
  float y[MAX_DECIMATED];
  for (int i = 0; i < n; i++) {
    float sum = 0;
    for (int j = 0; j < step; j++) sum += samples[(count - n * step) + i * step + j];
    y[i] = sum / step;
  }

  int shortest = (int)(fs / HIGHEST_VOICE);
  int longest = (int)(fs / LOWEST_VOICE);
  if (longest >= MAX_LAG) longest = MAX_LAG - 1;
  int width = n - longest;
  if (width < longest) return 0;

  float cmnd[MAX_LAG] = {1};
  float running = 0;
  for (int lag = 1; lag <= longest; lag++) {
    float d = 0;
    for (int i = 0; i < width; i++) {
      float delta = y[i] - y[i + lag];
      d += delta * delta;
    }
    running += d;
    cmnd[lag] = running > 0 ? d * lag / running : 1;
  }

  int best = 0;
  for (int lag = shortest; lag <= longest; lag++) {
    if (cmnd[lag] < 0.15f) {
      while (lag < longest && cmnd[lag + 1] < cmnd[lag]) lag++;
      best = lag;
      break;
    }
    if (!best || cmnd[lag] < cmnd[best]) best = lag;
  }
  if (best <= shortest || best >= longest) return 0;

  float a = cmnd[best - 1], b = cmnd[best], c = cmnd[best + 1];
  float bend = a - 2 * b + c;
  float shift = bend > 0 ? 0.5f * (a - c) / bend : 0;
  *clarity = 1 - b;
  return fs / (best + shift);
}

float voice_tone_brightness(const float *samples, int count, float rate) {
  float energy = 0, change = 0;
  for (int i = 1; i < count; i++) {
    float delta = samples[i] - samples[i - 1];
    energy += samples[i] * samples[i];
    change += delta * delta;
  }
  if (energy <= 0) return 0;
  float ratio = sqrtf(change / energy) / 2;
  return rate / (float)M_PI * asinf(ratio > 1 ? 1 : ratio);
}

void voice_tone_step(VoiceTone *state, const float *samples, int count, float rate, float dt) {
  float energy = 0;
  for (int i = 0; i < count; i++) energy += samples[i] * samples[i];
  float level = count ? 10 * log10f(energy / count + 1e-12f) : -120;
  if (count) state->floor = level < state->floor ? level : state->floor + 1.5f * dt;

  float clarity = 0;
  float f0 = level > -55 && level > state->floor + 10
                 ? voice_tone_f0(samples, count, rate, &clarity)
                 : 0;
  bool voiced = f0 > 0 && clarity > 0.75f;
  float pitch = voiced ? log2f(f0) : 0;
  if (voiced && state->voicedTime > 0.3f && fabsf(pitch - state->pitchBase) > OCTAVE_JUMP) {
    state->stray += dt;
    if (state->stray < 0.6f) voiced = false;
    else state->voicedTime = 0;
  }
  float bright = voiced ? voice_tone_brightness(samples, count, rate) : 0;
  float tone = bright > 0 ? log2f(bright) : 0;

  if (!voiced || bright <= 0) {
    state->silence += dt;
    if (state->silence > 0.15f) {
      state->pitch = approach(state->pitch, 0, dt, 0.3f);
      state->tone = approach(state->tone, 0, dt, 0.4f);
      if (fabsf(state->pitch) < 0.01f) state->pitch = 0;
      if (fabsf(state->tone) < 0.01f) state->tone = 0;
    }
    return;
  }

  state->silence = 0;
  state->stray = 0;
  state->voicedTime += dt;
  float pitchWeight = dt / fminf(state->voicedTime, 4);
  float toneWeight = dt / fminf(state->voicedTime, 8);
  state->pitchBase += (pitch - state->pitchBase) * pitchWeight;
  state->toneBase += (tone - state->toneBase) * toneWeight;
  float lift = (pitch - state->pitchBase) * 12 / SEMITONES_FOR_FULL_LIFT;
  float shape = (tone - state->toneBase) / OCTAVES_FOR_FULL_TONE;
  state->pitch = approach(state->pitch, clamp(lift), dt, 0.12f);
  state->tone = approach(state->tone, clamp(shape), dt, 0.45f);
}
