#%% md id=intro
# Tables — `slate_table`

Interactive tables: sort, filter, page — with per-column formatting and in-cell viz.

#%% code id=formatted
rows = [(product = "Widget",   revenue = 128_400.0, margin = 0.42, units = 3_400, size = 1_048_576),
        (product = "Gadget",   revenue =  86_900.0, margin = 0.31, units = 1_210, size =   524_288),
        (product = "Gizmo",    revenue = 203_500.0, margin = 0.55, units = 5_820, size = 2_310_000),
        (product = "Sprocket", revenue =  41_200.0, margin = 0.18, units =   760, size =   131_072),
        (product = "Cog",      revenue =  97_800.0, margin = 0.47, units = 2_050, size =   786_432)]

slate_table(rows;
    format = (revenue = :currency, margin = (kind = :percent, digits = 1),
              units = :integer, size = :bytes),
    viz    = (revenue = :bar, margin = :heat))
