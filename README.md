# Edge Image Builder - PostgreSQL Podman Lab

Build a **single-node** SUSE Linux Micro 6.2 edge image that runs **SUSE PostgreSQL 18 in a Podman container**, managed by a **systemd Quadlet** so it survives reboots, using the [SUSE Edge Image Builder](https://github.com/suse-edge/edge-image-builder).

This is the lightweight, no-Kubernetes counterpart to [eib-psql-lab](https://github.com/achuza/eib-psql-lab) (the HA CloudNativePG variant). Use this when you want a single edge box that just runs Postgres — no k3s, no Rancher, no Longhorn.

---

## Architecture

| Layer | What it is |
|---|---|
| **Base OS** | SUSE Linux Micro 6.2 (immutable, transactional) |
| **Container engine** | Podman (installed from SL Micro packages) |
| **Database** | SUSE PostgreSQL 18 (`registry.suse.com/suse/postgres:18`, embedded in the ISO) |
| **Process supervision** | systemd Quadlet → `/etc/containers/systemd/postgres.container` → auto-generated `postgres.service` |
| **Data persistence** | Host bind mount `/var/lib/postgres/data` → container `/var/lib/postgresql/data` |
| **Credentials** | Generated on first boot by a combustion script, stored at `/etc/postgres/postgres.env` |
| **External access** | Container port `5432` published on the host |
| **HA / replication** | None — single instance |

### Repo layout

```
psql-podman/
  eib-config.yaml                                    # EIB definition (no k8s block)
  custom/scripts/10-postgres-bootstrap.sh            # First-boot: generate password + env file
  os-files/etc/containers/systemd/postgres.container # Quadlet: postgres.service at boot
  os-files/etc/ssh/sshd_config                       # Enables root SSH
  network/psql.suse.com.yaml                         # Static net config (optional; delete for DHCP)
```

---

## Prerequisites

- [SL Micro 6.2 ISO](https://www.suse.com/download/sle-micro/) — `SL-Micro.aarch64-6.2-Default-SelfInstall-GM.install.iso`
- A valid SUSE registration code (needed at build time to install `podman` from SCC)
- [Podman](https://podman.io/) on the build host
- [UTM](https://mac.getutm.app/) on macOS (optional, for local testing)

---

## Build

### 1. Set up Podman on the build host (macOS)

```bash
brew install podman
podman machine init --cpus 6 --memory 8192 --disk-size 100
podman machine start
```

### 2. Pull Edge Image Builder

```bash
podman pull registry.suse.com/edge/3.5/edge-image-builder:1.3.2
```

### 3. Prepare the build directory

```bash
cd psql-podman
mkdir base-images
mv ~/Downloads/SL-Micro.aarch64-6.2-Default-SelfInstall-GM.install.iso \
   base-images/SL-Micro.aarch64-6.2-Default-SelfInstall-GM.install.iso
```

### 4. Add your SUSE registration code

Edit `eib-config.yaml`:

```yaml
operatingSystem:
  packages:
    sccRegistrationCode: YOUR-REGISTRATION-CODE-HERE
```

### 5. (Optional) Adjust networking

`network/psql.suse.com.yaml` ships with a static IP (`192.168.64.11/24`, gateway `192.168.64.1`) and a placeholder MAC address. Either:
- Edit `mac-address` to match your VM/host and adjust the IP, **or**
- Delete `network/psql.suse.com.yaml` to fall back to DHCP.

### 6. Build the ISO

```bash
podman run --privileged --rm -it \
  -v $(pwd):/eib \
  registry.suse.com/edge/3.5/edge-image-builder:1.3.2 \
  build --definition-file eib-config.yaml
```

Output: `psql-podman-aarch64-6.2.iso`.

---

## Deploy

### UTM (macOS)

1. Create a single VM in UTM (Virtualize → Linux).
2. Recommended: 4 CPU / 4 GB RAM / 40 GB disk.
3. Boot from `psql-podman-aarch64-6.2.iso`.
4. The image self-installs to `/dev/vda` and reboots.
5. On first boot, combustion runs `10-postgres-bootstrap.sh`, which generates a random superuser password and prints it to the console (see screenshot or `journalctl -b` after login).

### Network notes

If you kept the static network config:
- Host: `psql.suse.com`
- IP: `192.168.64.11/24`
- Gateway: `192.168.64.1`

UTM's default shared network uses `192.168.64.x`, so this should "just work" on a Mac.

---

## First Boot — Retrieving the Password

The password is generated **once** on first boot and printed to the console. If you missed it, grab it from the env file after logging in as root:

```bash
sudo grep POSTGRES_PASSWORD /etc/postgres/postgres.env
```

Or from the journal:

```bash
sudo journalctl -b | grep -A1 'PostgreSQL superuser password'
```

> **Heads up:** the password lives in `/etc/postgres/postgres.env` with mode `600`, root-owned. Rotate it manually if needed (update the file, then `systemctl restart postgres.service`).

---

## Working with PostgreSQL

### Verify the service

```bash
systemctl status postgres.service
podman ps
podman logs postgres
```

The `postgres.service` is generated at boot from `/etc/containers/systemd/postgres.container` by `podman-system-generator`. You won't find a static `postgres.service` file on disk — that's expected.

### Connect from inside the VM

```bash
podman exec -it postgres psql -U postgres
```

### Connect from outside the VM

```bash
psql -h 192.168.64.11 -U postgres
# password: <value from /etc/postgres/postgres.env>
```

(Or whatever IP DHCP assigned, if you removed the static network file.)

### Inspect data

The PostgreSQL data directory lives at `/var/lib/postgres/data` on the host (bind-mounted into the container at `/var/lib/postgresql/data`):

```bash
sudo ls /var/lib/postgres/data
```

This survives reboots, `podman rm`, and image pulls — it's only tied to the host filesystem.

---

## Managing the Container

The quadlet is a regular systemd unit (after generation), so use `systemctl`:

```bash
sudo systemctl restart postgres.service
sudo systemctl stop postgres.service
sudo systemctl start postgres.service
sudo systemctl status postgres.service
journalctl -u postgres.service -f
```

After editing `/etc/containers/systemd/postgres.container`, reload the generator and restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart postgres.service
```

---

## Customization

### Change the data directory

Edit `psql-podman/os-files/etc/containers/systemd/postgres.container`:

```ini
Volume=/srv/postgres-data:/var/lib/postgresql/data:Z
```

And update `10-postgres-bootstrap.sh` so it `mkdir`s the new path. Useful if you want to put the data on a separate disk — partition/mount it before first boot, then bind-mount.

### Change the published port

```ini
PublishPort=15432:5432
```

### Use a different Postgres image

Swap `Image=` in the quadlet, **and** update `embeddedArtifactRegistry.images` in `eib-config.yaml` so the new image is bundled into the ISO (otherwise it'll try to pull at first start and fail if the VM has no internet).

### Pin a stronger / weaker password policy

Edit `10-postgres-bootstrap.sh` — adjust `head -c 32` (length) or the `tr -dc` character class (e.g., add `_-!@%` for symbols).

### Run as a non-privileged container

Add `User=postgres` and adjust the volume ownership. The SUSE postgres image runs as uid 999 by default — bind mounts may need matching ownership on the host.

---

## Troubleshooting

### Build failures

- **"No space left on device"** — increase Podman machine disk: `podman machine rm && podman machine init --cpus 6 --memory 8192 --disk-size 100`
- **"Permission denied"** — the build needs `--privileged`
- **Package install failures** — verify SCC registration code is valid

### postgres.service doesn't start

Check the generator picked up the quadlet:

```bash
sudo systemctl list-unit-files | grep postgres
sudo /usr/libexec/podman/podman-system-generator --user=0 --dry-run
```

If the unit is missing, the quadlet syntax is probably wrong. Check `journalctl -b | grep -i quadlet`.

### Container exits immediately

```bash
podman logs postgres
```

Most common cause: `POSTGRES_PASSWORD` empty or missing — verify `/etc/postgres/postgres.env` exists and is readable by root.

### Embedded image didn't pull

If `podman ps -a` shows the container failing with "image not found", the embedded artifact registry may not have populated for podman. Manually pull:

```bash
sudo podman pull registry.suse.com/suse/postgres:18
sudo systemctl restart postgres.service
```

(Requires network access. EIB's embedded registry is primarily wired for k3s/RKE2; podman pulls may not auto-mirror in all EIB versions.)

---

## Resources

- [Podman Quadlet documentation](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
- [SUSE PostgreSQL container](https://registry.suse.com/suse/postgres)
- [Edge Image Builder](https://github.com/suse-edge/edge-image-builder)
- [SUSE Linux Micro Downloads](https://www.suse.com/download/sle-micro/)
- [Sibling repo: eib-psql-lab (HA CloudNativePG variant)](https://github.com/achuza/eib-psql-lab)
