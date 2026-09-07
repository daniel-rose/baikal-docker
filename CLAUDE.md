# Hinweise für Claude

Dieses Repo baut ein Container-Image für Baïkal (CalDAV/CardDAV) und sonst
nichts. Kein Stack, kein Deploy, keine Konfiguration — die liegen im
konsumierenden Compose-Repo. Was das Image kann und wie man es betreibt, steht
in der [README](README.md); hier steht nur, was man wissen muss, um nichts
kaputt zu machen.

## Das Repo ist public — nichts Privates rein

Genau deshalb darf es public sein: **keine Secrets, keine Hostnamen, keine
E-Mail-Adressen, keine IP-Adressen.** Jeder konkrete Wert kommt zur Laufzeit.
Beispiele ausschließlich mit Platzhaltern: `<smtp-host>`, `<lan-ip>`,
`<relay-account>`, `dav.example.com`.

Freigegeben sind nur die beiden Image-Namen, die man zum Pullen braucht:
`ghcr.io/daniel-rose/baikal` und `danielrose85/baikal`. In den Workflows
trotzdem nie hartkodieren, sondern `github.repository_owner` bzw. das Secret
`DOCKERHUB_USERNAME`.

Eine public Git-History ist eine Einbahnstraße. Vor jedem Commit den Baum
gegen IP-Muster, Mailadress-Muster und private Hostnamen greppen.

## Version und Checksumme wandern zusammen

`BAIKAL_VERSION` und `BAIKAL_SHA256` sind ARGs im Dockerfile und werden **immer
gemeinsam** angehoben. Eine der beiden allein lässt den Build an `sha256sum -c`
scheitern — so gewollt, das ist die Prüfung und kein Ärgernis.

Deshalb gibt es auch keinen Bot, der die Version anhebt: die Checksumme kann
keiner berechnen, der das Archiv nicht heruntergeladen hat.
`upstream-release.yml` öffnet nur ein Issue.

Die Version steht ausschließlich im Dockerfile. Die Workflows lesen sie per
`sed` von dort. Keine zweite Kopie anlegen — Drift fällt erst als falsch
getaggtes Image in der Registry auf.

## Images immer `tag@sha256:digest`

Nie der Digest allein. Dependabot zieht einen Digest nur nach, wenn ein Tag
dabeisteht; ohne Tag wird die Zeile stillschweigend nie aktualisiert. Kein
`:latest` als Basis.

## Kein Composer, keine Extension-Builds

Das Release-Archiv bringt `vendor/` samt `autoload.php` mit, und alle nötigen
Extensions sind in `php:8.3-apache` enthalten (`pdo_sqlite` ist per
`--with-pdo-sqlite=/usr` einkompiliert). Wer hier `composer install` oder
`docker-php-ext-install` einbaut, verlängert den Build um Minuten und riskiert
den arm64-Zweig, ohne etwas zu gewinnen.

## Der Vhost hält sich aus der `.htaccess` raus

Die mitgelieferte `html/.htaccess` macht die 308-Redirects für
`.well-known/{caldav,carddav}` (mod_alias) und die
`HTTP_AUTHORIZATION`-Durchleitung (mod_rewrite) selbst. Der Vhost setzt nur
DocumentRoot und `AllowOverride All`.

Keine eigenen RewriteRules ergänzen. Doppelte Regeln sind der Weg, auf dem der
Authorization-Header verloren geht — und das sieht nicht wie ein Konfigfehler
aus, sondern wie „alle Clients haben plötzlich das falsche Passwort".
`+FollowSymLinks` muss bleiben, sonst verweigert mod_rewrite in einer
`.htaccess` den Dienst und die Autodiscovery ist still weg.

## Der Entrypoint ist die einzige Zutat

Er schreibt `$MSMTPRC` nach `/etc/msmtprc` und übergibt an
`docker-php-entrypoint` (und damit an `apache2-foreground`). Ist die Variable
leer oder ungesetzt, wird die Datei nicht angelegt.

