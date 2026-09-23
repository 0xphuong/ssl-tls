# ssl-tls

Step-by-step guide for purchasing SSL/TLS certificates from a CA (e.g. Sectigo, GoGetSSL),
assembling the certificate chain, and rolling it out to Kubernetes / Nginx.

> **The single most common failure**: the bundle is missing the **intermediate CA**, or has
> the intermediate and the root in the wrong order. Everything in Step 3 and Step 4 exists
> to catch that before it reaches production. Read them.

---

## Step 1 — Generate private key and CSR

```bash
# Generate 2048-bit RSA private key
openssl genrsa -out private.key 2048

# Generate Certificate Signing Request
openssl req -new -sha256 -key private.key -out certreq.csr
```

You will be prompted to fill in:

| Field | Example |
|-------|---------|
| Country Name | `VN` |
| State or Province | `Ho Chi Minh` |
| Locality | `Ho Chi Minh` |
| Organization Name | `SEVEN SYSTEM VIET NAM JOINT STOCK COMPANY` |
| Organizational Unit | `7Lab` |
| Common Name | `*.7-eleven.vn` |
| Email | _(leave blank)_ |

A wildcard CN such as `*.example.vn` does **not** cover the apex `example.vn`. Most CAs add
the apex to the SAN list automatically — confirm it on the issued cert (Step 4) before you
assume `example.vn` is covered.

> **Keep `private.key` secret. Never commit it to git.** This repo's `.gitignore` already
> blocks `*.key`, `*.crt`, `*.csr`, `*.pem`, `*.p12`, `*.pfx`, `*.ca-bundle`, `*.zip`.

**Reusing the existing key on renewal** is fine and avoids re-pinning anything downstream.
Only generate a new key if the old one may have been exposed. If you reuse it, you still
need a fresh CSR — but it must be generated *from that same key*:

```bash
openssl req -new -sha256 -key private.key -out certreq.csr
```

---

## Step 2 — Submit CSR to CA

```bash
cat certreq.csr
```

The CA validates domain ownership (DV) or organization (OV/EV), then emails a `.zip`
containing the certificate chain.

---

## Step 3 — Assemble the certificate chain

### The rule

```
leaf (your domain)  →  intermediate CA(s)  →  cross-signed root (optional)
```

Each certificate's **issuer** must equal the **subject** of the next one in the file.

- The **intermediate is mandatory**. Omit it and every client fails with
  *"unable to get local issuer certificate"* — this is the #1 cause of a broken install.
- The **root is optional** — clients already have it in their trust store. Include the
  CA's *cross-signed* root (e.g. Sectigo R46, signed by USERTrust) only for compatibility
  with older devices. Never put a self-signed root in the middle of the chain.

### Don't guess the order — derive it

Before concatenating anything, print the subject/issuer of every file the CA sent:

```bash
for f in *.crt; do
  printf '%-55s ' "$f"
  openssl x509 -in "$f" -noout -subject -issuer 2>/dev/null | tr '\n' ' '
  echo
done
```

Example output (GoGetSSL / Sectigo, 2026 chain):

```
_example_vn.crt       subject=CN=*.example.vn         issuer=CN=GoGetSSL RSA DV SSL CA 2
GoGetSSL_RSA_DV_SSL_CA_2.crt   subject=CN=GoGetSSL RSA DV SSL CA 2   issuer=CN=Sectigo ... Root R46
Sectigo_..._Root_R46.crt       subject=CN=Sectigo ... Root R46        issuer=CN=USERTrust RSA Certification Authority
USERTrust_..._Authority.crt    subject=CN=USERTrust RSA ...           issuer=CN=USERTrust RSA ...   ← self-signed root, SKIP
```

Now chain them by following `issuer → subject`. Anything whose subject never appears as
another cert's issuer, and which is self-signed (subject == issuer), is a root — leave it out
unless it is cross-signed.

### Concatenate safely

**Do not use plain `cat`.** Many CAs ship files with no trailing newline, which glues
`-----END CERTIFICATE----------BEGIN CERTIFICATE-----` together and corrupts the bundle.
Re-emit each cert through `openssl` instead — it normalises PEM framing and line endings
(including CRLF from Windows-generated files):

```bash
for f in _example_vn.crt \
         GoGetSSL_RSA_DV_SSL_CA_2.crt \
         Sectigo_Public_Server_Authentication_Root_R46.crt; do
  openssl x509 -in "$f" -outform PEM
done > example-vn-tls.crt
```

