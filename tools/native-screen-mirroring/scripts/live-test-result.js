export function liveTestResult({ sessions, decoded, unexpectedDisconnects, validatedRotations }) {
  if (!sessions) return { status: 'not_connected', exitCode: 2 };
  if (!decoded) return { status: 'no_decoded_video', exitCode: 1 };
  if (sessions !== 1 || unexpectedDisconnects) return { status: 'connection_interrupted', exitCode: 1 };
  if (validatedRotations < 2) return { status: 'rotation_not_validated', exitCode: 2 };
  return { status: 'decoded_video_and_rotation_observed', exitCode: 0 };
}

export function displayEvidence(events) {
  if (!events.length) return { status: 'no_display_evidence' };
  const baseline = events[0].active.filter(d => d.vendor === 0x6161706c && d.product === 0x69506164).map(d => d.id);
  if (!baseline.length) return { status: 'no_sidecar_baseline' };
  if (events.some(event => event.error !== 0)) return { status: 'display_query_failed' };
  const interrupted = events.some(event => (event.removed && baseline.includes(event.display)) ||
    (!event.begin && baseline.some(id => !event.active.some(d => d.id === id))));
  return { status: interrupted ? 'sidecar_interrupted' : 'sidecar_remained_registered', samples: events.length };
}
