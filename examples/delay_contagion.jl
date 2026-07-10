#%% md id=title title
# Delay Contagion: How Late Flights Infect the Network

*A DAG-driven pipeline over BTS On-Time Performance data — months of flights resident in DuckDB, aircraft rotations, delay transfer, and network spillover.*

#%% code id=deps
using DuckDB, DataFrames, Dates, Printf
using CairoMakie
using ZipArchives: ZipReader, zip_names, zip_openentry
import Downloads

#%% code id=theme collapsed
## Dark Makie theme to match the notebook.
set_theme!(merge(theme_dark(), Theme(
    backgroundcolor = :transparent,
    Axis = (backgroundcolor = :transparent, xgridcolor = (:white, 0.08), ygridcolor = (:white, 0.08)),
    Legend = (backgroundcolor = :transparent, framevisible = false),
)))

#%% code id=config
## Pipeline configuration — the root of the DAG. `MONTHS` is the scale knob: `1:1` is an
## instant demo (~500k flights); `1:12` is the medium-data version (~7M flights, ~350 MB of
## one-time downloads). Row-level data lives in a persistent DuckDB file — the notebook only
## ever materializes AGGREGATES, so the reactive graph stays light at any scale.
YEAR = 2025
MONTHS = 1:1
DATA_DIR = joinpath(homedir(), ".cache", "kaimon", "data", "delay_contagion")
mkpath(DATA_DIR)
(; YEAR, MONTHS = collect(MONTHS), DATA_DIR)

#%% code id=ingest cache
## **Stage 1 — ingest.** Per month: download the BTS zip (~27 MB), extract, load typed+cleaned
## rows into the persistent DuckDB file, then delete the raw files (the DB has the rows).
## Idempotent via an `ingested` ledger — growing MONTHS only adds the missing months. The cached
## artifact is the DB PATH + the WINDOW's row count (window-scoped so the cached value is a pure
## function of the config, even when the file holds more months than this window).
dbpath = joinpath(DATA_DIR, "flights.duckdb")
ingested_n = let con = DBInterface.connect(DuckDB.DB, dbpath)
    try
        DBInterface.execute(con, "CREATE TABLE IF NOT EXISTS ingested(y INTEGER, m INTEGER)")
        done = Set((r.y, r.m) for r in DBInterface.execute(con, "SELECT y, m FROM ingested"))
        todo = [(YEAR, m) for m in MONTHS if (YEAR, m) ∉ done]
        DBInterface.execute(con,
            "CREATE OR REPLACE MACRO hhmm_min(t) AS (CAST(t AS INT) // 100) * 60 + (CAST(t AS INT) % 100)")
        for (i, (y, m)) in enumerate(todo)
            slate_progress((i - 1) / length(todo); msg = "ingesting $y-$(lpad(m, 2, '0'))")
            stem = "On_Time_Reporting_Carrier_On_Time_Performance_1987_present_$(y)_$(m)"
            zippath = joinpath(DATA_DIR, stem * ".zip")
            csvpath = joinpath(DATA_DIR, stem * ".csv")
            if !isfile(csvpath)
                if !isfile(zippath) || filesize(zippath) == 0
                    Downloads.download("https://transtats.bts.gov/PREZIP/" * stem * ".zip", zippath)
                end
                zr = ZipReader(read(zippath))
                entry = only(filter(endswith(".csv"), zip_names(zr)))
                open(csvpath, "w") do out
                    write(out, zip_openentry(zr, entry))
                end
            end
            sel = """
                SELECT
                    FlightDate                                 AS date,
                    Reporting_Airline                          AS carrier,
                    Tail_Number                                AS tail,
                    CAST(Flight_Number_Reporting_Airline AS INT) AS flight_num,
                    Origin                                     AS origin,
                    Dest                                       AS dest,
                    FlightDate + INTERVAL 1 MINUTE * hhmm_min(CRSDepTime) AS sched_dep,
                    FlightDate + INTERVAL 1 MINUTE * (hhmm_min(CRSDepTime) + CAST(DepDelay AS INT)) AS dep_ts,
                    datetrunc('day', FlightDate + INTERVAL 1 MINUTE * (hhmm_min(CRSDepTime) + CAST(DepDelay AS INT)))
                      + INTERVAL 1 MINUTE * (hhmm_min(ArrTime) % 1440)
                      + CASE WHEN (hhmm_min(ArrTime) % 1440) < (hhmm_min(DepTime) % 1440)
                             THEN INTERVAL 1 DAY ELSE INTERVAL 0 DAY END AS arr_ts,
                    CAST(DepDelay AS INT)                      AS dep_delay,
                    CAST(ArrDelay AS INT)                      AS arr_delay,
                    CAST(ActualElapsedTime AS INT)             AS elapsed,
                    CAST(Distance AS INT)                      AS distance
                FROM read_csv_auto('$(csvpath)', header=true)
                WHERE Cancelled = 0 AND Diverted = 0
                  AND Tail_Number IS NOT NULL AND Tail_Number <> ''
                  AND DepTime IS NOT NULL AND ArrTime IS NOT NULL
                  AND ActualElapsedTime IS NOT NULL
            """
            hasfl = !isempty(collect(DBInterface.execute(con,
                "SELECT 1 FROM information_schema.tables WHERE table_name = 'flights'")))
            DBInterface.execute(con, (hasfl ? "INSERT INTO flights " : "CREATE TABLE flights AS ") * sel)
            DBInterface.execute(con, "INSERT INTO ingested VALUES ($y, $m)")
            rm(csvpath; force = true); rm(zippath; force = true)
            slate_progress(i / length(todo); msg = "ingested $y-$(lpad(m, 2, '0'))")
        end
        DataFrame(DBInterface.execute(con, """
            SELECT count(*) AS n FROM flights
            WHERE year(date) = $YEAR AND month(date) IN ($(join(collect(MONTHS), ',')))
        """)).n[1]
    finally
        DBInterface.close!(con)
    end
