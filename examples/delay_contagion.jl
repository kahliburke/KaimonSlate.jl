#%% md id=intro
# New Notebook

#%% md id=title title
# Delay Contagion: How Late Flights Infect the Network

*A DAG-driven pipeline over BTS On-Time Performance data — aircraft rotations, delay transfer, and network spillover.*

#%% code id=deps
using DuckDB, DataFrames, Chain, Dates, Statistics, Printf
using CairoMakie
using ZipArchives: ZipReader, zip_names, zip_openentry
import Downloads

#%% code id=theme hidecode
## Dark Makie theme to match the notebook.
set_theme!(merge(theme_dark(), Theme(
    backgroundcolor = :transparent,
    Axis = (backgroundcolor = :transparent, xgridcolor = (:white, 0.08), ygridcolor = (:white, 0.08)),
    Legend = (backgroundcolor = :transparent, framevisible = false),
)))

#%% code id=config
## Pipeline configuration — the root of the DAG. Change the month and
## watch only the affected stages recompute. Data lives in a stable cache
## dir (not tempdir, which the OS reaps) so cached stages survive reboots.
YEAR = 2024
MONTH = 1
DATA_DIR = joinpath(homedir(), ".cache", "kaimon", "data", "delay_contagion")
mkpath(DATA_DIR)
(; YEAR, MONTH, DATA_DIR)

#%% code id=fetch_raw cache
## **Stage 1 — fetch.** One month of BTS On-Time Performance data (~27 MB zip,
## ~600k flights). Idempotent: skips the download/extract if the files are already
## on disk, and the `cache` tag persists the result across sessions.
raw_csv = let
    stem = "On_Time_Reporting_Carrier_On_Time_Performance_1987_present_$(YEAR)_$(MONTH)"
    zippath = joinpath(DATA_DIR, stem * ".zip")
    csvpath = joinpath(DATA_DIR, stem * ".csv")
    if !isfile(csvpath)
        if !isfile(zippath) || filesize(zippath) == 0
            Downloads.download("https://transtats.bts.gov/PREZIP/" * stem * ".zip", zippath)
        end
        zr = ZipReader(read(zippath))
        entry = only(filter(endswith(".csv"), zip_names(zr)))
        open(csvpath, "w") do out
            zip_openentry(zr, entry) do io
                write(out, io)
            end
        end
    end
    csvpath
end

#%% code id=flights cache
## **Stage 2 — load & type.** DuckDB does the heavy lifting: drop cancelled/diverted
## flights, turn hhmm strings into real local timestamps (departure = schedule + signed
## delay, so past-midnight departures land on the right day; arrivals roll a day when
## the clock wraps), and coalesce the five delay-cause columns (NULL unless delay ≥ 15).
flights = let
    con = DBInterface.connect(DuckDB.DB)
    DBInterface.execute(con, "CREATE MACRO hhmm_min(t) AS (CAST(t AS INT) // 100) * 60 + (CAST(t AS INT) % 100)")
    df = DataFrame(DBInterface.execute(con, """
        WITH src AS (
            SELECT *,
                FlightDate + INTERVAL 1 MINUTE * (hhmm_min(CRSDepTime) + DepDelay) AS dep_ts
            FROM read_csv_auto('$(raw_csv)', header=true)
            WHERE Cancelled = 0 AND Diverted = 0
              AND Tail_Number IS NOT NULL AND Tail_Number <> ''
              AND DepTime IS NOT NULL AND ArrTime IS NOT NULL
              AND ActualElapsedTime IS NOT NULL
        )
        SELECT
            FlightDate                              AS date,
            Reporting_Airline                       AS carrier,
            Tail_Number                             AS tail,
            CAST(Flight_Number_Reporting_Airline AS INT) AS flight_num,
            Origin                                  AS origin,
            Dest                                    AS dest,
            FlightDate + INTERVAL 1 MINUTE * hhmm_min(CRSDepTime) AS sched_dep,
            dep_ts,
            datetrunc('day', dep_ts)
              + INTERVAL 1 MINUTE * (hhmm_min(ArrTime) % 1440)
              + CASE WHEN (hhmm_min(ArrTime) % 1440) < (hhmm_min(DepTime) % 1440)
                     THEN INTERVAL 1 DAY ELSE INTERVAL 0 DAY END AS arr_ts,
            CAST(DepDelay AS INT)                   AS dep_delay,
            CAST(ArrDelay AS INT)                   AS arr_delay,
            CAST(ActualElapsedTime AS INT)          AS elapsed,
            CAST(Distance AS INT)                   AS distance,
            CAST(COALESCE(CarrierDelay,      0) AS INT) AS d_carrier,
            CAST(COALESCE(WeatherDelay,      0) AS INT) AS d_weather,
            CAST(COALESCE(NASDelay,          0) AS INT) AS d_nas,
            CAST(COALESCE(SecurityDelay,     0) AS INT) AS d_security,
            CAST(COALESCE(LateAircraftDelay, 0) AS INT) AS d_lateac
        FROM src
        ORDER BY tail, dep_ts
    """))
    DBInterface.close!(con)
    df
