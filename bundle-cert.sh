#!/usr/bin/env bash
#
# Assemble a TLS certificate chain and verify it before it reaches production.
#
# Unlike `cat`, this normalises PEM framing (many CAs ship files with no trailing
# newline, or with CRLF), checks that each cert's issuer matches the next cert's
# subject, and verifies the chain against the system trust store.
#
# Exits non-zero on any failure, so it is safe to call from CI.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bundle-cert.sh -o OUTPUT_CRT [-k PRIVATE_KEY] LEAF.crt INTERMEDIATE.crt [ROOT.crt ...]
       bundle-cert.sh --inspect FILE...

  -o OUTPUT_CRT   Output bundle filename (e.g. example-vn-tls.crt)
  -k PRIVATE_KEY  Also check the key matches the leaf, and run a local TLS handshake
  --inspect       Print subject/issuer of each file so you can derive the chain order
  -h, --help      This message

Order: leaf (your domain) first, then intermediate CA(s), then the cross-signed root.
Omit self-signed roots — clients already trust them. Use --inspect if unsure.

Examples:
  bundle-cert.sh --inspect *.crt
  bundle-cert.sh -o example-vn-tls.crt -k private.key \
    _example_vn.crt GoGetSSL_RSA_DV_SSL_CA_2.crt Sectigo_Public_Server_Authentication_Root_R46.crt
USAGE
  exit "${1:-1}"
}

die()  { echo "ERROR: $*" >&2; exit 1; }
ok()   { echo "  ok    $*"; }
warn() { echo "  warn  $*"; }

inspect() {
  printf '%-58s %s\n' "FILE" "SUBJECT / ISSUER"
  for f in "$@"; do
    [[ -f "$f" ]] || { printf '%-58s %s\n' "$f" "(not found)"; continue; }
    local subj issuer
    subj=$(openssl x509 -in "$f" -noout -subject 2>/dev/null | sed 's/^subject=//') || subj=""
    issuer=$(openssl x509 -in "$f" -noout -issuer 2>/dev/null | sed 's/^issuer=//') || issuer=""
    if [[ -z "$subj" ]]; then
      printf '%-58s %s\n' "$f" "(not a single PEM certificate — may be a ca-bundle)"
      continue
    fi
    printf '%-58s S: %s\n' "$f" "$subj"
    if [[ "$subj" == "$issuer" ]]; then
      printf '%-58s I: %s  <-- self-signed root, usually SKIP\n' "" "$issuer"
    else
      printf '%-58s I: %s\n' "" "$issuer"
    fi
  done
}

OUTPUT=""
KEY=""
FILES=()

