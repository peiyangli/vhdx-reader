#!/usr/bin/env bash
# Fail closed if configure silently selected a generic or legacy padded AES path.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
config="${1:?config.h}"; prefix="${2:?native install prefix}"; platform="${3:?platform}"
for macro in HAVE_LIBCRYPTO HAVE_OPENSSL_EVP_H HAVE_EVP_CIPHERINIT_EX2 HAVE_EVP_CRYPTO_AES_CBC HAVE_EVP_CRYPTO_AES_ECB HAVE_EVP_CRYPTO_AES_XTS; do
  grep -q "^#define $macro 1$" "$config" || { echo "Missing $macro in $config" >&2; exit 1; }
done
if grep -q '^#define HAVE_OPENSSL_AES_H 1$' "$config"; then echo 'Unexpected legacy AES backend' >&2; exit 1; fi
perl -MJSON::PP -0777 -e 'open my $f,"<",$ARGV[0] or die $!; my $m=decode_json(<$f>); $m->{backend}="openssl-evp"; $m->{platform}=$ARGV[1]; print JSON::PP->new->canonical->pretty->encode($m)' "$repo_root/scripts/openssl-source.json" "$platform" > "$prefix/native-crypto.json"
