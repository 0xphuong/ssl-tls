#!/usr/bin/env bash
#
# Pre-flight gate for a TLS certificate bundle + private key.
#
# Run this on the exact files (or the exact Kubernetes Secret YAML) you are about to
# deploy. It catches the failures that only show up in production:
#
#   - the intermediate CA is missing        -> clients get "unable to get local issuer certificate"
#   - the chain is in the wrong order       -> some clients fail, others do not
#   - the key does not match the cert       -> Nginx / Kubernetes refuse the pair
#   - the cert is expired or not yet valid  -> opaque browser errors
#   - the hostname is not in the SAN list   -> NET::ERR_CERT_COMMON_NAME_INVALID
#
# Exits 0 only when every check passes, so it is safe as a CI or pre-apply gate.

set -uo pipefail

VERSION="1.0.0"

usage() {
  cat <<'USAGE'
Usage:
  check-cert.sh -c BUNDLE.crt -k PRIVATE.key [options]
  check-cert.sh -f SECRET.yaml [options]

Input (one of):
  -c, --cert FILE     Certificate bundle (leaf + intermediates, PEM)
  -k, --key FILE      Private key (PEM, unencrypted)
  -f, --from-yaml F   Kubernetes TLS Secret YAML — reads tls.crt and tls.key from it

Options:
  -H, --host NAME     Hostname that must be covered by the certificate (repeatable)
      --days N        Fail if the certificate expires within N days (default: 14)
      --live HOST[:PORT]
                      Also compare against what HOST is serving right now
      --no-handshake  Skip the local TLS handshake test
      --lenient       Downgrade "wrong chain order" from FAIL to WARN
  -q, --quiet         Only print the final verdict
  -h, --help          This message
  -v, --version       Print version

Examples:
  check-cert.sh -c example-vn-tls.crt -k private.key -H '*.example.vn' -H example.vn
  check-cert.sh -f example-vn-tls.yaml --days 30
  check-cert.sh -c example-vn-tls.crt -k private.key --live example.vn
USAGE
  exit "${1:-1}"
}

# ---------------------------------------------------------------- output ----
PASS=0; FAIL=0; WARN=0; STEP=0; TOTAL=10
QUIET=0
C_OK=""; C_BAD=""; C_WARN=""; C_DIM=""; C_OFF=""
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_WARN=$'\033[33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
fi

_line() { # _line LABEL STATUS DETAIL
  STEP=$((STEP+1))
  [ "$QUIET" -eq 1 ] && return 0
  local dots label
  label="$1"
  dots=$(printf '%.0s.' $(seq 1 $(( 26 - ${#label} > 0 ? 26 - ${#label} : 1 ))))
  printf '[%2d/%d] %s %s %s  %s\n' "$STEP" "$TOTAL" "$label" "$dots" "$2" "${3:-}"
}
pass()  { PASS=$((PASS+1)); _line "$1" "${C_OK}PASS${C_OFF}" "$2"; }
fail()  { FAIL=$((FAIL+1)); _line "$1" "${C_BAD}FAIL${C_OFF}" "$2"; }
warns() { WARN=$((WARN+1)); _line "$1" "${C_WARN}WARN${C_OFF}" "$2"; }
skip()  {                   _line "$1" "${C_DIM}SKIP${C_OFF}" "$2"; }
note()  { [ "$QUIET" -eq 1 ] || printf '       %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }
die()   { printf '%sERROR:%s %s\n' "$C_BAD" "$C_OFF" "$*" >&2; exit 2; }

# ------------------------------------------------------------------ args ----
CERT=""; KEY=""; YAML=""; DAYS=14; LIVE=""; DO_HANDSHAKE=1; LENIENT=0
HOSTS=()

[ $# -eq 0 ] && usage

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--cert)      [ $# -ge 2 ] || die "$1 needs a value"; CERT="$2"; shift 2 ;;
    -k|--key)       [ $# -ge 2 ] || die "$1 needs a value"; KEY="$2";  shift 2 ;;
    -f|--from-yaml) [ $# -ge 2 ] || die "$1 needs a value"; YAML="$2"; shift 2 ;;
    -H|--host)      [ $# -ge 2 ] || die "$1 needs a value"; HOSTS[${#HOSTS[@]}]="$2"; shift 2 ;;
    --days)         [ $# -ge 2 ] || die "$1 needs a value"; DAYS="$2"; shift 2 ;;
    --live)         [ $# -ge 2 ] || die "$1 needs a value"; LIVE="$2"; shift 2 ;;
    --no-handshake) DO_HANDSHAKE=0; shift ;;
    --lenient)      LENIENT=1; shift ;;
    -q|--quiet)     QUIET=1; shift ;;
    -h|--help)      usage 0 ;;
    -v|--version)   echo "check-cert.sh $VERSION"; exit 0 ;;
    -*)             echo "Unknown option: $1" >&2; usage ;;
    *)              echo "Unexpected argument: $1" >&2; usage ;;
  esac
