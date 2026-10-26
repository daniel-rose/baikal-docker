---
paths:
  - README.md
---

# The README does not name the current Baïkal version

The version lives in the `Dockerfile` only. A number in the README is a second
copy, and every bump that forgets it leaves examples pointing at an old image.

- Pull, pin and inspect examples use `<version>`; the quick start uses
  `:latest`, marked as for trying it out, and links the GHCR package page for
  the list of versions.
- Where the README has to say which version is shipped, it points at
  `BAIKAL_VERSION` and the `org.opencontainers.image.version` label.
- A version stays when it states a fact rather than the current state, such as
  "the 0.12.1 fix for an authenticated XSS".
- PHP is the exception: the base image version stays in the prose, in the
  "Base" row and under "Known limitations" with its support end date, because
  that date cannot be stated without it.
- No version badge: shields.io only covers Docker Hub, and Docker Hub is the
  mirror, not the authority.