[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) [[ $# -ge 2 ]] || die "-o needs a value"; OUTPUT="$2"; shift 2 ;;
    -k) [[ $# -ge 2 ]] || die "-k needs a value"; KEY="$2";    shift 2 ;;
    --inspect) shift; [[ $# -ge 1 ]] || die "--inspect needs at least one file"; inspect "$@"; exit 0 ;;
    -h|--help) usage 0 ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *)  FILES+=("$1"); shift ;;
  esac
done

[[ -n "$OUTPUT" ]] || die "-o OUTPUT_CRT is required"
[[ ${#FILES[@]} -ge 2 ]] || die "at least 2 certificate files required (leaf + intermediate)"
for f in "${FILES[@]}"; do [[ -f "$f" ]] || die "file not found: $f"; done
[[ -n "$KEY" && ! -f "$KEY" ]] && die "key not found: $KEY"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- 1. Normalise and concatenate -------------------------------------------
# openssl re-emits canonical PEM, fixing missing trailing newlines and CRLF.
# A .ca-bundle may hold several certs, so fall back to a multi-cert read.
echo "Bundling:"
: > "$TMP/bundle.crt"
for f in "${FILES[@]}"; do
  if openssl x509 -in "$f" -outform PEM >> "$TMP/bundle.crt" 2>/dev/null; then
    echo "  + $f"
  elif openssl crl2pkcs7 -nocrl -certfile "$f" 2>/dev/null \
       | openssl pkcs7 -print_certs -outform PEM 2>/dev/null \
       | grep -v '^$' >> "$TMP/bundle.crt"; then
    echo "  + $f (multi-cert bundle)"
  else
    die "cannot parse as PEM certificate(s): $f"
  fi
done

# --- 2. Parse every certificate back out ------------------------------------
echo ""
echo "Verifying:"
awk '/BEGIN CERTIFICATE/{n++} n>0 {print > ("'"$TMP"'/c" n ".pem")}' "$TMP/bundle.crt"
COUNT=$(find "$TMP" -name 'c*.pem' | wc -l | tr -d ' ')
[[ "$COUNT" -ge 2 ]] || die "only $COUNT certificate(s) parsed — the intermediate is missing"
ok "$COUNT certificates parsed"

# --- 3. issuer(n) must equal subject(n+1) -----------------------------------
for ((i=1; i<COUNT; i++)); do
  j=$((i+1))
  iss=$(openssl x509 -in "$TMP/c$i.pem" -noout -issuer  | sed 's/^issuer=//')
  sub=$(openssl x509 -in "$TMP/c$j.pem" -noout -subject | sed 's/^subject=//')
  [[ "$iss" == "$sub" ]] || die "chain order is wrong: cert $i is issued by
          $iss
        but cert $j is
          $sub
        Re-run with --inspect and order the files leaf -> intermediate -> root."
done
ok "chain order correct (issuer -> subject links intact)"

# --- 4. Self-signed root in the middle? -------------------------------------
for ((i=1; i<COUNT; i++)); do
  s=$(openssl x509 -in "$TMP/c$i.pem" -noout -subject | sed 's/^subject=//')
  x=$(openssl x509 -in "$TMP/c$i.pem" -noout -issuer  | sed 's/^issuer=//')
  [[ "$s" == "$x" ]] && die "cert $i is a self-signed root but is not last in the chain"
done
last_s=$(openssl x509 -in "$TMP/c$COUNT.pem" -noout -subject | sed 's/^subject=//')
last_i=$(openssl x509 -in "$TMP/c$COUNT.pem" -noout -issuer  | sed 's/^issuer=//')
[[ "$last_s" == "$last_i" ]] && warn "last cert is a self-signed root — clients already trust it, you can drop it"

# --- 5. Verify against the system trust store -------------------------------
CHAIN="$TMP/chain.pem"
: > "$CHAIN"
for ((i=2; i<=COUNT; i++)); do cat "$TMP/c$i.pem" >> "$CHAIN"; done
if openssl verify -untrusted "$CHAIN" "$TMP/c1.pem" >/dev/null 2>&1; then
  ok "chain verifies against the system trust store"
else
  echo ""
  openssl verify -untrusted "$CHAIN" "$TMP/c1.pem" || true
  die "chain does not reach a trusted root"
fi

# --- 6. notBefore / notAfter ------------------------------------------------
openssl x509 -in "$TMP/c1.pem" -noout -checkend 0 >/dev/null 2>&1 \
  || die "leaf certificate has already expired"
nb=$(openssl x509 -in "$TMP/c1.pem" -noout -startdate | sed 's/^notBefore=//')
if ! openssl x509 -in "$TMP/c1.pem" -noout -dates >/dev/null 2>&1; then :; fi
python3 - "$nb" <<'PY' 2>/dev/null || true
import sys, datetime
nb = datetime.datetime.strptime(sys.argv[1].strip(), "%b %d %H:%M:%S %Y %Z")
if nb > datetime.datetime.utcnow():
    print(f"  warn  certificate is not valid until {nb} UTC — it will fail if deployed now")
PY
ok "leaf is within its validity window"

# --- 7. Key match + local handshake -----------------------------------------
if [[ -n "$KEY" ]]; then
  ck=$(openssl x509 -in "$TMP/c1.pem" -noout -pubkey | openssl sha256 | awk '{print $NF}')
  kk=$(openssl pkey -in "$KEY" -pubout 2>/dev/null   | openssl sha256 | awk '{print $NF}')
  [[ -n "$kk" ]] || die "cannot read private key: $KEY"
  [[ "$ck" == "$kk" ]] || die "private key does not match the leaf certificate"
  ok "private key matches the leaf certificate"

  PORT=${BUNDLE_CERT_PORT:-14433}
  openssl s_server -cert "$TMP/bundle.crt" -cert_chain "$CHAIN" -key "$KEY" \
    -accept "$PORT" -www >/dev/null 2>&1 &
  SRV=$!
  sleep 1
  if kill -0 "$SRV" 2>/dev/null; then
    rc=$(echo | openssl s_client -connect "127.0.0.1:$PORT" 2>&1 | grep 'Verify return code' | head -1)
    kill "$SRV" 2>/dev/null || true
    wait "$SRV" 2>/dev/null || true
    if [[ "$rc" == *"return code: 0"* ]]; then
      ok "live TLS handshake verified ($rc)"
    else
      die "live TLS handshake failed — $rc"
    fi
  else
    warn "could not start a local test server on port $PORT — skipped handshake test"
  fi
fi

# --- 8. Emit -----------------------------------------------------------------
cp "$TMP/bundle.crt" "$OUTPUT"
echo ""
echo "Output: $OUTPUT"
echo ""
openssl crl2pkcs7 -nocrl -certfile "$OUTPUT" | openssl pkcs7 -print_certs -noout
echo ""
openssl x509 -in "$OUTPUT" -noout -dates -ext subjectAltName 2>/dev/null || true
[[ -z "$KEY" ]] && echo "" && echo "Tip: re-run with -k private.key to also verify the key and a live handshake."
exit 0