Or use the helper: `./bundle-cert.sh -o example-vn-tls.crt leaf.crt intermediate.crt root.crt`
— it normalises, orders-checks, and verifies in one shot.

### Real-world chain cases

| Case | Files received | Bundle order |
|------|----------------|--------------|
| **1 — CA-bundle included** | `STAR_example_vn.crt`, `STAR_example_vn.ca-bundle` | leaf, then the `.ca-bundle` (already ordered) |
| **2 — Sectigo Public CA (R36)** | `_example_vn.crt`, `Sectigo_Public_Server_Authentication_CA_DV_R36.crt`, `Sectigo_..._Root_R46.crt`, `USERTrust_....crt` | leaf, `..._CA_DV_R36`, `..._Root_R46` |
| **3 — GoGetSSL reseller, 2026 chain** | `_example_vn.crt`, `GoGetSSL_RSA_DV_SSL_CA_2.crt`, `Sectigo_..._Root_R46.crt`, `USERTrust_....crt` | leaf, `GoGetSSL_RSA_DV_SSL_CA_2`, `Sectigo_..._Root_R46` |
| **4 — GoGetSSL legacy (pre-2026)** | `_example_vn.crt`, `GoGetSSL_RSA_DV_CA.crt`, `USERTrust_....crt`, `AAA_Certificate_Services.crt` | leaf, `GoGetSSL_RSA_DV_CA`, `USERTrust_...` |

`USERTrust_RSA_Certification_Authority.crt` is self-signed in Case 3 (skip it) but
cross-signed by `AAA Certificate Services` in Case 4 (keep it). Always check with the
subject/issuer loop above rather than going by filename.

> **Sectigo 2026 chain migration**: from 1 Jan 2026 Sectigo no longer reissues under the old
> roots. A renewal will often arrive on a *different* intermediate than last year's — never
> reuse last year's bundle file and just swap the leaf.

---

## Step 4 — Verify the chain **before** deploying

**The fastest path is [`check-cert.sh`](./check-cert.sh)** — it runs every check below in one
command and exits non-zero on failure, so it works as a pre-apply or CI gate:

```bash
./check-cert.sh -c example-vn-tls.crt -k private.key \
  -H '*.example.vn' -H example.vn --days 30
```

```
[ 1/10] PEM parse ................. PASS  3 certificate(s)
[ 2/10] Intermediate present ...... PASS  at position 2
[ 3/10] Chain order ............... PASS  leaf -> intermediate -> root
[ 4/10] Root placement ............ PASS  no self-signed root in bundle
[ 5/10] Trust store verify ........ PASS  chain reaches a trusted root
[ 6/10] Key matches cert .......... PASS  public keys identical
[ 7/10] Validity window ........... PASS  valid, 196 days left (until Apr  7 23:59:59 2027 GMT)
[ 8/10] SAN coverage .............. PASS  all 2 hostname(s) covered
[ 9/10] Algorithm strength ........ PASS  sha256WithRSAEncryption, 2048-bit
[10/10] Local handshake ........... PASS  3 cert(s) sent, 0 (ok)

RESULT: PASS — safe to apply.
```

It also reads a Kubernetes Secret YAML directly, which checks the bytes you are actually
about to `kubectl apply` rather than the files you think they came from:

```bash
./check-cert.sh -f example-vn-tls.yaml -H '*.example.vn' --days 30
```

The rest of this section is what those checks do, so you can run them by hand or understand
a failure. Each catches a different problem.

### 4.1 — Are all the certificates actually parseable?

`grep -c "BEGIN CERTIFICATE"` is **not** a valid check: it counts *lines*, so a glued
`-----END CERTIFICATE----------BEGIN CERTIFICATE-----` boundary still counts as one match
and the broken bundle passes. Use a real parser:

```bash
openssl crl2pkcs7 -nocrl -certfile example-vn-tls.crt \
  | openssl pkcs7 -print_certs -noout
```

Every certificate must be listed, in leaf → intermediate → root order, with each one's
`issuer=` matching the next one's `subject=`.

### 4.2 — Does the chain reach a trusted root?

```bash
# Split the bundle: cert1 = leaf, cert2+ = chain
awk '/BEGIN CERT/{n++} {print > ("/tmp/cert" n ".pem")}' example-vn-tls.crt

# Verify against the system trust store — must print "OK"
openssl verify -untrusted <(cat /tmp/cert2.pem /tmp/cert3.pem 2>/dev/null) /tmp/cert1.pem
```

> **Never use `openssl verify -CAfile bundle.crt bundle.crt`.** That tells OpenSSL to trust
> the bundle itself, so it prints `OK` even when the chain is broken or the root is untrusted.
> It is a guaranteed false pass.

