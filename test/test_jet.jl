using ReTest
using JET
using KaimonSlate

@testset "JET.jl" begin
    JET.report_package(KaimonSlate)
end