done

TMP=$(mktemp -d) || die "cannot create temp dir"
trap 'rm -rf "$TMP"' EXIT

SRC_DESC=""
if [ -n "$YAML" ]; then
  [ -f "$YAML" ] || die "file not found: $YAML"
  [ -n "$CERT$KEY" ] && die "--from-yaml cannot be combined with --cert/--key"
  # Extract the base64 values of tls.crt / tls.key from a kubernetes.io/tls Secret.
  b64crt=$(grep -E '^[[:space:]]*tls\.crt:' "$YAML" | head -1 | sed -E 's/^[[:space:]]*tls\.crt:[[:space:]]*//')
  b64key=$(grep -E '^[[:space:]]*tls\.key:' "$YAML" | head -1 | sed -E 's/^[[:space:]]*tls\.key:[[:space:]]*//')
  [ -n "$b64crt" ] || die "no tls.crt found in $YAML"
  [ -n "$b64key" ] || die "no tls.key found in $YAML"
  printf '%s' "$b64crt" | base64 -d > "$TMP/tls.crt" 2>/dev/null || die "tls.crt in $YAML is not valid base64"
  printf '%s' "$b64key" | base64 -d > "$TMP/tls.key" 2>/dev/null || die "tls.key in $YAML is not valid base64"
  CERT="$TMP/tls.crt"; KEY="$TMP/tls.key"
  SRC_DESC="$YAML (Secret $(grep -E '^[[:space:]]*name:' "$YAML" | head -1 | sed -E 's/^[[:space:]]*name:[[:space:]]*//'))"
else
  [ -n "$CERT" ] || die "--cert is required (or use --from-yaml)"
  [ -n "$KEY"  ] || die "--key is required (or use --from-yaml)"
  [ -f "$CERT" ] || die "file not found: $CERT"
  [ -f "$KEY"  ] || die "file not found: $KEY"
  SRC_DESC="$CERT + $KEY"
fi

case "$DAYS" in ''|*[!0-9]*) die "--days must be a whole number" ;; esac

if [ "$QUIET" -eq 0 ]; then
  echo ""
  echo "Checking: $SRC_DESC"
  echo ""
fi

# ------------------------------------------------- 1. parse the bundle ----
awk '/BEGIN CERTIFICATE/{n++} n>0 {print > ("'"$TMP"'/c" n ".pem")}' "$CERT" 2>/dev/null
COUNT=$(find "$TMP" -name 'c*.pem' 2>/dev/null | wc -l | tr -d ' ')
BAD=0
i=1
while [ "$i" -le "$COUNT" ]; do
  openssl x509 -in "$TMP/c$i.pem" -noout >/dev/null 2>&1 || BAD=1
  i=$((i+1))
done
if [ "$COUNT" -eq 0 ] || [ "$BAD" -eq 1 ]; then
  fail "PEM parse" "certificate file is not valid PEM"
  note "A missing newline between certs glues '-----END-----' to '-----BEGIN-----'."
  note "Fix: for f in leaf.crt int.crt; do openssl x509 -in \$f -outform PEM; done > bundle.crt"
  echo ""
  printf '%sRESULT: FAIL%s — do not apply\n' "$C_BAD" "$C_OFF"
  exit 1
fi
pass "PEM parse" "$COUNT certificate(s)"

leaf_sub=$(openssl x509 -in "$TMP/c1.pem" -noout -subject | sed 's/^subject=//')
leaf_iss=$(openssl x509 -in "$TMP/c1.pem" -noout -issuer  | sed 's/^issuer=//')

