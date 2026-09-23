# Hosted database public CA

`supabase-prod-ca-2021.crt` is the public certificate supplied by Supabase Studio's [official download configuration](https://github.com/supabase/supabase/blob/master/apps/studio/hooks/custom-content/custom-content.json), retrieved 2026-09-23 from `https://supabase-downloads.s3-ap-southeast-1.amazonaws.com/prod/ssl/prod-ca-2021.crt`.

File SHA256: `700723581420dd1ac98fd7e9ac529f0ef210eadcaf87fc868a3ad7d114c2f3b7`. DER SHA256: `807025ad50d4ed219d2c9c7d299c004f824eb00cf7f65afef607d07b72e6cafa`. Valid through 2031-04-26. This contains no private key or credential.

Supabase [documents](https://supabase.com/docs/guides/platform/ssl-enforcement) using its CA with `verify-full`. This repair does not change a machine's trust store, disable verification, or fetch trust material during apply. An explicit target binding pins the canonical path and exact hash; the runner rechecks the CA and hostname-verification mode for every connection. Rotation requires a newly reviewed binding and plan.