### 4.3 — Does the private key match the certificate?

Compare public keys, not moduli — this works for ECDSA keys too, where `-modulus` fails:

```bash
openssl x509 -in example-vn-tls.crt -noout -pubkey  | openssl sha256
openssl pkey -in private.key         -pubout        | openssl sha256
openssl req  -in certreq.csr -noout  -pubkey        | openssl sha256
# All three hashes must be identical
```

### 4.4 — Are the names and dates right?

```bash
openssl x509 -in example-vn-tls.crt -noout -subject -dates -ext subjectAltName
```

Check that every hostname you serve appears in the SAN list, and that `notBefore` is not in
the future — a cert issued for tomorrow will fail today with an opaque error.

### 4.5 — Definitive test: a real handshake, locally

This is the only check that proves what clients will actually see. Note `-cert_chain`:
`openssl s_server -cert` reads **only the first certificate** from the file, so without it
you will get a false failure even with a perfect bundle.

```bash
awk '/BEGIN CERT/{n++} n>1' example-vn-tls.crt > /tmp/chain-only.pem

openssl s_server -cert example-vn-tls.crt -cert_chain /tmp/chain-only.pem \
  -key private.key -accept 14433 -www >/dev/null 2>&1 &

sleep 1
echo | openssl s_client -connect 127.0.0.1:14433 -servername example.vn 2>&1 \
  | grep -E '^ [0-9] s:|Verify return code'

kill %1
```

Expected — the full chain, and code 0:

```
 0 s:CN=*.example.vn
 1 s:CN=GoGetSSL RSA DV SSL CA 2
 2 s:CN=Sectigo Public Server Authentication Root R46
Verify return code: 0 (ok)
```

`Verify return code: 20 (unable to get local issuer certificate)` means the intermediate is
missing or out of order. Go back to Step 3.

---

## Step 5 — Roll out to Kubernetes

### 5.1 — Find out what the cluster actually uses

A valid certificate in a Secret nobody references changes nothing. **Before writing any
YAML**, find the Secret name the Ingresses really point at:

```bash
kubectl get ingress -A \
  -o jsonpath='{range .items[*]}{.spec.tls[*].secretName}{"\n"}{end}' \
  | tr ' ' '\n' | sort | uniq -c | sort -rn
```

Then confirm the name, namespace and current expiry of what is live:

```bash
kubectl get secret -A | grep -i <name>

kubectl -n <namespace> get secret <name> \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -dates
```

If `kubectl get ingress -A` returns nothing, TLS is not terminated by an Ingress — check for
Istio `Gateway`, Traefik `IngressRoute`, Gateway API `HTTPRoute`, or an LB/CDN in front:

```bash
kubectl get crd | grep -iE 'gateway|ingressroute|virtualservice|httproute'
```

### 5.2 — Check every cluster

`kubectl config current-context` is not the cluster you think it is often enough to be worth
checking every single time. Certificates usually have to be rolled out to **several**
clusters (prod, DR, staging, non-prod), each with its own copy of the Secret:

```bash
for ctx in $(kubectl config get-contexts -o name); do
  printf '%-22s ' "$ctx"
  kubectl --context="$ctx" -n <namespace> get secret <name> \
    --request-timeout=12s 2>&1 | tail -1
done
```

### 5.3 — Mind the Secret replicator

