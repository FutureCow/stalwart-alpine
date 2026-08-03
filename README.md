# Stalwart Mail Server — Alpine Linux install script

Installatie- en updatescript voor [Stalwart Mail Server](https://github.com/stalwartlabs/stalwart) op **Alpine Linux** (musl libc, `apk`, OpenRC).

Herschreven voor Alpine op basis van de [community-scripts/ProxmoxVED](https://github.com/community-scripts/ProxmoxVED) scripts (`ct/stalwart.sh` + `install/stalwart-install.sh`), die gericht zijn op Debian LXC-containers op Proxmox VE met systemd.

## Waarom deze versie?

| | Origineel (ProxmoxVED) | Deze versie |
|---|---|---|
| Package manager | `apt` | `apk` |
| Init systeem | systemd | **OpenRC** |
| Binary | glibc build | **musl build** (statisch gelinkt, geen gcompat nodig) |
| Priviliged ports (25/80/443) | — | `setcap cap_net_bind_service` |
| Service user | root | dedicated `stalwart` user |

## Gebruik

```sh
# Installeren (als root)
curl -fsSL https://raw.githubusercontent.com/FutureCow/stalwart-alpine/main/stalwart-alpine.sh | sh

# Of lokaal:
./stalwart-alpine.sh            # installeren (of herinstalleren)
./stalwart-alpine.sh update     # updaten naar nieuwste release
```

## Wat het script doet

1. Installeert dependencies via `apk` (curl, ca-certificates, tar, libcap)
2. Maakt een dedicated `stalwart` systeemuser aan
3. Downloadt de nieuwste **musl** release van GitHub (`stalwart-<arch>-unknown-linux-musl.tar.gz`, ondersteunt x86_64 en aarch64)
4. Deployt het binary naar `/opt/stalwart/stalwart`
5. Past `setcap cap_net_bind_service=+ep` toe (poort 25/80/443 binden zonder root)
6. Maakt data-directories: `/opt/stalwart_data/{etc,data,logs}` + `etc/stalwart.env` config-sjabloon (rechten 600)
7. Registreert een OpenRC-service (`/etc/init.d/stalwart`, start bij boot via `rc-update`)
8. Start de service

## Na installatie

- **Admin interface:** `http://<server-ip>:8080/admin`
- **Bootstrap wachtwoord** (eerste keer, staat in stderr-log):
  ```sh
  grep -A8 'bootstrap mode' /opt/stalwart_data/logs/stalwart.err
  # fallback: /opt/stalwart_data/logs/stalwart.log
  ```
- **Service beheren:**
  ```sh
  rc-service stalwart {start|stop|restart|status}
  ```
- **Instellingen:** `/opt/stalwart_data/etc/stalwart.env` (uitcommentarieer en pas aan, dan `rc-service stalwart restart`)

## Testen

Het script is getest in een schone Alpine 3.22 minirootfs (user namespace chroot):

- ✅ Installatie-flow draait volledig door (deps → user → download → deploy → setcap → dirs → service → start)
- ✅ Binary is statisch gelinkt en draait (Stalwart bootstrap mode start correct)
- ✅ `update`-modus gedraaid
- ✅ `rc_ulimit` syntax geverifieerd tegen OpenRC-broncode (`-n 65536`)
- ✅ POSIX `sh` compatibel (busybox ash — geen bash-ismen zoals brace-expansion)

## Licentie

MIT — gebaseerd op [community-scripts/ProxmoxVED](https://github.com/community-scripts/ProxmoxVED) (© 2021-2026 community-scripts ORG, auteur MickLesk).
