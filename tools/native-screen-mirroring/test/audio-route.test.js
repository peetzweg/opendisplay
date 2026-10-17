import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

test('native audio guard preserves user choices and handles bridge routing, unavailable devices and setter failure', { skip: process.platform !== 'darwin' }, () => {
  const directory = mkdtempSync(path.join(tmpdir(), 'mirror-audio-test-'));
  const root = fileURLToPath(new URL('../native/', import.meta.url));
  try {
    const source = path.join(directory, 'test.c');
    writeFileSync(source, `
#include "audio-route.h"
#include <assert.h>
typedef struct { uint32_t output, unavailable, selected; bool fail; unsigned writes; } simulation;
static uint32_t current(void *c) { return ((simulation *)c)->output; }
static bool bridge(void *c, uint32_t d) { (void)c; return d == 99; }
static bool usable(void *c, uint32_t d) { return d && d != ((simulation *)c)->unavailable; }
static bool select_output(void *c, uint32_t d) {
    simulation *s=c; s->writes++; if(s->fail) return false;
    s->selected=d; s->output=d; return true;
}
int main(void) {
    simulation s={.output=10}; mirror_audio_route route={0};
    mirror_audio_backend backend={&s,current,bridge,usable,select_output};
    assert(mirror_audio_route_step(&route,&backend)==0 && s.writes==0);
    s.output=99; assert(mirror_audio_route_step(&route,&backend)==1 && s.output==10);
    s.output=20; assert(mirror_audio_route_step(&route,&backend)==0);
    s.output=99; assert(mirror_audio_route_step(&route,&backend)==1 && s.output==20);
    s.output=30; assert(mirror_audio_route_step(&route,&backend)==0 && s.writes==2);
    s.output=99; s.unavailable=30;
    assert(mirror_audio_route_step(&route,&backend)==0 && s.writes==2);
    s.unavailable=0; s.fail=true;
    assert(mirror_audio_route_step(&route,&backend)==-1);
    s.fail=false; assert(mirror_audio_route_step(&route,&backend)==1 && s.output==30);
    route.previous=0; s.output=99;
    assert(mirror_audio_route_step(&route,&backend)==0 && s.writes==4);
    s.output=0; assert(mirror_audio_route_step(&route,&backend)==0 && s.writes==4);
    return 0;
}
`);
    const binary = path.join(directory, 'test');
    const compiled = spawnSync('/usr/bin/clang', ['-std=c11', '-Wall', '-Wextra', '-Werror', '-I', root, source, path.join(root, 'audio-route-policy.c'), '-o', binary]);
    assert.equal(compiled.status, 0, compiled.stderr.toString());
    const checked = spawnSync(binary);
    assert.equal(checked.status, 0, checked.stderr.toString());
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
