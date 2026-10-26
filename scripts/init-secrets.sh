#!/usr/bin/env bash
# Turn the cleartext templates into the real (gitignored) inputs of kubeseal:
#
#   server/secrets-unsealed/<slug>.yaml.example -> server/secrets-unsealed/<slug>.yaml
#
#   scripts/init-secrets.sh            # every template
#   scripts/init-secrets.sh sonarr     # only these slugs
#
# Placeholders:
#   @GEN:<name>@     32 random alphanumerics
#   @GEN64:<name>@   64 random alphanumerics
#   @GENHEX:<name>@  64 random hex digits
# The same <name> gets the same value in every file, and the values are kept
# in server/secrets-unsealed/.generated.json, so a later run reuses them.
#
# An existing output file is never overwritten. CHANGE_ME values are left for
# you; the script lists the files that still have them.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
umask 077

python3 - "$@" <<'PY'
import json, pathlib, re, secrets, string, sys

unsealed = pathlib.Path("server/secrets-unsealed")
state_file = unsealed / ".generated.json"
state = json.loads(state_file.read_text()) if state_file.exists() else {}

pairs = [(t, t.with_name(t.name.removesuffix(".example"))) for t in sorted(unsealed.glob("*.yaml.example"))]

wanted = set(sys.argv[1:])
if wanted:
    pairs = [(t, o) for t, o in pairs if o.name.split(".")[0] in wanted]

alnum = string.ascii_letters + string.digits
def gen(kind, name):
    key = f"{kind}:{name}"
    if key not in state:
        if kind == "GENHEX":
            state[key] = secrets.token_hex(32)
        else:
            n = 64 if kind == "GEN64" else 32
            state[key] = "".join(secrets.choice(alnum) for _ in range(n))
    return state[key]

todo = []
for tmpl, out in pairs:
    if out.exists():
        print(f"keep   {out}")
    else:
        text = re.sub(r"@(GEN|GEN64|GENHEX):([a-z0-9_]+)@", lambda m: gen(m[1], m[2]), tmpl.read_text())
        out.write_text(text)
        print(f"wrote  {out}")
    if re.search(r"^[^#\n]*CHANGE_ME", out.read_text(), re.M):
        todo.append(out)

state_file.write_text(json.dumps(state, indent=2) + "\n")
if todo:
    print("\nStill CHANGE_ME (fill these in by hand before sealing):")
    for f in todo:
        print(f"  {f}")
PY