end
"$(nrow(flights)) flights, $(length(unique(flights.tail))) aircraft, $(length(unique(flights.origin))) airports"

#%% code id=rotations cache
## **Stage 3 — rotation join.** Link every flight to the previous leg flown by the
## SAME aircraft (tail number). A link is a valid rotation when the aircraft departs
## from where it landed within 24 h — that inbound leg is the contagion vector: its
## arrival delay becomes the next flight's inherited handicap.
rotations = let
    con = DBInterface.connect(DuckDB.DB)
    DuckDB.register_data_frame(con, flights, "flights")
    df = DataFrame(DBInterface.execute(con, """
        WITH lagged AS (
            SELECT *,
                LAG(dest)      OVER w AS prev_dest,
                LAG(arr_ts)    OVER w AS prev_arr_ts,
                LAG(arr_delay) OVER w AS prev_arr_delay
            FROM flights
            WINDOW w AS (PARTITION BY tail ORDER BY dep_ts)
        )
        SELECT *,
            CAST(date_diff('minute', prev_arr_ts, dep_ts) AS INT) AS turn_min,
            (prev_dest = origin
              AND date_diff('minute', prev_arr_ts, dep_ts) BETWEEN 0 AND 1440) AS linked
        FROM lagged
        ORDER BY tail, dep_ts
    """))
    DBInterface.close!(con)
    df.linked = coalesce.(df.linked, false)
    df
end
let n = nrow(rotations), l = sum(rotations.linked)
    @sprintf "%d flights — %d (%.1f%%) linked to their inbound aircraft rotation" n l 100l/n
end

#%% code id=transfer_curve
## **Consumer A — delay transfer.** How much of an inbound delay does the aircraft
## pass on to its next departure? Bin inbound arrival delay, average the outbound
## departure delay per bin — the slope of this curve is the contagion coefficient.
transfer_curve = @chain rotations begin
    subset(:linked; skipmissing=true)
    dropmissing([:prev_arr_delay, :dep_delay])
    transform(:prev_arr_delay => ByRow(d -> clamp(15 * fld(d, 15), -30, 240)) => :in_bin)
    groupby(:in_bin)
    combine(nrow => :n, :dep_delay => mean => :mean_out, :dep_delay => median => :med_out)
    sort(:in_bin)
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
         yAxisIndex = 0, itemStyle = (opacity = 0.15,)),
    ],
)

#%% code id=airport_stats
## **Consumer B — airport pressure.** Per-airport departure stats, split into delay
## the airport *originates* (first legs / long turnarounds) vs delay it *transmits*
## (inherited from late inbound aircraft). Feeds the network map later.
airport_stats = @chain rotations begin
    groupby(:origin)
    combine(
        nrow => :n_dep,
        :dep_delay => mean => :mean_dep_delay,
        :dep_delay => (d -> mean(d .>= 15)) => :frac_late15,
        [:linked, :prev_arr_delay] =>
            ((l, p) -> mean(coalesce.(p[l], 0) .>= 15)) => :frac_inbound_late,
    )
    subset(:n_dep => ByRow(>=(500)))
    sort(:mean_dep_delay; rev=true)
end
first(airport_stats, 8)