**Mode `0600`, Owner `www-data` — nicht „härten" auf `root`.** PHPs `mail()`
ruft `/usr/sbin/sendmail` als `www-data` auf. Gehört die Datei root, kann msmtp
sie bei `0600` nicht lesen und jede Einladung scheitert stumm. Genau dieser
stille Fehlschlag ist der Grund, warum dieses Image existiert.

Der Inhalt wird verbatim geschrieben, ohne Escape-Interpretation — ein
Relay-Passwort mit Backslash muss unverändert ankommen.

## Fähigkeiten am Quellcode des Releases prüfen

Nicht an Issues, Mailinglisten oder Blogposts — die sind bei diesem Projekt
nachweislich veraltet. Bei jedem Versions-Sprung im entpackten Archiv
nachsehen: neue Extension-Anforderungen, Änderungen an `html/.htaccess`,
Lizenzangaben. Beispiel für den Nutzen: die Source-Header gewähren „GPL v2 or
any later version", während das Archiv den GPL-3-Text mitliefert — GitHub
zeigt nur letzteres.

Ein neu gebautes `latest` heißt nicht neue App-Version. Dafür
`org.opencontainers.image.version` lesen; das Label wird hier aus dem ARG
gesetzt, damit es nicht lügt.

## Das Package stellt Daniel selbst auf public

Ein GHCR-Package, das public war, kann nicht wieder private werden. Diesen
Schritt nicht vorschlagen und nicht ausführen — er passiert von Hand, nach dem
ersten grünen Build. Ebenso: nichts pushen, ohne vorher zu zeigen, was im
Commit steckt.

Der Package-Name ist `baikal`, nicht der Repo-Name — die Pull-Referenz soll
`ghcr.io/<owner>/baikal` lauten (`IMAGE_NAME` in `build.yml`).

## Verifikation vor dem Commit

Docker ist lokal da, also lokal belegen statt hoffen:

```sh
docker build -t baikal:test .
docker run --rm baikal:test php -m                      # die 12 + pdo_sqlite
docker run --rm baikal:test php -r 'echo ini_get("sendmail_path");'
docker run --rm -e MSMTPRC="account default" baikal:test stat -c '%a %U' /etc/msmtprc
docker run -d --name t -p 127.0.0.1:8080:80 baikal:test && curl -sSI http://127.0.0.1:8080/.well-known/caldav
```

Erwartung: alle Extensions vorhanden, `/usr/sbin/sendmail -t -i`,
`600 www-data`, `308` mit `Location: …/dav.php`. Für den Vollbeweis das
mitgelieferte Schema aus `Core/Resources/Db/SQLite/db.sql` in eine SQLite-Datei
laden und eine gemountete `config/baikal.yaml` dazugeben — dann muss
`/dav.php` mit `401` und `WWW-Authenticate: Basic` antworten.

Workflows nicht nur nach Augenmaß: YAML mit `ruby -ryaml` laden (PyYAML fehlt
auf dieser Maschine), das `run`-Skript herausziehen und mit `bash -n` prüfen.
Die Logik von `upstream-release.yml` lässt sich mit einem `gh`-Stub im `PATH`
komplett durchspielen, inklusive Dedupe-Zweig.

## Konventionen

- **Alles auf Englisch — außer dieser Datei.** Quellcode inklusive Kommentare,
  README, Workflows, Skript-Ausgaben, Commit-Messages.
- Kommentare nennen das **Symptom**, nicht die Mechanik: „ohne das sieht es aus
  wie ein falsches Passwort" ist nützlich, „setzt AllowOverride" nicht.
- Shell: POSIX `sh` mit `set -eu` im Entrypoint, `set -euo pipefail` in
  Workflow-Skripten. Konstanten am Dateikopf, eine Aufgabe pro Funktion.
- **Conventional Commits**, kein `Co-Authored-By`.
- Keine Dateien löschen ohne ausdrückliche Bestätigung.
- Actions per Major-Tag (`actions/checkout@v5`); Dependabot hält sie aktuell.