Kubernetes Secrets are namespaced, so a wildcard cert used by Ingresses in many namespaces is
usually mirrored by a controller such as
[emberstack/kubernetes-reflector](https://github.com/emberstack/kubernetes-reflector).
In that setup there is **one source Secret** and N read-only mirrors — you update the source,
and the controller propagates within seconds.

Identify the source (it carries `reflection-allowed`, the mirrors carry `reflects`):

```bash
kubectl -n <namespace> get secret <name> \
  -o jsonpath='{.metadata.annotations}' | python3 -m json.tool
```

```jsonc
// SOURCE — edit this one
{ "reflector.v1.k8s.emberstack.com/reflection-allowed": "true",
  "reflector.v1.k8s.emberstack.com/reflection-auto-enabled": "true" }

// MIRROR — do not edit, it will be overwritten
{ "reflector.v1.k8s.emberstack.com/reflects": "default/<name>" }
```

> **Trap**: the usual one-liner
> `kubectl create secret tls ... --dry-run=client -o yaml | kubectl apply -f -`
> generates a Secret with **no annotations**. Applying that over a reflector source strips
> `reflection-allowed`, replication silently stops, and the mirrors keep serving the old
> certificate until they expire. Always apply a YAML that carries the annotations.

### 5.4 — The Secret manifest

```bash
CRT=$(base64 < example-vn-tls.crt | tr -d '\n')
KEY=$(base64 < private.key        | tr -d '\n')

cat > example-vn-tls.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: star-example-vn-tls
  namespace: default
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
type: kubernetes.io/tls
data:
  tls.crt: $CRT
  tls.key: $KEY
EOF
```

`base64` on macOS wraps at 76 columns; the `tr -d '\n'` is required or the YAML breaks.
Omit the reflector annotations if the cluster has no replicator — but keep `namespace`
explicit either way, so the Secret cannot land in the wrong one.

### 5.5 — Staged rollout

Never swap a shared wildcard Secret as the first move. Prove it on one service first:

```bash
# 1. Deploy under a temporary name, in one namespace
sed 's/name: star-example-vn-tls/name: star-example-vn-tls-2026/' example-vn-tls.yaml \
  | kubectl -n <test-ns> apply -f -

# 2. Point ONE ingress at it
kubectl -n <test-ns> patch ingress <ingress> --type=json \
  -p='[{"op":"replace","path":"/spec/tls/0/secretName","value":"star-example-vn-tls-2026"}]'

# 3. Verify in a browser and with Step 6.2 below

# 4. Server-side dry run against the real Secret — must say "configured", not "created"
kubectl apply -f example-vn-tls.yaml --dry-run=server

# 5. Apply for real
kubectl apply -f example-vn-tls.yaml

# 6. Revert the test ingress and delete the temporary Secret
```

`--dry-run=server` saying `created` instead of `configured` means the name or namespace is
wrong and you are about to create an orphan Secret that nothing uses.

### 5.6 — Confirm the rollout landed

```bash
# Source updated?
kubectl -n default get secret star-example-vn-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates

# Every mirror updated? (all dates should match)
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  d=$(kubectl -n "$ns" get secret star-example-vn-tls -o jsonpath='{.data.tls\.crt}' 2>/dev/null)
  [ -n "$d" ] && printf '%-24s %s\n' "$ns" \
    "$(echo "$d" | base64 -d | openssl x509 -noout -enddate)"
done
```

ingress-nginx picks up Secret changes automatically — no reload needed. If a host still
serves the old certificate after a minute, that host's Ingress references a *different*
Secret; re-run 5.1.

---

## Step 6 — Nginx

### 6.1 — Config

```bash
sudo mkdir -p /etc/nginx/ssl/example-vn
sudo cp private.key         /etc/nginx/ssl/example-vn/private.key
sudo cp example-vn-tls.crt  /etc/nginx/ssl/example-vn/ssl-bundle.crt
sudo chmod 600 /etc/nginx/ssl/example-vn/private.key
```

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name *.example.vn example.vn;

    ssl_certificate     /etc/nginx/ssl/example-vn/ssl-bundle.crt;   # leaf + intermediates
    ssl_certificate_key /etc/nginx/ssl/example-vn/private.key;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
}
```

`ssl_certificate` **must** be the full bundle. `ssl_trusted_certificate` is for OCSP stapling
and client-cert verification only — it is **not** sent to clients and will not fix a missing
intermediate. Do not use it to supply the chain.

```bash
sudo nginx -t && sudo nginx -s reload
```

Nginx keeps the old certificate in memory until reloaded, so `nginx -s reload` is required
even though the file on disk already changed.

### 6.2 — Verify what is actually being served

```bash
# Against the public name
echo | openssl s_client -connect example.vn:443 -servername example.vn 2>&1 \
  | grep -E '^ [0-9] s:|Verify return code'

# Against a specific backend / ingress IP, bypassing DNS
echo | openssl s_client -connect 10.0.0.5:443 -servername example.vn 2>&1 \
  | grep -E '^ [0-9] s:|Verify return code'
