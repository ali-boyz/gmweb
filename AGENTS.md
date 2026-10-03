# Operational facts

- Native browser WebSocket handshakes cannot supply the site HTTP Basic credentials. The `/sync` and `/gm/sync` Nginx locations therefore disable Basic auth while preserving their AgentGUI upstream and upgrade routing.
- The Compose service references `gmweb-h1@file`; deployment must provide that Traefik transport through its file provider.
- Only `99-gmweb-startup.sh` is executable in `/custom-cont-init.d`; it invokes the non-executable helper scripts so s6 does not start them independently.
