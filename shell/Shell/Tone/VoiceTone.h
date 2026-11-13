#pragma once

#include <stdbool.h>

typedef struct {
  float pitch;
  float tone;
  float pitchBase;
  float toneBase;
  float floor;
  float voicedTime;
  float silence;
  float stray;
} VoiceTone;

void voice_tone_reset(VoiceTone *state);
void voice_tone_step(VoiceTone *state, const float *samples, int count, float rate, float dt);
float voice_tone_f0(const float *samples, int count, float rate, float *clarity);
float voice_tone_brightness(const float *samples, int count, float rate);

bool voice_tap_install(void);
void voice_tap_enable(bool enabled);
int voice_tap_read(float *out, int count);
