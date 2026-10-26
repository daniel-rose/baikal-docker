---
name: baikal-upgrade
description: Prove that existing installations survive a Baïkal version bump - run the release's database migrations through the upgrade wizard against data written by the previous image. Use when raising BAIKAL_VERSION, when an upstream-release issue is being worked, or when a release adds a block to VersionUpgrade.php. Not for the smoke test or the full proof on a fresh database (CLAUDE.md, "Verifikation vor dem Commit").
---

# Upgrade test for a Baïkal version bump

The full proof in `CLAUDE.md` starts from a fresh database. It does not show
that a database written by the previous release still works after the bump,
and that is where a release's migrations run.

## Find the migrations first

Diff `Core/Frameworks/BaikalAdmin/Controller/Install/VersionUpgrade.php` and
`Core/Resources/Db/SQLite/db.sql` between the two extracted archives. A block
gated on `version_compare($sVersionFrom, '<new>', '<')` with an `sqlite` branch
is what this test has to exercise. Seed the old database with the data that
block exists for - for 0.13.0 that was a `calendarinstances` row with `access`
and `share_invitestatus` both `NULL`.

## How the wizard behaves

- It runs only while `configured_version !== BAIKAL_VERSION`. A hand-edited
  `configured_version` skips every migration, silently.
- Until it has run, every request - `/dav.php` included - is redirected to
  `admin/install/`.
- It asks for no login. "Start upgrade" is a plain
  `GET /admin/install/index.php?upgradeConfirmed=true`; no session, no CSRF
  token.
- A failed migration renders an HTML error page that can still be `200`.
  Assert the text `successfully upgraded`, never the status code.

## Procedure

1. Build both images: the new one as `baikal:test`, the old release as
   `baikal:old` with `--build-arg BAIKAL_VERSION=<old> --build-arg
   BAIKAL_SHA256=<old-sha>`.
2. Create two named volumes for `config/` and `Specific/`. Copy a
   `baikal.yaml` with `configured_version: <old>`, `dav_auth_type: Basic` and a
   non-empty `admin_passwordhash` into a stopped `baikal:old` container, load
   the old `db.sql` with `sqlite3` inside it, add a user as described in
   `CLAUDE.md`, `chown -R www-data` both directories.
3. Against `baikal:old`: `MKCALENDAR` and `PUT` an event through `/dav.php`,
   so the data is written by the old release and not by hand. Then insert the
   rows the migration exists for.
4. Replace the container with `baikal:test` on the same volumes. Check that
   `/dav.php` redirects to `admin/install/`, then call
   `?upgradeConfirmed=true` and assert `successfully upgraded`.
5. Check the result: the schema from `sqlite_master`, the migrated values, the
   row count, `configured_version: <new>` written back into `baikal.yaml`.
6. Read the old data back: authenticated `PROPFIND` `207`, `GET` of the event
   `200` with an unchanged `SUMMARY`. A bare "`/dav.php` answers" proves
   nothing - a broken instance answers `200` too.
7. `docker logs` grepped for `deprecat|fatal|uncaught|warning` must be 0.

Use `Authorization: Basic` with `</dev/null`, as in `CLAUDE.md`, so curl never
waits for a password. Use a container name longer than one character - Docker
rejects `--name t`.
