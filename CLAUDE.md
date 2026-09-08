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
trotzdem nie hartkodieren, sondern `github.repository_owner` bzw. die Variable
`vars.DOCKERHUB_USERNAME`.

Dieses Repo braucht **lokal keine Credentials** — `docker build` und
`docker run` kommen ohne aus, gepusht wird nur aus Actions. Also kein
`.env`, kein `direnv`, keine `.dist`-Vorlage; es gäbe nichts zu füllen.
Genau zwei Werte liegen in GitHub: `vars.DOCKERHUB_USERNAME` (Variable, weil
der Namespace Teil des öffentlichen Image-Namens ist und als Secret nur die
Logs zu `docker.io/***/baikal` maskieren würde) und
`secrets.DOCKERHUB_TOKEN` (Secret). GHCR braucht nichts davon, dort genügt
`GITHUB_TOKEN`. Der einzige echte Laufzeit-Secret ist `MSMTPRC`, und der
gehört ins Deploy-Repo, nicht hierher.

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

**Jeder Build erzeugt einen neuen Index-Digest, auch ohne inhaltliche
Änderung** — gemessen: ein Docs-only-Commit ergab einen neuen Digest, weil die
Provenance-Attestation Commit-SHA und Run-ID trägt. Dazu ist auch der Inhalt
nicht reproduzierbar: bei zwei Builds war das amd64-Manifest byte-identisch,
das arm64-Manifest nicht, weil der Cache dort nicht griff und `apt-get install`
holt, was der Mirror gerade ausliefert.

Daraus folgt: einem bestehenden Pin nicht hinterherlaufen. Alte Manifeste
bleiben abrufbar, der Pin bleibt gültig. Neu gepinnt wird, wenn die
Baïkal-Version oder eine Image-Eigenschaft sich ändert — nicht weil `latest`
weitergewandert ist.

## Kein Composer, keine Extension-Builds

Das Release-Archiv bringt `vendor/` samt `autoload.php` mit, und alle nötigen
Extensions sind in `php:8.5-apache` enthalten (`pdo_sqlite` ist per
`--with-pdo-sqlite=/usr` einkompiliert). Wer hier `composer install` oder
`docker-php-ext-install` einbaut, verlängert den Build um Minuten und riskiert
den arm64-Zweig, ohne etwas zu gewinnen.

Folge davon: **das Image kann nur Baïkals SQLite-Backend.** `pdo_mysql` und
`pdo_pgsql` fehlen, `mysqlnd` in `php -m` ist nur die Treiber-Bibliothek und
kein PDO-Treiber. Eine Bitte nach MySQL/PostgreSQL ist also ein
Extension-Build und widerspricht dieser Regel — nicht stillschweigend
einbauen, sondern die Konsequenz nennen.

## Ohne Datenbank antwortet `/dav.php` mit 200

