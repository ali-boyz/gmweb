#!/usr/bin/env node


import { execSync } from 'child_process';
import { promisify } from 'util';
import https from 'https';
import fs from 'fs';

const sleep = promisify(setTimeout);

const NAME = 'version-check';

const SERVICES_TO_MONITOR = [
  { serviceName: 'opencode', bundleName: 'opencode-ai', type: 'npm' },
  { serviceName: 'gm-oc', bundleName: 'gm-oc', type: 'github', github: 'AnEntrypoint/gm-oc' },
  { serviceName: 'proxypilot', bundleName: 'proxypilot', type: 'npm' },
  { serviceName: 'moltbot', bundleName: 'molt.bot', type: 'npm' }
];

class VersionChecker {
  constructor() {
    this.versions = new Map();
    this.checkInterval = 60000;
    this.supervisor = null;
  }

  log(level, message, serviceName = '') {
    const timestamp = new Date().toISOString();
    const prefix = serviceName ? `[${NAME}:${serviceName}]` : `[${NAME}]`;
    console.log(`${timestamp} ${prefix} ${message}`);
  }

  async getLatestVersion(packageName) {
    return new Promise((resolve) => {
      const timeoutId = setTimeout(() => {
        this.log('WARN', `Registry timeout for ${packageName}`);
        resolve(null);
      }, 8000);

      const options = {
        hostname: 'registry.npmjs.org',
        path: `/${packageName}`,
        method: 'GET',
        timeout: 8000,
        headers: { 'User-Agent': 'gmweb-version-check/1.0' }
      };

      try {
        https.request(options, (res) => {
          let data = '';
          res.on('data', (chunk) => { data += chunk; });
          res.on('end', () => {
            clearTimeout(timeoutId);
            try {
              const info = JSON.parse(data);
              const latestVersion = info['dist-tags']?.latest;
              if (latestVersion) {
                resolve(latestVersion);
              } else {
                this.log('WARN', `No latest tag found for ${packageName}`);
                resolve(null);
              }
            } catch (e) {
              this.log('WARN', `Failed to parse registry for ${packageName}: ${e.message}`);
              resolve(null);
            }
          });
        }).on('error', (e) => {
          clearTimeout(timeoutId);
          this.log('WARN', `Registry error for ${packageName}: ${e.message}`);
          resolve(null);
        }).end();
      } catch (e) {
        clearTimeout(timeoutId);
        this.log('WARN', `Request error for ${packageName}: ${e.message}`);
        resolve(null);
      }
    });
  }

