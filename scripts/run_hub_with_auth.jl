using KaimonSlate
using KaimonSlateHub
using HTTP

const NS = KaimonSlate.NotebookServer

# A persistent data directory so users survive restarts.
data_dir = get(ENV, "KAIMON_DATA_DIR", joinpath(homedir(), ".kaimonslate-hub"))
mkpath(data_dir)

# Known admin credentials for this demo run.
admin_user = get(ENV, "KAIMON_ADMIN", "admin")
admin_pass = get(ENV, "KAIMON_ADMIN_PASSWORD", "kaimon-admin-2026")

auth_hub = KaimonSlateHub.new_hub_server(data_dir;
    port = 8765, bootstrap_admin_username = admin_user,
    bootstrap_admin_password = admin_pass)

host = get(ENV, "KAIMON_HOST", "0.0.0.0")
port = parse(Int, get(ENV, "KAIMON_PORT", "8765"))

h = NS.start_hub(; host = host, port = port, auth_hub = auth_hub)

# Open the demo notebook if present, else create a tiny welcome notebook.
nb_path = joinpath(dirname(dirname(@__DIR__)), "examples", "demo.jl")
if !isfile(nb_path)
    nb_path = joinpath(data_dir, "welcome.jl")
    isfile(nb_path) || write(nb_path,
        "# Welcome notebook\n\nprintln(\"Hello from KaimonSlateHub-controlled KaimonSlate\")\n\n2 + 2\n")
end
id = NS.open_notebook!(h, nb_path)

println("=" ^ 60)
println("KaimonSlate hub running on $host:$port")
println("Data dir:        $data_dir")
println("Admin user:      $admin_user")
println("Admin password:  $admin_pass")
println("Login API:       POST http://<host>:$port/api/login  {\"username\":\"$admin_user\",\"password\":\"$admin_pass\"}")
println("Notebook UI:     http://<host>:$port/n/$id")
println("=" ^ 60)
println("Press Ctrl+C to stop.")

try
    wait(Condition())
catch e
    e isa InterruptException || rethrow(e)
finally
    NS.stop_hub(h)
end