#features files used to compute the transition path of the full model

using Plots

"""
    get_transition_full(TR::Int64,T::Int64,p::params,SS::steady_state; RChange::Float64 = -0.005)

Convenience function to solve for a transition path. Relies on function `solve_for_transition`. 

Always uses the steady state factor prices, price dispersion, etc. as initial guess for the transition path.

Inputs: `TR` (time until single-quarter interest rate change), `T` (time horizon transition path), 
`p` (parameter structure), `SS` (steady state structure), `RChange` (Change of R at time TR).
The default `RChange` value corresponds to the 50 basis points decrease considered in the MNS paper.
"""   
function get_transition_full(TR::Int64,T::Int64,p::params,SS::steady_state; RChange::Float64 = -0.005)

    @unpack Rbar = p

    #generate R path
    Rpath = repeat([Rbar],T); Rpath[TR+2] = Rbar + RChange
    
    #make guess for paths: just steady state state_values for entire transition periods
    wpath = repeat([SS.w],T) ; div_path = repeat([SS.div],T) 
    Spath = ones(T) ; 

    #get transition path
    tp = solve_for_transition(Rpath,wpath,div_path,Spath,SS,p)

    return tp 
end

"""
    solve_for_transition(Rpath::Array{Float64,1},wguess::Array{Float64,1},div_path::Array{Float64,1},
                         Spath::Array{Float64,1},SS::steady_state,p::params,S_tol::Float64=1e-6,w_tol::Float64=1e-6)

Solves for the perfect foresight transition path for a given interest interest rate path `Rpath`, assuming that the economy will be back in 
steady state as of the final entry of `Rpath`.

The other `_path` inputs constitue initial guesses.

Given initial guesses, the function applies an iterative procedure to solve for the equilibrium transition path of wages and price dispersion.
Specifically, it first iteratively solves for a wage path so that, given the current guess for the path of `S`, output is (approximately)
equal to labor supply. By Walras' law, this means that the asset market must be cleared as well.

Afterwards, the algorithm computes the price dispersion path S implied by the wage and output paths, which will be the guess of S
for the next iteration.

The function relies on the functions `solveback` and `simulate_forward`.

Default tolerance values correspond to the values used for the MNS code.
"""
function solve_for_transition(Rpath::Array{Float64,1},wguess::Array{Float64,1},div_path::Array{Float64,1},
                            Spath::Array{Float64,1},SS::steady_state,p::params;S_tol::Float64= 1e-6, w_tol::Float64 = 1e-6)

 #unpack some parameters
 @unpack B,tax_weights, Γ, ψ, μ, β , θ , nk, nz, nb = p


 #back out number of periods
 T = length(Rpath)   

 #get path for tax rate
 τ_path = (B*SS.Y/(Γ'*tax_weights))*(1.0 .- 1.0./Rpath)
 wpath = wguess[:] ; 

 #make objects exist outside while loop
 Ypath = ones(T-1) ; pΠpath = ones(T)  
 Dpath = Array{Float64,2}(undef,nk*nz,T) ; cpol_path =  Array{Float64,2}(undef,nb*nz,T)

 #outer loop solving for S (price dispersion) path
 iterS = 1 ; distS = 1.0
 while (iterS < 100) & (distS > S_tol )

    
    #inner loop solving for wage path
    iterW = 1 ; distW = 1.0
    while (iterW < 100) & (distW > w_tol) #does not need to converge fully for every S iteration
    
    #solve HH problem backwards
    cs = solveback(reshape_c(SS.c_policies,p),wpath,Rpath,τ_path,div_path,β,p)
    cpol_path = cs

    #use result to simulate aggregate forwards
    Cpath,Lpath,Bpath = simulate_forward(SS.D,cpol_path,Rpath,wpath,div_path,τ_path,p)

    #define output path
    Ypath = Cpath[:]

    #get aggregate labor demand path
    Npath = Spath[1:T-1].*Ypath

    #update wage and dividend paths
    oldwage = wpath[:]
    wpath[2:T-1] = wpath[2:T-1].*(Npath[2:T-1]./Lpath[2:T-1]).^ψ
    
    #same update rule as in MNS
    wpath[2:T-1] = 0.25*wpath[2:T-1] .+ 0.75*oldwage[2:T-1]

    div_path[2:T-1] = Ypath[2:T-1] .- wpath[2:T-1].*Npath[2:T-1]

    #calculate distance
    distW = maximum(abs.(wpath[2:T-1]./oldwage[2:T-1] .- 1.0))

    println("Current W distance: ", distW," Current wage iteration: ",iterW)
    iterW = iterW + 1
    end

    #initialize pbarA and pbarB terms (nominator and denominator in MNS eqaution (7))
    pbarA = μ*SS.w*SS.Y / (1-β*(1-θ)) ; pbarB = SS.Y/(1-β*(1-θ))

    #pre-allocate
    pΠpath = ones(T) ; pstar = ones(T) 

    #solve backwards for pbarA, pbarB and reset inflation
    for t = T-1:-1:2
        pbarA = μ*wpath[1+t]*Ypath[t] + β*(1-θ)*(pΠpath[t+1]^(μ/(μ-1)))*pbarA
        pbarB = Ypath[t] + β*(1-θ)*(pΠpath[t+1]^(1/(μ-1)))*pbarB
        pstar[t] = pbarA/pbarB
        pΠpath[t] = ((1-θ)/(1-θ*pstar[t]^(1/(1-μ))))^(1-μ)
    end

    oldS = Spath ; Spath = ones(T)
    Slast = 1.0 #steady state price dispersion
    #solve for S path
    for t = 2:T-1
        Spath[t] = (1-θ)*Slast*pΠpath[t]^(μ/(μ-1)) + θ*pstar[t]^(μ/(1-μ))
        Slast = Spath[t]
    end

    #compute Distance
    distS = maximum(abs.(Spath./oldS .- 1.0))
    println("Current S distance: ", distS," Current S iteration: ",iterS)
    println(" ")

    iterS = iterS + 1
 end

 return transition_full(Spath[2:T-1],wpath[2:T-1],pΠpath[2:T-1],Ypath[2:T-1],Rpath[2:T-1],τ_path[2:T-1],div_path[2:T-1])

end



"""
    simulate_forward(D0::Array{Float64,1},cpol_path::Array{Float64,2},Rpath::Array{Float64,1},
                     wpath::Array{Float64,1},div_path::Array{Float64,1},τ_path::Array{Float64,1},p::params)

Given an initial wealth distribution `D0`, household policy functions `cpol_path` and prices for factor prices,
taxes and dividends, this function simulates the implied aggregate consumption, labor supply and asset holdings
for a transition period.

Relies on the function `aggregate_C_L` and `forward_dist`.
"""
function simulate_forward(D0::Array{Float64,1},cpol_path::Array{Float64,2},Rpath::Array{Float64,1},
                        wpath::Array{Float64,1},div_path::Array{Float64,1},τ_path::Array{Float64,1},p::params)

 @unpack k_grid = p

 #back out number of periods
 T = length(Rpath)

 #pre-allocate some arrays
 Cpath = Array{Float64,1}(undef,T-1);  Lpath = Array{Float64,1}(undef,T-1)
 Bpath = Array{Float64,1}(undef,T-1)  
 Dpath = Array{Float64,2}(undef,p.nz*p.nk,T)
 Dpath[:,2] .= D0 

 for t = 2:T-1

 #simulate forward
  cpols = reshape_c(cpol_path[:,t],p)
  Cpath[t],Lpath[t] = aggregate_C_L(Dpath[:,t],cpols,Rpath[t],wpath[t],τ_path[t],div_path[t],p)
  Dpath[:,t+1]     .= forward_dist(Dpath[:,t],forwardmat(cpols,Rpath[t],wpath[t],τ_path[t],div_path[t],p))
  Bpath[t]          = dot(Dpath[:,t+1],repeat(k_grid,3))

 #check distribution
 @assert (abs(sum(Dpath[:,t+1]) - 1.0) < 1e-6)
 end
 

 return Cpath , Lpath, Bpath

    
end


"""
    simulate_step(D::Array{Float64,1},c_pol::Array{Float64,2},R::Float64,w::Float64,
                  τ::Float64,div::Float64,p::params)

Conducts forward simulation for one period. Helper function to simulate_forward, equivalent 
to simulatestep() in MNS code.Originally used in loop in Simulate_forward, replaced it to 
do better pre-allocation there.

Since the function is not used in the final implementation, no more documentation. 
(The function is in principle usable though.)

The following was originally in the simulate forward loop: 

`Cpath[t], Lpath[t], Bpath[t], Dpath[:,t+1]  = simulate_CLB(Dpath[:,t],reshape_c(cpol_path[:,t],p),Rpath[t],wpath[t],τ_path[t],div_path[t],p)`
"""
function simulate_step(D::Array{Float64,1},c_pol::Array{Float64,2},R::Float64,w::Float64,τ::Float64,div::Float64,p::params)

    @unpack k_grid = p

 #household consumption and labor supply
 C,L = aggregate_C_L(D,c_pol,R,w,τ,div,p)

 Pi = forwardmat(c_pol,R,w,τ,div,p)

 #distribution in next period
 Dprime = Pi'*D

 #aggregate assets
 Assets = dot(Dprime,repeat(k_grid,3))

 #test for validity of distribution 
 @assert (abs(sum(Dprime) - 1.0) < 1e-6)

 return C, L, Assets, Dprime
    
end

"""
    forward_dist(D::Array{Float64,1},Pi::SparseMatrixCSC)

Calculates asset distribution in next period given transition matrix `Pi` and current distribution `D`.
This is just multiplying a (sparse) matrix with a vector.
"""
function forward_dist(D::Array{Float64,1},Pi::SparseMatrixCSC)
return Pi'*D
end