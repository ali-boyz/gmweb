import { spawn } from 'child_process';
import { promisify } from 'util';

const sleep = promisify(setTimeout);
const HOME_DIR = process.env.HOME || '/config';

export default {
  name: 'gcloud',
  type: 'install',
  requiresDesktop: false,
  dependencies: [],

  async start(env) {
    const ps = spawn('bash', ['-c', `
      curl -sSL https://sdk.cloud.google.com > /tmp/install_gcloud.sh
      bash /tmp/install_gcloud.sh --disable-prompts --install-dir=${HOME_DIR}
      rm -f /tmp/install_gcloud.sh
    `], {
      env: { ...env, HOME: HOME_DIR },
      stdio: ['ignore', 'pipe', 'pipe'],
      detached: true
    });

    ps.unref();
    return {
      pid: ps.pid,
      process: ps,
      cleanup: async () => {
        try {
          process.kill(-ps.pid, 'SIGKILL');
        } catch (e) {}
      }
    };
  },

  async health() {
    try {
      const { execSync } = await import('child_process');
      execSync(`which gcloud || test -f ${HOME_DIR}/google-cloud-sdk/bin/gcloud`, { stdio: 'pipe' });
      return true;
    } catch (e) {
      return false;
    }
  }
};
