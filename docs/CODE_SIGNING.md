# Code signing (stable Input Monitoring TCC)

iPaste CI signs Release builds with a **persistent self-signed** certificate so
macOS Input Monitoring (and any later Accessibility grant) can treat updates as
the same app. Ad-hoc signatures (`codesign -s -`) mint a new cdhash every build
and the system forgets the permission.

## Identity

| Field | Value |
| --- | --- |
| Common Name | `iPaste Self-Signed` |
| Bundle ID | `io.github.bianyanhui.iPaste` |
| GitHub secrets | `IPASTE_SIGNING_CERTIFICATE_P12` (base64 PKCS#12), `IPASTE_SIGNING_CERTIFICATE_PASSWORD` |

The PKCS#12 must contain a code-signing identity whose name is exactly
`iPaste Self-Signed`. This repo does not store the certificate or the password.

Pull-request builds still produce `iPaste.zip` if the secrets are missing, and
that zip is ad-hoc signed so the job can run. **Tag builds refuse to publish**
an ad-hoc zip. Do not ship the ad-hoc artifact: every update would ask for
Input Monitoring again.

## Create the certificate (once, on a Mac)

Pick your own export password. Do not commit the key, the certificate, or the
`.p12`.

```bash
cat > codesign.cnf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
prompt = no
x509_extensions = codesign_ext

[ req_distinguished_name ]
CN = iPaste Self-Signed

[ codesign_ext ]
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
EOF

openssl req -x509 -newkey rsa:3072 -keyout codesign.key -out codesign.crt \
  -days 3650 -nodes -config codesign.cnf
openssl pkcs12 -export -inkey codesign.key -in codesign.crt \
  -out ipaste-codesign.p12 -name "iPaste Self-Signed"
```

## Store it as GitHub Actions secrets

Replace the password argument with the export password you chose. The command
reads it from stdin and does not print it.

```bash
base64 -w0 ipaste-codesign.p12 | gh secret set IPASTE_SIGNING_CERTIFICATE_P12 -R BianYanhui/iPaste
printf '%s' 'YOUR_P12_PASSWORD' | gh secret set IPASTE_SIGNING_CERTIFICATE_PASSWORD -R BianYanhui/iPaste
```

On macOS, `base64` has no `-w0`. Use `base64 < ipaste-codesign.p12 | tr -d '\n'`
instead.

Keep a backup of the `.p12` and password offline. Losing them forces a new
identity and another one-time Input Monitoring grant.

## One-time after switching to this identity

1. Install iPaste from the signed Release zip.
2. Open **系统设置 → 隐私与安全性 → 输入监视**.
3. Remove old iPaste entries (each ad-hoc build looks like a different app).
4. Turn on the switch for the new `iPaste.app`. Quit and reopen iPaste.

Later updates signed with the **same** certificate should keep Input Monitoring.

## Local builds

Xcode uses manual signing with an empty team, so a local Run is ad-hoc unless
you import the same `.p12` into the login keychain and re-sign:

```bash
codesign --force --deep --sign "iPaste Self-Signed" --timestamp=none path/to/iPaste.app
```

Do not pass `--options runtime`. Hardened runtime needs an Apple Developer
certificate, which this project does not use.