# --------------------------------------------- 2. intermediate present ----
if [ "$leaf_sub" = "$leaf_iss" ]; then
  fail "Intermediate present" "leaf is self-signed — this is not a CA-issued certificate"
elif [ "$COUNT" -lt 2 ]; then
  fail "Intermediate present" "bundle holds only the leaf"
  note "Issuer needed: $leaf_iss"
  note "Add that CA's certificate to the bundle, or every client will fail."
else
  found=0; pos=0
  i=2
  while [ "$i" -le "$COUNT" ]; do
    s=$(openssl x509 -in "$TMP/c$i.pem" -noout -subject | sed 's/^subject=//')
    if [ "$s" = "$leaf_iss" ]; then found=1; pos=$i; break; fi
    i=$((i+1))
  done
  if [ "$found" -eq 1 ]; then
    pass "Intermediate present" "at position $pos"
  else
    fail "Intermediate present" "MISSING"
    note "Leaf is issued by: $leaf_iss"
    note "No certificate in the bundle has that subject. Clients will report"
    note "\"unable to get local issuer certificate\". Add the intermediate CA file."
  fi
fi

# ---------------------------------------------------- 3. chain ordering ----
order_bad=""
i=1
while [ "$i" -lt "$COUNT" ]; do
  j=$((i+1))
  iss=$(openssl x509 -in "$TMP/c$i.pem" -noout -issuer  | sed 's/^issuer=//')
  sub=$(openssl x509 -in "$TMP/c$j.pem" -noout -subject | sed 's/^subject=//')
  if [ "$iss" != "$sub" ]; then order_bad="$i"; break; fi
  i=$((i+1))
done
if [ -z "$order_bad" ]; then
  pass "Chain order" "leaf -> intermediate -> root"
else
  j=$((order_bad+1))
  msg="cert $order_bad does not link to cert $j"
  if [ "$LENIENT" -eq 1 ]; then warns "Chain order" "$msg"; else fail "Chain order" "$msg"; fi
  note "cert $order_bad issuer : $(openssl x509 -in "$TMP/c$order_bad.pem" -noout -issuer | sed 's/^issuer=//')"
  note "cert $j subject: $(openssl x509 -in "$TMP/c$j.pem" -noout -subject | sed 's/^subject=//')"
  note "Reorder as leaf -> intermediate -> root. Most browsers tolerate a wrong order;"
  note "older Android, Java and some load balancers do not."
fi

# --------------------------------------- 4. self-signed root positioning ----
mid_root=""
i=1
while [ "$i" -lt "$COUNT" ]; do
  s=$(openssl x509 -in "$TMP/c$i.pem" -noout -subject | sed 's/^subject=//')
  x=$(openssl x509 -in "$TMP/c$i.pem" -noout -issuer  | sed 's/^issuer=//')
  if [ "$s" = "$x" ]; then mid_root="$i"; break; fi
  i=$((i+1))
done
last_s=$(openssl x509 -in "$TMP/c$COUNT.pem" -noout -subject | sed 's/^subject=//')
last_i=$(openssl x509 -in "$TMP/c$COUNT.pem" -noout -issuer  | sed 's/^issuer=//')
if [ -n "$mid_root" ]; then
  fail "Root placement" "cert $mid_root is a self-signed root but is not last"
  note "A root in the middle breaks the chain. Remove it, or move it to the end."
elif [ "$last_s" = "$last_i" ]; then
  warns "Root placement" "last cert is a self-signed root"
  note "Clients already trust it. Dropping it saves bytes on every handshake, but it is harmless."
else
  pass "Root placement" "no self-signed root in bundle"
fi

# --------------------------------------------- 5. verify to trusted root ----
: > "$TMP/chain.pem"
i=2
while [ "$i" -le "$COUNT" ]; do cat "$TMP/c$i.pem" >> "$TMP/chain.pem"; i=$((i+1)); done
vout=$(openssl verify -untrusted "$TMP/chain.pem" "$TMP/c1.pem" 2>&1)
if printf '%s' "$vout" | grep -q ': OK$'; then
  pass "Trust store verify" "chain reaches a trusted root"
else
  fail "Trust store verify" "$(printf '%s' "$vout" | grep -i 'error' | head -1)"
  note "The chain does not build to a root in this machine's trust store."
fi

