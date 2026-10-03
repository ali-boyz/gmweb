import { spawn, execSync } from 'child_process';
import { promisify } from 'util';

const sleep = promisify(setTimeout);

export default {
  name: 'file-manager',
  type: 'web',
  requiresDesktop: false,
  dependencies: [],

  async start(env) {
    console.log('[file-manager] Starting fsbrowse on port 9998...');
    return this.startFSBrowse(env);
  },

   async startFSBrowse(env) {
     return new Promise((resolve, reject) => {
       const childEnv = { ...env, PORT: '9998', HOSTNAME: 'localhost' };

       let command = 'bunx';
       let args = ['fsbrowse@latest'];
       
        try {
          execSync('which bunx', { stdio: 'pipe' });
         console.log('[file-manager] ✓ bunx available, using Bun package runner');
       } catch (e) {
         console.log('[file-manager] ⚠ bunx not available, falling back to npx');
         console.log(`[file-manager] Error details: ${e.message}`);
         console.log(`[file-manager] PATH: ${env.PATH}`);
         command = 'npx';
         args = ['-y', 'fsbrowse@latest'];
       }

       console.log(`[file-manager] Launching: ${command} ${args.join(' ')}`);
       const ps = spawn(command, args, {
         env: childEnv,
         stdio: ['ignore', 'pipe', 'pipe'],
         detached: false
       });

       ps.on('error', (err) => {
         console.error(`[file-manager] Failed to spawn process: ${err.message}`);
         reject(new Error(`Failed to start fsbrowse: ${err.message}`));
       });

       ps.stderr?.on('data', (data) => {
         const msg = data.toString().trim();
         if (msg) console.log(`[file-manager] stderr: ${msg}`);
       });

      let startCheckCount = 0;
      let startCheckInterval = null;

      const checkIfStarted = async () => {
        startCheckCount++;
        try {
          const { execSync: exec } = await import('child_process');
          const output = exec('ss -tln 2>/dev/null | grep ":9998"', {
            stdio: ['pipe', 'pipe', 'pipe'],
            shell: true,
            encoding: 'utf8',
            timeout: 2000
          });

          if (output && output.includes('LISTEN')) {
            clearInterval(startCheckInterval);
            console.log('[file-manager] ✓ fsbrowse responding on port 9998');
            resolve({
              pid: ps.pid,
              process: ps,
              cleanup: async () => {
                try {
                  ps.kill('SIGTERM');
                  await sleep(1000);
                  ps.kill('SIGKILL');
                } catch (e) {}
              }
            });
          } else if (startCheckCount > 120) {
            clearInterval(startCheckInterval);
            ps.kill('SIGKILL');
            reject(new Error('fsbrowse failed to start after 120s'));
          }
        } catch (e) {
          if (startCheckCount > 120) {
            clearInterval(startCheckInterval);
            ps.kill('SIGKILL');
            reject(new Error('fsbrowse failed to start after 120s'));
          }
        }
      };

      ps.stdout?.on('data', (data) => {
        console.log(`[file-manager] ${data.toString().trim()}`);
      });

      ps.stderr?.on('data', (data) => {
        console.log(`[file-manager:err] ${data.toString().trim()}`);
      });

      ps.on('error', (err) => {
        clearInterval(startCheckInterval);
        reject(new Error(`Failed to spawn fsbrowse: ${err.message}`));
      });

      ps.on('exit', (code) => {
        clearInterval(startCheckInterval);
        if (code !== 0) {
          reject(new Error(`fsbrowse exited with code ${code}`));
        }
      });

      startCheckInterval = setInterval(checkIfStarted, 1000);
    });
  },

  async health() {
    try {
      const { execSync: exec } = await import('child_process');
      const output = exec('ss -tln 2>/dev/null | grep ":9998"', {
        stdio: ['pipe', 'pipe', 'pipe'],
        shell: true,
        encoding: 'utf8',
        timeout: 2000
      });
      return output && output.includes('LISTEN');
    } catch (e) {
      return false;
    }
  }
};
