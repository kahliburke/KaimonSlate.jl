using ReTest
using Aqua
using KaimonSlate

@testset "Aqua.jl" begin
    Aqua.test_all(KaimonSlate)
end
