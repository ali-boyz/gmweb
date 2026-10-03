# gmweb Services

This directory contains all startup services for gmweb. Services are started in dependency order by the supervisor.

## Service Types

- **install**: One-time installation services (create wrappers, install packages)
- **system**: System services (tmux, scrot, etc.)
- **web**: Web services (file-manager, webssh2, etc.)
- **critical**: Critical services that block startup if they fail

## Key Services

### Core Infrastructure
- **tmux**: Shared terminal session at port 9999 (via ttyd)
- **webssh2**: Web-based SSH client via browser
- **scrot**: Screenshot utility for testing

### OpenCode CLI
- **opencode**: Creates npx wrapper for opencode-ai binary (CLI only)

### Development Tools
- **gm-oc**: OpenCode plugin with dev agents (gm, code-search, web-search)
- **claude-cli**: Claude command-line interface
- **claude-marketplace**: Claude Marketplace plugin installer
- **gemini-cli**: Google Gemini CLI wrapper
- **kilo-cli**: Kilo AI CLI wrapper
- **wrangler**: Cloudflare Wrangler CLI

### Utilities
- **file-manager**: NHFS web file browser at http://localhost:3001
- **playwriter**: Playwriter MCP relay for browser automation
- **chromium-ext**: Enables Chromium extensions (disabled by default)

### Installation Services
- **gcloud**: Google Cloud SDK installer
- **claude-plugin-gm**: GM plugin for Claude

## Service Dependencies

Services are executed in topological order. Specify dependencies in your service's export:

```javascript
export default {
  name: 'my-service',
  dependencies: ['service-a', 'service-b']
}
```

Example: services can specify dependencies to control startup order.

## Creating a New Service - DEAD SIMPLE

All services automatically get: proper PATH, PASSWORD, FQDN, logging, error handling, cleanup.

### Option 1: npx CLI wrapper (1 line!)
```javascript
import { npxWrapperService } from '../lib/service-templates.js';
export default npxWrapperService('my-cli', '@org/my-cli-package');
```

### Option 2: Web service on port (1 line!)
```javascript
import { webServiceOnPort } from '../lib/service-templates.js';
import { spawn } from 'child_process';

export default webServiceOnPort('my-web', 8000, (env) =>
  spawn('my-server', ['--port', '8000'], { env })
);
```

### Option 3: System daemon (1 line!)
```javascript
import { systemService } from '../lib/service-templates.js';
import { spawn } from 'child_process';

export default systemService('my-daemon', (env) =>
  spawn('daemon-binary', [...args], { env })
);
```

### Option 4: Custom service (if needed)
```javascript
import { customService } from '../lib/service-templates.js';

export default customService('complex-service', {
  async start(env) {
    console.log('[complex-service] Starting...');
    return { pid, process, cleanup };
  },
  
  async health() {
    return checkHealth();
  },
  
  dependencies: ['other-service'],
  type: 'web'
});
```

## Environment Variables

All services receive these environment variables from supervisor:

- `HOME`: User home directory (/config)
- `PATH`: Updated with NVM node bin path
- `PASSWORD`: HTTP Basic Auth password
- `COOLIFY_FQDN`: External domain (if deployed via Coolify)

Services may add their own environment variables before spawning.

## Health Checks

Health checks run every 30 seconds. Failed health checks trigger service restart with exponential backoff.

For install services, keep health checks lightweight - just check if wrapper/binary exists.

## Debugging

View service logs:
```bash
tail -f /config/logs/supervisor.log
tail -f /config/logs/services/my-service.log
```

Test service manually:
```bash
node /opt/gmweb-startup/index.js
```

## Common Issues

### Service won't start
- Check PATH includes `/usr/local/local/nvm/versions/node/v23.11.1/bin`
- Check HOME is set to `/config`
- Check dependencies are listed correctly

### Port already in use
- Kill existing process: `lsof -i :PORT | grep -v PID | awk '{print $2}' | xargs kill -9`

### npx wrapper fails
- Ensure full PATH is passed to spawn: `PATH: '/usr/local/local/nvm/versions/node/v23.11.1/bin:${env.PATH || '...'}'`
- Never rely on `/usr/bin/env` for node - always use full NVM path