end
@sprintf "%d flights in the window → %s" ingested_n dbpath

#%% code id=db nocache
## **The shared handle.** One DuckDB handle downstream cells query through (each opens its own
## connection). Never cached — a handle is process state; if the cache dir was cleared, press ▶
## on the ingest cell to rebuild the file.
db = let
    isfile(dbpath) || error("$dbpath is missing — press ▶ on the ingest cell to rebuild it")
    DuckDB.DB(dbpath)
end;
"connected: $(basename(dbpath))"

#%% code id=rotations cache
## **Stage 2 — rotation join, in the database.** Link every flight to the previous leg flown by
## the SAME aircraft (a valid rotation = departs where it landed, within 24 h) — the inbound
## leg's arrival delay is the contagion vector. Materialized as a `rotations` table filtered to
## the configured MONTHS; at 12 months this window-join over ~7M rows is the pipeline's hot node.
rotations_n, linked_n = let con = DBInterface.connect(db)
    try
        DBInterface.execute(con, """
            CREATE OR REPLACE TABLE rotations AS
            WITH src AS (
                SELECT * FROM flights
                WHERE year(date) = $YEAR AND month(date) IN ($(join(collect(MONTHS), ',')))
            ), lagged AS (
                SELECT *,
                    LAG(dest)      OVER w AS prev_dest,
                    LAG(arr_ts)    OVER w AS prev_arr_ts,
                    LAG(arr_delay) OVER w AS prev_arr_delay
                FROM src
                WINDOW w AS (PARTITION BY tail ORDER BY dep_ts)
            )
            SELECT *,
                CAST(date_diff('minute', prev_arr_ts, dep_ts) AS INT) AS turn_min,
                COALESCE(prev_dest = origin
                  AND date_diff('minute', prev_arr_ts, dep_ts) BETWEEN 0 AND 1440, FALSE) AS linked
            FROM lagged
        """)
        d = DataFrame(DBInterface.execute(con,
            "SELECT count(*) AS n, sum(CASE WHEN linked THEN 1 ELSE 0 END) AS l FROM rotations"))
        (Int(d.n[1]), Int(d.l[1]))
    finally
        DBInterface.close!(con)
    end
