#include "../Utils.hpp"
#include "Ccds.hpp"
#include "Solver.cuh"
#include "zensim/geometry/Distance.hpp"
#include "zensim/geometry/Friction.hpp"
#include "zensim/geometry/SpatialQuery.hpp"
#include "zensim/types/SmallVector.hpp"

namespace zeno {

void IPCSystem::computeConstraints(zs::CudaExecutionPolicy &pol) {
    using namespace zs;
    constexpr auto space = execspace_e::cuda;
    pol(Collapse{numDofs}, [vtemp = proxy<space>({}, vtemp)] __device__(int vi) mutable {
        auto BCbasis = vtemp.pack<3, 3>("BCbasis", vi);
        auto BCtarget = vtemp.pack<3>("BCtarget", vi);
        int BCorder = vtemp("BCorder", vi);
        auto x = BCbasis.transpose() * vtemp.pack<3>("xn", vi);
        int d = 0;
        for (; d != BCorder; ++d)
            vtemp("cons", d, vi) = x[d] - BCtarget[d];
        for (; d != 3; ++d)
            vtemp("cons", d, vi) = 0;
    });
}
bool IPCSystem::areConstraintsSatisfied(zs::CudaExecutionPolicy &pol) {
    using namespace zs;
    computeConstraints(pol);
    auto res = constraintResidual(pol);
    return res < s_constraint_residual;
}
typename IPCSystem::T IPCSystem::constraintResidual(zs::CudaExecutionPolicy &pol, bool maintainFixed) {
    using namespace zs;
    constexpr auto space = execspace_e::cuda;
    if (projectDBC)
        return 0;
    Vector<T> num{vtemp.get_allocator(), numDofs}, den{vtemp.get_allocator(), numDofs};
    pol(Collapse{numDofs}, [vtemp = proxy<space>({}, vtemp), den = proxy<space>(den), num = proxy<space>(num),
                            maintainFixed] __device__(int vi) mutable {
        auto BCbasis = vtemp.pack<3, 3>("BCbasis", vi);
        auto BCtarget = vtemp.pack<3>("BCtarget", vi);
        int BCorder = vtemp("BCorder", vi);
        auto cons = vtemp.pack<3>("cons", vi);
        auto xt = vtemp.pack<3>("xhat", vi);
        T n = 0, d_ = 0;
        // https://ipc-sim.github.io/file/IPC-supplement-A-technical.pdf Eq5
        for (int d = 0; d != BCorder; ++d) {
            n += zs::sqr(cons[d]);
            d_ += zs::sqr(col(BCbasis, d).dot(xt) - BCtarget[d]);
        }
        num[vi] = n;
        den[vi] = d_;
        if (maintainFixed && BCorder > 0) {
            if (d_ != 0) {
                if (zs::sqrt(n / d_) < 1e-6)
                    vtemp("BCfixed", vi) = 1;
            } else {
                if (zs::sqrt(n) < 1e-6)
                    vtemp("BCfixed", vi) = 1;
            }
        }
    });
    auto nsqr = reduce(pol, num);
    auto dsqr = reduce(pol, den);
    T ret = 0;
    if (dsqr == 0)
        ret = std::sqrt(nsqr);
    else
        ret = std::sqrt(nsqr / dsqr);
    return ret < 1e-6 ? 0 : ret;
}

void IPCSystem::findCollisionConstraints(zs::CudaExecutionPolicy &pol, T dHat, T xi) {
    nPP.setVal(0);
    nPE.setVal(0);
    nPT.setVal(0);
    nEE.setVal(0);
    nPPM.setVal(0);
    nPEM.setVal(0);
    nEEM.setVal(0);

    ncsPT.setVal(0);
    ncsEE.setVal(0);
    {
        auto triBvs = retrieve_bounding_volumes(pol, vtemp, "xn", stInds, zs::wrapv<3>{}, 0);
        stBvh.refit(pol, triBvs);
        auto edgeBvs = retrieve_bounding_volumes(pol, vtemp, "xn", seInds, zs::wrapv<2>{}, 0);
        seBvh.refit(pol, edgeBvs);
        findCollisionConstraintsImpl(pol, dHat, xi, false);
    }

    if (coVerts)
        if (coVerts->size()) {
            auto triBvs = retrieve_bounding_volumes(pol, vtemp, "xn", *coEles, zs::wrapv<3>{}, coOffset);
            bouStBvh.refit(pol, triBvs);
            auto edgeBvs = retrieve_bounding_volumes(pol, vtemp, "xn", *coEdges, zs::wrapv<2>{}, coOffset);
            bouSeBvh.refit(pol, edgeBvs);
            findCollisionConstraintsImpl(pol, dHat, xi, true);
        }
}
void IPCSystem::findCollisionConstraintsImpl(zs::CudaExecutionPolicy &pol, T dHat, T xi, bool withBoundary) {
    using namespace zs;
    constexpr auto space = execspace_e::cuda;

    /// pt
    pol(Collapse{svInds.size()},
        [svInds = proxy<space>({}, svInds), eles = proxy<space>({}, withBoundary ? *coEles : stInds),
         vtemp = proxy<space>({}, vtemp), bvh = proxy<space>(withBoundary ? bouStBvh : stBvh), PP = proxy<space>(PP),
         nPP = proxy<space>(nPP), PE = proxy<space>(PE), nPE = proxy<space>(nPE), PT = proxy<space>(PT),
         nPT = proxy<space>(nPT), csPT = proxy<space>(csPT), ncsPT = proxy<space>(ncsPT), dHat, xi,
         thickness = xi + dHat, voffset = withBoundary ? coOffset : 0] __device__(int vi) mutable {
            vi = reinterpret_bits<int>(svInds("inds", vi));
            const auto dHat2 = zs::sqr(dHat + xi);
            int BCorder0 = vtemp("BCorder", vi);
            auto p = vtemp.template pack<3>("xn", vi);
            auto bv = bv_t{get_bounding_box(p - thickness, p + thickness)};
            bvh.iter_neighbors(bv, [&](int stI) {
                auto tri = eles.template pack<3>("inds", stI).template reinterpret_bits<int>() + voffset;
                if (vi == tri[0] || vi == tri[1] || vi == tri[2])
                    return;
                // all affected by sticky boundary conditions
                if (BCorder0 == 3 && vtemp("BCorder", tri[0]) == 3 && vtemp("BCorder", tri[1]) == 3 &&
                    vtemp("BCorder", tri[2]) == 3)
                    return;
                // ccd
                auto t0 = vtemp.template pack<3>("xn", tri[0]);
                auto t1 = vtemp.template pack<3>("xn", tri[1]);
                auto t2 = vtemp.template pack<3>("xn", tri[2]);

                switch (pt_distance_type(p, t0, t1, t2)) {
                case 0: {
                    if (auto d2 = dist2_pp(p, t0); d2 < dHat2) {
                        auto no = atomic_add(exec_cuda, &nPP[0], 1);
                        PP[no] = pair_t{vi, tri[0]};
                        csPT[atomic_add(exec_cuda, &ncsPT[0], 1)] = pair4_t{vi, tri[0], tri[1], tri[2]};
                    }
                    break;
                }
                case 1: {
                    if (auto d2 = dist2_pp(p, t1); d2 < dHat2) {
                        auto no = atomic_add(exec_cuda, &nPP[0], 1);
                        PP[no] = pair_t{vi, tri[1]};
                        csPT[atomic_add(exec_cuda, &ncsPT[0], 1)] = pair4_t{vi, tri[0], tri[1], tri[2]};
                    }
                    break;
                }
                case 2: {
                    if (auto d2 = dist2_pp(p, t2); d2 < dHat2) {
                        auto no = atomic_add(exec_cuda, &nPP[0], 1);
                        PP[no] = pair_t{vi, tri[2]};
                        csPT[atomic_add(exec_cuda, &ncsPT[0], 1)] = pair4_t{vi, tri[0], tri[1], tri[2]};
                    }
                    break;
                }
                case 3: {
                    if (auto d2 = dist2_pe(p, t0, t1); d2 < dHat2) {
                        auto no = atomic_add(exec_cuda, &nPE[0], 1);
                        PE[no] = pair3_t{vi, tri[0], tri[1]};
                        csPT[atomic_add(exec_cuda, &ncsPT[0], 1)] = pair4_t{vi, tri[0], tri[1], tri[2]};
                    }
                    break;
                }
                case 4: {
                    if (auto d2 = dist2_pe(p, t1, t2); d2 < dHat2) {
                        auto no = atomic_add(exec_cuda, &nPE[0], 1);
                        PE[no] = pair3_t{vi, tri[1], tri[2]};
                        csPT[atomic_add(exec_cuda, &ncsPT[0], 1)] = pair4_t{vi, tri[0], tri[1], tri[2]};
                    }
                    break;
                }
                case 5: {
                    if (auto d2 = dist2_pe(p, t2, t0); d2 < dHat2) {
                        auto no = atomic_add(exec_cuda, &nPE[0], 1);
                        PE[no] = pair3_t{vi, tri[2], tri[0]};
                        csPT[atomic_add(exec_cuda, &ncsPT[0], 1)] = pair4_t{vi, tri[0], tri[1], tri[2]};
                    }
                    break;
                }
                case 6: {
                    if (auto d2 = dist2_pt(p, t0, t1, t2); d2 < dHat2) {
                        auto no = atomic_add(exec_cuda, &nPT[0], 1);
                        PT[no] = pair4_t{vi, tri[0], tri[1], tri[2]};
                        csPT[atomic_add(exec_cuda, &ncsPT[0], 1)] = pair4_t{vi, tri[0], tri[1], tri[2]};
                    }
                    break;
                }
                default: break;
                }
            });
        });
    /// ee
    pol(Collapse{seInds.size()},
        [seInds = proxy<space>({}, seInds), sedges = proxy<space>({}, withBoundary ? *coEdges : seInds),
         vtemp = proxy<space>({}, vtemp), bvh = proxy<space>(withBoundary ? bouSeBvh : seBvh), PP = proxy<space>(PP),
         nPP = proxy<space>(nPP), PE = proxy<space>(PE), nPE = proxy<space>(nPE), EE = proxy<space>(EE),
         nEE = proxy<space>(nEE),
         // mollifier
         PPM = proxy<space>(PPM), nPPM = proxy<space>(nPPM), PEM = proxy<space>(PEM), nPEM = proxy<space>(nPEM),
         EEM = proxy<space>(EEM), nEEM = proxy<space>(nEEM), enableMollification = enableMollification,
         //
         csEE = proxy<space>(csEE), ncsEE = proxy<space>(ncsEE), dHat, xi, thickness = xi + dHat,
         voffset = withBoundary ? coOffset : 0] __device__(int sei) mutable {
            const auto dHat2 = zs::sqr(dHat + xi);
            auto eiInds = seInds.template pack<2>("inds", sei).template reinterpret_bits<int>();
            bool selfFixed = vtemp("BCorder", eiInds[0]) == 3 && vtemp("BCorder", eiInds[1]) == 3;
            auto v0 = vtemp.template pack<3>("xn", eiInds[0]);
            auto v1 = vtemp.template pack<3>("xn", eiInds[1]);
            auto rv0 = vtemp.template pack<3>("x0", eiInds[0]);
            auto rv1 = vtemp.template pack<3>("x0", eiInds[1]);
            auto [mi, ma] = get_bounding_box(v0, v1);
            auto bv = bv_t{mi - thickness, ma + thickness};
            bvh.iter_neighbors(bv, [&](int sej) {
                if (voffset == 0 && sei < sej)
                    return;
                auto ejInds = sedges.template pack<2>("inds", sej).template reinterpret_bits<int>() + voffset;
                if (eiInds[0] == ejInds[0] || eiInds[0] == ejInds[1] || eiInds[1] == ejInds[0] ||
                    eiInds[1] == ejInds[1])
                    return;
                // all affected by sticky boundary conditions
                if (selfFixed && vtemp("BCorder", ejInds[0]) == 3 && vtemp("BCorder", ejInds[1]) == 3)
                    return;
                // ccd
                auto v2 = vtemp.template pack<3>("xn", ejInds[0]);
                auto v3 = vtemp.template pack<3>("xn", ejInds[1]);
                auto rv2 = vtemp.template pack<3>("x0", ejInds[0]);
                auto rv3 = vtemp.template pack<3>("x0", ejInds[1]);

                bool mollify = false;
                if (enableMollification) {
                    // IPC (24)
                    T c = cn2_ee(v0, v1, v2, v3);
                    T epsX = mollifier_threshold_ee(rv0, rv1, rv2, rv3);
                    mollify = c < epsX;
                }

                switch (ee_distance_type(v0, v1, v2, v3)) {
                case 0: {
                    if (auto d2 = dist2_pp(v0, v2); d2 < dHat2) {
                        csEE[atomic_add(exec_cuda, &ncsEE[0], 1)] = pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
                        if (mollify) {
                            auto no = atomic_add(exec_cuda, &nPPM[0], 1);
                            PPM[no] = pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
                            break;
                        }
                        {
                            auto no = atomic_add(exec_cuda, &nPP[0], 1);
#if 0
                printf("ee category 0: %d-th <%d, %d, %d, %d>, dist: %f (%f) < "
                       "%f\n",
                       (int)no, (int)eiInds[0], (int)eiInds[1], (int)ejInds[0],
                       (int)ejInds[1], (float)zs::sqrt(d2),
                       (float)(v0 - v2).norm(), (float)dHat);
#endif
                            PP[no] = pair_t{eiInds[0], ejInds[0]};
                        }
                    }
                    break;
                }
                case 1: {
                    if (auto d2 = dist2_pp(v0, v3); d2 < dHat2) {
                        csEE[atomic_add(exec_cuda, &ncsEE[0], 1)] = pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
                        if (mollify) {
                            auto no = atomic_add(exec_cuda, &nPPM[0], 1);
                            PPM[no] = pair4_t{eiInds[0], eiInds[1], ejInds[1], ejInds[0]};
                            break;
                        }
                        {
                            auto no = atomic_add(exec_cuda, &nPP[0], 1);
                            PP[no] = pair_t{eiInds[0], ejInds[1]};
                        }
                    }
                    break;
                }
                case 2: {
                    if (auto d2 = dist2_pe(v0, v2, v3); d2 < dHat2) {
                        csEE[atomic_add(exec_cuda, &ncsEE[0], 1)] = pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
                        if (mollify) {
                            auto no = atomic_add(exec_cuda, &nPEM[0], 1);
                            PEM[no] = pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
                            break;
                        }
                        {
                            auto no = atomic_add(exec_cuda, &nPE[0], 1);
                            PE[no] = pair3_t{eiInds[0], ejInds[0], ejInds[1]};
                        }
                    }
                    break;
                }
                case 3: {
                    if (auto d2 = dist2_pp(v1, v2); d2 < dHat2) {
                        csEE[atomic_add(exec_cuda, &ncsEE[0], 1)] = pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
                        if (mollify) {
                            auto no = atomic_add(exec_cuda, &nPPM[0], 1);
                            PPM[no] = pair4_t{eiInds[1], eiInds[0], ejInds[0], ejInds[1]};
                            break;
                        }
                        {
                            auto no = atomic_add(exec_cuda, &nPP[0], 1);
                            PP[no] = pair_t{eiInds[1], ejInds[0]};
                        }
                    }
                    break;
                }
                case 4: {
                    if (auto d2 = dist2_pp(v1, v3); d2 < dHat2) {
                        csEE[atomic_add(exec_cuda, &ncsEE[0], 1)] = pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
                        if (mollify) {
                            auto no = atomic_add(exec_cuda, &nPPM[0], 1);
                            PPM[no] = pair4_t{eiInds[1], eiInds[0], ejInds[1], ejInds[0]};
                            break;
                        }
                        {
                            auto no = atomic_add(exec_cuda, &nPP[0], 1);
                            PP[no] = pair_t{eiInds[1], ejInds[1]};
                        }
                    }
                    break;
                }
                case 5: {
                    if (auto d2 = dist2_pe(v1, v2, v3); d2 < dHat2) {
                        csEE[atomic_add(exec_cuda, &ncsEE[0], 1)] = pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
                        if (mollify) {
                            auto no = atomic_add(exec_cuda, &nPEM[0], 1);
                            PEM[no] = pair4_t{eiInds[1], eiInds[0], ejInds[0], ejInds[1]};
                            break;
                        }
                        {
                            auto no = atomic_add(exec_cuda, &nPE[0], 1);
                            PE[no] = pair3_t{eiInds[1], ejInds[0], ejInds[1]};
                        }
                    }
                    break;
                }
                case 6: {
                    if (auto d2 = dist2_pe(v2, v0, v1); d2 < dHat2) {
                        csEE[atomic_add(exec_cuda, &ncsEE[0], 1)] = pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
                        if (mollify) {
                            auto no = atomic_add(exec_cuda, &nPEM[0], 1);
                            PEM[no] = pair4_t{ejInds[0], ejInds[1], eiInds[0], eiInds[1]};
                            break;
                        }
                        {
                            auto no = atomic_add(exec_cuda, &nPE[0], 1);
                            PE[no] = pair3_t{ejInds[0], eiInds[0], eiInds[1]};
                        }
                    }
                    break;
                }
                case 7: {
                    if (auto d2 = dist2_pe(v3, v0, v1); d2 < dHat2) {
                        csEE[atomic_add(exec_cuda, &ncsEE[0], 1)] = pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
                        if (mollify) {
                            auto no = atomic_add(exec_cuda, &nPEM[0], 1);
                            PEM[no] = pair4_t{ejInds[1], ejInds[0], eiInds[0], eiInds[1]};
                            break;
                        }
                        {
                            auto no = atomic_add(exec_cuda, &nPE[0], 1);
                            PE[no] = pair3_t{ejInds[1], eiInds[0], eiInds[1]};
                        }
                    }
                    break;
                }
                case 8: {
                    if (auto d2 = dist2_ee(v0, v1, v2, v3); d2 < dHat2) {
                        csEE[atomic_add(exec_cuda, &ncsEE[0], 1)] = pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
                        if (mollify) {
                            auto no = atomic_add(exec_cuda, &nEEM[0], 1);
                            EEM[no] = pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
                            break;
                        }
                        {
                            auto no = atomic_add(exec_cuda, &nEE[0], 1);
                            EE[no] = pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
                        }
                    }
                    break;
                }
                default: break;
                }
            });
        });
}
void IPCSystem::findCCDConstraints(zs::CudaExecutionPolicy &pol, T alpha, T xi) {
    ncsPT.setVal(0);
    ncsEE.setVal(0);
    {
        auto triBvs = retrieve_bounding_volumes(pol, vtemp, "xn", stInds, zs::wrapv<3>{}, vtemp, "dir", alpha, 0);
        stBvh.refit(pol, triBvs);
        auto edgeBvs = retrieve_bounding_volumes(pol, vtemp, "xn", seInds, zs::wrapv<2>{}, vtemp, "dir", alpha, 0);
        seBvh.refit(pol, edgeBvs);
    }
    findCCDConstraintsImpl(pol, alpha, xi, false);

    if (coVerts)
        if (coVerts->size()) {
            auto triBvs =
                retrieve_bounding_volumes(pol, vtemp, "xn", *coEles, zs::wrapv<3>{}, vtemp, "dir", alpha, coOffset);
            bouStBvh.refit(pol, triBvs);
            auto edgeBvs =
                retrieve_bounding_volumes(pol, vtemp, "xn", *coEdges, zs::wrapv<2>{}, vtemp, "dir", alpha, coOffset);
            bouSeBvh.refit(pol, edgeBvs);
            findCCDConstraintsImpl(pol, alpha, xi, true);
        }
}
void IPCSystem::findCCDConstraintsImpl(zs::CudaExecutionPolicy &pol, T alpha, T xi, bool withBoundary) {
    using namespace zs;
    constexpr auto space = execspace_e::cuda;
    const auto dHat2 = dHat * dHat;

    /// pt
    pol(Collapse{svInds.size()},
        [svInds = proxy<space>({}, svInds), eles = proxy<space>({}, withBoundary ? *coEles : stInds),
         vtemp = proxy<space>({}, vtemp), bvh = proxy<space>(withBoundary ? bouStBvh : stBvh), PP = proxy<space>(PP),
         nPP = proxy<space>(nPP), PE = proxy<space>(PE), nPE = proxy<space>(nPE), PT = proxy<space>(PT),
         nPT = proxy<space>(nPT), csPT = proxy<space>(csPT), ncsPT = proxy<space>(ncsPT), xi, alpha,
         voffset = withBoundary ? coOffset : 0] __device__(int vi) mutable {
            vi = reinterpret_bits<int>(svInds("inds", vi));
            auto p = vtemp.template pack<3>("xn", vi);
            auto dir = vtemp.template pack<3>("dir", vi);
            auto bv = bv_t{get_bounding_box(p, p + alpha * dir)};
            bv._min -= xi;
            bv._max += xi;
            bvh.iter_neighbors(bv, [&](int stI) {
                auto tri = eles.template pack<3>("inds", stI).template reinterpret_bits<int>() + voffset;
                if (vi == tri[0] || vi == tri[1] || vi == tri[2])
                    return;
                // all affected by sticky boundary conditions
                if (vtemp("BCorder", vi) == 3 && vtemp("BCorder", tri[0]) == 3 && vtemp("BCorder", tri[1]) == 3 &&
                    vtemp("BCorder", tri[2]) == 3)
                    return;
                csPT[atomic_add(exec_cuda, &ncsPT[0], 1)] = pair4_t{vi, tri[0], tri[1], tri[2]};
            });
        });
    /// ee
    pol(Collapse{seInds.size()},
        [seInds = proxy<space>({}, seInds), sedges = proxy<space>({}, withBoundary ? *coEdges : seInds),
         vtemp = proxy<space>({}, vtemp), bvh = proxy<space>(withBoundary ? bouSeBvh : seBvh), PP = proxy<space>(PP),
         nPP = proxy<space>(nPP), PE = proxy<space>(PE), nPE = proxy<space>(nPE), EE = proxy<space>(PT),
         nEE = proxy<space>(nPT), csEE = proxy<space>(csEE), ncsEE = proxy<space>(ncsEE), xi, alpha,
         voffset = withBoundary ? coOffset : 0] __device__(int sei) mutable {
            auto eiInds = seInds.template pack<2>("inds", sei).template reinterpret_bits<int>();
            bool selfFixed = vtemp("BCorder", eiInds[0]) == 3 && vtemp("BCorder", eiInds[1]) == 3;
            auto v0 = vtemp.template pack<3>("xn", eiInds[0]);
            auto v1 = vtemp.template pack<3>("xn", eiInds[1]);
            auto dir0 = vtemp.template pack<3>("dir", eiInds[0]);
            auto dir1 = vtemp.template pack<3>("dir", eiInds[1]);
            auto bv = bv_t{get_bounding_box(v0, v0 + alpha * dir0)};
            merge(bv, v1);
            merge(bv, v1 + alpha * dir1);
            bv._min -= xi;
            bv._max += xi;
            bvh.iter_neighbors(bv, [&](int sej) {
                if (voffset == 0 && sei < sej)
                    return;
                auto ejInds = sedges.template pack<2>("inds", sej).template reinterpret_bits<int>() + voffset;
                if (eiInds[0] == ejInds[0] || eiInds[0] == ejInds[1] || eiInds[1] == ejInds[0] ||
                    eiInds[1] == ejInds[1])
                    return;
                // all affected by sticky boundary conditions
                if (selfFixed && vtemp("BCorder", ejInds[0]) == 3 && vtemp("BCorder", ejInds[1]) == 3)
                    return;
                csEE[atomic_add(exec_cuda, &ncsEE[0], 1)] = pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
            });
        });
}
void IPCSystem::precomputeFrictions(zs::CudaExecutionPolicy &pol, T dHat, T xi) {
    using namespace zs;
    constexpr auto space = execspace_e::cuda;
    T activeGap2 = dHat * dHat + (T)2.0 * xi * dHat;
    nFPP.setVal(0);
    nFPE.setVal(0);
    nFPT.setVal(0);
    nFEE.setVal(0);
    if (enableContact) {
        if (s_enableSelfFriction) {
            nFPP = nPP;
            nFPE = nPE;
            nFPT = nPT;
            nFEE = nEE;

            auto numFPP = nFPP.getVal();
            pol(range(numFPP),
                [vtemp = proxy<space>({}, vtemp), fricPP = proxy<space>({}, fricPP), PP = proxy<space>(PP),
                 FPP = proxy<space>(FPP), xi2 = xi * xi, activeGap2, kappa = kappa] __device__(int fppi) mutable {
                    auto fpp = PP[fppi];
                    FPP[fppi] = fpp;
                    auto x0 = vtemp.pack<3>("xn", fpp[0]);
                    auto x1 = vtemp.pack<3>("xn", fpp[1]);
                    auto dist2 = dist2_pp(x0, x1);
                    auto bGrad = barrier_gradient(dist2 - xi2, activeGap2, kappa);
                    fricPP("fn", fppi) = -bGrad * 2 * zs::sqrt(dist2);
                    fricPP.tuple<6>("basis", fppi) = point_point_tangent_basis(x0, x1);
                });
            auto numFPE = nFPE.getVal();
            pol(range(numFPE),
                [vtemp = proxy<space>({}, vtemp), fricPE = proxy<space>({}, fricPE), PE = proxy<space>(PE),
                 FPE = proxy<space>(FPE), xi2 = xi * xi, activeGap2, kappa = kappa] __device__(int fpei) mutable {
                    auto fpe = PE[fpei];
                    FPE[fpei] = fpe;
                    auto p = vtemp.pack<3>("xn", fpe[0]);
                    auto e0 = vtemp.pack<3>("xn", fpe[1]);
                    auto e1 = vtemp.pack<3>("xn", fpe[2]);
                    auto dist2 = dist2_pe(p, e0, e1);
                    auto bGrad = barrier_gradient(dist2 - xi2, activeGap2, kappa);
                    fricPE("fn", fpei) = -bGrad * 2 * zs::sqrt(dist2);
                    fricPE("yita", fpei) = point_edge_closest_point(p, e0, e1);
                    fricPE.tuple<6>("basis", fpei) = point_edge_tangent_basis(p, e0, e1);
                });
            auto numFPT = nFPT.getVal();
            pol(range(numFPT),
                [vtemp = proxy<space>({}, vtemp), fricPT = proxy<space>({}, fricPT), PT = proxy<space>(PT),
                 FPT = proxy<space>(FPT), xi2 = xi * xi, activeGap2, kappa = kappa] __device__(int fpti) mutable {
                    auto fpt = PT[fpti];
                    FPT[fpti] = fpt;
                    auto p = vtemp.pack<3>("xn", fpt[0]);
                    auto t0 = vtemp.pack<3>("xn", fpt[1]);
                    auto t1 = vtemp.pack<3>("xn", fpt[2]);
                    auto t2 = vtemp.pack<3>("xn", fpt[3]);
                    auto dist2 = dist2_pt(p, t0, t1, t2);
                    auto bGrad = barrier_gradient(dist2 - xi2, activeGap2, kappa);
                    fricPT("fn", fpti) = -bGrad * 2 * zs::sqrt(dist2);
                    fricPT.tuple<2>("beta", fpti) = point_triangle_closest_point(p, t0, t1, t2);
                    fricPT.tuple<6>("basis", fpti) = point_triangle_tangent_basis(p, t0, t1, t2);
                });
            auto numFEE = nFEE.getVal();
            pol(range(numFEE),
                [vtemp = proxy<space>({}, vtemp), fricEE = proxy<space>({}, fricEE), EE = proxy<space>(EE),
                 FEE = proxy<space>(FEE), xi2 = xi * xi, activeGap2, kappa = kappa] __device__(int feei) mutable {
                    auto fee = EE[feei];
                    FEE[feei] = fee;
                    auto ea0 = vtemp.pack<3>("xn", fee[0]);
                    auto ea1 = vtemp.pack<3>("xn", fee[1]);
                    auto eb0 = vtemp.pack<3>("xn", fee[2]);
                    auto eb1 = vtemp.pack<3>("xn", fee[3]);
                    auto dist2 = dist2_ee(ea0, ea1, eb0, eb1);
                    auto bGrad = barrier_gradient(dist2 - xi2, activeGap2, kappa);
                    fricEE("fn", feei) = -bGrad * 2 * zs::sqrt(dist2);
                    fricEE.tuple<2>("gamma", feei) = edge_edge_closest_point(ea0, ea1, eb0, eb1);
                    fricEE.tuple<6>("basis", feei) = edge_edge_tangent_basis(ea0, ea1, eb0, eb1);
                });
        }
    }
    if (enableGround) {
        for (auto &primHandle : prims) {
            if (primHandle.isBoundary()) // skip soft boundary
                continue;
            const auto &svs = primHandle.getSurfVerts();
            pol(range(svs.size()),
                [vtemp = proxy<space>({}, vtemp), svs = proxy<space>({}, svs),
                 svtemp = proxy<space>({}, primHandle.svtemp), kappa = kappa, xi2 = xi * xi, activeGap2,
                 gn = s_groundNormal, svOffset = primHandle.svOffset] ZS_LAMBDA(int svi) mutable {
                    const auto vi = reinterpret_bits<int>(svs("inds", svi)) + svOffset;
                    auto x = vtemp.pack<3>("xn", vi);
                    auto dist = gn.dot(x);
                    auto dist2 = dist * dist;
                    if (dist2 < activeGap2) {
                        auto bGrad = barrier_gradient(dist2 - xi2, activeGap2, kappa);
                        svtemp("fn", svi) = -bGrad * 2 * dist;
                    } else
                        svtemp("fn", svi) = 0;
                });
        }
    }
}

void IPCSystem::project(zs::CudaExecutionPolicy &pol, const zs::SmallString tag) {
    using namespace zs;
    constexpr execspace_e space = execspace_e::cuda;
    // projection
    pol(zs::range(numDofs), [vtemp = proxy<space>({}, vtemp), projectDBC = projectDBC, tag] ZS_LAMBDA(int vi) mutable {
        int BCfixed = vtemp("BCfixed", vi);
        if (projectDBC || (!projectDBC && BCfixed)) {
            int BCorder = vtemp("BCorder", vi);
            for (int d = 0; d != BCorder; ++d)
                vtemp(tag, d, vi) = 0;
        }
    });
}
void IPCSystem::precondition(zs::CudaExecutionPolicy &pol, const zs::SmallString srcTag, const zs::SmallString dstTag) {
    using namespace zs;
    constexpr execspace_e space = execspace_e::cuda;
    // precondition
    pol(zs::range(numDofs), [vtemp = proxy<space>({}, vtemp), srcTag, dstTag] ZS_LAMBDA(int vi) mutable {
        vtemp.template tuple<3>(dstTag, vi) = vtemp.template pack<3, 3>("P", vi) * vtemp.template pack<3>(srcTag, vi);
    });
}

void IPCSystem::multiply(zs::CudaExecutionPolicy &pol, const zs::SmallString dxTag, const zs::SmallString bTag) {
    using namespace zs;
    constexpr execspace_e space = execspace_e::cuda;
    constexpr auto execTag = wrapv<space>{};
    // dx -> b
    pol(range(numDofs), [execTag, vtemp = proxy<space>({}, vtemp), bTag] ZS_LAMBDA(int vi) mutable {
        vtemp.template tuple<3>(bTag, vi) = vec3::zeros();
    });
    // inertial
    pol(zs::range(coOffset), [execTag, tempI = proxy<space>({}, tempI), vtemp = proxy<space>({}, vtemp), dxTag,
                              bTag] __device__(int i) mutable {
        auto Hi = tempI.template pack<3, 3>("Hi", i);
        auto dx = vtemp.template pack<3>(dxTag, i);
        dx = Hi * dx;
        for (int d = 0; d != 3; ++d)
            atomic_add(execTag, &vtemp(bTag, d, i), dx(d));
    });

    // elasticity
    for (auto &primHandle : prims) {
        auto &verts = primHandle.getVerts();
        auto &eles = primHandle.getEles();
        // elasticity
        if (primHandle.category == ZenoParticles::curve) {
            if (primHandle.isBoundary())
                continue;
            pol(Collapse{eles.size(), 32}, [execTag, etemp = proxy<space>({}, primHandle.etemp),
                                            vtemp = proxy<space>({}, vtemp), eles = proxy<space>({}, eles), dxTag, bTag,
                                            vOffset = primHandle.vOffset] ZS_LAMBDA(int ei, int tid) mutable {
                int rowid = tid / 5;
                int colid = tid % 5;
                auto inds = eles.template pack<2>("inds", ei).template reinterpret_bits<int>() + vOffset;
                T entryH = 0, entryDx = 0, entryG = 0;
                if (tid < 30) {
                    entryH = etemp("He", rowid * 6 + colid, ei);
                    entryDx = vtemp(dxTag, colid % 3, inds[colid / 3]);
                    entryG = entryH * entryDx;
                    if (colid == 0) {
                        entryG += etemp("He", rowid * 6 + 5, ei) * vtemp(dxTag, 2, inds[1]);
                    }
                }
                for (int iter = 1; iter <= 4; iter <<= 1) {
                    T tmp = __shfl_down_sync(0xFFFFFFFF, entryG, iter);
                    if (colid + iter < 5 && tid < 30)
                        entryG += tmp;
                }
                if (colid == 0 && rowid < 6)
                    atomic_add(execTag, &vtemp(bTag, rowid % 3, inds[rowid / 3]), entryG);
            });
        } else if (primHandle.category == ZenoParticles::surface) {
            if (primHandle.isBoundary())
                continue;
#if 1
            pol(range(eles.size()),
                [execTag, etemp = proxy<space>({}, primHandle.etemp), vtemp = proxy<space>({}, vtemp),
                 eles = proxy<space>({}, eles), dxTag, bTag, vOffset = primHandle.vOffset] ZS_LAMBDA(int ei) mutable {
                    constexpr int dim = 3;
                    auto inds = eles.template pack<3>("inds", ei).template reinterpret_bits<int>() + vOffset;
                    zs::vec<T, 3 * dim> temp{};
                    for (int vi = 0; vi != 3; ++vi)
                        for (int d = 0; d != dim; ++d) {
                            temp[vi * dim + d] = vtemp(dxTag, d, inds[vi]);
                        }
                    auto He = etemp.template pack<dim * 3, dim * 3>("He", ei);

                    temp = He * temp;

                    for (int vi = 0; vi != 3; ++vi)
                        for (int d = 0; d != dim; ++d) {
                            atomic_add(execTag, &vtemp(bTag, d, inds[vi]), temp[vi * dim + d]);
                        }
                });
#else
            pol(range(eles.size() * 81),
                [execTag, etemp = proxy<space>({}, primHandle.etemp), vtemp = proxy<space>({}, vtemp),
                 eles = proxy<space>({}, eles), dxTag, bTag, vOffset = primHandle.vOffset,
                 n = eles.size() * 81] ZS_LAMBDA(int idx) mutable {
                    constexpr int dim = 3;
                    __shared__ int offset;
                    // directly use PCG_Solve_AX9_b2 from kemeng huang
                    int ei = idx / 81;
                    int entryId = idx % 81;
                    int MRid = entryId / 9;
                    int MCid = entryId % 9;
                    int vId = MCid / dim;
                    int axisId = MCid % dim;
                    int GRtid = idx % 9;

                    auto inds = eles.template pack<3>("inds", ei).template reinterpret_bits<int>() + vOffset;
                    T rdata = etemp("He", entryId, ei) * vtemp(dxTag, axisId, inds[vId]);

                    if (threadIdx.x == 0)
                        offset = 9 - GRtid;
                    __syncthreads();

                    int BRid = (threadIdx.x - offset + 9) / 9;
                    int landidx = (threadIdx.x - offset) % 9;
                    if (BRid == 0) {
                        landidx = threadIdx.x;
                    }

                    auto [mask, numValid] = warp_mask(idx, n);
                    int laneId = threadIdx.x & 0x1f;
                    bool bBoundary = (landidx == 0) || (laneId == 0);

                    unsigned int mark = __ballot_sync(mask, bBoundary); // a bit-mask
                    mark = __brev(mark);
                    unsigned int interval = zs::math::min(__clz(mark << (laneId + 1)), 31 - laneId);

                    for (int iter = 1; iter < 9; iter <<= 1) {
                        T tmp = __shfl_down_sync(mask, rdata, iter);
                        if (interval >= iter && laneId + iter < numValid)
                            rdata += tmp;
                    }

                    if (bBoundary)
                        atomic_add(exec_cuda, &vtemp(bTag, MRid % 3, inds[MRid / 3]), rdata);
                });
#endif
        } else if (primHandle.category == ZenoParticles::tet)
#if 1
            pol(range(eles.size()),
                [execTag, etemp = proxy<space>({}, primHandle.etemp), vtemp = proxy<space>({}, vtemp),
                 eles = proxy<space>({}, eles), dxTag, bTag, vOffset = primHandle.vOffset] ZS_LAMBDA(int ei) mutable {
                    constexpr int dim = 3;
                    auto inds = eles.template pack<4>("inds", ei).template reinterpret_bits<int>() + vOffset;
                    zs::vec<T, 4 * dim> temp{};
                    for (int vi = 0; vi != 4; ++vi)
                        for (int d = 0; d != dim; ++d) {
                            temp[vi * dim + d] = vtemp(dxTag, d, inds[vi]);
                        }
                    auto He = etemp.template pack<dim * 4, dim * 4>("He", ei);

                    temp = He * temp;

                    for (int vi = 0; vi != 4; ++vi)
                        for (int d = 0; d != dim; ++d) {
                            atomic_add(execTag, &vtemp(bTag, d, inds[vi]), temp[vi * dim + d]);
                        }
                });
#else
            pol(range(eles.size() * 144),
                [execTag, etemp = proxy<space>({}, primHandle.etemp), vtemp = proxy<space>({}, vtemp),
                 eles = proxy<space>({}, eles), dxTag, bTag, vOffset = primHandle.vOffset,
                 n = eles.size() * 144] ZS_LAMBDA(int idx) mutable {
                    constexpr int dim = 3;
                    __shared__ int offset;
                    // directly use PCG_Solve_AX9_b2 from kemeng huang
                    int Hid = idx / 144;
                    int entryId = idx % 144;
                    int MRid = entryId / 12;
                    int MCid = entryId % 12;
                    int vId = MCid / dim;
                    int axisId = MCid % dim;
                    int GRtid = idx % 12;

                    auto inds = eles.template pack<4>("inds", Hid).template reinterpret_bits<int>() + vOffset;
                    T rdata = etemp("He", entryId, Hid) * vtemp(dxTag, axisId, inds[vId]);

                    if (threadIdx.x == 0)
                        offset = 12 - GRtid;
                    __syncthreads();

                    int BRid = (threadIdx.x - offset + 12) / 12;
                    int landidx = (threadIdx.x - offset) % 12;
                    if (BRid == 0) {
                        landidx = threadIdx.x;
                    }

                    auto [mask, numValid] = warp_mask(idx, n);
                    int laneId = threadIdx.x & 0x1f;
                    bool bBoundary = (landidx == 0) || (laneId == 0);

                    unsigned int mark = __ballot_sync(mask, bBoundary); // a bit-mask
                    mark = __brev(mark);
                    unsigned int interval = zs::math::min(__clz(mark << (laneId + 1)), 31 - laneId);

                    for (int iter = 1; iter < 12; iter <<= 1) {
                        T tmp = __shfl_down_sync(mask, rdata, iter);
                        if (interval >= iter && laneId + iter < numValid)
                            rdata += tmp;
                    }

                    if (bBoundary)
                        atomic_add(exec_cuda, &vtemp(bTag, MRid % 3, inds[MRid / 3]), rdata);
                });
#endif
    }

    // contacts
    if (enableContact) {
        auto numPP = nPP.getVal();
#if 0
          pol(range(numPP), [execTag, tempPP = proxy<space>({}, tempPP),
                             vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                             PP = proxy<space>(PP)] ZS_LAMBDA(int ppi) mutable {
            constexpr int dim = 3;
            auto pp = PP[ppi];
            zs::vec<T, dim * 2> temp{};
            for (int vi = 0; vi != 2; ++vi)
              for (int d = 0; d != dim; ++d) {
                temp[vi * dim + d] = vtemp(dxTag, d, pp[vi]);
              }
            auto ppHess = tempPP.template pack<6, 6>("H", ppi);

            auto dx = temp;
            temp = ppHess * temp;

            for (int vi = 0; vi != 2; ++vi)
              for (int d = 0; d != dim; ++d) {
                atomic_add(execTag, &vtemp(bTag, d, pp[vi]),
                           temp[vi * dim + d]);
              }
          });
#elif 1
        pol(Collapse{numPP, 32}, [execTag, tempPP = proxy<space>({}, tempPP), vtemp = proxy<space>({}, vtemp), dxTag,
                                  bTag, PP = proxy<space>(PP)] ZS_LAMBDA(int ppi, int tid) mutable {
            int rowid = tid / 5;
            int colid = tid % 5;
            ;
            auto pp = PP[ppi];
            T entryH = 0, entryDx = 0, entryG = 0;
            if (tid < 30) {
                entryH = tempPP("H", rowid * 6 + colid, ppi);
                entryDx = vtemp(dxTag, colid % 3, pp[colid / 3]);
                entryG = entryH * entryDx;
                if (colid == 0) {
                    entryG += tempPP("H", rowid * 6 + 5, ppi) * vtemp(dxTag, 2, pp[1]);
                }
            }
            for (int iter = 1; iter <= 4; iter <<= 1) {
                T tmp = __shfl_down_sync(0xFFFFFFFF, entryG, iter);
                if (colid + iter < 5 && tid < 30)
                    entryG += tmp;
            }
            if (colid == 0 && rowid < 6)
                atomic_add(execTag, &vtemp(bTag, rowid % 3, pp[rowid / 3]), entryG);
        });
#else
        pol(range(numPP * 36), [execTag, tempPP = proxy<space>({}, tempPP), vtemp = proxy<space>({}, vtemp), dxTag,
                                bTag, PP = proxy<space>(PP), n = numPP * 36] ZS_LAMBDA(int idx) mutable {
            constexpr int dim = 3;
            __shared__ int offset;
            // directly use PCG_Solve_AX9_b2 from kemeng huang
            int Hid = idx / 36;
            int entryId = idx % 36;
            int MRid = entryId / 6;
            int MCid = entryId % 6;
            int vId = MCid / dim;
            int axisId = MCid % dim;
            int GRtid = idx % 6;

            auto inds = PP[Hid];
            T rdata = tempPP("H", entryId, Hid) * vtemp(dxTag, axisId, inds[vId]);

            if (threadIdx.x == 0)
                offset = 6 - GRtid;
            __syncthreads();

            int BRid = (threadIdx.x - offset + 6) / 6;
            int landidx = (threadIdx.x - offset) % 6;
            if (BRid == 0) {
                landidx = threadIdx.x;
            }

            auto [mask, numValid] = warp_mask(idx, n);
            int laneId = threadIdx.x & 0x1f;
            bool bBoundary = (landidx == 0) || (laneId == 0);

            unsigned int mark = __ballot_sync(mask, bBoundary); // a bit-mask
            mark = __brev(mark);
            unsigned int interval = zs::math::min(__clz(mark << (laneId + 1)), 31 - laneId);

            for (int iter = 1; iter < 6; iter <<= 1) {
                T tmp = __shfl_down_sync(mask, rdata, iter);
                if (interval >= iter && laneId + iter < numValid)
                    rdata += tmp;
            }

            if (bBoundary)
                atomic_add(exec_cuda, &vtemp(bTag, MRid % 3, inds[MRid / 3]), rdata);
        });
#endif
        auto numPE = nPE.getVal();
#if 0
          pol(range(numPE), [execTag, tempPE = proxy<space>({}, tempPE),
                             vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                             PE = proxy<space>(PE)] ZS_LAMBDA(int pei) mutable {
            constexpr int dim = 3;
            auto pe = PE[pei];
            zs::vec<T, dim * 3> temp{};
            for (int vi = 0; vi != 3; ++vi)
              for (int d = 0; d != dim; ++d) {
                temp[vi * dim + d] = vtemp(dxTag, d, pe[vi]);
              }
            auto peHess = tempPE.template pack<9, 9>("H", pei);

            temp = peHess * temp;

            for (int vi = 0; vi != 3; ++vi)
              for (int d = 0; d != dim; ++d) {
                atomic_add(execTag, &vtemp(bTag, d, pe[vi]),
                           temp[vi * dim + d]);
              }
          });
#elif 1
        {
            auto numRows = numPE * 9;
            auto numWarps = (numRows + 3) / 4; // 8 threads per row
            pol(Collapse{numWarps * 32}, [execTag, tempPE = proxy<space>({}, tempPE), vtemp = proxy<space>({}, vtemp),
                                          dxTag, bTag, PE = proxy<space>(PE), numRows] ZS_LAMBDA(int tid) mutable {
                int growid = tid / 8;
                int rowid = growid % 9;
                int pei = growid / 9;
                int colid = tid % 8;
                ;
                auto pe = PE[pei];
                T entryG = 0;
                if (growid < numRows) {
                    entryG = tempPE("H", rowid * 9 + colid, pei) * vtemp(dxTag, colid % 3, pe[colid / 3]);
                    if (colid == 0) {
                        auto cid = colid + 8;
                        entryG += tempPE("H", rowid * 9 + cid, pei) * vtemp(dxTag, cid % 3, pe[cid / 3]);
                    }
                }
                for (int iter = 1; iter <= 4; iter <<= 1) {
                    T tmp = __shfl_down_sync(0xFFFFFFFF, entryG, iter);
                    if (colid + iter < 8 && growid < numRows)
                        entryG += tmp;
                }
                if (colid == 0 && growid < numRows)
                    atomic_add(execTag, &vtemp(bTag, rowid % 3, pe[rowid / 3]), entryG);
            });
        }
#else
        pol(range(numPE * 81), [execTag, tempPE = proxy<space>({}, tempPE), vtemp = proxy<space>({}, vtemp), dxTag,
                                bTag, PE = proxy<space>(PE), n = numPE * 81] ZS_LAMBDA(int idx) mutable {
            constexpr int dim = 3;
            __shared__ int offset;
            // directly use PCG_Solve_AX9_b2 from kemeng huang
            int Hid = idx / 81;
            int entryId = idx % 81;
            int MRid = entryId / 9;
            int MCid = entryId % 9;
            int vId = MCid / dim;
            int axisId = MCid % dim;
            int GRtid = idx % 9;

            auto inds = PE[Hid];
            T rdata = tempPE("H", entryId, Hid) * vtemp(dxTag, axisId, inds[vId]);

            if (threadIdx.x == 0)
                offset = 9 - GRtid;
            __syncthreads();

            int BRid = (threadIdx.x - offset + 9) / 9;
            int landidx = (threadIdx.x - offset) % 9;
            if (BRid == 0) {
                landidx = threadIdx.x;
            }

            auto [mask, numValid] = warp_mask(idx, n);
            int laneId = threadIdx.x & 0x1f;
            bool bBoundary = (landidx == 0) || (laneId == 0);

            unsigned int mark = __ballot_sync(mask, bBoundary); // a bit-mask
            mark = __brev(mark);
            unsigned int interval = zs::math::min(__clz(mark << (laneId + 1)), 31 - laneId);

            for (int iter = 1; iter < 9; iter <<= 1) {
                T tmp = __shfl_down_sync(mask, rdata, iter);
                if (interval >= iter && laneId + iter < numValid)
                    rdata += tmp;
            }

            if (bBoundary)
                atomic_add(exec_cuda, &vtemp(bTag, MRid % 3, inds[MRid / 3]), rdata);
        });
#endif
        auto numPT = nPT.getVal();
#if 0
          pol(range(numPT), [execTag, tempPT = proxy<space>({}, tempPT),
                             vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                             PT = proxy<space>(PT)] ZS_LAMBDA(int pti) mutable {
            constexpr int dim = 3;
            auto pt = PT[pti];
            zs::vec<T, dim * 4> temp{};
            for (int vi = 0; vi != 4; ++vi)
              for (int d = 0; d != dim; ++d) {
                temp[vi * dim + d] = vtemp(dxTag, d, pt[vi]);
              }
            auto ptHess = tempPT.template pack<12, 12>("H", pti);

            temp = ptHess * temp;

            for (int vi = 0; vi != 4; ++vi)
              for (int d = 0; d != dim; ++d) {
                atomic_add(execTag, &vtemp(bTag, d, pt[vi]),
                           temp[vi * dim + d]);
              }
          });
#elif 1
        // 0, 1, ..., 7, 0, 1, 2, 3
        pol(Collapse{numPT, 32 * 3}, [execTag, tempPT = proxy<space>({}, tempPT), vtemp = proxy<space>({}, vtemp),
                                      dxTag, bTag, PT = proxy<space>(PT)] ZS_LAMBDA(int pti, int tid) mutable {
            int rowid = tid / 8;
            int colid = tid % 8;
            ;
            auto pt = PT[pti];
            T entryH = 0, entryDx = 0, entryG = 0;
            {
                entryH = tempPT("H", rowid * 12 + colid, pti);
                entryDx = vtemp(dxTag, colid % 3, pt[colid / 3]);
                entryG = entryH * entryDx;
                if (colid < 4) {
                    auto cid = colid + 8;
                    entryG += tempPT("H", rowid * 12 + cid, pti) * vtemp(dxTag, cid % 3, pt[cid / 3]);
                }
            }
            for (int iter = 1; iter <= 4; iter <<= 1) {
                T tmp = __shfl_down_sync(0xFFFFFFFF, entryG, iter);
                if (colid + iter < 8)
                    entryG += tmp;
            }
            if (colid == 0)
                atomic_add(execTag, &vtemp(bTag, rowid % 3, pt[rowid / 3]), entryG);
        });
#else
        pol(range(numPT * 144), [execTag, tempPT = proxy<space>({}, tempPT), vtemp = proxy<space>({}, vtemp), dxTag,
                                 bTag, PT = proxy<space>(PT), n = numPT * 144] ZS_LAMBDA(int idx) mutable {
            constexpr int dim = 3;
            __shared__ int offset;
            // directly use PCG_Solve_AX9_b2 from kemeng huang
            int Hid = idx / 144;
            int entryId = idx % 144;
            int MRid = entryId / 12;
            int MCid = entryId % 12;
            int vId = MCid / dim;
            int axisId = MCid % dim;
            int GRtid = idx % 12;

            auto inds = PT[Hid];
            T rdata = tempPT("H", entryId, Hid) * vtemp(dxTag, axisId, inds[vId]);

            if (threadIdx.x == 0)
                offset = 12 - GRtid;
            __syncthreads();

            int BRid = (threadIdx.x - offset + 12) / 12;
            int landidx = (threadIdx.x - offset) % 12;
            if (BRid == 0) {
                landidx = threadIdx.x;
            }

            auto [mask, numValid] = warp_mask(idx, n);
            int laneId = threadIdx.x & 0x1f;
            bool bBoundary = (landidx == 0) || (laneId == 0);

            unsigned int mark = __ballot_sync(mask, bBoundary); // a bit-mask
            mark = __brev(mark);
            unsigned int interval = zs::math::min(__clz(mark << (laneId + 1)), 31 - laneId);

            for (int iter = 1; iter < 12; iter <<= 1) {
                T tmp = __shfl_down_sync(mask, rdata, iter);
                if (interval >= iter && laneId + iter < numValid)
                    rdata += tmp;
            }

            if (bBoundary)
                atomic_add(exec_cuda, &vtemp(bTag, MRid % 3, inds[MRid / 3]), rdata);
        });
#endif
        auto numEE = nEE.getVal();
#if 0
          pol(range(numEE), [execTag, tempEE = proxy<space>({}, tempEE),
                             vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                             EE = proxy<space>(EE)] ZS_LAMBDA(int eei) mutable {
            constexpr int dim = 3;
            auto ee = EE[eei];
            zs::vec<T, dim * 4> temp{};
            for (int vi = 0; vi != 4; ++vi)
              for (int d = 0; d != dim; ++d) {
                temp[vi * dim + d] = vtemp(dxTag, d, ee[vi]);
              }
            auto eeHess = tempEE.template pack<12, 12>("H", eei);

            temp = eeHess * temp;

            for (int vi = 0; vi != 4; ++vi)
              for (int d = 0; d != dim; ++d) {
                atomic_add(execTag, &vtemp(bTag, d, ee[vi]),
                           temp[vi * dim + d]);
              }
          });
#elif 1
        // 0, 1, ..., 7, 0, 1, 2, 3
        pol(Collapse{numEE, 32 * 3}, [execTag, tempEE = proxy<space>({}, tempEE), vtemp = proxy<space>({}, vtemp),
                                      dxTag, bTag, EE = proxy<space>(EE)] ZS_LAMBDA(int eei, int tid) mutable {
            int rowid = tid / 8;
            int colid = tid % 8;
            ;
            auto ee = EE[eei];
            T entryH = 0, entryDx = 0, entryG = 0;
            {
                entryH = tempEE("H", rowid * 12 + colid, eei);
                entryDx = vtemp(dxTag, colid % 3, ee[colid / 3]);
                entryG = entryH * entryDx;
                if (colid < 4) {
                    auto cid = colid + 8;
                    entryG += tempEE("H", rowid * 12 + cid, eei) * vtemp(dxTag, cid % 3, ee[cid / 3]);
                }
            }
            for (int iter = 1; iter <= 4; iter <<= 1) {
                T tmp = __shfl_down_sync(0xFFFFFFFF, entryG, iter);
                if (colid + iter < 8)
                    entryG += tmp;
            }
            if (colid == 0)
                atomic_add(execTag, &vtemp(bTag, rowid % 3, ee[rowid / 3]), entryG);
        });
#else
        pol(range(numEE * 144), [execTag, tempEE = proxy<space>({}, tempEE), vtemp = proxy<space>({}, vtemp), dxTag,
                                 bTag, EE = proxy<space>(EE), n = numEE * 144] ZS_LAMBDA(int idx) mutable {
            constexpr int dim = 3;
            __shared__ int offset;
            // directly use PCG_Solve_AX9_b2 from kemeng huang
            int Hid = idx / 144;
            int entryId = idx % 144;
            int MRid = entryId / 12;
            int MCid = entryId % 12;
            int vId = MCid / dim;
            int axisId = MCid % dim;
            int GRtid = idx % 12;

            auto inds = EE[Hid];
            T rdata = tempEE("H", entryId, Hid) * vtemp(dxTag, axisId, inds[vId]);

            if (threadIdx.x == 0)
                offset = 12 - GRtid;
            __syncthreads();

            int BRid = (threadIdx.x - offset + 12) / 12;
            int landidx = (threadIdx.x - offset) % 12;
            if (BRid == 0) {
                landidx = threadIdx.x;
            }

            auto [mask, numValid] = warp_mask(idx, n);
            int laneId = threadIdx.x & 0x1f;
            bool bBoundary = (landidx == 0) || (laneId == 0);

            unsigned int mark = __ballot_sync(mask, bBoundary); // a bit-mask
            mark = __brev(mark);
            unsigned int interval = zs::math::min(__clz(mark << (laneId + 1)), 31 - laneId);

            for (int iter = 1; iter < 12; iter <<= 1) {
                T tmp = __shfl_down_sync(mask, rdata, iter);
                if (interval >= iter && laneId + iter < numValid)
                    rdata += tmp;
            }

            if (bBoundary)
                atomic_add(exec_cuda, &vtemp(bTag, MRid % 3, inds[MRid / 3]), rdata);
        });
#endif
        if (enableMollification) {
            auto numEEM = nEEM.getVal();
            pol(Collapse{numEEM, 32 * 3},
                [execTag, tempEEM = proxy<space>({}, tempEEM), vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                 EEM = proxy<space>(EEM)] ZS_LAMBDA(int eemi, int tid) mutable {
                    int rowid = tid / 8;
                    int colid = tid % 8;

                    auto eem = EEM[eemi];
                    T entryH = 0, entryDx = 0, entryG = 0;
                    {
                        entryH = tempEEM("H", rowid * 12 + colid, eemi);
                        entryDx = vtemp(dxTag, colid % 3, eem[colid / 3]);
                        entryG = entryH * entryDx;
                        if (colid < 4) {
                            auto cid = colid + 8;
                            entryG += tempEEM("H", rowid * 12 + cid, eemi) * vtemp(dxTag, cid % 3, eem[cid / 3]);
                        }
                    }
                    for (int iter = 1; iter <= 4; iter <<= 1) {
                        T tmp = __shfl_down_sync(0xFFFFFFFF, entryG, iter);
                        if (colid + iter < 8)
                            entryG += tmp;
                    }
                    if (colid == 0)
                        atomic_add(execTag, &vtemp(bTag, rowid % 3, eem[rowid / 3]), entryG);
                });

            auto numPPM = nPPM.getVal();
            pol(Collapse{numPPM, 32 * 3},
                [execTag, tempPPM = proxy<space>({}, tempPPM), vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                 PPM = proxy<space>(PPM)] ZS_LAMBDA(int ppmi, int tid) mutable {
                    int rowid = tid / 8;
                    int colid = tid % 8;

                    auto ppm = PPM[ppmi];
                    T entryH = 0, entryDx = 0, entryG = 0;
                    {
                        entryH = tempPPM("H", rowid * 12 + colid, ppmi);
                        entryDx = vtemp(dxTag, colid % 3, ppm[colid / 3]);
                        entryG = entryH * entryDx;
                        if (colid < 4) {
                            auto cid = colid + 8;
                            entryG += tempPPM("H", rowid * 12 + cid, ppmi) * vtemp(dxTag, cid % 3, ppm[cid / 3]);
                        }
                    }
                    for (int iter = 1; iter <= 4; iter <<= 1) {
                        T tmp = __shfl_down_sync(0xFFFFFFFF, entryG, iter);
                        if (colid + iter < 8)
                            entryG += tmp;
                    }
                    if (colid == 0)
                        atomic_add(execTag, &vtemp(bTag, rowid % 3, ppm[rowid / 3]), entryG);
                });

            auto numPEM = nPEM.getVal();
            pol(Collapse{numPEM, 32 * 3},
                [execTag, tempPEM = proxy<space>({}, tempPEM), vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                 PEM = proxy<space>(PEM)] ZS_LAMBDA(int pemi, int tid) mutable {
                    int rowid = tid / 8;
                    int colid = tid % 8;

                    auto pem = PEM[pemi];
                    T entryH = 0, entryDx = 0, entryG = 0;
                    {
                        entryH = tempPEM("H", rowid * 12 + colid, pemi);
                        entryDx = vtemp(dxTag, colid % 3, pem[colid / 3]);
                        entryG = entryH * entryDx;
                        if (colid < 4) {
                            auto cid = colid + 8;
                            entryG += tempPEM("H", rowid * 12 + cid, pemi) * vtemp(dxTag, cid % 3, pem[cid / 3]);
                        }
                    }
                    for (int iter = 1; iter <= 4; iter <<= 1) {
                        T tmp = __shfl_down_sync(0xFFFFFFFF, entryG, iter);
                        if (colid + iter < 8)
                            entryG += tmp;
                    }
                    if (colid == 0)
                        atomic_add(execTag, &vtemp(bTag, rowid % 3, pem[rowid / 3]), entryG);
                });
        } // end mollification

        if (s_enableFriction) {
            if (fricMu != 0) {
                if (s_enableSelfFriction) {
                    auto numFPP = nFPP.getVal();
                    pol(Collapse{numFPP, 32},
                        [execTag, fricPP = proxy<space>({}, fricPP), vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                         FPP = proxy<space>(FPP)] ZS_LAMBDA(int fppi, int tid) mutable {
                            int rowid = tid / 5;
                            int colid = tid % 5;
                            ;
                            auto fpp = FPP[fppi];
                            T entryH = 0, entryDx = 0, entryG = 0;
                            if (tid < 30) {
                                entryH = fricPP("H", rowid * 6 + colid, fppi);
                                entryDx = vtemp(dxTag, colid % 3, fpp[colid / 3]);
                                entryG = entryH * entryDx;
                                if (colid == 0) {
                                    entryG += fricPP("H", rowid * 6 + 5, fppi) * vtemp(dxTag, 2, fpp[1]);
                                }
                            }
                            for (int iter = 1; iter <= 4; iter <<= 1) {
                                T tmp = __shfl_down_sync(0xFFFFFFFF, entryG, iter);
                                if (colid + iter < 5 && tid < 30)
                                    entryG += tmp;
                            }
                            if (colid == 0 && rowid < 6)
                                atomic_add(execTag, &vtemp(bTag, rowid % 3, fpp[rowid / 3]), entryG);
                        });

                    auto numFPE = nFPE.getVal();
                    pol(range(numFPE * 81),
                        [execTag, fricPE = proxy<space>({}, fricPE), vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                         FPE = proxy<space>(FPE), n = numFPE * 81] ZS_LAMBDA(int idx) mutable {
                            constexpr int dim = 3;
                            __shared__ int offset;
                            // directly use PCG_Solve_AX9_b2 from kemeng huang
                            int Hid = idx / 81;
                            int entryId = idx % 81;
                            int MRid = entryId / 9;
                            int MCid = entryId % 9;
                            int vId = MCid / dim;
                            int axisId = MCid % dim;
                            int GRtid = idx % 9;

                            auto inds = FPE[Hid];
                            T rdata = fricPE("H", entryId, Hid) * vtemp(dxTag, axisId, inds[vId]);

                            if (threadIdx.x == 0)
                                offset = 9 - GRtid;
                            __syncthreads();

                            int BRid = (threadIdx.x - offset + 9) / 9;
                            int landidx = (threadIdx.x - offset) % 9;
                            if (BRid == 0) {
                                landidx = threadIdx.x;
                            }

                            auto [mask, numValid] = warp_mask(idx, n);
                            int laneId = threadIdx.x & 0x1f;
                            bool bBoundary = (landidx == 0) || (laneId == 0);

                            unsigned int mark = __ballot_sync(mask, bBoundary); // a bit-mask
                            mark = __brev(mark);
                            unsigned int interval = zs::math::min(__clz(mark << (laneId + 1)), 31 - laneId);

                            for (int iter = 1; iter < 9; iter <<= 1) {
                                T tmp = __shfl_down_sync(mask, rdata, iter);
                                if (interval >= iter && laneId + iter < numValid)
                                    rdata += tmp;
                            }

                            if (bBoundary)
                                atomic_add(exec_cuda, &vtemp(bTag, MRid % 3, inds[MRid / 3]), rdata);
                        });

                    auto numFPT = nFPT.getVal();
                    pol(Collapse{numFPT, 32 * 3},
                        [execTag, fricPT = proxy<space>({}, fricPT), vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                         FPT = proxy<space>(FPT)] ZS_LAMBDA(int fpti, int tid) mutable {
                            int rowid = tid / 8;
                            int colid = tid % 8;
                            ;
                            auto fpt = FPT[fpti];
                            T entryH = 0, entryDx = 0, entryG = 0;
                            {
                                entryH = fricPT("H", rowid * 12 + colid, fpti);
                                entryDx = vtemp(dxTag, colid % 3, fpt[colid / 3]);
                                entryG = entryH * entryDx;
                                if (colid < 4) {
                                    auto cid = colid + 8;
                                    entryG += fricPT("H", rowid * 12 + cid, fpti) * vtemp(dxTag, cid % 3, fpt[cid / 3]);
                                }
                            }
                            for (int iter = 1; iter <= 4; iter <<= 1) {
                                T tmp = __shfl_down_sync(0xFFFFFFFF, entryG, iter);
                                if (colid + iter < 8)
                                    entryG += tmp;
                            }
                            if (colid == 0)
                                atomic_add(execTag, &vtemp(bTag, rowid % 3, fpt[rowid / 3]), entryG);
                        });

                    auto numFEE = nFEE.getVal();
                    pol(Collapse{numFEE, 32 * 3},
                        [execTag, fricEE = proxy<space>({}, fricEE), vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                         FEE = proxy<space>(FEE)] ZS_LAMBDA(int feei, int tid) mutable {
                            int rowid = tid / 8;
                            int colid = tid % 8;
                            ;
                            auto fee = FEE[feei];
                            T entryH = 0, entryDx = 0, entryG = 0;
                            {
                                entryH = fricEE("H", rowid * 12 + colid, feei);
                                entryDx = vtemp(dxTag, colid % 3, fee[colid / 3]);
                                entryG = entryH * entryDx;
                                if (colid < 4) {
                                    auto cid = colid + 8;
                                    entryG += fricEE("H", rowid * 12 + cid, feei) * vtemp(dxTag, cid % 3, fee[cid / 3]);
                                }
                            }
                            for (int iter = 1; iter <= 4; iter <<= 1) {
                                T tmp = __shfl_down_sync(0xFFFFFFFF, entryG, iter);
                                if (colid + iter < 8)
                                    entryG += tmp;
                            }
                            if (colid == 0)
                                atomic_add(execTag, &vtemp(bTag, rowid % 3, fee[rowid / 3]), entryG);
                        });
                } // self friction
            }     //fricmu
        }         //enable friction
    }             //enable contact

    // ground contact
    if (enableGround) {
        for (auto &primHandle : prims) {
            if (primHandle.isBoundary()) // skip soft boundary
                continue;
            const auto &svs = primHandle.getSurfVerts();
            pol(range(svs.size()),
                [execTag, vtemp = proxy<space>({}, vtemp), dxTag, bTag, svtemp = proxy<space>({}, primHandle.svtemp),
                 svs = proxy<space>({}, svs), svOffset = primHandle.svOffset] ZS_LAMBDA(int svi) mutable {
                    const auto vi = reinterpret_bits<int>(svs("inds", svi)) + svOffset;
                    auto dx = vtemp.template pack<3>(dxTag, vi);
                    auto pbHess = svtemp.template pack<3, 3>("H", svi);
                    dx = pbHess * dx;
                    for (int d = 0; d != 3; ++d)
                        atomic_add(execTag, &vtemp(bTag, d, vi), dx(d));
                });
        }
    }

    // constraint hessian
    if (!BCsatisfied) {
        pol(range(numDofs), [execTag, vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                             boundaryKappa = boundaryKappa] ZS_LAMBDA(int vi) mutable {
            auto cons = vtemp.template pack<3>("cons", vi);
            auto dx = vtemp.template pack<3>(dxTag, vi);
            auto w = vtemp("ws", vi);
            int BCfixed = vtemp("BCfixed", vi);
            if (!BCfixed) {
                int BCorder = vtemp("BCorder", vi);
                for (int d = 0; d != BCorder; ++d)
                    atomic_add(execTag, &vtemp(bTag, d, vi), boundaryKappa * w * dx(d));
            }
        });
    }
}

template <typename Model>
typename IPCSystem::T elasticityEnergy(zs::CudaExecutionPolicy &pol, typename IPCSystem::dtiles_t &vtemp,
                                       typename IPCSystem::PrimitiveHandle &primHandle, const Model &model,
                                       typename IPCSystem::T dt, zs::Vector<typename IPCSystem::T> &es) {
    using namespace zs;
    constexpr auto space = execspace_e::cuda;
    using mat3 = typename IPCSystem::mat3;
    using vec3 = typename IPCSystem::vec3;
    using T = typename IPCSystem::T;

    auto &eles = primHandle.getEles();
    es.resize(count_warps(eles.size()));
    es.reset(0);
    const zs::SmallString tag = "xn";
    if (primHandle.category == ZenoParticles::curve) {
        if (primHandle.isBoundary())
            return 0;
        // elasticity
        pol(range(eles.size()),
            [eles = proxy<space>({}, eles), vtemp = proxy<space>({}, vtemp), es = proxy<space>(es), tag, model = model,
             vOffset = primHandle.vOffset, n = eles.size()] __device__(int ei) mutable {
                auto inds = eles.template pack<2>("inds", ei).template reinterpret_bits<int>() + vOffset;

                int BCorder[2];
                for (int i = 0; i != 2; ++i)
                    BCorder[i] = vtemp("BCorder", inds[i]);
                T E;
                if (BCorder[0] == 3 && BCorder[1] == 3)
                    E = 0;
                else {
                    auto vole = eles("vol", ei);
                    auto k = eles("k", ei);
                    // auto k = model.mu;
                    auto rl = eles("rl", ei);
                    vec3 xs[2] = {vtemp.template pack<3>(tag, inds[0]), vtemp.template pack<3>(tag, inds[1])};
                    auto xij = xs[1] - xs[0];
                    auto lij = xij.norm();

                    E = (T)0.5 * k * zs::sqr(lij - rl) * vole;
                }
                reduce_to(ei, n, E, es[ei / 32]);
            });
        return reduce(pol, es) * dt * dt;
    } else if (primHandle.category == ZenoParticles::surface) {
        if (primHandle.isBoundary())
            return 0;
        // elasticity
        pol(range(eles.size()),
            [eles = proxy<space>({}, eles), vtemp = proxy<space>({}, vtemp), es = proxy<space>(es), tag, model = model,
             vOffset = primHandle.vOffset, n = eles.size()] __device__(int ei) mutable {
                auto IB = eles.template pack<2, 2>("IB", ei);
                auto inds = eles.template pack<3>("inds", ei).template reinterpret_bits<int>() + vOffset;

                int BCorder[3];
                for (int i = 0; i != 3; ++i)
                    BCorder[i] = vtemp("BCorder", inds[i]);
                T E;
                if (BCorder[0] == 3 && BCorder[1] == 3 && BCorder[2] == 3)
                    E = 0;
                else {
                    auto vole = eles("vol", ei);
                    vec3 xs[3] = {vtemp.template pack<3>(tag, inds[0]), vtemp.template pack<3>(tag, inds[1]),
                                  vtemp.template pack<3>(tag, inds[2])};
                    auto x1x0 = xs[1] - xs[0];
                    auto x2x0 = xs[2] - xs[0];

                    zs::vec<T, 3, 2> Ds{x1x0[0], x2x0[0], x1x0[1], x2x0[1], x1x0[2], x2x0[2]};
                    auto F = Ds * IB;
                    auto f0 = col(F, 0);
                    auto f1 = col(F, 1);
                    auto f0Norm = zs::sqrt(f0.l2NormSqr());
                    auto f1Norm = zs::sqrt(f1.l2NormSqr());
                    auto Estretch = model.mu * vole * (zs::sqr(f0Norm - 1) + zs::sqr(f1Norm - 1));
                    auto Eshear = (model.mu * 0.3) * vole * zs::sqr(f0.dot(f1));
                    E = Estretch + Eshear;
                }
                reduce_to(ei, n, E, es[ei / 32]);
            });
        return (reduce(pol, es) * dt * dt);
    } else if (primHandle.category == ZenoParticles::tet) {
        pol(zs::range(eles.size()),
            [vtemp = proxy<space>({}, vtemp), eles = proxy<space>({}, eles), es = proxy<space>(es), model, tag,
             vOffset = primHandle.vOffset, n = eles.size()] __device__(int ei) mutable {
                auto IB = eles.template pack<3, 3>("IB", ei);
                auto inds = eles.template pack<4>("inds", ei).template reinterpret_bits<int>() + vOffset;
                auto vole = eles("vol", ei);
                vec3 xs[4] = {vtemp.pack<3>(tag, inds[0]), vtemp.pack<3>(tag, inds[1]), vtemp.pack<3>(tag, inds[2]),
                              vtemp.pack<3>(tag, inds[3])};

                int BCorder[4];
                for (int i = 0; i != 4; ++i)
                    BCorder[i] = vtemp("BCorder", inds[i]);
                T E;
                if (BCorder[0] == 3 && BCorder[1] == 3 && BCorder[2] == 3 && BCorder[3] == 3)
                    E = 0;
                else {
                    mat3 F{};
                    auto x1x0 = xs[1] - xs[0];
                    auto x2x0 = xs[2] - xs[0];
                    auto x3x0 = xs[3] - xs[0];
                    auto Ds = mat3{x1x0[0], x2x0[0], x3x0[0], x1x0[1], x2x0[1], x3x0[1], x1x0[2], x2x0[2], x3x0[2]};
                    F = Ds * IB;
                    E = model.psi(F) * vole;
                }
                reduce_to(ei, n, E, es[ei / 32]);
            });
        return (reduce(pol, es) * dt * dt);
    }
    return 0;
}

typename IPCSystem::T IPCSystem::energy(zs::CudaExecutionPolicy &pol, const zs::SmallString tag,
                                        bool includeAugLagEnergy) {
    using namespace zs;
    constexpr auto space = execspace_e::cuda;
    Vector<T> &es = temp;

    es.resize(count_warps(coOffset));
    es.reset(0);
    std::vector<T> Es(0);

    // inertial
    pol(range(coOffset), [vtemp = proxy<space>({}, vtemp), es = proxy<space>(es), tag, extForce = extForce,
                          dt = this->dt, n = coOffset] __device__(int vi) mutable {
        auto m = zs::sqr(vtemp("ws", vi));
        auto x = vtemp.pack<3>(tag, vi);
        auto xt = vtemp.pack<3>("xhat", vi);
        int BCorder = vtemp("BCorder", vi);
        T E = 0;
        {
            // inertia
            E += (T)0.5 * m * (x - vtemp.pack<3>("xtilde", vi)).l2NormSqr();
            // external force
            if (vtemp("BCsoft", vi) == 0 && vtemp("BCorder", vi) != 3) {
                E += -m * extForce.dot(x - xt) * dt * dt;
            }
        }
        reduce_to(vi, n, E, es[vi / 32]);
    });
    Es.push_back(reduce(pol, es));

    for (auto &primHandle : prims) {
        match([&](auto &elasticModel) {
            Es.push_back(elasticityEnergy(pol, vtemp, primHandle, elasticModel, dt, es));
        })(primHandle.models.getElasticModel());
    }
    // contacts
    {
        if (enableContact) {
            auto activeGap2 = dHat * dHat + 2 * xi * dHat;
            auto numPP = nPP.getVal();
            es.resize(count_warps(numPP));
            es.reset(0);
            pol(range(numPP), [vtemp = proxy<space>({}, vtemp), PP = proxy<space>(PP), es = proxy<space>(es),
                               xi2 = xi * xi, dHat = dHat, activeGap2, n = numPP] __device__(int ppi) mutable {
                auto pp = PP[ppi];
                auto x0 = vtemp.pack<3>("xn", pp[0]);
                auto x1 = vtemp.pack<3>("xn", pp[1]);
                auto dist2 = dist2_pp(x0, x1);
                if (dist2 < xi2)
                    printf("dist already smaller than xi!\n");
                // atomic_add(exec_cuda, &res[0],
                //           zs::barrier(dist2 - xi2, activeGap2, kappa));
                // es[ppi] = zs::barrier(dist2 - xi2, activeGap2, (T)1);

                auto I5 = dist2 / activeGap2;
                auto lenE = (dist2 - activeGap2);
                auto E = -lenE * lenE * zs::log(I5);
                reduce_to(ppi, n, E, es[ppi / 32]);
            });
            Es.push_back(reduce(pol, es) * kappa);

            auto numPE = nPE.getVal();
            es.resize(count_warps(numPE));
            es.reset(0);
            pol(range(numPE), [vtemp = proxy<space>({}, vtemp), PE = proxy<space>(PE), es = proxy<space>(es),
                               xi2 = xi * xi, dHat = dHat, activeGap2, n = numPE] __device__(int pei) mutable {
                auto pe = PE[pei];
                auto p = vtemp.pack<3>("xn", pe[0]);
                auto e0 = vtemp.pack<3>("xn", pe[1]);
                auto e1 = vtemp.pack<3>("xn", pe[2]);

                auto dist2 = dist2_pe(p, e0, e1);
                if (dist2 < xi2)
                    printf("dist already smaller than xi!\n");
                // atomic_add(exec_cuda, &res[0],
                //           zs::barrier(dist2 - xi2, activeGap2, kappa));
                // es[pei] = zs::barrier(dist2 - xi2, activeGap2, (T)1);

                auto I5 = dist2 / activeGap2;
                auto lenE = (dist2 - activeGap2);
                auto E = -lenE * lenE * zs::log(I5);
                reduce_to(pei, n, E, es[pei / 32]);
            });
            Es.push_back(reduce(pol, es) * kappa);

            auto numPT = nPT.getVal();
            es.resize(count_warps(numPT));
            es.reset(0);
            pol(range(numPT), [vtemp = proxy<space>({}, vtemp), PT = proxy<space>(PT), es = proxy<space>(es),
                               xi2 = xi * xi, dHat = dHat, activeGap2, n = numPT] __device__(int pti) mutable {
                auto pt = PT[pti];
                auto p = vtemp.pack<3>("xn", pt[0]);
                auto t0 = vtemp.pack<3>("xn", pt[1]);
                auto t1 = vtemp.pack<3>("xn", pt[2]);
                auto t2 = vtemp.pack<3>("xn", pt[3]);

                auto dist2 = dist2_pt(p, t0, t1, t2);
                if (dist2 < xi2)
                    printf("dist already smaller than xi!\n");
                // atomic_add(exec_cuda, &res[0],
                //           zs::barrier(dist2 - xi2, activeGap2, kappa));
                // es[pti] = zs::barrier(dist2 - xi2, activeGap2, (T)1);

                auto I5 = dist2 / activeGap2;
                auto lenE = (dist2 - activeGap2);
                auto E = -lenE * lenE * zs::log(I5);
                reduce_to(pti, n, E, es[pti / 32]);
            });
            Es.push_back(reduce(pol, es) * kappa);

            auto numEE = nEE.getVal();
            es.resize(count_warps(numEE));
            es.reset(0);
            pol(range(numEE), [vtemp = proxy<space>({}, vtemp), EE = proxy<space>(EE), es = proxy<space>(es),
                               xi2 = xi * xi, dHat = dHat, activeGap2, n = numEE] __device__(int eei) mutable {
                auto ee = EE[eei];
                auto ea0 = vtemp.pack<3>("xn", ee[0]);
                auto ea1 = vtemp.pack<3>("xn", ee[1]);
                auto eb0 = vtemp.pack<3>("xn", ee[2]);
                auto eb1 = vtemp.pack<3>("xn", ee[3]);

                auto dist2 = dist2_ee(ea0, ea1, eb0, eb1);
                if (dist2 < xi2)
                    printf("dist already smaller than xi!\n");
                // atomic_add(exec_cuda, &res[0],
                //           zs::barrier(dist2 - xi2, activeGap2, kappa));
                // es[eei] = zs::barrier(dist2 - xi2, activeGap2, (T)1);

                auto I5 = dist2 / activeGap2;
                auto lenE = (dist2 - activeGap2);
                auto E = -lenE * lenE * zs::log(I5);
                reduce_to(eei, n, E, es[eei / 32]);
            });
            Es.push_back(reduce(pol, es) * kappa);

            if (enableMollification) {
                auto numEEM = nEEM.getVal();
                es.resize(count_warps(numEEM));
                es.reset(0);
                pol(range(numEEM), [vtemp = proxy<space>({}, vtemp), EEM = proxy<space>(EEM), es = proxy<space>(es),
                                    xi2 = xi * xi, dHat = dHat, activeGap2, n = numEEM] __device__(int eemi) mutable {
                    auto eem = EEM[eemi];
                    auto ea0 = vtemp.pack<3>("xn", eem[0]);
                    auto ea1 = vtemp.pack<3>("xn", eem[1]);
                    auto eb0 = vtemp.pack<3>("xn", eem[2]);
                    auto eb1 = vtemp.pack<3>("xn", eem[3]);

                    auto v0 = ea1 - ea0;
                    auto v1 = eb1 - eb0;
                    auto c = v0.cross(v1).norm();
                    auto I1 = c * c;
                    T E = 0;
                    if (I1 != 0) {
                        auto dist2 = dist2_ee(ea0, ea1, eb0, eb1);
                        if (dist2 < xi2)
                            printf("dist already smaller than xi!\n");
                        auto I2 = dist2 / activeGap2;

                        auto rv0 = vtemp.pack<3>("x0", eem[0]);
                        auto rv1 = vtemp.pack<3>("x0", eem[1]);
                        auto rv2 = vtemp.pack<3>("x0", eem[2]);
                        auto rv3 = vtemp.pack<3>("x0", eem[3]);
                        T epsX = mollifier_threshold_ee(rv0, rv1, rv2, rv3);
                        E = (2 - I1 / epsX) * (I1 / epsX) * -zs::sqr(activeGap2 - activeGap2 * I2) * zs::log(I2);
                    }
                    reduce_to(eemi, n, E, es[eemi / 32]);
                });
                Es.push_back(reduce(pol, es) * kappa);

                auto numPPM = nPPM.getVal();
                es.resize(count_warps(numPPM));
                es.reset(0);
                pol(range(numPPM), [vtemp = proxy<space>({}, vtemp), PPM = proxy<space>(PPM), es = proxy<space>(es),
                                    xi2 = xi * xi, dHat = dHat, activeGap2, n = numPPM] __device__(int ppmi) mutable {
                    auto ppm = PPM[ppmi];

                    auto v0 = vtemp.pack<3>("xn", ppm[1]) - vtemp.pack<3>("xn", ppm[0]);
                    auto v1 = vtemp.pack<3>("xn", ppm[3]) - vtemp.pack<3>("xn", ppm[2]);
                    auto c = v0.cross(v1).norm();
                    auto I1 = c * c;
                    T E = 0;
                    if (I1 != 0) {
                        auto dist2 = dist2_pp(vtemp.pack<3>("xn", ppm[0]), vtemp.pack<3>("xn", ppm[2]));
                        if (dist2 < xi2)
                            printf("dist already smaller than xi!\n");
                        auto I2 = dist2 / activeGap2;

                        auto rv0 = vtemp.pack<3>("x0", ppm[0]);
                        auto rv1 = vtemp.pack<3>("x0", ppm[1]);
                        auto rv2 = vtemp.pack<3>("x0", ppm[2]);
                        auto rv3 = vtemp.pack<3>("x0", ppm[3]);
                        T epsX = mollifier_threshold_ee(rv0, rv1, rv2, rv3);
                        E = (2 - I1 / epsX) * (I1 / epsX) * -zs::sqr(activeGap2 - activeGap2 * I2) * zs::log(I2);
                    }
                    reduce_to(ppmi, n, E, es[ppmi / 32]);
                });
                Es.push_back(reduce(pol, es) * kappa);

                auto numPEM = nPEM.getVal();
                es.resize(count_warps(numPEM));
                es.reset(0);
                pol(range(numPEM), [vtemp = proxy<space>({}, vtemp), PEM = proxy<space>(PEM), es = proxy<space>(es),
                                    xi2 = xi * xi, dHat = dHat, activeGap2, n = numPEM] __device__(int pemi) mutable {
                    auto pem = PEM[pemi];

                    auto p = vtemp.pack<3>("xn", pem[0]);
                    auto e0 = vtemp.pack<3>("xn", pem[2]);
                    auto e1 = vtemp.pack<3>("xn", pem[3]);
                    auto v0 = vtemp.pack<3>("xn", pem[1]) - p;
                    auto v1 = e1 - e0;
                    auto c = v0.cross(v1).norm();
                    auto I1 = c * c;
                    T E = 0;
                    if (I1 != 0) {
                        auto dist2 = dist2_pe(p, e0, e1);
                        if (dist2 < xi2)
                            printf("dist already smaller than xi!\n");
                        auto I2 = dist2 / activeGap2;

                        auto rv0 = vtemp.pack<3>("x0", pem[0]);
                        auto rv1 = vtemp.pack<3>("x0", pem[1]);
                        auto rv2 = vtemp.pack<3>("x0", pem[2]);
                        auto rv3 = vtemp.pack<3>("x0", pem[3]);
                        T epsX = mollifier_threshold_ee(rv0, rv1, rv2, rv3);
                        E = (2 - I1 / epsX) * (I1 / epsX) * -zs::sqr(activeGap2 - activeGap2 * I2) * zs::log(I2);
                    }
                    reduce_to(pemi, n, E, es[pemi / 32]);
                });
                Es.push_back(reduce(pol, es) * kappa);
            } // mollification

            if (s_enableFriction) {
                if (fricMu != 0) {
                    if (s_enableSelfFriction) {
                        auto numFPP = nFPP.getVal();
                        es.resize(count_warps(numFPP));
                        es.reset(0);
                        pol(range(numFPP), [vtemp = proxy<space>({}, vtemp), fricPP = proxy<space>({}, fricPP),
                                            FPP = proxy<space>(FPP), es = proxy<space>(es), epsvh = epsv * dt,
                                            n = numFPP] __device__(int fppi) mutable {
                            auto fpp = FPP[fppi];
                            auto p0 = vtemp.pack<3>("xn", fpp[0]) - vtemp.pack<3>("xhat", fpp[0]);
                            auto p1 = vtemp.pack<3>("xn", fpp[1]) - vtemp.pack<3>("xhat", fpp[1]);
                            auto basis = fricPP.template pack<3, 2>("basis", fppi);
                            auto fn = fricPP("fn", fppi);
                            auto relDX3D = point_point_rel_dx(p0, p1);
                            auto relDX = basis.transpose() * relDX3D;
                            auto relDXNorm2 = relDX.l2NormSqr();
                            auto E = f0_SF(relDXNorm2, epsvh) * fn;
                            reduce_to(fppi, n, E, es[fppi / 32]);
                        });
                        Es.push_back(reduce(pol, es) * fricMu);

                        auto numFPE = nFPE.getVal();
                        es.resize(count_warps(numFPE));
                        es.reset(0);
                        pol(range(numFPE), [vtemp = proxy<space>({}, vtemp), fricPE = proxy<space>({}, fricPE),
                                            FPE = proxy<space>(FPE), es = proxy<space>(es), epsvh = epsv * dt,
                                            n = numFPE] __device__(int fpei) mutable {
                            auto fpe = FPE[fpei];
                            auto p = vtemp.pack<3>("xn", fpe[0]) - vtemp.pack<3>("xhat", fpe[0]);
                            auto e0 = vtemp.pack<3>("xn", fpe[1]) - vtemp.pack<3>("xhat", fpe[1]);
                            auto e1 = vtemp.pack<3>("xn", fpe[2]) - vtemp.pack<3>("xhat", fpe[2]);
                            auto basis = fricPE.template pack<3, 2>("basis", fpei);
                            auto fn = fricPE("fn", fpei);
                            auto yita = fricPE("yita", fpei);
                            auto relDX3D = point_edge_rel_dx(p, e0, e1, yita);
                            auto relDX = basis.transpose() * relDX3D;
                            auto relDXNorm2 = relDX.l2NormSqr();
                            auto E = f0_SF(relDXNorm2, epsvh) * fn;
                            reduce_to(fpei, n, E, es[fpei / 32]);
                        });
                        Es.push_back(reduce(pol, es) * fricMu);

                        auto numFPT = nFPT.getVal();
                        es.resize(count_warps(numFPT));
                        es.reset(0);
                        pol(range(numFPT), [vtemp = proxy<space>({}, vtemp), fricPT = proxy<space>({}, fricPT),
                                            FPT = proxy<space>(FPT), es = proxy<space>(es), epsvh = epsv * dt,
                                            n = numFPT] __device__(int fpti) mutable {
                            auto fpt = FPT[fpti];
                            auto p = vtemp.pack<3>("xn", fpt[0]) - vtemp.pack<3>("xhat", fpt[0]);
                            auto v0 = vtemp.pack<3>("xn", fpt[1]) - vtemp.pack<3>("xhat", fpt[1]);
                            auto v1 = vtemp.pack<3>("xn", fpt[2]) - vtemp.pack<3>("xhat", fpt[2]);
                            auto v2 = vtemp.pack<3>("xn", fpt[3]) - vtemp.pack<3>("xhat", fpt[3]);
                            auto basis = fricPT.template pack<3, 2>("basis", fpti);
                            auto fn = fricPT("fn", fpti);
                            auto betas = fricPT.template pack<2>("beta", fpti);
                            auto relDX3D = point_triangle_rel_dx(p, v0, v1, v2, betas[0], betas[1]);
                            auto relDX = basis.transpose() * relDX3D;
                            auto relDXNorm2 = relDX.l2NormSqr();
                            auto E = f0_SF(relDXNorm2, epsvh) * fn;
                            reduce_to(fpti, n, E, es[fpti / 32]);
                        });
                        Es.push_back(reduce(pol, es) * fricMu);

                        auto numFEE = nFEE.getVal();
                        es.resize(count_warps(numFEE));
                        es.reset(0);
                        pol(range(numFEE), [vtemp = proxy<space>({}, vtemp), fricEE = proxy<space>({}, fricEE),
                                            FEE = proxy<space>(FEE), es = proxy<space>(es), epsvh = epsv * dt,
                                            n = numFEE] __device__(int feei) mutable {
                            auto fee = FEE[feei];
                            auto e0 = vtemp.pack<3>("xn", fee[0]) - vtemp.pack<3>("xhat", fee[0]);
                            auto e1 = vtemp.pack<3>("xn", fee[1]) - vtemp.pack<3>("xhat", fee[1]);
                            auto e2 = vtemp.pack<3>("xn", fee[2]) - vtemp.pack<3>("xhat", fee[2]);
                            auto e3 = vtemp.pack<3>("xn", fee[3]) - vtemp.pack<3>("xhat", fee[3]);
                            auto basis = fricEE.template pack<3, 2>("basis", feei);
                            auto fn = fricEE("fn", feei);
                            auto gammas = fricEE.template pack<2>("gamma", feei);
                            auto relDX3D = edge_edge_rel_dx(e0, e1, e2, e3, gammas[0], gammas[1]);
                            auto relDX = basis.transpose() * relDX3D;
                            auto relDXNorm2 = relDX.l2NormSqr();
                            auto E = f0_SF(relDXNorm2, epsvh) * fn;
                            reduce_to(feei, n, E, es[feei / 32]);
                        });
                        Es.push_back(reduce(pol, es) * fricMu);
                    }
                }
            } // fric
        }
        if (enableGround) {
            for (auto &primHandle : prims) {
                if (primHandle.isBoundary()) // skip soft boundary
                    continue;
                const auto &svs = primHandle.getSurfVerts();
                // boundary
                es.resize(count_warps(svs.size()));
                es.reset(0);
                pol(range(svs.size()), [vtemp = proxy<space>({}, vtemp), svs = proxy<space>({}, svs),
                                        es = proxy<space>(es), gn = s_groundNormal, dHat2 = dHat * dHat, n = svs.size(),
                                        svOffset = primHandle.svOffset] ZS_LAMBDA(int svi) mutable {
                    const auto vi = reinterpret_bits<int>(svs("inds", svi)) + svOffset;
                    auto x = vtemp.pack<3>("xn", vi);
                    auto dist = gn.dot(x);
                    auto dist2 = dist * dist;
                    T E;
                    if (dist2 < dHat2)
                        E = -zs::sqr(dist2 - dHat2) * zs::log(dist2 / dHat2);
                    else
                        E = 0;
                    reduce_to(svi, n, E, es[svi / 32]);
                });
                Es.push_back(reduce(pol, es) * kappa);

                if (s_enableFriction)
                    if (fricMu != 0) {
                        es.resize(count_warps(svs.size()));
                        es.reset(0);
                        pol(range(svs.size()),
                            [vtemp = proxy<space>({}, vtemp), svtemp = proxy<space>({}, primHandle.svtemp),
                             svs = proxy<space>({}, svs), es = proxy<space>(es), gn = s_groundNormal, dHat = dHat,
                             epsvh = epsv * dt, fricMu = fricMu, n = svs.size(),
                             svOffset = primHandle.svOffset] ZS_LAMBDA(int svi) mutable {
                                const auto vi = reinterpret_bits<int>(svs("inds", svi)) + svOffset;
                                auto fn = svtemp("fn", svi);
                                T E = 0;
                                if (fn != 0) {
                                    auto x = vtemp.pack<3>("xn", vi);
                                    auto dx = x - vtemp.pack<3>("xhat", vi);
                                    auto relDX = dx - gn.dot(dx) * gn;
                                    auto relDXNorm2 = relDX.l2NormSqr();
                                    auto relDXNorm = zs::sqrt(relDXNorm2);
                                    if (relDXNorm > epsvh) {
                                        E = fn * (relDXNorm - epsvh / 2);
                                    } else {
                                        E = fn * relDXNorm2 / epsvh / 2;
                                    }
                                }
                                reduce_to(svi, n, E, es[svi / 32]);
                            });
                        Es.push_back(reduce(pol, es) * fricMu);
                    }
            }
        }
    }
    // constraints
    if (includeAugLagEnergy) {
        computeConstraints(pol);
        es.resize(count_warps(numDofs));
        es.reset(0);
        pol(range(numDofs), [vtemp = proxy<space>({}, vtemp), es = proxy<space>(es), n = numDofs,
                             boundaryKappa = boundaryKappa] __device__(int vi) mutable {
            // already updated during "xn" update
            auto cons = vtemp.template pack<3>("cons", vi);
            auto w = vtemp("ws", vi);
            auto lambda = vtemp.pack<3>("lambda", vi);
            int BCfixed = vtemp("BCfixed", vi);
            T E = 0;
            if (!BCfixed)
                E = (T)(-lambda.dot(cons) * w + 0.5 * w * boundaryKappa * cons.l2NormSqr());
            reduce_to(vi, n, E, es[vi / 32]);
        });
        Es.push_back(reduce(pol, es));
    }

    std::sort(Es.begin(), Es.end());
    T E = 0;
    for (auto e : Es)
        E += e;
    return E;
}

void IPCSystem::cgsolve(zs::CudaExecutionPolicy &cudaPol) {
    // input "grad", multiply, constraints
    // output "dir"
    using namespace zs;
    constexpr auto space = execspace_e::cuda;

    // solve for A dir = grad;
    cudaPol(zs::range(numDofs), [vtemp = proxy<space>({}, vtemp)] ZS_LAMBDA(int i) mutable {
        vtemp.tuple<3>("dir", i) = vec3::zeros();
        vtemp.tuple<3>("temp", i) = vec3::zeros();
    });
    // initial guess for hard boundary constraints
    if (coVerts)
        cudaPol(zs::range(coVerts->size()),
                [vtemp = proxy<space>({}, vtemp), coOffset = coOffset, dt = dt] ZS_LAMBDA(int i) mutable {
                    i += coOffset;
                    vtemp.tuple<3>("dir", i) = (vtemp.pack<3>("xtilde", i) - vtemp.pack<3>("xn", i)) * dt;
                });
    // temp = A * dir
    multiply(cudaPol, "dir", "temp");
    // r = grad - temp
    cudaPol(zs::range(numDofs), [vtemp = proxy<space>({}, vtemp)] ZS_LAMBDA(int i) mutable {
        vtemp.tuple<3>("r", i) = vtemp.pack<3>("grad", i) - vtemp.pack<3>("temp", i);
    });
    // project(cudaPol, "r");
    precondition(cudaPol, "r", "q");
    cudaPol(zs::range(numDofs), [vtemp = proxy<space>({}, vtemp)] ZS_LAMBDA(int i) mutable {
        vtemp.tuple<3>("p", i) = vtemp.pack<3>("q", i);
    });
    T zTrk = dot(cudaPol, vtemp, "r", "q");
    auto residualPreconditionedNorm2 = zTrk;
    auto localTol2 = cgRel * cgRel * residualPreconditionedNorm2;
    int iter = 0;

    //
    auto [npp, npe, npt, nee, nppm, npem, neem, ncspt, ncsee] = getCnts();

    for (; iter != CGCap; ++iter) {
        if (iter % 50 == 0)
            fmt::print("cg iter: {}, norm2: {} (zTrk: {}) npp: {}, npe: {}, "
                       "npt: {}, nee: {}, nppm: {}, npem: {}, neem: {}, ncspt: "
                       "{}, ncsee: {}\n",
                       iter, residualPreconditionedNorm2, zTrk, npp, npe, npt, nee, nppm, npem, neem, ncspt, ncsee);

        if (residualPreconditionedNorm2 <= localTol2)
            break;
        multiply(cudaPol, "p", "temp");
        // project(cudaPol, "temp"); // need further checking hessian!

        T alpha = zTrk / dot(cudaPol, vtemp, "temp", "p");
        cudaPol(range(numDofs), [vtemp = proxy<space>({}, vtemp), alpha] ZS_LAMBDA(int vi) mutable {
            vtemp.tuple<3>("dir", vi) = vtemp.pack<3>("dir", vi) + alpha * vtemp.pack<3>("p", vi);
            vtemp.tuple<3>("r", vi) = vtemp.pack<3>("r", vi) - alpha * vtemp.pack<3>("temp", vi);
        });

        precondition(cudaPol, "r", "q");
        auto zTrkLast = zTrk;
        zTrk = dot(cudaPol, vtemp, "q", "r");
        auto beta = zTrk / zTrkLast;
        cudaPol(range(numDofs), [vtemp = proxy<space>({}, vtemp), beta] ZS_LAMBDA(int vi) mutable {
            vtemp.tuple<3>("p", vi) = vtemp.pack<3>("q", vi) + beta * vtemp.pack<3>("p", vi);
        });

        residualPreconditionedNorm2 = zTrk;
    } // end cg step
}
void IPCSystem::groundIntersectionFreeStepsize(zs::CudaExecutionPolicy &pol, T &stepSize) {
    using namespace zs;
    // constexpr T slackness = 0.8;
    constexpr auto space = execspace_e::cuda;

    zs::Vector<T> finalAlpha{vtemp.get_allocator(), 1};
    finalAlpha.setVal(stepSize);
    pol(Collapse{coOffset},
        [vtemp = proxy<space>({}, vtemp),
         // boundary
         gn = s_groundNormal, finalAlpha = proxy<space>(finalAlpha), stepSize] ZS_LAMBDA(int vi) mutable {
            // this vert affected by sticky boundary conditions
            if (vtemp("BCorder", vi) == 3)
                return;
            auto dir = vtemp.pack<3>("dir", vi);
            auto coef = gn.dot(dir);
            if (coef < 0) { // impacting direction
                auto x = vtemp.pack<3>("xn", vi);
                auto dist = gn.dot(x);
                auto maxAlpha = (dist * 0.8) / (-coef);
                if (maxAlpha < stepSize)
                    atomic_min(exec_cuda, &finalAlpha[0], maxAlpha);
            }
        });
    stepSize = finalAlpha.getVal();
    fmt::print(fg(fmt::color::dark_cyan), "ground alpha: {}\n", stepSize);
}
void IPCSystem::intersectionFreeStepsize(zs::CudaExecutionPolicy &pol, T xi, T &stepSize) {
    using namespace zs;
    constexpr auto space = execspace_e::cuda;

    Vector<T> alpha{vtemp.get_allocator(), 1};
    alpha.setVal(stepSize);
    auto npt = ncsPT.getVal();
    pol(range(npt), [csPT = proxy<space>(csPT), vtemp = proxy<space>({}, vtemp), alpha = proxy<space>(alpha), stepSize,
                     xi, coOffset = (int)coOffset] __device__(int pti) {
        auto ids = csPT[pti];
        auto p = vtemp.template pack<3>("xn", ids[0]);
        auto t0 = vtemp.template pack<3>("xn", ids[1]);
        auto t1 = vtemp.template pack<3>("xn", ids[2]);
        auto t2 = vtemp.template pack<3>("xn", ids[3]);
        auto dp = vtemp.template pack<3>("dir", ids[0]);
        auto dt0 = vtemp.template pack<3>("dir", ids[1]);
        auto dt1 = vtemp.template pack<3>("dir", ids[2]);
        auto dt2 = vtemp.template pack<3>("dir", ids[3]);
        T tmp = alpha[0];
#if 1
        if (accd::ptccd(p, t0, t1, t2, dp, dt0, dt1, dt2, (T)0.2, xi, tmp))
#elif 1
            if (ticcd::ptccd(p, t0, t1, t2, dp, dt0, dt1, dt2, (T)0.2, xi, tmp))
#else
            if (pt_ccd(p, t0, t1, t2, dp, dt0, dt1, dt2, xi, tmp))
#endif
            atomic_min(exec_cuda, &alpha[0], tmp);
    });
    auto nee = ncsEE.getVal();
    pol(range(nee), [csEE = proxy<space>(csEE), vtemp = proxy<space>({}, vtemp), alpha = proxy<space>(alpha), stepSize,
                     xi, coOffset = (int)coOffset] __device__(int eei) {
        auto ids = csEE[eei];
        auto ea0 = vtemp.template pack<3>("xn", ids[0]);
        auto ea1 = vtemp.template pack<3>("xn", ids[1]);
        auto eb0 = vtemp.template pack<3>("xn", ids[2]);
        auto eb1 = vtemp.template pack<3>("xn", ids[3]);
        auto dea0 = vtemp.template pack<3>("dir", ids[0]);
        auto dea1 = vtemp.template pack<3>("dir", ids[1]);
        auto deb0 = vtemp.template pack<3>("dir", ids[2]);
        auto deb1 = vtemp.template pack<3>("dir", ids[3]);
        auto tmp = alpha[0];
#if 1
        if (accd::eeccd(ea0, ea1, eb0, eb1, dea0, dea1, deb0, deb1, (T)0.2, xi, tmp))
#elif 1
            if (ticcd::eeccd(ea0, ea1, eb0, eb1, dea0, dea1, deb0, deb1, (T)0.2, xi, tmp))
#else
            if (ee_ccd(ea0, ea1, eb0, eb1, dea0, dea1, deb0, deb1, xi, tmp))
#endif
            atomic_min(exec_cuda, &alpha[0], tmp);
    });
    stepSize = alpha.getVal();
}
void IPCSystem::lineSearch(zs::CudaExecutionPolicy &cudaPol, T &alpha) {
    using namespace zs;
    constexpr auto space = execspace_e::cuda;
    // initial energy
    T E0 = energy(cudaPol, "xn", !BCsatisfied); // must be "xn", cuz elasticity is hardcoded

    T E{E0};
    T c1m = 0;
    int lsIter = 0;
    c1m = armijoParam * dot(cudaPol, vtemp, "dir", "grad");
    fmt::print(fg(fmt::color::white), "c1m : {}\n", c1m);
    do {
        cudaPol(zs::range(vtemp.size()), [vtemp = proxy<space>({}, vtemp), alpha] __device__(int i) mutable {
            vtemp.tuple<3>("xn", i) = vtemp.pack<3>("xn0", i) + alpha * vtemp.pack<3>("dir", i);
        });

        if (enableContact)
            findCollisionConstraints(cudaPol, dHat, xi);

        E = energy(cudaPol, "xn", !BCsatisfied); // must be "xn", cuz elasticity is hardcoded

        fmt::print("E: {} at alpha {}. E0 {}\n", E, alpha, E0);
        if (E <= E0 + alpha * c1m)
            break;

        if (alpha < 1e-3) { // adhoc
            fmt::print(fg(fmt::color::light_yellow), "linesearch early exit with alpha {}\n", alpha);
            break;
        }

        alpha /= 2;
        if (++lsIter > 30) {
            auto cr = constraintResidual(cudaPol);
            fmt::print("too small stepsize at iteration [{}]! alpha: {}, cons "
                       "res: {}\n",
                       lsIter, alpha, cr);
        }
    } while (true);
}

void IPCSystem::newtonKrylov(zs::CudaExecutionPolicy &pol) {
    using namespace zs;
    constexpr auto space = execspace_e::cuda;

    /// optimizer
    for (int newtonIter = 0; newtonIter != PNCap; ++newtonIter) {
        // check constraints
        if (!BCsatisfied) {
            computeConstraints(pol);
            auto cr = constraintResidual(pol, true);
            if (cr < s_constraint_residual) {
                zeno::log_info("satisfied cons res [{}] at newton iter [{}]\n", cr, newtonIter);
                projectDBC = true;
                BCsatisfied = true;
            }
            fmt::print(fg(fmt::color::alice_blue), "newton iter {} cons residual: {}\n", newtonIter, cr);
        }
        // PRECOMPUTE
        if (enableContact) {
            findCollisionConstraints(pol, dHat, xi);
        }
        if (s_enableFriction)
            if (fricMu != 0) {
                precomputeFrictions(pol, dHat, xi);
            }
        // GRAD, HESS, P
        pol(zs::range(numDofs), [vtemp = proxy<space>({}, vtemp)] ZS_LAMBDA(int i) mutable {
            vtemp.tuple<9>("P", i) = mat3::zeros();
            vtemp.tuple<3>("grad", i) = vec3::zeros();
        });
        computeInertialAndGravityPotentialGradient(pol);
        computeElasticGradientAndHessian(pol, "grad");
        if (enableGround)
            computeBoundaryBarrierGradientAndHessian(pol);
        if (enableContact) {
            computeBarrierGradientAndHessian(pol, "grad");
            if (s_enableFriction)
                if (fricMu != 0) {
                    computeFrictionBarrierGradientAndHessian(pol, "grad");
                }
        }
        // ROTATE GRAD, APPLY CONSTRAINTS, PROJ GRADIENT
        pol(zs::range(coOffset), [vtemp = proxy<space>({}, vtemp)] ZS_LAMBDA(int i) mutable {
            auto grad = vtemp.pack<3, 3>("BCbasis", i).transpose() * vtemp.pack<3>("grad", i);
            vtemp.tuple<3>("grad", i) = grad;
        });
        if (!BCsatisfied) {
            // grad
            pol(zs::range(numDofs),
                [vtemp = proxy<space>({}, vtemp), boundaryKappa = boundaryKappa] ZS_LAMBDA(int i) mutable {
                    // computed during the previous constraint residual check
                    auto cons = vtemp.pack<3>("cons", i);
                    auto w = vtemp("ws", i);
                    vtemp.tuple<3>("grad", i) =
                        vtemp.pack<3>("grad", i) + w * vtemp.pack<3>("lambda", i) - boundaryKappa * w * cons;
                    int BCfixed = vtemp("BCfixed", i);
                    if (!BCfixed) {
                        int BCorder = vtemp("BCorder", i);
                        for (int d = 0; d != BCorder; ++d)
                            vtemp("P", 4 * d, i) += boundaryKappa * w;
                    }
                });
            // hess (embedded in multiply)
        }
        project(pol, "grad");
        // PREPARE P
        pol(zs::range(numDofs), [vtemp = proxy<space>({}, vtemp)] ZS_LAMBDA(int i) mutable {
            auto mat = vtemp.pack<3, 3>("P", i);
            if (zs::abs(zs::determinant(mat)) > limits<T>::epsilon() * 10)
                vtemp.tuple<9>("P", i) = inverse(mat);
            else
                vtemp.tuple<9>("P", i) = mat3::identity();
        });
        // CG SOLVE
        cgsolve(pol);
        // ROTATE BACK
        pol(Collapse{vtemp.size()}, [vtemp = proxy<space>({}, vtemp)] ZS_LAMBDA(int vi) mutable {
            vtemp.template tuple<3>("dir", vi) =
                vtemp.template pack<3, 3>("BCbasis", vi) * vtemp.template pack<3>("dir", vi);
        });
        // CHECK PN CONDITION
        T res = infNorm(pol, vtemp, "dir") / dt;
        T cons_res = constraintResidual(pol);
        if (res < targetGRes && cons_res == 0) {
            zeno::log_info("\t# substep {} newton optimizer ends in {} iters with residual {}\n", substep, newtonIter,
                           res);
            break;
        }
        fmt::print(fg(fmt::color::aquamarine),
                   "substep {} newton iter {}: direction residual(/dt) {}, "
                   "grad residual {}\n",
                   substep, newtonIter, res, infNorm(pol, vtemp, "grad"));
        // LINESEARCH
        pol(zs::range(vtemp.size()), [vtemp = proxy<space>({}, vtemp)] ZS_LAMBDA(int i) mutable {
            vtemp.tuple<3>("xn0", i) = vtemp.pack<3>("xn", i);
        });
        T alpha = 1.;
        if (enableGround) {
            groundIntersectionFreeStepsize(pol, alpha);
            fmt::print("\tstepsize after ground: {}\n", alpha);
        }
        if (enableContact) {
            // A.intersectionFreeStepsize(cudaPol, xi, alpha);
            // fmt::print("\tstepsize after intersection-free: {}\n", alpha);
            findCCDConstraints(pol, alpha, xi);
            auto [npp, npe, npt, nee, nppm, npem, neem, ncspt, ncsee] = getCnts();
            intersectionFreeStepsize(pol, xi, alpha);
            fmt::print("\tstepsize after ccd: {}. (ncspt: {}, ncsee: {})\n", alpha, ncspt, ncsee);
        }
        lineSearch(pol, alpha);
        pol(zs::range(vtemp.size()), [vtemp = proxy<space>({}, vtemp), alpha] ZS_LAMBDA(int i) mutable {
            vtemp.tuple<3>("xn", i) = vtemp.pack<3>("xn0", i) + alpha * vtemp.pack<3>("dir", i);
        });
        // UPDATE RULE
        cons_res = constraintResidual(pol);
        if (res * dt < updateZoneTol && cons_res > consTol) {
            if (boundaryKappa < kappaMax) {
                boundaryKappa *= 2;
                fmt::print(fg(fmt::color::ivory),
                           "increasing boundarykappa to {} due to constraint "
                           "difficulty.\n",
                           boundaryKappa);
                // getchar();
            } else {
                pol(Collapse{numDofs},
                    [vtemp = proxy<space>({}, vtemp), boundaryKappa = boundaryKappa] ZS_LAMBDA(int vi) mutable {
                        if (int BCorder = vtemp("BCorder", vi); BCorder > 0) {
                            vtemp.tuple<3>("lambda", vi) = vtemp.pack<3>("lambda", vi) -
                                                           boundaryKappa * vtemp("ws", vi) * vtemp.pack<3>("cons", vi);
                        }
                    });
                fmt::print(fg(fmt::color::ivory), "updating constraint lambda due to constraint difficulty.\n");
                // getchar();
            }
        }
    }
}

struct AdvanceIPCSystem : INode {
    void apply() override {
        using namespace zs;
        constexpr auto space = execspace_e::cuda;
        auto A = get_input<IPCSystem>("ZSIPCSystem");

        auto cudaPol = zs::cuda_exec();

        int nSubsteps = get_input2<int>("num_substeps");
        auto dt = get_input2<float>("dt");

        A->reinitialize(cudaPol, dt);
        A->suggestKappa(cudaPol);

        for (int subi = 0; subi != nSubsteps; ++subi) {
            A->advanceSubstep(cudaPol, (typename IPCSystem::T)1 / nSubsteps);

            int numFricSolve = A->s_enableFriction && A->fricMu != 0 ? 2 : 1;
        for_fric:

            A->newtonKrylov(cudaPol);

            if (--numFricSolve > 0)
                goto for_fric;

            A->updateVelocities(cudaPol);
        }
        // update velocity and positions
        A->writebackPositionsAndVelocities(cudaPol);

        set_output("ZSIPCSystem", A);
    }
};

ZENDEFNODE(AdvanceIPCSystem, {{
                                  "ZSIPCSystem",
                                  {"int", "num_substeps", "1"},
                                  {"float", "dt", "0.01"},
                              },
                              {"ZSIPCSystem"},
                              {},
                              {"FEM"}});

struct IPCSystemClothBinding : INode { // usually called after 'MoveTorwards' zsboundary
    void apply() override {
        using namespace zs;
        constexpr auto space = execspace_e::cuda;
        auto A = get_input<IPCSystem>("ZSIPCSystem");
        auto zsls = get_input<ZenoLevelSet>("ZSLevelSet");
        bool ifHardCons = get_input2<bool>("hard_constraint");

        auto cudaPol = zs::cuda_exec();
        using basic_ls_t = typename ZenoLevelSet::basic_ls_t;
        using const_sdf_vel_ls_t = typename ZenoLevelSet::const_sdf_vel_ls_t;
        using const_transition_ls_t = typename ZenoLevelSet::const_transition_ls_t;
#if 0
        match([&](const auto &ls) {
            if constexpr (is_same_v<RM_CVREF_T(ls), basic_ls_t>) {
                match([&](const auto &lsPtr) {
                    auto lsv = get_level_set_view<execspace_e::cuda>(lsPtr);
                    bindBoundary(cudaPol, lsv, verts, stBvh, bouVerts, tris, dist_cap);
                })(ls._ls);
            } else if constexpr (is_same_v<RM_CVREF_T(ls), const_sdf_vel_ls_t>) {
                match([&](auto lsv) {
                    bindBoundary(cudaPol, SdfVelFieldView{lsv}, verts, stBvh, bouVerts, tris, dist_cap);
                })(ls.template getView<execspace_e::cuda>());
            } else if constexpr (is_same_v<RM_CVREF_T(ls), const_transition_ls_t>) {
                match([&](auto fieldPair) {
                    auto &fvSrc = std::get<0>(fieldPair);
                    auto &fvDst = std::get<1>(fieldPair);
                    bindBoundary(
                        cudaPol,
                        TransitionLevelSetView{SdfVelFieldView{fvSrc}, SdfVelFieldView{fvDst}, ls._stepDt, ls._alpha},
                        verts, stBvh, bouVerts, tris, dist_cap);
                })(ls.template getView<zs::execspace_e::cuda>());
            }
        })(zsls->getLevelSet());
#endif

        set_output("ZSIPCSystem", A);
    }
};

ZENDEFNODE(IPCSystemClothBinding, {{
                                       "ZSIPCSystem",
                                       "ZSLevelSet",
                                       {"bool", "hard_constraint", "1"},
                                   },
                                   {"ZSIPCSystem"},
                                   {},
                                   {"FEM"}});

} // namespace zeno