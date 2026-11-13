// WebRTC's iOS audio device renders the microphone from its voice-processing unit with
// AudioUnitRender and has no public way to see those samples. Rebinding that one import inside
// WebRTC.framework, the way https://github.com/facebook/fishhook does, lets us copy each
// echo-cancelled buffer as WebRTC receives it, without touching the audio session, the unit or
// the audio itself.
#include "VoiceTone.h"

#include <AudioToolbox/AudioToolbox.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <stdatomic.h>
#include <string.h>

#define RING 8192
#define MICROPHONE_BUS 1

typedef OSStatus (*Render)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *,
                           UInt32, UInt32, AudioBufferList *);

static Render render = AudioUnitRender;
static float ring[RING];
static _Atomic unsigned long written;
static unsigned long consumed;
static atomic_bool enabled;

static OSStatus tapped_render(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                              const AudioTimeStamp *time, UInt32 bus, UInt32 frames,
                              AudioBufferList *data) {
  OSStatus status = render(unit, flags, time, bus, frames, data);
  const AudioBuffer *buffer = &data->mBuffers[0];
  if (status != noErr || bus != MICROPHONE_BUS ||
      !atomic_load_explicit(&enabled, memory_order_relaxed) || data->mNumberBuffers < 1 ||
      buffer->mNumberChannels != 1 || buffer->mDataByteSize != frames * sizeof(SInt16))
    return status;
  const SInt16 *samples = buffer->mData;
  unsigned long head = atomic_load_explicit(&written, memory_order_relaxed);
  for (UInt32 i = 0; i < frames; i++) ring[(head + i) % RING] = samples[i] / 32768.0f;
  atomic_store_explicit(&written, head + frames, memory_order_release);
  return status;
}

static bool rebind(const struct mach_header_64 *header, intptr_t slide) {
  const struct segment_command_64 *linkedit = NULL;
  const struct symtab_command *symtab = NULL;
  const struct dysymtab_command *dysymtab = NULL;
  const struct load_command *command = (const void *)(header + 1);
  for (uint32_t i = 0; i < header->ncmds; i++) {
    if (command->cmd == LC_SEGMENT_64 &&
        !strcmp(((const struct segment_command_64 *)command)->segname, SEG_LINKEDIT))
      linkedit = (const void *)command;
    if (command->cmd == LC_SYMTAB) symtab = (const void *)command;
    if (command->cmd == LC_DYSYMTAB) dysymtab = (const void *)command;
    command = (const void *)((const char *)command + command->cmdsize);
  }
  if (!linkedit || !symtab || !dysymtab) return false;

  uintptr_t base = slide + linkedit->vmaddr - linkedit->fileoff;
  const struct nlist_64 *symbols = (const void *)(base + symtab->symoff);
  const char *names = (const char *)(base + symtab->stroff);
  const uint32_t *indirect = (const void *)(base + dysymtab->indirectsymoff);

  bool bound = false;
  command = (const void *)(header + 1);
  for (uint32_t i = 0; i < header->ncmds; i++) {
    const struct segment_command_64 *segment = (const void *)command;
    command = (const void *)((const char *)command + command->cmdsize);
    if (segment->cmd != LC_SEGMENT_64 || (strcmp(segment->segname, SEG_DATA) &&
                                          strcmp(segment->segname, "__DATA_CONST")))
      continue;
    const struct section_64 *section = (const void *)(segment + 1);
    for (uint32_t j = 0; j < segment->nsects; j++, section++) {
      uint32_t type = section->flags & SECTION_TYPE;
      if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
      void **slots = (void **)(slide + section->addr);
      for (uint64_t k = 0; k < section->size / sizeof(void *); k++) {
        uint32_t symbol = indirect[section->reserved1 + k];
        if (symbol & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) continue;
        if (strcmp(names + symbols[symbol].n_un.n_strx, "_AudioUnitRender")) continue;
        if (vm_protect(mach_task_self(), (vm_address_t)&slots[k], sizeof(void *), false,
                       VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS)
          continue;
        slots[k] = (void *)tapped_render;
        bound = true;
      }
    }
  }
  return bound;
}

bool voice_tap_install(void) {
  static bool installed;
  if (installed) return true;
  for (uint32_t i = 0; i < _dyld_image_count(); i++) {
    const char *name = _dyld_get_image_name(i);
    if (name && strstr(name, "/WebRTC.framework/WebRTC"))
      installed = rebind((const struct mach_header_64 *)_dyld_get_image_header(i),
                         _dyld_get_image_vmaddr_slide(i));
  }
  return installed;
}

void voice_tap_enable(bool on) {
  consumed = atomic_load_explicit(&written, memory_order_acquire);
  atomic_store_explicit(&enabled, on, memory_order_relaxed);
}

int voice_tap_read(float *out, int count) {
  unsigned long head = atomic_load_explicit(&written, memory_order_acquire);
  if (head == consumed) return 0;
  consumed = head;
  if (count > RING / 2) count = RING / 2;
  if ((unsigned long)count > head) count = (int)head;
  for (int i = 0; i < count; i++) out[i] = ring[(head - count + i) % RING];
  return count;
}
