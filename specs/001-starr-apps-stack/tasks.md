# Tasks for Starr Apps Media Stack

**Date**: 2025-09-09

This document lists the tasks to implement the Starr Apps Media Stack.

## Task List

1.  **Create `starr-apps.yaml` file**: Create the main Docker Compose file in the `stacks` directory.
2.  **Add Sonarr service**: Add the Sonarr service definition to `starr-apps.yaml`, ensuring the volume mappings are `/mnt/spool/apps/config/sonarr:/config` and `/mnt/dpool/media:/media`.
3.  **Add Radarr service**: Add the Radarr service definition to `starr-apps.yaml`, ensuring the volume mappings are `/mnt/spool/apps/config/radarr:/config` and `/mnt/dpool/media:/media`.
4.  **Add Prowlarr service**: Add the Prowlarr service definition to `starr-apps.yaml`, ensuring the volume mapping is `/mnt/spool/apps/config/prowlarr:/config`.
5.  **Add Sabnzbd service**: Add the Sabnzbd service definition to `starr-apps.yaml`, ensuring the volume mappings are `/mnt/spool/apps/config/sabnzbd:/config` and `/mnt/dpool/media/usenet:/downloads`.
6.  **Add qBittorrent service**: Add the qBittorrent service definition to `starr-apps.yaml`, ensuring the volume mappings are `/mnt/spool/apps/config/qbittorrent:/config` and `/mnt/dpool/media/torrents:/downloads`.
7.  **Add Flaresolverr service**: Add the Flaresolverr service definition to `starr-apps.yaml`, ensuring the volume mapping is `/mnt/spool/apps/config/flaresolverr:/config`.
8.  **Add Unpackerr service**: Add the Unpackerr service definition to `starr-apps.yaml`, ensuring the volume mappings are `/mnt/spool/apps/config/unpackerr:/config` and `/mnt/dpool/media:/media`.
9.  **Add Cloudflared service**: Add the Cloudflared service definition to `starr-apps.yaml`, ensuring the volume mapping is `/mnt/spool/apps/config/cloudflared:/config`.
10. **Add Recyclarr service**: Add the Recyclarr service definition to `starr-apps.yaml`, ensuring the volume mapping is `/mnt/spool/apps/config/recyclarr:/config`.
11. **Define network**: Define the `starr_media_network` in `starr-apps.yaml`.
11. **Update `stack.env` file**: Ensure the required variables are present in the `stacks/stack.env` file.
13. **Update documentation**: Update the project's main documentation to include the new stack.
14. **Test the stack**: Follow the `quickstart.md` guide to deploy and test the stack.