Gemessen: liegt eine gerenderte `baikal.yaml` vor, aber keine
`Specific/db/db.sqlite`, liefert `/dav.php` **HTTP 200** und im Body einen
Stacktrace samt Dateisystempfaden („no connection to a database is
available"). Baïkal druckt den selbst in `Framework::bootstrap`, deshalb hilft
`display_errors = Off` dagegen nicht — deswegen trotzdem gesetzt, denn für
PHP-eigene Fehler greift es, und `expose_php = Off` entfernt `X-Powered-By`.

Folgen, die man nicht wegkonfigurieren kann: die Datenbank muss existieren,
bevor der Endpunkt erreichbar ist, und ein Healthcheck darf sich nie auf den
Statuscode allein stützen. Eine kaputte Instanz sieht damit gesund aus.

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
Lizenzangaben.

Das Archiv ist dabei nicht die einzige Quelle, und eine einzelne Quelle reicht
nicht. Zwei Lehren aus dem ersten Durchgang:

- **`composer.json` liegt nicht im Release-Archiv**, nur im Repo. Dort stehen
  aber die verbindlichen Angaben — `"php": "^8.2"` und
  `"license": "GPL-3.0-only"`. Holen mit
  `gh api "repos/sabre-io/Baikal/contents/composer.json?ref=<tag>" --jq .content | base64 -d`
  (URL quoten, sonst frisst zsh das `?ref=`).
- **Immer den Tag, nie master.** master trägt schon die nächste Version; ein
  Commit ohne Tag sagt nichts über das, was das Image ausliefert.
  `gh api repos/sabre-io/Baikal/commits/<sha>/branches-where-head` klärt das.

Widersprechen sich Quellen, gewinnt die maschinenlesbare Deklaration am Tag,
nicht ein Kommentarkopf: Baïkals Source-Header gewähren noch „GPL v2 or any
later version" (Boilerplate von 2013), deklariert und ausgeliefert wird aber
GPL-3.0-only. Das Label sagt deshalb `GPL-3.0-only`.

Ein neu gebautes `latest` heißt nicht neue App-Version. Dafür
`org.opencontainers.image.version` lesen; das Label wird hier aus dem ARG
gesetzt, damit es nicht lügt.

## Das GHCR-Package ist public — und bleibt es

Seit dem ersten Build ist es public, und ein public Package kann nicht wieder
private werden. Also nicht versuchen, das zurückzudrehen, und für den Pull
keine Registry-Credentials einbauen: dass die Docker-VM ohne auskommt, ist der
Grund für diese Entscheidung.

Sichtbarkeit anonym prüfen statt vermuten — die Package-Seite auf GitHub
beweist nichts, weil der Owner sie immer sieht, und ein lokaler `docker pull`
kann auf gespeicherten Credentials laufen:

```sh
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository%3Adaniel-rose%2Fbaikal%3Apull&service=ghcr.io" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.oci.image.index.v1+json" \
  https://ghcr.io/v2/daniel-rose/baikal/manifests/0.12.1
```

`200` heißt public. Nebenbei: `gh api user/packages/...` hilft hier nicht, dem
Standard-Token fehlt der `read:packages`-Scope.

Nichts pushen, ohne vorher zu zeigen, was im Commit steckt.

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
`600 www-data`, `308` mit `Location: …/dav.php`.

### Der Vollbeweis, wenn das Basis-Image sich ändert

Der Smoke-Test zeigt Build, Extensions und Redirects — er zeigt **nicht**, ob
Baïkal auf einer neuen PHP-Version noch läuft. Dafür gibt es diesen Ablauf; er
hat den Sprung auf PHP 8.5 entschieden:

1. Schema aus `Core/Resources/Db/SQLite/db.sql` in eine SQLite-Datei laden,
   `config/baikal.yaml` mit `configured_version` und `auth_realm` mounten,
   beides `chown www-data`.
2. Benutzer von Hand anlegen — `principals (uri='principals/<user>', email,
   displayname)` und `users (username, digesta1)` mit
   `digesta1 = md5("<user>:<realm>:<passwort>")`.
3. Dann gegen `/dav.php` fahren: `OPTIONS` muss `calendar-auto-schedule` im
   `DAV`-Header melden (sonst ist das RFC-6638-Plugin tot, und genau dafür gibt
   es dieses Setup), authentifizierter `PROPFIND` `207`, `MKCALENDAR` `201`,
   ein `PUT` mit VEVENT `201` und das `GET` danach `200` mit unveränderter
   `SUMMARY`, falsches Passwort `401`, `/admin/` `200`.
4. Zum Schluss `docker logs` auf `deprecat|fatal|uncaught|warning` prüfen —
   muss 0 ergeben.

Für `-u user:pass` bei `curl` den Authorization-Header selbst setzen
(`printf '%s:%s' u p | base64`) und `</dev/null` anhängen: sonst fragt curl
interaktiv nach dem Passwort und der Lauf hängt.

Ein Basis-Image-Bump ist nie nur die `FROM`-Zeile: die README nennt die
Version in der Prosa, in der Tabellenzeile „Base" und bei „Known limitations"
samt Support-Enddatum. Datum bei php.net nachsehen, nicht schätzen.

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
- Actions per Major-Tag (`actions/checkout@v7`); Dependabot hält sie aktuell.
  Mehrere Action-Bumps hintereinander mergen kollidiert, sobald zwei davon auf
  benachbarten Zeilen stehen (`setup-qemu` und `setup-buildx`) — dann nicht von
  Hand nachziehen, sondern `gh pr comment <nr> --body "@dependabot rebase"`
  und den grünen Check abwarten.
- In Beschreibungstexten, die von Hand gepflegt werden (Docker-Hub-Description,
  Image-`description`-Label), keine Versionsnummern — weder Baïkals noch die
  von PHP. Sie veralten beim ersten Bump, und niemand denkt daran. Versionen
  gehören ins `image.version`-Label, das aus dem ARG kommt.