  getCurrentVersion(packageName, localPath) {
    if (localPath) {
      try {
        const pkg = JSON.parse(fs.readFileSync(localPath, 'utf8'));
        return pkg.version || null;
      } catch (e) { return null; }
    }
    try {
      const result = execSync(`npm list -g "${packageName}" --depth=0 2>/dev/null || echo "not-installed"`, {
        encoding: 'utf8',
        stdio: ['pipe', 'pipe', 'pipe'],
        timeout: 5000
      }).trim();

      const match = result.match(/@([\d.]+[a-z0-9.\-]*)/);
      if (match && match[1]) {
        return match[1];
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  isNewerVersion(versionA, versionB) {
    if (!versionA || !versionB) return false;

    const parseVersion = (v) => {
      const parts = v.split(/[\.\-]/);
      return parts.slice(0, 3).map(p => {
        const num = parseInt(p, 10);
        return isNaN(num) ? 0 : num;
      });
    };

    const [a1, a2, a3] = parseVersion(versionA);
    const [b1, b2, b3] = parseVersion(versionB);

    if (a1 !== b1) return a1 > b1;
    if (a2 !== b2) return a2 > b2;
    if (a3 !== b3) return a3 > b3;
    return false;
  }

  async killServiceProcess(serviceName) {
    try {
      const patterns = [
        `bunx.*${serviceName}`,
        `node.*${serviceName}`,
        `node.*services/${serviceName}`,
        serviceName
      ];

      for (const pattern of patterns) {
        try {
          const result = execSync(
            `pgrep -f "${pattern}" 2>/dev/null | head -5`,
            { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }
          ).trim();

          const pids = result.split('\n').filter(p => p);
          for (const pidStr of pids) {
            const pid = parseInt(pidStr, 10);
            if (pid > 0) {
              try {
                process.kill(-pid, 'SIGTERM');
                await sleep(500);
                process.kill(-pid, 'SIGKILL');
              } catch (e) {
              }
            }
          }
        } catch (e) {
        }
      }

      this.log('INFO', `Killed process(es) for restart`, serviceName);
      return true;
    } catch (e) {
      this.log('WARN', `Could not kill service: ${e.message}`, serviceName);
      return false;
    }
  }

  async getLatestGitHubVersion(repo) {
    return new Promise((resolve) => {
      const timeoutId = setTimeout(() => {
        this.log('WARN', `GitHub timeout for ${repo}`);
        resolve(null);
      }, 8000);

      const options = {
        hostname: 'api.github.com',
        path: `/repos/${repo}/releases/latest`,
        method: 'GET',
        timeout: 8000,
        headers: { 'User-Agent': 'gmweb-version-check/1.0' }
      };

      try {
        https.request(options, (res) => {
          let data = '';
          res.on('data', (chunk) => { data += chunk; });
          res.on('end', () => {
            clearTimeout(timeoutId);
            try {
              const info = JSON.parse(data);
              const tagName = info.tag_name;
              if (tagName) {
                const version = tagName.startsWith('v') ? tagName.substring(1) : tagName;
                resolve(version);
              } else {
                resolve(null);
              }
            } catch (e) {
              this.log('WARN', `Failed to parse GitHub API for ${repo}`);
              resolve(null);
            }
          });
        }).on('error', () => {
          clearTimeout(timeoutId);
          resolve(null);
        }).end();
      } catch (e) {
        clearTimeout(timeoutId);
        resolve(null);
      }
    });
  }

  async checkForUpdates() {
    this.log('INFO', 'Starting version check cycle');

    for (const service of SERVICES_TO_MONITOR) {
      try {
        let latestVersion = null;

        if (service.type === 'github' && service.github) {
          latestVersion = await this.getLatestGitHubVersion(service.github);
        } else {
          latestVersion = await this.getLatestVersion(service.bundleName);
        }

        if (!latestVersion) {
          continue;
        }

        const currentVersion = this.getCurrentVersion(service.bundleName, service.localPath);

        if (!currentVersion) {
          this.log('DEBUG', `Not installed (skipped): ${service.bundleName}`, service.serviceName);
          continue;
        }

        this.versions.set(service.serviceName, {
          current: currentVersion,
          latest: latestVersion,
          lastChecked: new Date().toISOString()
        });

        if (this.isNewerVersion(latestVersion, currentVersion)) {
          this.log('INFO', `Update available: ${currentVersion} -> ${latestVersion}`, service.serviceName);

          await this.killServiceProcess(service.serviceName);
          this.log('INFO', `Restarted service for update`, service.serviceName);
        } else {
        }
      } catch (e) {
        this.log('ERROR', `Check failed: ${e.message}`, service.serviceName);
      }
    }

    this.log('DEBUG', 'Version check cycle complete');
  }

  async run() {
    this.log('INFO', 'Version check service started');
    this.log('INFO', `Checking for updates every ${this.checkInterval}ms (60s)`);

    await sleep(5000);

    await this.checkForUpdates();

    const intervalId = setInterval(() => {
      this.checkForUpdates().catch(e => {
        this.log('ERROR', `Cycle error: ${e.message}`);
      });
    }, this.checkInterval);

    await new Promise(() => {});
  }
}

export default {
  name: NAME,
  type: 'system',
  requiresDesktop: false,
  dependencies: [],

  async start(env) {
    console.log(`[${NAME}] Starting version check service...`);

    const checker = new VersionChecker();

    Promise.resolve().then(() => {
      checker.run().catch(err => {
        console.error(`[${NAME}] Fatal error:`, err.message);
      });
    });

    return {
      pid: process.pid,
      process: null,
      cleanup: async () => {
      }
    };
  },

  async health() {
    return true;
  }
};
