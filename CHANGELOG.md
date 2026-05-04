# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) | [Semantic Versioning](https://semver.org)

## [Unreleased]

## [1.1.0] - 2026-04-29

### Added
- Nginx SSL config: Option A (single bundle) and Option B (separate intermediate files)
- Note on checking newline between `-----END CERTIFICATE-----` and `-----BEGIN CERTIFICATE-----`
- `awk` fix command for missing newline between certs
- Step 6: Nginx configuration with test and reload commands

### Changed
- CSR table: Organization Name → `SEVEN SYSTEM VIET NAM JOINT STOCK COMPANY`, OU → `7Lab`, CN → `*.7-eleven.vn`
- Renewal checklist: added newline check and Nginx reload step

## [1.0.0] - 2026-04-26

### Added
- `README.md` — full guide: CSR generation → CA submission → chain assembly → K8s secret
- `bundle-cert.sh` — helper script to assemble and verify certificate chain
- 3 real-world Sectigo chain assembly cases documented
- Certificate verification steps (modulus check, openssl verify)
- Kubernetes Ingress TLS example
- Renewal checklist
