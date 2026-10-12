#!/bin/bash
# Type-checks the edge function. It cannot prove an email ever arrives — that
# needs a provider key — but it does prove the code is well formed and agrees
# with the shape of the Supabase client it calls.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
W=${TMPDIR:-/tmp}/peony-fn-check
rm -rf "$W"; mkdir -p "$W"; cd "$W"
npm install --no-audit --no-fund --silent typescript@5.6.3 > /dev/null 2>&1 || {
  echo "skip: npm unavailable, cannot type-check the edge function"; exit 0; }
cat > shim.d.ts <<'EOF'
declare module "jsr:@supabase/supabase-js@2" {
  export function createClient(url: string, key: string, opts?: any): {
    rpc(name: string, args?: Record<string, unknown>):
      Promise<{ data: unknown; error: { message: string } | null }>;
  };
}
declare const Deno: {
  env: { get(k: string): string | undefined };
  serve(h: (req: Request) => Response | Promise<Response>): void;
};
EOF
npm install --no-audit --no-fund --silent stripe@16.12.0 > /dev/null 2>&1 || true
cat > stripe-shim.d.ts <<'EOF'
declare module "npm:stripe@16.12.0" { export * from "stripe"; export { default } from "stripe"; }
EOF
fail=0
for fn in send-mail checkout stripe-webhook; do
  rm -f index.ts; cp "$HERE/functions/$fn/index.ts" .
  if ./node_modules/.bin/tsc --noEmit --strict --target es2022 --lib es2022,dom \
       --module esnext --moduleResolution bundler --skipLibCheck \
       shim.d.ts stripe-shim.d.ts index.ts; then
    echo "ok   $fn type-checks under --strict"
  else
    echo "FAIL $fn does not type-check"; fail=1
  fi
done
exit $fail
