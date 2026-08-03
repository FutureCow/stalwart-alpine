# lego + mijn.host — ACME certificaten voor Stalwart op Alpine

Installatie- en renewal-script voor **Let's Encrypt-certificaten** via de **mijn.host DNS-API** (DNS-01 challenge), met automatische reload in **Stalwart Mail Server**.

## Waarom dit script?

Stalwart's ingebouwde ACME ondersteunt 70 DNS-providers, maar **mijn.host ontbreekt** in die lijst. [lego](https://go-acme.github.io/lego/) (de ACME-client van Go) ondersteunt mijnhost wél sinds v4.18.0. Dit script:

1. Installeert **lego** (static binary, werkt op Alpine x86_64/aarch64)
2. Installeert **stalwart-cli** (voor de certificaat-reload)
3. Vraagt certificaten aan via de mijnhost DNS-API (`MIJNHOST_API_KEY`)
4. Laadt ze automatisch in Stalwart na elke renewal (`ReloadTlsCertificates`)

**Voordelen:** wildcards mogelijk (`*.domein.nl`), werkt zonder open poort 80/443, volledig geautomatiseerd via cron.

## Installatie

```sh
# Script downloaden en uitvoerbaar maken
curl -fsSL https://raw.githubusercontent.com/FutureCow/stalwart-alpine/main/lego-mijnhost-alpine.sh -o /usr/local/bin/lego-mijnhost-alpine.sh
chmod +x /usr/local/bin/lego-mijnhost-alpine.sh

# Installeren (binaries + config-sjablonen)
/usr/local/bin/lego-mijnhost-alpine.sh install
```

Daarna twee config-bestanden invullen:

**`/etc/lego/lego.env`** (rechten 600):
```sh
MIJNHOST_API_KEY=jouw-mijnhost-api-key     # https://mijn.host/api/doc
LEGO_EMAIL=jij@voorbeeld.nl                # contact voor Let's Encrypt
STALWART_URL=http://localhost:8080         # Stalwart admin endpoint
STALWART_USER=admin
STALWART_PASSWORD=jouw-admin-wachtwoord
# Optioneel (test eerst met staging!):
#LEGO_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory
```

**`/etc/lego/domains.conf`** (één domein per regel):
```
mail.domein1.nl
mail.domein2.nl
*.domein3.nl
```

## Certificaten aanvragen

```sh
/usr/local/bin/lego-mijnhost-alpine.sh
```

**Tip:** doe de eerste aanvraag met `LEGO_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory` in `lego.env` (staging, geen rate-limits). Als het werkt, verwijder je die regel voor productie.

## Koppelen aan Stalwart

In de Stalwart WebUI (*Settings › TLS › Certificates*) een Certificate-object aanmaken:

| Veld | Waarde |
|---|---|
| `certificate` | File → `/etc/lego/certificates/<domein>.crt` |
| `privateKey` | File → `/etc/lego/certificates/<domein>.key` |

Doe dit voor elk domein. (Wildcards leveren één certificaat op voor alle subdomeinen.)

## Automatische renewal (cron)

```sh
/usr/local/bin/lego-mijnhost-alpine.sh cron
```

Dit voegt een maandelijkse cron-job toe (1e van de maand, 03:00) die:
1. `lego renew` draait (vernieuwt alleen als het certificaat < 30 dagen geldig is)
2. Bij vernieuwing Stalwart automatisch herlaadt via `stalwart-cli`

**Handmatig:** `/usr/local/bin/lego-mijnhost-alpine.sh renew` of `... reload`

## Gebruik

| Commando | Functie |
|---|---|
| `lego-mijnhost-alpine.sh` | Installeren + eerste aanvraag |
| `lego-mijnhost-alpine.sh install` | Alleen binaries + config |
| `lego-mijnhost-alpine.sh renew` | Renewals draaien (handmatig) |
| `lego-mijnhost-alpine.sh reload` | Alleen Stalwart-reload |
| `lego-mijnhost-alpine.sh cron` | Cron-job installeren |

## Testen

Getest in een schone Alpine 3.22 minirootfs (user namespace chroot):

- ✅ lego v5.3.1 + stalwart-cli v1.0.12 installatie (beide statisch gelinkt)
- ✅ Config-sjablonen met rechten 600/700
- ✅ Issue-route: `lego run --dns mijnhost --email ... --domains ...` (incl. wildcards)
- ✅ Renewal-route: `lego renew --days 30` + hook naar reload
- ✅ Reload-hook: `stalwart-cli create x:Action/ReloadTlsCertificates`
- ✅ Cron: maandelijks, idempotent

## Licentie

MIT — zie [FutureCow/stalwart-alpine](https://github.com/FutureCow/stalwart-alpine).