end
@sprintf "%d flights (of %d ingested) — %d (%.1f%%) linked to their inbound rotation" rotations_n ingested_n linked_n 100linked_n/rotations_n

#%% code id=transfer_curve
## **Consumer A — delay transfer.** How much of an inbound delay does the aircraft pass to its
## next departure? Binned in SQL; only the 19-row curve ever leaves the database.
@assert rotations_n > 0   # dataflow edge: the `rotations` TABLE is db state, invisible to analysis
transfer_curve = let con = DBInterface.connect(db)
    try
        DataFrame(DBInterface.execute(con, """
            SELECT CAST(least(greatest(15 * floor(prev_arr_delay / 15.0), -30), 240) AS INT) AS in_bin,
                   count(*) AS n, avg(dep_delay) AS mean_out, median(dep_delay) AS med_out
            FROM rotations
            WHERE linked AND prev_arr_delay IS NOT NULL AND dep_delay IS NOT NULL
            GROUP BY in_bin ORDER BY in_bin
        """))
    finally
        DBInterface.close!(con)
    end
end
first(transfer_curve, 6)

#%% code id=transfer_chart
## **The contagion curve** (ECharts): how much of an inbound delay the next
## departure inherits. The slope above ~0 is the delay-transfer coefficient.
echart(
    height = 380,
    tooltip = (trigger = "axis",),
    legend = (top = 6,),
    xAxis = (type = "category", name = "inbound arrival delay (min, binned)",
             nameLocation = "middle", nameGap = 28,
             data = string.(transfer_curve.in_bin)),
    yAxis = (type = "value", name = "outbound departure delay (min)"),
    series = [
        (type = "line", name = "mean", data = round.(transfer_curve.mean_out; digits = 1),
         smooth = true, symbolSize = 5, lineStyle = (width = 3,)),
        (type = "line", name = "median", data = round.(transfer_curve.med_out; digits = 1),
         smooth = true, symbolSize = 4, lineStyle = (type = "dashed",)),
        (type = "bar", name = "flights (k)", data = round.(transfer_curve.n ./ 1000; digits = 1),
         yAxisIndex = 0, itemStyle = (opacity = .15,)),
    ],
)

#%% code id=late_thresh
## **Explore:** what counts as "late"? Everything below — airport pressure, the contagion
## network, the drill-down, the prose — re-queries the database on release.
@bind late_thresh Slider(5:5:120, default = 15, label = "late ≥ (min)")

#%% code id=airport_stats
## **Consumer B — airport pressure.** Per-airport departure stats, split into delay the airport
## *originates* vs delay it *transmits* (inherited from late inbound aircraft). "Late" follows
## the slider; the traffic floor scales with the configured months.
@assert rotations_n > 0   # dataflow edge: the `rotations` TABLE is db state, invisible to analysis
airport_stats = let con = DBInterface.connect(db)
    try
        DataFrame(DBInterface.execute(con, """
            SELECT origin, count(*) AS n_dep, avg(dep_delay) AS mean_dep_delay,
                   avg(CASE WHEN dep_delay >= $late_thresh THEN 1.0 ELSE 0.0 END) AS frac_late,
                   avg(CASE WHEN COALESCE(prev_arr_delay, 0) >= $late_thresh THEN 1.0 ELSE 0.0 END)
                       FILTER (WHERE linked) AS frac_inbound_late
            FROM rotations
            GROUP BY origin
            HAVING count(*) >= $(500 * length(MONTHS))
            ORDER BY mean_dep_delay DESC
        """))
    finally
        DBInterface.close!(con)
    end
