set shell := ["bash", "-cu"]

julia := env_var_or_default("JULIA", "julia +1.12")

# List the available recipes.
default:
    @just --list

# Instantiate the project with the in-repository extension SDK.
setup:
    {{julia}} --project=. -e 'using Pkg; Pkg.develop(path="lib/SlateExtensionsBase"); Pkg.instantiate()'

# Run the complete test suite with the same GC setting as CI.
test: setup
    JULIA_NUM_GC_THREADS=1 {{julia}} --project=. -e 'using Pkg; Pkg.test(; allow_reresolve=true)'

# Run the extension SDK test suite.
test-sdk:
    {{julia}} --project=lib/SlateExtensionsBase -e 'using Pkg; Pkg.instantiate(); Pkg.test()'

# Instantiate the documentation environments.
docs-setup:
    {{julia}} --project=docs -e 'using Pkg; Pkg.develop(path="lib/SlateExtensionsBase"); Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
    npm --prefix docs install

# Build the documentation.
docs: docs-setup
    {{julia}} --project=docs docs/make.jl

# Serve the built documentation with VitePress.
docs-serve: docs
    npm --prefix docs run docs:dev

# Start Slate for this machine only.
serve-local notebook="examples/demo.jl" port="8765":
    @echo "Slate local: http://127.0.0.1:{{port}} (not accessible from other machines)"
    {{julia}} --project=. -e 'using KaimonSlate; serve_notebook(ARGS[1]; host="127.0.0.1", port=parse(Int, ARGS[2]))' {{notebook}} {{port}}

# Start Slate on every network interface, protected by an automatically generated token.
serve-network notebook="examples/demo.jl" port="8765":
    # The server banner below prints the complete one-time URL, including its access token.
    @network_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"; \
        if [[ -n "$network_ip" ]]; then \
            echo "Slate network: http://$network_ip:{{port}} (accessible from other machines)"; \
        else \
            echo "Slate network: port {{port}} on all interfaces (could not detect the LAN IP)"; \
        fi
    {{julia}} --project=. -e 'using KaimonSlate; serve_notebook(ARGS[1]; host="0.0.0.0", port=parse(Int, ARGS[2]))' {{notebook}} {{port}}

# Backwards-compatible alias for local serving.
serve notebook="examples/demo.jl" port="8765": (serve-local notebook port)

# Build the local development container.
docker-build tag="slate:dev":
    docker build -t {{tag}} docker/