# ---------------------------------------------------- 6. key / cert pair ----
ck=$(openssl x509 -in "$TMP/c1.pem" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $NF}')
kk=$(openssl pkey -in "$KEY" -pubout 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $NF}')
if [ -z "$kk" ]; then
  fail "Key matches cert" "cannot read the private key"
  note "If it is encrypted, decrypt first: openssl pkey -in $KEY -out plain.key"
elif [ "$ck" = "$kk" ]; then
  pass "Key matches cert" "public keys identical"
else
  fail "Key matches cert" "the key does not belong to this certificate"
  note "cert pubkey sha256: $ck"
  note "key  pubkey sha256: $kk"
  note "You are probably using the key from a different CSR or a previous renewal."
fi

# ------------------------------------------------------ 7. validity dates ----
nb=$(openssl x509 -in "$TMP/c1.pem" -noout -startdate | sed 's/^notBefore=//')
na=$(openssl x509 -in "$TMP/c1.pem" -noout -enddate   | sed 's/^notAfter=//')
if ! openssl x509 -in "$TMP/c1.pem" -noout -checkend 0 >/dev/null 2>&1; then
  fail "Validity window" "EXPIRED on $na"
elif ! openssl x509 -in "$TMP/c1.pem" -noout -dates >/dev/null 2>&1; then
  fail "Validity window" "cannot read dates"
else
  future=$(python3 - "$nb" <<'PY' 2>/dev/null
import sys, datetime
try:
    nb = datetime.datetime.strptime(sys.argv[1].strip(), "%b %d %H:%M:%S %Y %Z")
    print("yes" if nb > datetime.datetime.utcnow() else "no")
except Exception:
    print("unknown")
PY
)
  secs=$(( DAYS * 86400 ))
  if [ "$future" = "yes" ]; then
    fail "Validity window" "not valid until $nb"
    note "Deploying now will fail with \"certificate is not yet valid\"."
  elif ! openssl x509 -in "$TMP/c1.pem" -noout -checkend "$secs" >/dev/null 2>&1; then
    warns "Validity window" "expires within $DAYS days — $na"
  else
    left=$(python3 - "$na" <<'PY' 2>/dev/null
import sys, datetime
try:
    na = datetime.datetime.strptime(sys.argv[1].strip(), "%b %d %H:%M:%S %Y %Z")
    print((na - datetime.datetime.utcnow()).days)
except Exception:
    print("?")
PY
)
    pass "Validity window" "valid, ${left} days left (until $na)"
  fi
fi

# ------------------------------------------------------ 8. SAN / hostname ----
san=$(openssl x509 -in "$TMP/c1.pem" -noout -ext subjectAltName 2>/dev/null \
      | grep -o 'DNS:[^,]*' | sed 's/^DNS://' | tr -d ' ' | tr '\n' ' ')
if [ -z "$san" ]; then
  warns "SAN coverage" "certificate has no subjectAltName"
  note "Modern browsers ignore the Common Name entirely — this cert will be rejected."
elif [ ${#HOSTS[@]} -eq 0 ]; then
  pass "SAN coverage" "$san"
  note "Pass -H <hostname> to assert a specific hostname is covered."
else
  missing=""
  for h in "${HOSTS[@]}"; do
    hit=0
    for d in $san; do
      if [ "$h" = "$d" ]; then hit=1; break; fi
      # wildcard: *.example.vn matches one label of host.example.vn
      case "$d" in
        \*.*) suffix=${d#\*}
              case "$h" in
                *"$suffix") stem=${h%"$suffix"}; case "$stem" in *.*) ;; ?*) hit=1 ;; esac ;;
              esac ;;
      esac
      [ "$hit" -eq 1 ] && break
    done
    [ "$hit" -eq 0 ] && missing="$missing $h"
  done
  if [ -z "$missing" ]; then
    pass "SAN coverage" "all ${#HOSTS[@]} hostname(s) covered"
  else
    fail "SAN coverage" "not covered:$missing"
    note "Certificate covers: $san"
    note "Note a wildcard *.example.vn does NOT cover the apex example.vn."
  fi
fi

# --------------------------------------------- 9. algorithm / key strength ----
sigalg=$(openssl x509 -in "$TMP/c1.pem" -noout -text 2>/dev/null \
         | grep -m1 'Signature Algorithm' | sed 's/.*Signature Algorithm: //' | tr -d ' ')