#%% code id=airport_table
## **Airport pressure table** (interactive — sort/filter/page).
slate_table(
    @chain airport_stats begin
        transform(
            :mean_dep_delay => ByRow(x -> round(x; digits = 1)) => :mean_dep_delay,
            :frac_late15 => ByRow(x -> round(100x; digits = 1)) => :pct_late15,
            :frac_inbound_late => ByRow(x -> round(100x; digits = 1)) => :pct_inbound_late,
        )
        select(:origin, :n_dep, :mean_dep_delay, :pct_late15, :pct_inbound_late)
    end;
    page_size = 12,
)

#%% code id=daily_fig
## **Daily pulse of the system** (CairoMakie): mean departure delay + late share
## per day. The mid-January winter storms light up immediately.
daily_fig = let
    d = @chain rotations begin
        groupby(:date)
        combine(nrow => :n,
                :dep_delay => mean => :mean_delay,
                :dep_delay => (x -> 100mean(x .>= 15)) => :pct_late)
        sort(:date)
    end
    fig = Figure(size = (860, 340))
    ax1 = Axis(fig[1, 1]; xlabel = "day of January 2024", ylabel = "mean departure delay (min)",
               xticks = 1:2:31)
    days = Dates.day.(d.date)
    barplot!(ax1, days, d.mean_delay; color = d.pct_late, colormap = :inferno,
             colorrange = (10, 50))
    Colorbar(fig[1, 2]; limits = (10, 50), colormap = :inferno, label = "% departures ≥15 min late")
    fig
end

#%% code id=late_thresh
## **Explore:** what counts as "late"? Everything downstream recomputes on release.
@bind late_thresh Slider(5:5:120, default = 15)

#%% md id=late_share
With "late" defined as **≥ {{ late_thresh }} min**, **{{ round(100 * mean(rotations.dep_delay .>= late_thresh); digits = 1) }}%** of January departures were late — and among aircraft that arrived ≥ {{ late_thresh }} min behind schedule, the next departure left late **{{ round(100 * mean(skipmissing(rotations.dep_delay[rotations.linked .& (coalesce.(rotations.prev_arr_delay, 0) .>= late_thresh)] .>= late_thresh)); digits = 1) }}%** of the time.

#%% code id=export_csv
## **Export** — the airport pressure table as CSV (a file-producing pipeline sink).
airport_csv = let
    path = joinpath(DATA_DIR, "airport_stats_$(YEAR)_$(lpad(MONTH, 2, '0')).csv")
    cols = names(airport_stats)
    open(path, "w") do io
        println(io, join(cols, ","))
        for r in eachrow(airport_stats)
            println(io, join((r[c] for c in cols), ","))
        end
    end
    path
end

#%% md id=dag_scaffold_md
## DAG test scaffolding

*Temporary timed nodes (`heavy_*`) — multi-second compute branches + a diamond join into the real pipeline, for exercising the pipeline graph (breathing, heat map, stats).*

#%% code id=heavy_alpha nocache
## Timed test node — predictable 3 s (root of the scaffold branch). `sleep` is
## interruptible and wall-clock is all the memo threshold / stats see. Tagged
## `nocache` so it ALWAYS recomputes — scaffolding should breathe on every run.
heavy_alpha = begin
    sleep(3.0)
    length(raw_csv)
end

#%% code id=heavy_beta nocache
## Timed test node — 1.5 s, downstream of alpha. `nocache`: always recomputes.
heavy_beta = begin
    sleep(1.5)
    heavy_alpha / 2
end

#%% code id=heavy_gamma nocache
## Timed test node — 0.8 s, a second branch off alpha (fan-out). `nocache`: always recomputes.
heavy_gamma = begin
    sleep(0.8)
    heavy_alpha * 3
end

#%% code id=heavy_join
## Diamond join — cheap combiner reading BOTH scaffold branches AND the real
## pipeline (transfer_curve), so the scaffold is wired into the actual DAG.
heavy_join = (beta = heavy_beta, gamma = heavy_gamma, curve_rows = nrow(transfer_curve))

# ╔═╡ Slate.env · notebook packages (auto-maintained — manage via the package panel)
#   Chain 1.0.0 8be319e6-bccf-4806-a6f7-6fae938471bc
#   ZipArchives 2.6.0 49080126-0e18-4c2a-b176-c102e4b3760c
# ╚═╡
