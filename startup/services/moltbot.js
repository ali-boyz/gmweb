import { execSync } from 'child_process';
import { spawnAsAbcUser } from '../lib/service-utils.js';

const PORT = parseInt(process.env.MOLTBOT_PORT || '7890');

export default {
  name: 'moltbot',
  type: 'web',
  requiresDesktop: false,
  dependencies: [],

  async start(env) {
    console.log(`[moltbot] Starting on port ${PORT}...`);
    console.log(`[moltbot] Docs: https://docs.molt.bot/web`);
    console.log(`[moltbot] Getting Started: https://docs.molt.bot/start/getting-started`);

    const ps = spawnAsAbcUser(
      `npm exec -- molt web --port ${PORT} 2>&1 || npx -y molt web --port ${PORT}`,
      { ...env, MOLTBOT_PORT: String(PORT) }
    );

    ps.stdout?.on('data', (data) => {
      const msg = data.toString().trim();
      if (msg && !msg.includes('npm error could not determine')) {
        console.log(`[moltbot] ${msg}`);
      }
    });

    ps.stderr?.on('data', (data) => {
      const msg = data.toString().trim();
      if (msg && !msg.includes('deprecat')) {
        console.log(`[moltbot:err] ${msg}`);
      }
    });

    ps.unref();

    return {
      pid: ps.pid,
      process: ps,
      cleanup: async () => {
        try {
          process.kill(-ps.pid, 'SIGTERM');
          await new Promise(r => setTimeout(r, 2000));
          process.kill(-ps.pid, 'SIGKILL');
        } catch (e) {}
      }
    };
  },

  async health() {
    try {
      execSync(`lsof -i :${PORT} 2>/dev/null | grep -q LISTEN`, {
        stdio: 'pipe',
        shell: true,
        timeout: 2000
      });
      return true;
    } catch (e) {
      return false;
    }
  }
};
