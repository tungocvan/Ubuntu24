#!/bin/bash
param1="$1"
mkcert -key-file "/etc/.cert/$param1-key.pem" -cert-file "/etc/.cert/$param1-cert.pem"  "*.$param1"  "$param1"
cp "/etc/.cert/$param1-cert.pem" "/usr/local/share/ca-certificates/$param1-cert.crt"
update-ca-certificates