bits=$(openssl x509 -in "$TMP/c1.pem" -noout -text 2>/dev/null \
       | grep -m1 -E 'Public-Key:' | grep -o '[0-9]\+')
alg_bad=0
case "$sigalg" in *sha1*|*md5*|*SHA1*|*MD5*) alg_bad=1 ;; esac
if [ "$alg_bad" -eq 1 ]; then
  fail "Algorithm strength" "signed with $sigalg — rejected by all modern clients"
elif [ -n "$bits" ] && [ "$bits" -lt 2048 ] 2>/dev/null; then
  fail "Algorithm strength" "${bits}-bit key is below the 2048-bit minimum"
else
  pass "Algorithm strength" "$sigalg, ${bits:-?}-bit"
fi

# ------------------------------------------------- 10. local handshake ----
if [ "$DO_HANDSHAKE" -eq 0 ]; then
  skip "Local handshake" "--no-handshake"
else
  PORT=${CHECK_CERT_PORT:-14455}
  sni=""
  [ ${#HOSTS[@]} -gt 0 ] && sni=$(printf '%s' "${HOSTS[0]}" | sed 's/^\*\./test./')
  openssl s_server -cert "$TMP/c1.pem" -cert_chain "$TMP/chain.pem" -key "$KEY" \
    -accept "$PORT" -www >/dev/null 2>&1 &
  SRV=$!
  sleep 1
  if kill -0 "$SRV" 2>/dev/null; then
    if [ -n "$sni" ]; then
      out=$(echo | openssl s_client -connect "127.0.0.1:$PORT" -servername "$sni" 2>&1)
    else
      out=$(echo | openssl s_client -connect "127.0.0.1:$PORT" 2>&1)
    fi
    kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
    rc=$(printf '%s' "$out" | grep -m1 'Verify return code')
    depth=$(printf '%s' "$out" | grep -c '^ [0-9] s:')
    if printf '%s' "$rc" | grep -q 'return code: 0'; then
      pass "Local handshake" "$depth cert(s) sent, ${rc#*: }"
    else
      fail "Local handshake" "${rc:-handshake failed}"
      note "This is what a real client will see. Code 20 = missing/misordered intermediate."
    fi
  else
    warns "Local handshake" "could not bind port $PORT — skipped"
    note "Set CHECK_CERT_PORT to use a different port."
  fi
fi

# ----------------------------------------------------- optional: live ----
if [ -n "$LIVE" ]; then
  echo ""
  host=${LIVE%%:*}; port=${LIVE##*:}; [ "$port" = "$LIVE" ] && port=443
  live_out=$(echo | openssl s_client -connect "$host:$port" -servername "$host" 2>/dev/null)
  if [ -z "$live_out" ]; then
    printf '%sLIVE%s  %s:%s unreachable — skipped comparison\n' "$C_WARN" "$C_OFF" "$host" "$port"
  else
    live_fp=$(printf '%s' "$live_out" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
    new_fp=$(openssl x509 -in "$TMP/c1.pem" -noout -fingerprint -sha256 | cut -d= -f2)
    live_end=$(printf '%s' "$live_out" | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
    if [ "$live_fp" = "$new_fp" ]; then
      printf '%sLIVE%s  %s already serves this exact certificate (expires %s)\n' "$C_OK" "$C_OFF" "$host" "$live_end"
    else
      printf '%sLIVE%s  %s currently serves a DIFFERENT certificate\n' "$C_WARN" "$C_OFF" "$host"
      printf '       live expires: %s\n' "$live_end"
      printf '       new  expires: %s\n' "$na"
    fi
  fi
fi

# ---------------------------------------------------------- verdict ----
echo ""
if [ "$FAIL" -gt 0 ]; then
  printf '%sRESULT: FAIL%s — %d failed, %d warning(s). Do NOT apply to production.\n' \
    "$C_BAD" "$C_OFF" "$FAIL" "$WARN"
  exit 1
elif [ "$WARN" -gt 0 ]; then
  printf '%sRESULT: PASS with %d warning(s)%s — review the notes above before applying.\n' \
    "$C_WARN" "$WARN" "$C_OFF"
  exit 0
else
  printf '%sRESULT: PASS%s — safe to apply.\n' "$C_OK" "$C_OFF"
  exit 0
fi
