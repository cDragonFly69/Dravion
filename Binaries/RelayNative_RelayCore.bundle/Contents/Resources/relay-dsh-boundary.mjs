// Enforce the selected role's boundary even when a resumed session stored a broader preset.
export const name = 'relay-role-boundary';
export const inject = ['permissionPresets', 'sessions'];

export function apply(ctx, config) {
  if (!['relay-read-only', 'relay-workspace'].includes(config.preset) || !config.cwd?.startsWith('/')) {
    throw new Error('Relay role boundary configuration is invalid');
  }
  const pin = (session) => {
    if (session.header.cwd !== config.cwd) {
      throw new Error('Relay refuses a session outside the selected workspace');
    }
    ctx.permissionPresets.set(session, config.preset);
  };
  ctx.on('session/created', pin);
  for (const session of ctx.sessions.list()) pin(session);
  ctx.provide('relayRoleBoundary', Object.freeze({ preset: config.preset }));
}
