#!/bin/sh
#
# Entrypoint for the Baikal image.
#
# The only thing this image adds beyond upstream: it renders the MSMTPRC
# environment variable into the msmtp configuration file, so the relay
# credentials arrive at runtime and never have to live in the image.
#
# Without that file, sabre/dav's IMipPlugin still calls sendmail, msmtp finds
# no account and exits non-zero, and the invitation is dropped. Baikal reports
# nothing - the event simply looks sent. That silent failure is the whole
# reason this image exists, so the checks below are deliberately loud.
#
set -eu

readonly MSMTPRC_PATH="/etc/msmtprc"
readonly MSMTPRC_MODE="0600"
# PHP's mail() runs as the Apache user, so msmtp reads this file as that user.
# Left owned by root, mode 0600 would make it unreadable and every invitation
# would fail - hence the Apache user owns it, not root.
readonly MSMTPRC_OWNER="www-data:www-data"

# Writes the configuration verbatim. No escape interpretation: a relay password
# containing a backslash must survive unchanged.
write_msmtprc() {
    umask 077
    printf '%s\n' "${MSMTPRC}" > "${MSMTPRC_PATH}"
    chown "${MSMTPRC_OWNER}" "${MSMTPRC_PATH}"
    chmod "${MSMTPRC_MODE}" "${MSMTPRC_PATH}"
    echo "Wrote ${MSMTPRC_PATH} (${MSMTPRC_MODE}, ${MSMTPRC_OWNER})"
}

# A single-line dotenv value cannot hold real newlines, so the variable often
# arrives with two-character "\n" sequences instead. msmtp needs real line
# breaks and would read the whole thing as one unusable line, so say so.
warn_if_escaped_newlines() {
    if grep -q '\\n' "${MSMTPRC_PATH}"; then
        echo "WARNING: ${MSMTPRC_PATH} contains literal '\\n' sequences." >&2
        echo "WARNING: msmtp needs real line breaks - invitations will not be sent." >&2
    fi
}

if [ -n "${MSMTPRC:-}" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: MSMTPRC is set but this container is not running as root," >&2
        echo "ERROR: so ${MSMTPRC_PATH} cannot be written. Drop the user override." >&2
        exit 1
    fi
    write_msmtprc
    warn_if_escaped_newlines
fi

# Hand off to the base image entrypoint, which keeps its own convenience of
# treating a leading "-" as arguments to php. With the default CMD this ends up
# at apache2-foreground.
exec docker-php-entrypoint "$@"
