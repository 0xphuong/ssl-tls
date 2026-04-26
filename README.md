# ssl-tls

Step-by-step guide for purchasing SSL/TLS certificates from a CA (e.g. Sectigo), assembling the certificate chain, and creating Kubernetes TLS secrets.

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
| Organization Name | `7-Eleven Vietnam Co., Ltd` |
| Organizational Unit | `IT` |
| Common Name | `sevensystem.vn` or `*.7-eleven.vn` |
| Email | _(leave blank)_ |

> **Keep `private.key` secret. Never commit it to git.**

---

## Step 2 — Submit CSR to CA

Send the contents of `certreq.csr` to your CA (e.g. Sectigo, DigiCert, GlobalSign):

```bash
cat certreq.csr
```

The CA will validate domain ownership (DV) or organization (OV/EV) then email you a `.zip` file with the certificate chain.

---

## Step 3 — Assemble the certificate chain

The CA sends a `.zip` containing multiple `.crt` files. You must **concatenate them in the correct order** (domain cert first, then intermediates).

### Case 1 — Individual chain files

Files received: `_sevensystem_vn.crt`, `Sectigo_RSA_Domain_Validation_Secure_Server_CA.crt`, `USERTrust_RSA_Certification_Authority.crt`, `AAA_Certificate_Services.crt`

```bash
cat _sevensystem_vn.crt \
    USERTrust_RSA_Certification_Authority.crt \
    Sectigo_RSA_Domain_Validation_Secure_Server_CA.crt \
    > sevensystem-vn-tls.crt
```

### Case 2 — CA-bundle included

Files received: `STAR_7-eleven_vn.crt`, `STAR_7-eleven_vn.ca-bundle`

```bash
cat STAR_7-eleven_vn.crt \
    STAR_7-eleven_vn.ca-bundle \
    > 7-eleven-vn-tls.crt
```

### Case 3 — Sectigo Public CA chain

Files received: `_7-eleven_vn.crt`, `Sectigo_Public_Server_Authentication_CA_DV_R36.crt`, `Sectigo_Public_Server_Authentication_Root_R46.crt`, `USERTrust_RSA_Certification_Authority.crt`

```bash
cat _7-eleven_vn.crt \
    Sectigo_Public_Server_Authentication_CA_DV_R36.crt \
    Sectigo_Public_Server_Authentication_Root_R46.crt \
    > 7-eleven-vn-tls.crt
```

> **Rule**: domain cert → intermediate CA(s) → root CA  
> `AAA_Certificate_Services.crt` is the legacy root — usually not needed, skip unless required.

---

## Step 4 — Verify the certificate chain

```bash
# Check cert details
openssl x509 -in sevensystem-vn-tls.crt -text -noout | grep -E "Subject:|Issuer:|Not Before:|Not After:"

# Verify chain is complete (should output: OK)
openssl verify -CAfile sevensystem-vn-tls.crt sevensystem-vn-tls.crt

# Verify private key matches the certificate
openssl x509 -noout -modulus -in sevensystem-vn-tls.crt | md5
openssl rsa  -noout -modulus -in private.key             | md5
# Both md5 values must be identical

# Test live TLS handshake (after deploying)
echo | openssl s_client -connect sevensystem.vn:443 -servername sevensystem.vn 2>/dev/null | openssl x509 -noout -dates
```

---

## Step 5 — Create Kubernetes TLS Secret

```bash
# Create TLS secret
kubectl create secret tls sevensystem-vn-tls \
  --key  private.key \
  --cert sevensystem-vn-tls.crt \
  -n default

# Verify
kubectl describe secret sevensystem-vn-tls -n default
```

Use in Ingress:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: sevensystem
  namespace: default
spec:
  tls:
    - hosts:
        - sevensystem.vn
      secretName: sevensystem-vn-tls
  rules:
    - host: sevensystem.vn
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: sevensystem-svc
                port:
                  number: 80
```

### Update an existing secret

```bash
kubectl create secret tls sevensystem-vn-tls \
  --key  private.key \
  --cert sevensystem-vn-tls.crt \
  -n default \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

## Helper script

Use [`bundle-cert.sh`](./bundle-cert.sh) to assemble and verify the chain in one command:

```bash
# Case 1
./bundle-cert.sh -o sevensystem-vn-tls.crt \
  _sevensystem_vn.crt \
  USERTrust_RSA_Certification_Authority.crt \
  Sectigo_RSA_Domain_Validation_Secure_Server_CA.crt

# Case 2
./bundle-cert.sh -o 7-eleven-vn-tls.crt \
  STAR_7-eleven_vn.crt \
  STAR_7-eleven_vn.ca-bundle
```

---

## Certificate renewal checklist

- [ ] Generate new `private.key` and `certreq.csr` (or reuse existing key)
- [ ] Submit CSR to CA, complete domain validation
- [ ] Download and assemble new `.crt` chain
- [ ] Verify modulus matches between `.crt` and `.key`
- [ ] Update Kubernetes secret (`--dry-run=client | kubectl apply`)
- [ ] Confirm new expiry: `openssl x509 -noout -dates -in <cert.crt>`
