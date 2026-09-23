# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) | [Semantic Versioning](https://semver.org)

## [Unreleased]

## [2.1.0] - 2026-09-23

### Added
- **`check-cert.sh`** — a verification-only pre-apply gate, separate from `bundle-cert.sh`.
  Takes a certificate bundle and private key (`-c` / `-k`), or reads `tls.crt` and `tls.key`
  straight out of a Kubernetes TLS Secret YAML (`-f`), so it checks the exact bytes being
  applied rather than the files they were supposedly built from. Runs 10 checks:
  PEM parse, intermediate present (names the exact missing CA subject), chain order,
  self-signed root placement, verification against the system trust store, key/cert match,
  validity window, SAN hostname coverage (with wildcard matching), signature algorithm and
  key strength, and a live local TLS handshake. Exits `0` pass, `1` failed, `2` bad usage.
- `check-cert.sh` flags: `-H` to assert specific hostnames, `--days N` for an expiry warning
  threshold, `--live HOST` to diff against the certificate a host serves today,
  `--no-handshake` for sandboxes that cannot bind a port, `--lenient` to downgrade a
  wrong chain order to a warning, `-q` for a verdict-only line suitable for
  `check-cert.sh -q && kubectl apply -f ...`.
- README Step 4 now leads with the gate script; the manual commands remain as explanation.
- README: helper-scripts section split into "check (gate)" and "bundle (assemble)", with a
  flag reference and exit-code table.
- Renewal checklist: gate must pass on the bundle *and* again on the Secret YAML.

### Why
The chain order and missing-intermediate faults that broke the September 2026 renewal both
verify clean under `openssl verify -untrusted`, which ignores ordering. Separating "is this
chain complete" from "is this chain ordered" is the point of the new script — check 5 passes
on a misordered bundle while check 3 fails it.

## [2.0.0] - 2026-09-22

Rewrite driven by a production incident: a renewal bundle was assembled by following the
Case 1 example in v1.1.0, which put the root before the intermediate and omitted the
intermediate entirely. Every verification command in v1.1.0 passed on that broken bundle.

### Fixed
- **Case 1 chain order was wrong** — listed `USERTrust...` (root) *before*
  `Sectigo_RSA_Domain_Validation_Secure_Server_CA` (intermediate). The same wrong order was
  repeated in the `bundle-cert.sh` usage examples. Order is always leaf → intermediate → root.
- **`openssl verify -CAfile bundle.crt bundle.crt` is a false pass** — it trusts the bundle
  being tested, so it prints `OK` on a broken or untrusted chain. Replaced with
  `openssl verify -untrusted <chain> <leaf>` against the system trust store.
- **`grep -c "BEGIN CERTIFICATE"` does not detect a missing newline** — it counts matching
  *lines*, so a glued `-----END CERTIFICATE----------BEGIN CERTIFICATE-----` boundary still
  counts as one. Verified: two CA files concatenated with `cat` parse as **0** certificates
  while that check reports **2**. Replaced with `openssl crl2pkcs7 | openssl pkcs7 -print_certs`.
- **The `awk` newline fix did not work** — it only matched `-----END CERTIFICATE-----` on its
  own line, which is exactly the case that is not broken. Replaced with
  `openssl x509 -in FILE -outform PEM`, which normalises framing and CRLF.
- **Key-match check used `-modulus`**, which fails on ECDSA keys. Now compares public keys via
  `openssl x509 -pubkey` / `openssl pkey -pubout` / `openssl req -pubkey`, covering the CSR too.

### Added
- Step 3: derive the chain order from the files instead of guessing — a subject/issuer loop
  over `*.crt`, plus the `issuer → subject` rule and how to spot a self-signed root.
- Step 3: Sectigo 2026 root migration note — a renewal often arrives on a *different*
  intermediate, so last year's bundle cannot be reused with the leaf swapped.
- Step 3: chain cases table, now 4 cases including the GoGetSSL 2026 chain
  (`GoGetSSL RSA DV SSL CA 2`) and the pre-2026 legacy chain.
- Step 4.5: local handshake test with `openssl s_server` / `s_client` as the definitive
  pre-deploy check, including the `-cert_chain` gotcha (`-cert` reads only the first cert,
  producing a false failure on a correct bundle).
- Step 4.4: check `notBefore` is not in the future, and check SAN covers every hostname —
  a wildcard CN does not cover the apex domain.
- Step 5.1: find the Secret name the Ingresses actually reference, before writing YAML.
  Includes the case where `kubectl get ingress -A` is empty (Istio / Traefik / Gateway API / CDN).
- Step 5.2: check every cluster context — certs usually span prod, DR, staging and non-prod.
- Step 5.3: Secret replicators (emberstack/kubernetes-reflector) — how to tell a source from a
  mirror, and the trap that `kubectl create secret tls --dry-run=client | kubectl apply -f -`
  strips the `reflection-allowed` annotation and silently stops replication.
- Step 5.4: Secret manifest carrying the reflector annotations and an explicit `namespace`;
  note that macOS `base64` wraps at 76 columns and needs `tr -d '\n'`.
- Step 5.5: staged rollout — temporary Secret on one ingress first, then
  `--dry-run=server` (`configured` vs `created` tells you whether anything references it).
- Step 5.6: confirm the source and every mirror carry the new expiry date.
- Step 6.2: verify the served chain per hostname, including against a specific ingress IP.
- Troubleshooting table mapping each symptom to the step that fixes it.
- Renewal checklist rewritten around the new verification and rollout steps.

### Changed
- `bundle-cert.sh` rewritten. It now normalises PEM via `openssl x509 -outform PEM`, expands
  multi-cert `.ca-bundle` inputs, enforces `issuer → subject` ordering, rejects a self-signed
  root in a non-terminal position, verifies against the system trust store, checks the
  validity window, and **exits non-zero on failure** so it can run in CI. New flags: `-k`
  (key match + live handshake test) and `--inspect` (print subject/issuer to derive the order).
  Previously it only ran `cat` and printed information, and always exited 0.
- README examples use placeholder domains (`example.vn`) rather than production hostnames.

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
