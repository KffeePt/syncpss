# Security Policy

## Reporting

- Do not open public issues for vulnerabilities that could expose secrets, private repo access, installer trust issues, or unsafe data handling.
- Report security issues privately to the maintainer channel you already use for this project.

## Project Boundaries

- The public `syncpss` repo contains application code and release assets.
- Each user's password data belongs in that user's private password-store repo.
- Runtime metadata and local settings must stay user-owned and minimize plaintext sensitive data.

## Current Security Posture

- Release installs are expected to use published release assets, not raw branch scripts.
- Host/IP/MAC metadata logging is off by default.
- Notes are stored in the encrypted password store path, not in plaintext runtime files.