```

Same expectations as Step 4.5: full chain listed, `Verify return code: 0 (ok)`.
Check every hostname on the certificate, not just one — different hosts often resolve to
different ingress controllers.

---

## Troubleshooting

Run `./check-cert.sh` first — it names the failing check directly.

| Symptom | Cause | Fix |
|---|---|---|
| `unable to get local issuer certificate` (code 20) | Intermediate missing from the bundle | Step 3 — add the intermediate |
| Works in Chrome, fails on Android / Java / curl | Bundle relies on the client having the intermediate cached | Step 3 — ship the full chain explicitly |
| `PEM routines:no start line` / `unsupported` | Missing newline between certs, or CRLF | Step 3 — re-emit with `openssl x509 -outform PEM` |
| `key values mismatch` on apply | Key does not belong to this certificate | Step 4.3 |
| Applied successfully, nothing changed | Secret name/namespace not referenced by any Ingress | Step 5.1, and `--dry-run=server` must say `configured` |
| Some namespaces updated, others not | Replicator source annotations were stripped | Step 5.3 |
| Cert correct on cluster A, site still broken | Wrong cluster context | Step 5.2 |
| `certificate is not yet valid` | `notBefore` is in the future | Step 4.4 — wait, or check server clock |

---

## Renewal checklist

- [ ] Note the current expiry and give yourself ≥ 14 days: `openssl x509 -noout -enddate`
- [ ] Reuse `private.key` (or generate a new one if it may be exposed) and create a fresh CSR
- [ ] Submit CSR, complete domain validation
- [ ] Download the new `.zip` — **do not assume the chain is the same as last year's**
- [ ] Derive the order with the subject/issuer loop (Step 3)
- [ ] Bundle with `openssl x509 -outform PEM`, never plain `cat` (Step 3)
- [ ] Run the gate: `./check-cert.sh -c <bundle> -k private.key -H <every hostname>` — must exit 0
- [ ] Find the real Secret name and namespace (Step 5.1)
- [ ] Check **every** cluster context (Step 5.2)
- [ ] Preserve replicator annotations (Step 5.3)
- [ ] Re-run the gate on the Secret YAML itself: `./check-cert.sh -f <secret>.yaml` — must exit 0
- [ ] Stage on one ingress, then `--dry-run=server` (must say `configured`), then apply (Step 5.5)
- [ ] Confirm source + all mirrors carry the new date (Step 5.6)
- [ ] Nginx hosts: copy files, `nginx -t && nginx -s reload` (Step 6.1)
- [ ] Verify the live handshake for **every** hostname on the cert (Step 6.2)
- [ ] Delete the temporary staging Secret

---

## Helper scripts

Two scripts, two jobs. `bundle-cert.sh` **builds** a chain from the CA's files;
`check-cert.sh` **verifies** a chain you already have. Use the second one as the gate before
every production apply — it is the one that would have caught both of the failures this
guide's v1.1.0 examples produced.

### check-cert.sh — pre-apply gate

```bash
# From files
./check-cert.sh -c example-vn-tls.crt -k private.key -H '*.example.vn' -H example.vn

# From the Kubernetes Secret YAML you are about to apply
./check-cert.sh -f example-vn-tls.yaml --days 30

# Compare against what a host is serving right now
./check-cert.sh -c example-vn-tls.crt -k private.key --live example.vn

# CI, no port binding available
./check-cert.sh -f example-vn-tls.yaml --no-handshake -q
```

| Flag | Meaning |
|---|---|
| `-c` / `-k` | Certificate bundle and private key |
| `-f FILE` | Read `tls.crt` / `tls.key` from a Kubernetes TLS Secret YAML instead |
| `-H NAME` | Assert this hostname is covered by the SAN list (repeatable) |
| `--days N` | Warn if the certificate expires within N days (default 14) |
| `--live HOST[:PORT]` | Also compare against the certificate that host serves today |
| `--no-handshake` | Skip the local TLS handshake (for sandboxes that cannot bind a port) |
| `--lenient` | Downgrade "wrong chain order" from FAIL to WARN |
| `-q` | Print only the verdict |

Exit codes: `0` pass (possibly with warnings), `1` at least one check failed, `2` bad usage
or unreadable input.

```bash
# Gate an apply on it
./check-cert.sh -f example-vn-tls.yaml -q && kubectl apply -f example-vn-tls.yaml
```

### bundle-cert.sh — assemble a chain

[`bundle-cert.sh`](./bundle-cert.sh) does Step 3 and Step 4 in one command:

```bash
./bundle-cert.sh -o example-vn-tls.crt \
  _example_vn.crt \
  GoGetSSL_RSA_DV_SSL_CA_2.crt \
  Sectigo_Public_Server_Authentication_Root_R46.crt

# Also verify the key matches and run a local handshake test
./bundle-cert.sh -o example-vn-tls.crt -k private.key leaf.crt intermediate.crt root.crt

# Just inspect what the CA sent, without bundling
./bundle-cert.sh --inspect *.crt
```

It normalises PEM framing, rejects an out-of-order or incomplete chain, and exits non-zero on
failure — so it is safe to call from CI.
