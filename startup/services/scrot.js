import { spawn } from 'child_process';

export default {
  name: 'scrot',
  type: 'system',
  requiresDesktop: false,
  dependencies: [],

  async start(env) {
    return {
      pid: process.pid,
      process: null,
      cleanup: async () => {}
    };
  },

  async health() {
    try {
      const { execSync } = await import('child_process');
      execSync('which scrot', { stdio: 'pipe' });
      return true;
    } catch (e) {
      return false;
    }
  }
};