end
first(airport_stats, 8)

#%% code id=airport_table
## **Airport pressure table** (interactive — sort/filter/page; "late" follows the slider).
slate_table(
    let t = copy(airport_stats)
        t.mean_dep_delay = round.(t.mean_dep_delay; digits = 1)
        t.pct_late = round.(100 .* t.frac_late; digits = 1)
        t.pct_inbound_late = round.(100 .* t.frac_inbound_late; digits = 1)
        t[:, [:origin, :n_dep, :mean_dep_delay, :pct_late, :pct_inbound_late]]
    end;
    page_size = 12, viz = (mean_dep_delay = :bar, pct_inbound_late = :heat),
)

#%% md id=network_md
## The contagion network

Delay doesn't just happen *at* airports — it travels *between* them on the tail of a
late aircraft. Each arrow below is a **spillover corridor**: an aircraft landed late
(≥ the slider) and carried that delay to its next destination. Drag nodes, scroll to
zoom; node size is traffic, color is the share of departures that inherit a late inbound.

#%% code id=network
## **Consumer C — network spillover** (ECharts force graph). Corridor counts come straight
## from SQL; only the busiest 80 edges leave the database.
@assert rotations_n > 0   # dataflow edge: the `rotations` TABLE is db state, invisible to analysis
network = let
    edges = let con = DBInterface.connect(db)
        try
            DataFrame(DBInterface.execute(con, """
                SELECT origin, dest, count(*) AS contagious FROM rotations
                WHERE linked AND prev_arr_delay >= $late_thresh AND dep_delay >= $late_thresh
                GROUP BY origin, dest ORDER BY contagious DESC LIMIT 80
            """))
        finally
            DBInterface.close!(con)
        end
    end
    stats = Dict(r.origin => (r.n_dep, r.frac_inbound_late) for r in eachrow(airport_stats))
    nodes = [let (n, f) = get(stats, a, (500, 0.0))
                 (name = a, symbolSize = round(6 + 3sqrt(n / (500 * length(MONTHS))); digits = 1),
                  value = round(100f; digits = 1))
             end for a in union(edges.origin, edges.dest)]
    wmax = maximum(edges.contagious)
    echart(
        height = 640,
        tooltip = (trigger = "item",),
        visualMap = (min = 10, max = 35, calculable = true, left = 8, bottom = 8,
                     inRange = (color = ["#7dd3fc", "#facc15", "#fb7185"],),
                     text = ["inherits delay often", "rarely"],
                     textStyle = (color = "#8b949e",)),
        series = [(
            type = "graph", layout = "force", roam = true,
            data = nodes,
            links = [(source = r.origin, target = r.dest,
                      lineStyle = (width = round(0.5 + 3r.contagious / wmax; digits = 2),))
                     for r in eachrow(edges)],
            force = (repulsion = 260, edgeLength = [40, 150], gravity = 0.12),
            edgeSymbol = ["none", "arrow"], edgeSymbolSize = 5,
            label = (show = true, fontSize = 10, color = "#8b949e"),
            lineStyle = (color = "source", opacity = 0.45, curveness = 0.15),
        )],
    )
end

