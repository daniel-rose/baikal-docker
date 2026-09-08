# Baikal - CalDAV and CardDAV server, built on the official PHP Apache image.
#
# There is no official Baikal image. This one exists because the community
# image has been stuck on 0.10.1 since 2025-07-31, which predates the 0.12.1
# fix for an authenticated XSS in the admin interface.
FROM php:8.3-apache@sha256:060ed9c0f6e4bbe4f8b25a34ca1ec596b96d8f4011cf7ee7eb6b7eecf01cb74f

# Raise these two together, always. The download is checked against
# BAIKAL_SHA256, so a version bump carrying a stale checksum fails the build
# instead of shipping an unverified release.
ARG BAIKAL_VERSION=0.12.1
ARG BAIKAL_SHA256=0449abb72b151d39d9c08c63cb83a05d9e9adb065b1165ef6786b0b6a13d203c

# image.version is set from the ARG on purpose: a rebuilt "latest" whose
# version label still names the old release is exactly how the community image
# hid the fact that it had not moved in thirteen months.
#
# The licence expression is upstream's own declaration: composer.json at the
# release tag says "GPL-3.0-only", and the archive ships the GPL-3 text. Some
# source headers still carry 2013 boilerplate granting "version 2 of the
# License, or (at your option) any later version" - stale, and not what the
# project declares today.
LABEL org.opencontainers.image.title="Baikal" \
      org.opencontainers.image.description="Baikal CalDAV and CardDAV server on PHP and Apache, SQLite backend, with msmtp so scheduling invitations are delivered" \
      org.opencontainers.image.version="${BAIKAL_VERSION}" \
      org.opencontainers.image.source="https://github.com/daniel-rose/baikal-docker" \
      org.opencontainers.image.licenses="GPL-3.0-only"

# msmtp-mta provides /usr/sbin/sendmail, which is PHP's default sendmail_path,
# so sabre/dav's IMipPlugin sends invitations without any php.ini change.
# sqlite3 is here for consistent backups: a plain file copy of a live SQLite
# database can be torn, ".backup" cannot.
# unzip is not part of the base image; curl and ca-certificates already are.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        msmtp \
        msmtp-mta \
        sqlite3 \
        unzip \
    ; \
    rm -rf /var/lib/apt/lists/*

# The release archive is deploy-ready: it ships vendor/ including autoload.php,
# so there is no Composer step, and every extension Baikal needs is already in
# the base image (pdo_sqlite is compiled in via --with-pdo-sqlite=/usr), so
# there is no extension build either.
# The archive unpacks into a "baikal/" directory, hence /var/www as the target.
#
# The chown has to happen here, before VOLUME: an anonymous volume inherits the
# ownership of the image directory, and if that is root the web installer
# cannot create the database - which presents itself as a blank error page.
RUN set -eux; \
    curl -fsSL -o /tmp/baikal.zip \
        "https://github.com/sabre-io/Baikal/releases/download/${BAIKAL_VERSION}/baikal-${BAIKAL_VERSION}.zip"; \
    echo "${BAIKAL_SHA256}  /tmp/baikal.zip" | sha256sum -c -; \
    unzip -q /tmp/baikal.zip -d /var/www; \
    rm /tmp/baikal.zip; \
    chown -R www-data:www-data /var/www/baikal/config /var/www/baikal/Specific

# rewrite and expires are what the shipped html/.htaccess uses; mod_alias is
# enabled by default on Debian.
RUN set -eux; \
    a2enmod rewrite expires; \
    a2dissite 000-default

COPY apache/baikal.conf /etc/apache2/sites-available/baikal.conf
RUN a2ensite baikal

# --chmod rather than a following RUN: the mode is then independent of whatever
# the checkout left on the file.
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

WORKDIR /var/www/baikal

# config holds baikal.yaml, Specific holds the SQLite database at
# Specific/db/db.sqlite together with the attachments.
VOLUME ["/var/www/baikal/config", "/var/www/baikal/Specific"]

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["apache2-foreground"]
