# Matrix All-in-One — task runner. Run `just` or `just --list` to see recipes.
# POSIX sh only. Needs docker for build/smoke/scan; the lint recipes skip
# cleanly when their tool is missing (CI always runs them).

set shell := ["sh", "-c"]

image       := "matrix:dev"
smoke_image := "matrix:smoke-amd64"

# List all recipes
default:
    @just --list

# Build the image locally for the host arch (versions from Dockerfile ARG defaults)
build:
    docker build -t {{image}} .

# Build the amd64 smoke image exactly as CI does (loaded locally, not pushed)
build-smoke:
    docker buildx build --platform linux/amd64 --load -t {{smoke_image}} .

# Boot the smoke image against a throwaway PostgreSQL and wait for /health (mirrors CI)
smoke: build-smoke
    #!/usr/bin/env sh
    set -eu
    net=mx-smoke-net
    cleanup() { docker rm -f mx-smoke mx-smoke-pg >/dev/null 2>&1 || true; docker network rm "$net" >/dev/null 2>&1 || true; }
    trap cleanup EXIT
    docker network create "$net" >/dev/null
    docker run -d --name mx-smoke-pg --network "$net" \
        -e POSTGRES_USER=synapse -e POSTGRES_PASSWORD=smoke -e POSTGRES_DB=synapse \
        -e POSTGRES_INITDB_ARGS="--encoding=UTF-8 --lc-collate=C --lc-ctype=C" \
        postgres:16-alpine >/dev/null
    docker run -d --name mx-smoke --network "$net" -p 8008:8008 \
        -e SERVER_NAME=smoke.local \
        -e POSTGRES_HOST=mx-smoke-pg -e POSTGRES_USER=synapse \
        -e POSTGRES_PASSWORD=smoke -e POSTGRES_DB=synapse \
        {{smoke_image}} >/dev/null
    for i in $(seq 1 180); do
        if curl -fsS -o /dev/null http://localhost:8008/health; then
            echo "Synapse /health responded after ${i}s"; exit 0
        fi
        if [ -z "$(docker ps -q --filter name=mx-smoke$)" ]; then
            echo "container exited early — logs:"; docker logs mx-smoke || true; exit 1
        fi
        sleep 1
    done
    echo "/health did not respond within 180s — logs:"; docker logs mx-smoke || true; exit 1

# Lint the Dockerfile (hadolint, same ignores + threshold as CI)
lint-docker:
    hadolint --failure-threshold warning --ignore DL3008 --ignore DL3009 --ignore DL3059 --ignore SC2086 Dockerfile

# Lint every shell script under rootfs/ (shellcheck, same flags as CI)
lint-sh:
    #!/usr/bin/env sh
    set -eu
    if ! command -v shellcheck >/dev/null 2>&1; then echo "shellcheck not installed — skipping (CI runs it)"; exit 0; fi
    scripts=$(find rootfs/ -type f \( -name "*.sh" -o -name "run" \))
    # shellcheck disable=SC2086
    shellcheck -S warning -x -e SC1091 $scripts
    echo "All shell scripts passed shellcheck."

# Lint the workflow YAML (yamllint, same config as CI)
lint-yaml:
    #!/usr/bin/env sh
    set -eu
    if ! command -v yamllint >/dev/null 2>&1; then echo "yamllint not installed — skipping (CI runs it)"; exit 0; fi
    yamllint -d '{extends: default, rules: {line-length: {max: 160}, truthy: {allowed-values: ["true", "false", "on", "off", "yes", "no"]}}}' .github/workflows/

# Validate the envsubst config templates parse as YAML (mirrors CI)
check-templates:
    #!/usr/bin/env python3
    import glob, re, sys, yaml
    errs = []
    for f in sorted(glob.glob("rootfs/defaults/*.yaml.tmpl")):
        content = re.sub(r"\$\{[^}]+\}", "PLACEHOLDER", open(f).read())
        try:
            yaml.safe_load(content)
            print("OK:", f)
        except yaml.YAMLError as e:
            errs.append(f"{f}: {e}")
    if errs:
        print("\n".join(errs), file=sys.stderr)
        sys.exit(1)

# Run every linter (Dockerfile + shell + YAML + templates)
lint: lint-docker lint-sh lint-yaml check-templates

# Scan the working tree for committed secrets (gitleaks)
secrets:
    gitleaks dir . --redact --no-banner

# Trivy CVE scan of the smoke image (HIGH/CRITICAL, report-only — like CI)
scan: build-smoke
    trivy image --severity HIGH,CRITICAL --ignore-unfixed {{smoke_image}}

# Full local gate before pushing: all linters + secret scan
check: lint secrets
