import { existsSync } from 'fs';
import { dirname } from 'path';
import { createNpxWrapper, precacheNpmPackage } from './service-utils.js';

export function npxWrapperService(name, packageName) {
  const binPath = `${dirname(process.execPath)}/${name}`;
  
  return {
    name,
    type: 'install',
    requiresDesktop: false,
    dependencies: [],

    async start(env) {
      console.log(`[${name}] Creating wrapper...`);
      if (!createNpxWrapper(binPath, packageName)) {
        console.log(`[${name}] ✗ Failed to create wrapper`);
        return { pid: 0, process: null, cleanup: async () => {} };
      }
      
      console.log(`[${name}] ✓ Wrapper created`);
      precacheNpmPackage(packageName, env);
      return { pid: 0, process: null, cleanup: async () => {} };
    },

    async health() {
      return existsSync(binPath);
    }
  };
}

export function webServiceOnPort(name, port, spawnerFn) {
  return {
    name,
    type: 'web',
    requiresDesktop: false,
    dependencies: [],

    async start(env) {
      console.log(`[${name}] Starting on port ${port}...`);
      const ps = spawnerFn(env);
      
      ps.stdout?.on('data', (data) => {
        console.log(`[${name}] ${data.toString().trim()}`);
      });
      ps.stderr?.on('data', (data) => {
        console.log(`[${name}:err] ${data.toString().trim()}`);
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
      const net = await import('net');
      return await new Promise((resolve) => {
        const socket = net.createConnection({ port, host: '127.0.0.1' });
        socket.on('connect', () => {
          socket.destroy();
          resolve(true);
        });
        socket.on('error', () => resolve(false));
        socket.setTimeout(2000, () => {
          socket.destroy();
          resolve(false);
        });
      });
    }
  };
}

export function systemService(name, spawnerFn) {
  return {
    name,
    type: 'system',
    requiresDesktop: false,
    dependencies: [],

    async start(env) {
      console.log(`[${name}] Starting...`);
      const ps = spawnerFn(env);
      
      ps.stdout?.on('data', (data) => {
        console.log(`[${name}] ${data.toString().trim()}`);
      });
      ps.stderr?.on('data', (data) => {
        console.log(`[${name}:err] ${data.toString().trim()}`);
      });

      ps.unref();
      return {
        pid: ps.pid,
        process: ps,
        cleanup: async () => {
          try {
            process.kill(-ps.pid, 'SIGTERM');
            await new Promise(r => setTimeout(r, 1000));
            process.kill(-ps.pid, 'SIGKILL');
          } catch (e) {}
        }
      };
    },

    async health() {
      return true;
    }
  };
}

export function customService(name, { start, health, type = 'system', dependencies = [], requiresDesktop = false }) {
  return {
    name,
    type,
    requiresDesktop,
    dependencies,
    start,
    health
  };
}
