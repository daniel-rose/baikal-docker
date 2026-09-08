# baikal-docker

A container image for [Baïkal](https://sabre.io/baikal/), the CalDAV and
CardDAV server built on sabre/dav.

**The image adds exactly one thing to upstream:** an entrypoint that renders the
`MSMTPRC` environment variable into `/etc/msmtprc`, so scheduling invitations
are actually delivered and the relay credentials never live in the image.
Everything else is the release archive as published, unpacked and served.

```sh
docker pull ghcr.io/daniel-rose/baikal:0.12.1
```

---

## Why this image exists

There is no official Baïkal image; upstream points at the community image
`ckulka/baikal`. That image is not a path to a current version:

| Observation | Value |
|---|---|
| `latest`, rebuilt 2026-09-06, reports | `org.opencontainers.image.version = 0.10.1` |
| Newest version tag | `0.10.1`, from 2025-07-31 |
| Last commit in its build repository | 2025-07-31 |

0.10.1 predates the 0.12.1 fix for an authenticated XSS that lets a logged-in
user take over the admin interface by renaming a calendar.

Building is cheap, because the release archive is deploy-ready: it ships
`vendor/` including `autoload.php`, so there is **no Composer step**, and every
extension Baïkal needs is already in `php:8.5-apache` with `pdo_sqlite`
compiled in, so there is **no extension build**. The whole build is a verified
download and an unzip.

## What is in the image

| | |
|---|---|
| Base | `php:8.5-apache`, pinned as `tag@sha256:digest` - the `FROM` line is authoritative |
| Baïkal | 0.12.1, downloaded from the upstream release and checked against `BAIKAL_SHA256` |
| `msmtp`, `msmtp-mta` | `msmtp-mta` provides `/usr/sbin/sendmail`, PHP's default `sendmail_path`, so sabre/dav's `IMipPlugin` sends invitations with no `php.ini` change |
| Database backend | **SQLite only.** `pdo_sqlite` is compiled into the base image; `pdo_mysql` and `pdo_pgsql` are not installed |
| PHP configuration | `php.ini-production` installed, plus `expose_php = Off`. The base image ships no `php.ini` at all, which would leave `display_errors` on and print filesystem paths into responses |
| `sqlite3` | For consistent backups: a plain file copy of a live SQLite database can be torn, `.backup` cannot |
| Apache modules | `rewrite` and `expires` enabled, `alias` on by default - the three the shipped `html/.htaccess` uses |
| DocumentRoot | `/var/www/baikal/html`, with `AllowOverride All` |
| Exposed | Port 80, HTTP only. Terminate TLS in front of it |

The shipped `html/.htaccess` does the rest by itself: `308` redirects for
`/.well-known/caldav` and `/.well-known/carddav` to `/dav.php`, and passing
`HTTP_AUTHORIZATION` through to PHP. This image adds no rewrite rules of its
own, on purpose.

## Tags, and how to pin them

Every build is pushed to two registries. GHCR is authoritative; Docker Hub
exists so the image is findable where people look for one.

```
ghcr.io/daniel-rose/baikal:0.12.1
ghcr.io/daniel-rose/baikal:latest
danielrose85/baikal:0.12.1
danielrose85/baikal:latest
```

Both receive the same build, so the manifest digest is identical in both and a
pin stays valid whichever registry it is pulled from.

GHCR needs no configuration - the workflow authenticates with `GITHUB_TOKEN`.
Docker Hub needs a repository variable `DOCKERHUB_USERNAME` and a repository
secret `DOCKERHUB_TOKEN`; without them the build skips Docker Hub instead of
failing, which is also what a fork gets.

**Pin as `tag@sha256:digest`, never as a bare digest.** A digest on its own is
never updated by Dependabot - it needs a tag beside it to recognise the
reference at all.

A rebuild produces a **new index digest even when the image did not change**:
the provenance attestation records the commit and the workflow run, and an
`apt-get install` layer is not reproducible either. An existing pin stays
valid - old manifests are not deleted - so there is no need to chase the newest
digest. Re-pin when the Baïkal version or an image property changes, not
because `latest` moved.

```sh
docker buildx imagetools inspect ghcr.io/daniel-rose/baikal:0.12.1
```

## Running it

```yaml
services:
  baikal:
    image: ghcr.io/daniel-rose/baikal:0.12.1@sha256:<digest>
    restart: unless-stopped
    environment:
      # Rendered to /etc/msmtprc (0600, owned by the Apache user) at startup.
      # Keep the real value in whatever secret store you use, not in here.
      MSMTPRC: |
        account default
        host <smtp-host>
        port 587
        tls on
        tls_starttls on
        auth on
        user <relay-account>
        password <relay-password>
        from <relay-account>
    ports:
      # The admin interface is not meant to be public - see below. Binding a
      # single address is the point; a bare "8800:80" would publish it on
      # every interface the host gains later.
      - "<lan-ip>:8800:80"
    volumes:
      - ./config:/var/www/baikal/config
      - specific:/var/www/baikal/Specific

volumes:
  specific:
```

Two volumes, and both matter:

- `config/` holds `baikal.yaml`. Either let the web installer create it, or
  render it yourself and version it.
- `Specific/` holds the SQLite database at `Specific/db/db.sqlite` **and** the
  attachments, so one volume covers both.

### The configuration file has to be writable

Mount `config/` writable, not `:ro`. Baïkal writes `configured_version` into
`baikal.yaml` through its upgrade controller, and a read-only mount breaks the
upgrade path. The directory must be writable by the Apache user, uid 33.

Keep `configured_version` in step with the Baïkal version of the pinned image.
If it lags behind, Baïkal shows the upgrade wizard on every request. That makes
a version bump two coupled changes: the new digest and the new
`configured_version`.

### Sending invitations

`IMipPlugin` hands the message to `sendmail`, which is msmtp. Without
`MSMTPRC`, msmtp has no account, exits non-zero, and the invitation is dropped
while the event still looks sent - so set it, or accept that scheduling mail
goes nowhere.

`MSMTPRC` needs **real line breaks**. A single-line dotenv value cannot hold
them, and the entrypoint warns on stderr if the value arrives with literal
`\n` sequences instead.

If the relay is a freemail account, it will force the `From` address to equal
the authenticated account. Baïkal's `invite_from` must then be that same
address, or the mail is rejected by DMARC downstream.

### The admin interface is not meant to be public

`/admin/` is where users, calendars and address books are created. It is needed
during setup and then almost never - clients create calendars themselves with
`MKCALENDAR`, and shared calendars are client-initiated. It is also the
component the 0.12.1 fix is about.

Publish only the DAV paths through whatever proxy sits in front, for example
`^/(dav\.php|\.well-known/)`, and reach the admin interface over the address
bound above, or through an SSH local forward:

```sh
ssh -N -L 8800:<lan-ip>:8800 <host>
```

Both locks are worth having: the path restriction in the proxy, and a port
bound to one address rather than all of them.

## Backup

Use SQLite's `.backup`, not `cp`:

```sh
docker exec <container> sqlite3 /var/www/baikal/Specific/db/db.sqlite \
    ".backup '/var/www/baikal/Specific/db/backup.sqlite'"
docker cp <container>:/var/www/baikal/Specific/db/backup.sqlite ./
docker exec <container> rm /var/www/baikal/Specific/db/backup.sqlite
```

Back up `config/baikal.yaml` with it. It carries the admin password hash, which
is salted with `auth_realm`, and the database encryption key.

## Raising the Baïkal version

`BAIKAL_VERSION` and `BAIKAL_SHA256` are build arguments in the `Dockerfile`
and move **together**. Either one alone fails the build, which is intended.

```sh
VERSION=<new-version>
curl -fsSLO "https://github.com/sabre-io/Baikal/releases/download/${VERSION}/baikal-${VERSION}.zip"
sha256sum "baikal-${VERSION}.zip"
```

A scheduled workflow opens an issue when upstream publishes a release. It
deliberately does not raise the version: no bot can compute the checksum for a
release it has not downloaded, and a pull request with a stale checksum is
worse than a reminder.

Check new releases for changed extension requirements and for changes to
`html/.htaccess` **against the source in the archive**, not against issues or
blog posts.

## Verifying an image yourself

```sh
IMAGE=ghcr.io/daniel-rose/baikal:0.12.1

# Every extension Baikal needs, and the version label
docker run --rm "$IMAGE" php -m
docker image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}'

# The mail path
docker run --rm "$IMAGE" php -r 'echo ini_get("sendmail_path"), PHP_EOL;'
docker run --rm "$IMAGE" readlink -f /usr/sbin/sendmail

# The payload, and no Composer needed
docker run --rm "$IMAGE" ls /var/www/baikal/html/dav.php /var/www/baikal/vendor/autoload.php

# Autodiscovery, served by the shipped .htaccess
docker run -d --name baikal-check -p 127.0.0.1:8080:80 "$IMAGE"
curl -sSI http://127.0.0.1:8080/.well-known/caldav | head -n 2
docker rm -f baikal-check
```

## Known limitations

1. **Baïkal's `mysql` and `pgsql` backends do not work here.** Only
   `pdo_sqlite` is present, so either one fails at runtime with "could not
   find driver". Supporting them would mean the extension build this image
   deliberately does without.
2. **No brute-force protection on the DAV login.** Upstream has none, and this
   image adds none. If the endpoint is reachable from the internet, rate-limit
   it in front, and use long random passwords with no self-registration.
3. **The version is discoverable.** sabre/dav sets `X-Sabre-Version` on every
   response (`$exposeVersion = true`, with no configuration switch), so falling
   behind on updates is visible from outside.
4. **linux/arm64 is built and smoke-tested under emulation**, not on arm64
   hardware.
5. **The pinned base image is PHP 8.5**, which has active support until
   31 December 2027 and security support until 31 December 2029. That is the
   runway before it has to move.
6. **No configuration ships with the image.** `baikal.yaml` is yours to create
   or render; nothing here has an opinion about its contents.
7. **An instance without a database answers `/dav.php` with HTTP 200** and a
   Baïkal stack trace in the body ("no connection to a database is
   available"), disclosing filesystem paths. Baïkal prints that itself, so
   `display_errors = Off` does not suppress it. Two consequences: create the
   database before the endpoint is reachable, and never health-check this
   service on the status code alone - a broken instance looks healthy.

## License

The files in this repository - `Dockerfile`, Apache configuration, entrypoint
and workflows - are MIT licensed; see [LICENSE](LICENSE).

The image content is not. Baïkal declares `GPL-3.0-only` in its `composer.json`
at the release tag and ships the GPL-3 text in the archive. PHP, Apache, msmtp
and SQLite carry their own licenses.
