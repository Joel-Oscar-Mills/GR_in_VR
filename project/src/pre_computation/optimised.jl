# using Distributed
# addprocs(nprocs(), exeflags="--project")
@everywhere using Gradus, StaticArrays, SharedArrays, Images, Distributed, FileIO, Plots #,Pkg

# @everywhere Pkg.activate(".")
# @everywhere Pkg.instantiate()
# @everywhere Pkg.precompile()



function velocity_vector(m, u, v)
    x = u[2] * sin(u[3]) * cos(u[4])
    y = u[2] * sin(u[3]) * sin(u[4])

    R = x^2 + y^2
    rdot = (x * v[1] + y * v[2]) / √R
    θdot = (x * v[2] - v[1] * y) / R
    Gradus.constrain_all(m, u, @SVector[1.0, rdot, θdot, 0.0], 1.0)
end


@everywhere begin
    m = KerrMetric(M = 1.0, a = 0.0)
    # coordinate: t    r      θ            ϕ          
    u = @SVector [0.0, 30.0, deg2rad(70), 0.0]
    # get the redshift function we want to use
    redshift_func = ConstPointFunctions.redshift(m, u)
end

# disc:               r_in            r_out  ϕ_inc
d = GeometricThinDisc(Gradus.isco(m), 150.0, π/2)
print(Gradus.isco(m))

# need a velocity prescription for the observer
# so a simple one is that the observer that is time-like stationary
gcomp = metric_components(m, u[2:3])
v_observer = inv(√(-gcomp[1])) * @SVector[1.0, 0.0, 0.0, 0.0]
v_observer = velocity_vector(m, u, [0.0, 0.0])



# φ₀, λ₀ (central parallel and meridian)
# φ₁ (standard parallels)
function inverse_equirectangular(x, y; φ₀ = 0, λ₀ = 0, φ₁ = 0, R = 1.0)
    λ = x / (R * cos(deg2rad(φ₁))) + λ₀
    φ = y / R + φ₀
    mod2pi.((deg2rad(φ), deg2rad(λ)))
end

# output image dimensions (y, x)
scale = ARGS[1] #5
dim = (180, 360) .* scale

angle_pairs = [inverse_equirectangular(x, y; R = scale) for y in 1:dim[1], x in 1:dim[2]]
vs = [Gradus.sky_angles_to_velocity(m, u, v_observer, -θ, ϕ) for (θ, ϕ) in angle_pairs]
us = fill(u, size(vs))

# don't save the full solution cus that's a lot of memory
sols = @time tracegeodesics(m, us, vs, d, (0.0, 2000.0); save_on = false)

points = process_solution.(m, sols.u)

# load in the image and work out the midpoint
image_file = "project/src/pre_computation/blank_disc.jpg"
disc_image = Float64.(Gray.(load(image_file)))
image_y, image_x = size(disc_image)
image_y_mid = image_y ÷ 2
image_x_mid = image_x ÷ 2



# populate the output image
shared = convert(SharedArray{Float64,2}, zeros(dim))


@sync @distributed for i in eachindex(shared)
    p = points[i]
    if (p.status == StatusCodes.IntersectedWithGeometry)

        r, ϕ = p.u2[2], p.u2[4]
        # scale r between 0 and 2
        x = cos(ϕ) * r / d.outer_radius + 1
        y = sin(ϕ) * r / d.outer_radius + 1
        # add 1 since julia arrays begin at 1
        xi = trunc(Int, x * image_x_mid) + 1
        yi = trunc(Int, y * image_y_mid) + 1
        g = redshift_func(m, p, 0.0) 
        value = disc_image[yi, xi]/g
        shared[i] = value
    end
end

print("maximum = ")
print(maximum(shared))
shared ./= maximum(shared) 


# y is flipped, so reverse along that axis
save("colourized11.png", reverse(shared; dims = 1))
