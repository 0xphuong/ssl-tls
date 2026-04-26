#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 -o OUTPUT_CRT FILE1 FILE2 [FILE3 ...]"
  echo ""
  echo "  Concatenates certificate files in order and verifies the result."
  echo ""
  echo "  -o OUTPUT_CRT   Output filename (e.g. domain-tls.crt)"
  echo "  FILE...         Cert files in order: domain cert first, then intermediates"
  echo ""
  echo "Examples:"
  echo "  $0 -o sevensystem-vn-tls.crt _sevensystem_vn.crt USERTrust_RSA_Certification_Authority.crt Sectigo_RSA_Domain_Validation_Secure_Server_CA.crt"
  echo "  $0 -o 7-eleven-vn-tls.crt STAR_7-eleven_vn.crt STAR_7-eleven_vn.ca-bundle"
  exit 1
}

OUTPUT=""
FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUTPUT="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1"; usage ;;
    *) FILES+=("$1"); shift ;;
  esac
done

[[ -z "$OUTPUT" ]] && { echo "ERROR: -o OUTPUT_CRT is required"; usage; }
[[ ${#FILES[@]} -lt 2 ]] && { echo "ERROR: At least 2 certificate files required"; usage; }

# Check all files exist
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || { echo "ERROR: File not found: $f"; exit 1; }
done

# Concatenate
echo "Bundling:"
for f in "${FILES[@]}"; do
  echo "  + $f"
done

cat "${FILES[@]}" > "$OUTPUT"
echo ""
echo "Output: $OUTPUT"

# Show cert info
echo ""
echo "Certificate info:"
openssl x509 -in "$OUTPUT" -noout -subject -issuer -dates 2>/dev/null || true

# Count certs in bundle
COUNT=$(grep -c 'BEGIN CERTIFICATE' "$OUTPUT" || true)
echo ""
echo "Certificates in bundle: $COUNT"
echo ""
echo "Done. Verify the key matches with:"
echo "  openssl x509 -noout -modulus -in $OUTPUT | md5"
echo "  openssl rsa  -noout -modulus -in private.key | md5"
