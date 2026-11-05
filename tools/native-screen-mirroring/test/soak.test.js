import { test } from 'node:test';
import assert from 'node:assert/strict';
import { virtualPhone } from './support/virtual-phone.js';

test('sustained bridge run forwards video after 120 fresh rotations and twelve TCP recoveries', {
  skip: process.env.RUN_SOAK_TESTS !== '1', timeout: 90000,
}, async t => {
  const phone = await virtualPhone(t);
  await phone.select(true); await phone.until(() => phone.log.includes('IPHONE-PLAYBACK confirmed'));
  for (let index = 0; index < 120; index++) {
    await phone.rotate(...(index % 2 === 0 ? [2796, 1290] : [1290, 2796]));
    const videos = phone.videos;
    await phone.until(() => phone.videos > videos);
    assert.equal(phone.connections.at(-1).destroyed, false);
    if (index % 10 === 9) {
      const connections = phone.connections.length, before = phone.videos;
      phone.connections.at(-1).destroy();
      await phone.until(() => phone.connections.length === connections + 1 && phone.videos > before);
    }
  }
  assert.equal((phone.log.match(/AIRPLAY-ORIENTATION/g) || []).length, 120);
  assert.equal(phone.connections.length, 13);
  assert.equal((phone.log.match(/FIXTURE-STREAM-STARTED/g) || []).length, 1, 'TCP recovery must not restart the AirPlay session');
  assert.doesNotMatch(phone.log, /IPHONE-NOT-READY/);
});