#%% code id=daily_fig
## **Daily pulse of the system** (CairoMakie): mean departure delay + late share per day,
## aggregated in SQL. Storm days light up immediately.
@assert rotations_n > 0   # dataflow edge: the `rotations` TABLE is db state, invisible to analysis
daily_fig = let
    d = let con = DBInterface.connect(db)
        try
            DataFrame(DBInterface.execute(con, """
                SELECT date, count(*) AS n, avg(dep_delay) AS mean_delay,
                       100 * avg(CASE WHEN dep_delay >= 15 THEN 1.0 ELSE 0.0 END) AS pct_late
                FROM rotations GROUP BY date ORDER BY date
            """))
        finally
            DBInterface.close!(con)
        end
    end
    days = Dates.value.(Date.(d.date) .- Date(YEAR, first(MONTHS), 1)) .+ 1
    span = maximum(days)
    fig = Figure(size = (860, 340))
    ax1 = Axis(fig[1, 1];
               xlabel = length(MONTHS) == 1 ? "day of $(Dates.monthname(first(MONTHS))) $YEAR" :
                        "days since $YEAR-$(lpad(first(MONTHS), 2, '0'))-01",
               ylabel = "mean departure delay (min)",
               xticks = 1:max(5, 5 * cld(span, 35)):span)
    barplot!(ax1, days, d.mean_delay; color = d.pct_late, colormap = :inferno,
             colorrange = (10, 50))
    Colorbar(fig[1, 2]; limits = (10, 50), colormap = :inferno, label = "% departures ≥15 min late")
    fig
end

#%% code id=shares
## The headline shares the prose below interpolates (two scalars — computed in SQL).
@assert rotations_n > 0   # dataflow edge: the `rotations` TABLE is db state, invisible to analysis
shares = let con = DBInterface.connect(db)
    try
        d = DataFrame(DBInterface.execute(con, """
            SELECT 100 * avg(CASE WHEN dep_delay >= $late_thresh THEN 1.0 ELSE 0.0 END) AS late_all,
                   100 * avg(CASE WHEN dep_delay >= $late_thresh THEN 1.0 ELSE 0.0 END)
                         FILTER (WHERE linked AND COALESCE(prev_arr_delay, 0) >= $late_thresh) AS relayed
            FROM rotations
        """))
        (late_all = round(d.late_all[1]; digits = 1), relayed = round(d.relayed[1]; digits = 1))
    finally
        DBInterface.close!(con)
    end
end

#%% md id=late_share
With "late" defined as **≥ {{ late_thresh }} min**, **{{ shares.late_all }}%** of departures in the configured window were late — and among aircraft that arrived ≥ {{ late_thresh }} min behind schedule, the next departure left late **{{ shares.relayed }}%** of the time.

#%% md id=drill_md
## Every worst offender, on demand

The table below is **server-paged**: sorting, searching, and paging run as SQL against the
DuckDB file — the browser only ever holds one page, whether the window is one month or twelve.

#%% code id=drill
## Server-paged drill-down over the raw rotations (worst inherited delays first).
@assert rotations_n > 0
slate_query(db, """
    SELECT date, carrier, tail, origin, dest, dep_delay, prev_arr_delay, turn_min
    FROM rotations WHERE linked AND dep_delay >= $late_thresh
    ORDER BY dep_delay DESC
"""; page_size = 15)

#%% code id=export_csv
## **Export** — the airport pressure table as CSV (a file-producing pipeline sink).
airport_csv = let
    path = joinpath(DATA_DIR, "airport_stats_$(YEAR)_$(lpad(first(MONTHS), 2, '0'))-$(lpad(last(MONTHS), 2, '0')).csv")
    cols = names(airport_stats)
    open(path, "w") do io
        println(io, join(cols, ","))
        for r in eachrow(airport_stats)
            println(io, join((r[c] for c in cols), ","))
        end
    end
    path
end

#%% md id=closing
## What the window says

Delay is infectious, and the vector is the airframe itself: an aircraft that lands
{{ late_thresh }}+ minutes behind hands most of that deficit to its next departure (the
contagion curve), mountain and island airports run the highest baseline pressure (the
table), and the spillover corridors concentrate on a handful of hub pairs (the network).
Widen `MONTHS` in `config` — or drag the slider — and the whole argument recomputes,
with every row staying in the database.

# ╔═╡ Slate.env · notebook packages (auto-maintained — manage via the package panel)
#   Chain 1.0.0 8be319e6-bccf-4806-a6f7-6fae938471bc
#   ZipArchives 2.6.0 49080126-0e18-4c2a-b176-c102e4b3760c
# ╚═╡
