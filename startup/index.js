#!/usr/bin/env node

import { readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { Supervisor } from './lib/supervisor.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
  try {
    console.log('[startup] === SUPERVISOR STARTING ===');
    console.log('[startup] PID:', process.pid);
    console.log('[startup] CWD:', process.cwd());
    console.log('[startup] Node:', process.version);

    const configPath = join(__dirname, 'config.json');
    console.log('[startup] Loading config from:', configPath);
    const config = JSON.parse(readFileSync(configPath, 'utf8'));
    console.log('[startup] Config loaded successfully');

    const supervisor = new Supervisor(config);

    const serviceDir = join(__dirname, 'services');
      const serviceNames = [
        'wrangler',
        'gcloud',
        'scrot',
        'webssh2',
        'file-manager',
        'log-viewer',
        'tmux',
        'proxypilot',
        'agentgui',
        'moltbot',
        'playwriter',
        'version-check',
        'cron'
      ];

    console.log('[startup] Loading services...');
    let loadedCount = 0;
    let skippedCount = 0;

    for (const name of serviceNames) {
      try {
        const serviceConfig = config.services[name];
        const isEnabled = serviceConfig?.enabled !== false;

        if (!isEnabled) {
          console.log(`[startup] Skipping disabled service: ${name}`);
          skippedCount++;
          continue;
        }

        console.log(`[startup] Loading service: ${name}...`);
        const module = await import(`./services/${name}.js`);
        const service = module.default;

        if (!service || typeof service !== 'object') {
          console.error(`[startup] ✗ Service ${name} has no valid default export`);
          continue;
        }
        if (!service.name) {
          console.error(`[startup] ✗ Service ${name} missing 'name' property`);
          continue;
        }
        if (typeof service.start !== 'function') {
          console.error(`[startup] ✗ Service ${name} missing 'start' function`);
          continue;
        }
        if (typeof service.health !== 'function') {
          console.error(`[startup] ✗ Service ${name} missing 'health' function`);
          continue;
        }
        if (!service.dependencies || !Array.isArray(service.dependencies)) {
          console.log(`[startup] Service ${name} has no dependencies array, setting to empty`);
          service.dependencies = [];
        }

        service.enabled = true;

        const registered = supervisor.register(service);
        if (registered) {
          console.log(`[startup] ✓ Registered: ${name}`);
          loadedCount++;
        } else {
          console.error(`[startup] ✗ Failed to register: ${name}`);
        }
      } catch (err) {
        console.error(`[startup] ✗ Failed to load service ${name}:`, err.message);
      }
    }

    console.log(`[startup] Service loading complete: ${loadedCount} loaded, ${skippedCount} skipped`);

    console.log('[startup] Starting supervisor...');
    await supervisor.start();

    console.log('[startup] Supervisor stopped (unexpected)');
    process.exit(0);
  } catch (err) {
    console.error('[startup] FATAL:', err.message);
    console.error('[startup] Stack:', err.stack);
    console.log('[startup] Retrying in 5 seconds...');
    setTimeout(main, 5000);
  }
}

process.on('uncaughtException', (err) => {
  console.error('[startup] Uncaught exception:', err);
});

process.on('unhandledRejection', (reason) => {
  console.error('[startup] Unhandled rejection:', reason);
});

main().catch((err) => {
  console.error('[startup] Startup error:', err);
  setTimeout(main, 5000);
});
