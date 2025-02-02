#include "../Structures.hpp"
#include "../Utils.hpp"
// #include "Ccd.hpp"
#include "Ccds.hpp"
// #include "GIPC.cuh"
#include "zensim/Logger.hpp"
#include "zensim/container/Bvh.hpp"
#include "zensim/container/Bvs.hpp"
#include "zensim/cuda/execution/ExecutionPolicy.cuh"
#include "zensim/execution/ExecutionPolicy.hpp"
#include "zensim/geometry/Distance.hpp"
#include "zensim/geometry/Friction.hpp"
#include "zensim/geometry/PoissonDisk.hpp"
#include "zensim/geometry/SpatialQuery.hpp"
#include "zensim/geometry/VdbLevelSet.h"
#include "zensim/geometry/VdbSampler.h"
#include "zensim/io/MeshIO.hpp"
#include "zensim/math/bit/Bits.h"
#include "zensim/physics/ConstitutiveModel.hpp"
#include "zensim/types/Property.h"
#include <atomic>
#include <thrust/device_vector.h>
#include <thrust/reduce.h>
#include <zeno/VDBGrid.h>
#include <zeno/types/ListObject.h>
#include <zeno/types/NumericObject.h>
#include <zeno/types/PrimitiveObject.h>
#include <zeno/types/StringObject.h>

namespace zeno {

template <typename TileVecT, int codim = 3>
zs::Vector<zs::AABBBox<3, typename TileVecT::value_type>>
retrieve_bounding_volumes(zs::CudaExecutionPolicy &pol, const TileVecT &vtemp, const zs::SmallString &xTag,
                          const typename ZenoParticles::particles_t &eles, zs::wrapv<codim>, int voffset) {
    using namespace zs;
    using T = typename TileVecT::value_type;
    using bv_t = AABBBox<3, T>;
    static_assert(codim >= 1 && codim <= 4, "invalid co-dimension!\n");
    constexpr auto space = execspace_e::cuda;
    zs::Vector<bv_t> ret{eles.get_allocator(), eles.size()};
    pol(range(eles.size()), [eles = proxy<space>({}, eles), bvs = proxy<space>(ret), vtemp = proxy<space>({}, vtemp),
                             codim_v = wrapv<codim>{}, xTag, voffset] ZS_LAMBDA(int ei) mutable {
        constexpr int dim = RM_CVREF_T(codim_v)::value;
        auto inds = eles.template pack<dim>("inds", ei).template reinterpret_bits<int>() + voffset;
        auto x0 = vtemp.template pack<3>(xTag, inds[0]);
        bv_t bv{x0, x0};
        for (int d = 1; d != dim; ++d)
            merge(bv, vtemp.template pack<3>(xTag, inds[d]));
        bvs[ei] = bv;
    });
    return ret;
}
template <typename TileVecT0, typename TileVecT1, int codim = 3>
zs::Vector<zs::AABBBox<3, typename TileVecT0::value_type>>
retrieve_bounding_volumes(zs::CudaExecutionPolicy &pol, const TileVecT0 &verts, const zs::SmallString &xTag,
                          const typename ZenoParticles::particles_t &eles, zs::wrapv<codim>, const TileVecT1 &vtemp,
                          const zs::SmallString &dirTag, float stepSize, int voffset) {
    using namespace zs;
    using T = typename TileVecT0::value_type;
    using bv_t = AABBBox<3, T>;
    static_assert(codim >= 1 && codim <= 4, "invalid co-dimension!\n");
    constexpr auto space = execspace_e::cuda;
    Vector<bv_t> ret{eles.get_allocator(), eles.size()};
    pol(zs::range(eles.size()), [eles = proxy<space>({}, eles), bvs = proxy<space>(ret),
                                 verts = proxy<space>({}, verts), vtemp = proxy<space>({}, vtemp),
                                 codim_v = wrapv<codim>{}, xTag, dirTag, stepSize, voffset] ZS_LAMBDA(int ei) mutable {
        constexpr int dim = RM_CVREF_T(codim_v)::value;
        auto inds = eles.template pack<dim>("inds", ei).template reinterpret_bits<int>() + voffset;
        auto x0 = verts.template pack<3>(xTag, inds[0]);
        auto dir0 = vtemp.template pack<3>(dirTag, inds[0]);
        bv_t bv{get_bounding_box(x0, x0 + stepSize * dir0)};
        for (int d = 1; d != dim; ++d) {
            auto x = verts.template pack<3>(xTag, inds[d]);
            auto dir = vtemp.template pack<3>(dirTag, inds[d]);
            merge(bv, x);
            merge(bv, x + stepSize * dir);
        }
        bvs[ei] = bv;
    });
    return ret;
}

struct CodimStepping : INode {
    using T = double;
    using Ti = zs::conditional_t<zs::is_same_v<T, double>, zs::i64, zs::i32>;
    using dtiles_t = zs::TileVector<T, 32>;
    using tiles_t = typename ZenoParticles::particles_t;
    using vec3 = zs::vec<T, 3>;
    using ivec3 = zs::vec<int, 3>;
    using ivec2 = zs::vec<int, 2>;
    using mat2 = zs::vec<T, 2, 2>;
    using mat3 = zs::vec<T, 3, 3>;
    using pair_t = zs::vec<int, 2>;
    using pair3_t = zs::vec<int, 3>;
    using bvh_t = zs::LBvh<3, 32, int, T>;
    using bv_t = zs::AABBBox<3, T>;

    static constexpr vec3 s_groundNormal{0, 1, 0};
    inline static const char s_meanMassTag[] = "MeanMass";
    inline static const char s_meanSurfEdgeLengthTag[] = "MeanSurfEdgeLength";
    inline static const char s_meanSurfAreaTag[] = "MeanSurfArea";
    inline static int refStepsizeCoeff = 1;
    inline static int numContinuousCap = 0;
    inline static bool projectDBC = false;
    inline static bool BCsatisfied = false;
    inline static int PNCap = 1000;
    inline static int CGCap = 500;
    inline static int CCDCap = 20000;
    inline static T updateZoneTol = 1e-1;
    inline static T consTol = 1e-2;
    inline static T armijoParam = 1e-4;
    inline static bool useGD = false;
    inline static T boxDiagSize2 = 0;
    inline static T avgNodeMass = 0;
    inline static T targetGRes = 1e-2;
#define s_enableAdaptiveSetting 1
// static constexpr bool s_enableAdaptiveSetting = false;
#define s_enableContact 1
#define s_enableMollification 1
#define s_enableFriction 1
#define s_enableSelfFriction 1
    inline static bool s_enableGround = false;
#define s_enableDCDCheck 0
#define s_enableDebugCheck 0
    // static constexpr bool s_enableDCDCheck = false;

    inline static std::size_t estNumCps = 1000000;
    inline static T augLagCoeff = 1e4;
    inline static T cgRel = 1e-2;
    inline static T pnRel = 1e-2;
    inline static T kappaMax = 1e8;
    inline static T kappaMin = 1e4;
    inline static T kappa0 = 1e4;
    inline static T kappa = kappa0;
    inline static T fricMu = 0;
    inline static T &boundaryKappa = kappa;
    inline static T xi = 0; // 1e-2; // 2e-3;
    inline static T dHat = 0.0025;
    inline static T epsv = 0.0;
    inline static vec3 extForce;

    template <typename T> static inline T computeHb(const T d2, const T dHat2) {
#if 0
    T hess = 0;
    if (d2 < dHat2) {
      T t2 = d2 - dHat2;
      hess = (std::log(d2 / dHat2) * (T)-2.0 - t2 * (T)4.0 / d2) / (dHat2 * dHat2)
                + 1.0 / (d2 * d2) * (t2 / dHat2) * (t2 / dHat2);
    }
    return hess;
#else
        if (d2 >= dHat2)
            return 0;
        T t2 = d2 - dHat2;
        return ((std::log(d2 / dHat2) * -2 - t2 * 4 / d2) + (t2 / d2) * (t2 / d2));
#endif
    }

    template <typename VecT, int N = VecT::template range_t<0>::value,
              zs::enable_if_all<N % 3 == 0, N == VecT::template range_t<1>::value> = 0>
    static constexpr void rotate_hessian(zs::VecInterface<VecT> &H, const mat3 BCbasis[N / 3], const int BCorder[N / 3],
                                         const int BCfixed[], bool projectDBC) {
        // hessian rotation: trans^T hess * trans
        // left trans^T: multiplied on rows
        // right trans: multiplied on cols
        constexpr int NV = N / 3;
        // rotate and project
        for (int vi = 0; vi != NV; ++vi) {
            int offsetI = vi * 3;
            for (int vj = 0; vj != NV; ++vj) {
                int offsetJ = vj * 3;
                mat3 tmp{};
                for (int i = 0; i != 3; ++i)
                    for (int j = 0; j != 3; ++j)
                        tmp(i, j) = H(offsetI + i, offsetJ + j);
                // rotate
                tmp = BCbasis[vi].transpose() * tmp * BCbasis[vj];
                // project
                if (projectDBC) {
                    for (int i = 0; i != 3; ++i) {
                        bool clearRow = i < BCorder[vi];
                        for (int j = 0; j != 3; ++j) {
                            bool clearCol = j < BCorder[vj];
                            if (clearRow || clearCol)
                                tmp(i, j) = (vi == vj && i == j ? 1 : 0);
                        }
                    }
                } else {
                    for (int i = 0; i != 3; ++i) {
                        bool clearRow = i < BCorder[vi] && BCfixed[vi] == 1;
                        for (int j = 0; j != 3; ++j) {
                            bool clearCol = j < BCorder[vj] && BCfixed[vj] == 1;
                            if (clearRow || clearCol)
                                tmp(i, j) = (vi == vj && i == j ? 1 : 0);
                        }
                    }
                }
                for (int i = 0; i != 3; ++i)
                    for (int j = 0; j != 3; ++j)
                        H(offsetI + i, offsetJ + j) = tmp(i, j);
            }
        }
        return;
    }

    /// ref: codim-ipc
    struct IPCSystem {

        /// utilities
        static constexpr std::size_t count_warps(std::size_t n) noexcept {
            return (n + 31) / 32;
        }
        static constexpr int warp_index(int n) noexcept {
            return n / 32;
        }
        static constexpr auto warp_mask(int i, int n) noexcept {
            int k = n % 32;
            const int tail = n - k;
            if (i < tail)
                return zs::make_tuple(0xFFFFFFFFu, 32);
            return zs::make_tuple(((unsigned)(1ull << k) - 1), k);
        }

        template <typename T> static __forceinline__ __device__ void reduce_to(int i, int n, T val, T &dst) {
            auto [mask, numValid] = warp_mask(i, n);
            __syncwarp(mask);
            auto locid = threadIdx.x & 31;
            for (int stride = 1; stride < 32; stride <<= 1) {
                auto tmp = __shfl_down_sync(mask, val, stride);
                if (locid + stride < numValid)
                    val += tmp;
            }
            if (locid == 0)
                zs::atomic_add(zs::exec_cuda, &dst, val);
        }

        void clearTemp(std::size_t size) {
            zs::memset(zs::mem_device, temp.data(), 0, sizeof(T) * size);
        }
        template <typename Op = std::plus<T>>
        static T reduce(zs::CudaExecutionPolicy &cudaPol, const zs::Vector<T> &res, Op op = {}) {
            using namespace zs;
            Vector<T> ret{res.get_allocator(), 1};
            zs::reduce(cudaPol, std::begin(res), std::end(res), std::begin(ret), (T)0, op);
            return ret.getVal();
        }
        static T dot(zs::CudaExecutionPolicy &cudaPol, dtiles_t &vertData, const zs::SmallString tag0,
                     const zs::SmallString tag1) {
            using namespace zs;
            constexpr auto space = execspace_e::cuda;
            // Vector<double> res{vertData.get_allocator(), vertData.size()};
            Vector<double> res{vertData.get_allocator(), count_warps(vertData.size())};
            zs::memset(zs::mem_device, res.data(), 0, sizeof(double) * count_warps(vertData.size()));
            cudaPol(range(vertData.size()), [data = proxy<space>({}, vertData), res = proxy<space>(res), tag0, tag1,
                                             n = vertData.size()] __device__(int pi) mutable {
                auto v0 = data.pack<3>(tag0, pi);
                auto v1 = data.pack<3>(tag1, pi);
                auto v = v0.dot(v1);
                // res[pi] = v;
                reduce_to(pi, n, v, res[pi / 32]);
            });
            return reduce(cudaPol, res, std::plus<double>{});
        }
        static T infNorm(zs::CudaExecutionPolicy &cudaPol, dtiles_t &vertData, const zs::SmallString tag = "dir") {
            using namespace zs;
            constexpr auto space = execspace_e::cuda;
            Vector<T> res{vertData.get_allocator(), count_warps(vertData.size())};
            zs::memset(zs::mem_device, res.data(), 0, sizeof(T) * count_warps(vertData.size()));
            cudaPol(range(vertData.size()), [data = proxy<space>({}, vertData), res = proxy<space>(res), tag,
                                             n = vertData.size()] __device__(int pi) mutable {
                auto v = data.pack<3>(tag, pi);
                auto val = v.abs().max();

                auto [mask, numValid] = warp_mask(pi, n);
                auto locid = threadIdx.x & 31;
                for (int stride = 1; stride < 32; stride <<= 1) {
                    auto tmp = __shfl_down_sync(mask, val, stride);
                    if (locid + stride < numValid)
                        val = zs::max(val, tmp);
                }
                if (locid == 0)
                    res[pi / 32] = val;
            });
            return reduce(cudaPol, res, getmax<T>{});
        }

        template <int numV> struct Hessian {
            using inds_t = zs::vec<int, numV>;

            zs::Vector<inds_t> inds;
            zs::Vector<int> cnt;
            dtiles_t hess;
        };

        struct PrimitiveHandle {
            PrimitiveHandle(ZenoParticles &zsprim, std::size_t &vOffset, std::size_t &sfOffset, std::size_t &seOffset,
                            std::size_t &svOffset, zs::wrapv<2>)
                : zsprim{zsprim}, verts{zsprim.getParticles<true>()}, eles{zsprim.getQuadraturePoints()},
                  etemp{zsprim.getQuadraturePoints().get_allocator(), {{"He", 6 * 6}}, zsprim.numElements()},
                  surfTris{zsprim.getQuadraturePoints()},  // this is fake!
                  surfEdges{zsprim.getQuadraturePoints()}, // all elements are surface edges
                  surfVerts{zsprim[ZenoParticles::s_surfVertTag]}, vOffset{vOffset},
                  svtemp{zsprim.getQuadraturePoints().get_allocator(),
                         {{"H", 3 * 3}, {"fn", 1}},
                         zsprim[ZenoParticles::s_surfVertTag].size()},
                  sfOffset{sfOffset}, seOffset{seOffset}, svOffset{svOffset}, category{zsprim.category} {
                if (category != ZenoParticles::curve)
                    throw std::runtime_error("dimension of 2 but is not curve");
                vOffset += verts.size();
                // sfOffset += 0; // no surface triangles
                seOffset += surfEdges.size();
                svOffset += surfVerts.size();
            }
            PrimitiveHandle(ZenoParticles &zsprim, std::size_t &vOffset, std::size_t &sfOffset, std::size_t &seOffset,
                            std::size_t &svOffset, zs::wrapv<3>)
                : zsprim{zsprim}, verts{zsprim.getParticles<true>()}, eles{zsprim.getQuadraturePoints()},
                  etemp{zsprim.getQuadraturePoints().get_allocator(), {{"He", 9 * 9}}, zsprim.numElements()},
                  surfTris{zsprim.getQuadraturePoints()}, surfEdges{zsprim[ZenoParticles::s_surfEdgeTag]},
                  surfVerts{zsprim[ZenoParticles::s_surfVertTag]}, vOffset{vOffset},
                  svtemp{zsprim.getQuadraturePoints().get_allocator(),
                         {{"H", 3 * 3}, {"fn", 1}},
                         zsprim[ZenoParticles::s_surfVertTag].size()},
                  sfOffset{sfOffset}, seOffset{seOffset}, svOffset{svOffset}, category{zsprim.category} {
                if (category != ZenoParticles::surface)
                    throw std::runtime_error("dimension of 3 but is not surface");
                vOffset += verts.size();
                sfOffset += surfTris.size();
                seOffset += surfEdges.size();
                svOffset += surfVerts.size();
            }
            PrimitiveHandle(ZenoParticles &zsprim, std::size_t &vOffset, std::size_t &sfOffset, std::size_t &seOffset,
                            std::size_t &svOffset, zs::wrapv<4>)
                : zsprim{zsprim}, verts{zsprim.getParticles<true>()}, eles{zsprim.getQuadraturePoints()},
                  etemp{zsprim.getQuadraturePoints().get_allocator(), {{"He", 12 * 12}}, zsprim.numElements()},
                  surfTris{zsprim[ZenoParticles::s_surfTriTag]}, surfEdges{zsprim[ZenoParticles::s_surfEdgeTag]},
                  surfVerts{zsprim[ZenoParticles::s_surfVertTag]}, vOffset{vOffset},
                  svtemp{zsprim.getQuadraturePoints().get_allocator(),
                         {{"H", 3 * 3}, {"fn", 1}},
                         zsprim[ZenoParticles::s_surfVertTag].size()},
                  sfOffset{sfOffset}, seOffset{seOffset}, svOffset{svOffset}, category{zsprim.category} {
                if (category != ZenoParticles::tet)
                    throw std::runtime_error("dimension of 4 but is not tetrahedra");
                vOffset += verts.size();
                sfOffset += surfTris.size();
                seOffset += surfEdges.size();
                svOffset += surfVerts.size();
            }
            T averageNodalMass(zs::CudaExecutionPolicy &pol) const {
                using namespace zs;
                constexpr auto space = execspace_e::cuda;
                if (zsprim.hasMeta(s_meanMassTag))
                    return zsprim.readMeta(s_meanMassTag, zs::wrapt<T>{});
                Vector<T> masses{verts.get_allocator(), verts.size()};
                pol(Collapse{verts.size()}, [verts = proxy<space>({}, verts), masses = proxy<space>(masses)] __device__(
                                                int vi) mutable { masses[vi] = verts("m", vi); });
                auto tmp = reduce(pol, masses) / masses.size();
                zsprim.setMeta(s_meanMassTag, tmp);
                return tmp;
            }
            T averageSurfEdgeLength(zs::CudaExecutionPolicy &pol) const {
                using namespace zs;
                constexpr auto space = execspace_e::cuda;
                if (zsprim.hasMeta(s_meanSurfEdgeLengthTag))
                    return zsprim.readMeta(s_meanSurfEdgeLengthTag, zs::wrapt<T>{});
                auto &edges = surfEdges;
                Vector<T> edgeLengths{edges.get_allocator(), edges.size()};
                pol(Collapse{edges.size()}, [edges = proxy<space>({}, edges), verts = proxy<space>({}, verts),
                                             edgeLengths = proxy<space>(edgeLengths)] __device__(int ei) mutable {
                    auto inds = edges.template pack<2>("inds", ei).template reinterpret_bits<int>();
                    edgeLengths[ei] = (verts.pack<3>("x0", inds[0]) - verts.pack<3>("x0", inds[1])).norm();
                });
                auto tmp = reduce(pol, edgeLengths) / edges.size();
                zsprim.setMeta(s_meanSurfEdgeLengthTag, tmp);
                return tmp;
            }
            T averageSurfArea(zs::CudaExecutionPolicy &pol) const {
                using namespace zs;
                constexpr auto space = execspace_e::cuda;
                if (zsprim.category == ZenoParticles::curve)
                    return (T)0;
                if (zsprim.hasMeta(s_meanSurfAreaTag))
                    return zsprim.readMeta(s_meanSurfAreaTag, zs::wrapt<T>{});
                auto &tris = surfTris;
                Vector<T> surfAreas{tris.get_allocator(), tris.size()};
                pol(Collapse{surfAreas.size()}, [tris = proxy<space>({}, tris), verts = proxy<space>({}, verts),
                                                 surfAreas = proxy<space>(surfAreas)] __device__(int ei) mutable {
                    auto inds = tris.template pack<3>("inds", ei).template reinterpret_bits<int>();
                    surfAreas[ei] = (verts.pack<3>("x0", inds[1]) - verts.pack<3>("x0", inds[0]))
                                        .cross(verts.pack<3>("x0", inds[2]) - verts.pack<3>("x0", inds[0]))
                                        .norm() /
                                    2;
                });
                auto tmp = reduce(pol, surfAreas) / tris.size();
                zsprim.setMeta(s_meanSurfAreaTag, tmp);
                return tmp;
            }
            auto getModelLameParams() const {
                T mu, lam;
                zs::match([&](const auto &model) {
                    mu = model.mu;
                    lam = model.lam;
                })(zsprim.getModel().getElasticModel());
                return zs::make_tuple(mu, lam);
            }

            decltype(auto) getVerts() const {
                return verts;
            }
            decltype(auto) getEles() const {
                return eles;
            }
            decltype(auto) getSurfTris() const {
                return surfTris;
            }
            decltype(auto) getSurfEdges() const {
                return surfEdges;
            }
            decltype(auto) getSurfVerts() const {
                return surfVerts;
            }
            bool isBoundary() const noexcept {
                return zsprim.asBoundary;
            }

            ZenoParticles &zsprim;
            typename ZenoParticles::dtiles_t &verts;
            typename ZenoParticles::particles_t &eles;
            typename ZenoParticles::dtiles_t etemp;
            typename ZenoParticles::particles_t &surfTris;
            typename ZenoParticles::particles_t &surfEdges;
            // not required for codim obj
            typename ZenoParticles::particles_t &surfVerts;
            typename ZenoParticles::dtiles_t svtemp;
            const std::size_t vOffset, sfOffset, seOffset, svOffset;
            ZenoParticles::category_e category;
        };

        T averageNodalMass(zs::CudaExecutionPolicy &pol) {
            T sumNodalMass = 0;
            std::size_t sumNodes = 0;
            for (auto &&primHandle : prims) {
                if (primHandle.isBoundary())
                    continue;
                auto numNodes = primHandle.getVerts().size();
                sumNodes += numNodes;
                sumNodalMass += primHandle.averageNodalMass(pol) * numNodes;
            }
            if (sumNodes)
                return sumNodalMass / sumNodes;
            else
                return 0;
        }
        T averageSurfEdgeLength(zs::CudaExecutionPolicy &pol) {
            T sumSurfEdgeLengths = 0;
            std::size_t sumSE = 0;
            for (auto &&primHandle : prims) {
                auto numSE = primHandle.getSurfEdges().size();
                sumSE += numSE;
                sumSurfEdgeLengths += primHandle.averageSurfEdgeLength(pol) * numSE;
            }
            if (sumSE)
                return sumSurfEdgeLengths / sumSE;
            else
                return 0;
        }
        T averageSurfArea(zs::CudaExecutionPolicy &pol) {
            T sumSurfArea = 0;
            std::size_t sumSF = 0;
            for (auto &&primHandle : prims) {
                if (primHandle.category == ZenoParticles::curve)
                    continue;
                auto numSF = primHandle.getSurfTris().size();
                sumSF += numSF;
                sumSurfArea += primHandle.averageSurfArea(pol) * numSF;
            }
            if (sumSF)
                return sumSurfArea / sumSF;
            else
                return 0;
        }
        T largestMu() const {
            T mu = 0;
            for (auto &&primHandle : prims) {
                auto [m, l] = primHandle.getModelLameParams();
                if (m > mu)
                    mu = m;
            }
            return mu;
        }

        ///
        auto getCnts() const {
            return zs::make_tuple(nPP.getVal(), nPE.getVal(), nPT.getVal(), nEE.getVal(), nPPM.getVal(), nPEM.getVal(),
                                  nEEM.getVal(), ncsPT.getVal(), ncsEE.getVal());
        }
        void computeConstraints(zs::CudaExecutionPolicy &pol, const zs::SmallString &tag) {
            using namespace zs;
            constexpr auto space = execspace_e::cuda;
            pol(Collapse{numDofs}, [vtemp = proxy<space>({}, vtemp), tag] __device__(int vi) mutable {
                auto BCbasis = vtemp.pack<3, 3>("BCbasis", vi);
                auto BCtarget = vtemp.pack<3>("BCtarget", vi);
                int BCorder = vtemp("BCorder", vi);
                auto x = BCbasis.transpose() * vtemp.pack<3>(tag, vi);
                int d = 0;
                for (; d != BCorder; ++d)
                    vtemp("cons", d, vi) = x[d] - BCtarget[d];
                for (; d != 3; ++d)
                    vtemp("cons", d, vi) = 0;
            });
        }
        bool areConstraintsSatisfied(zs::CudaExecutionPolicy &pol) {
            using namespace zs;
            computeConstraints(pol, "xn");
            // auto res = infNorm(pol, vtemp, "cons");
            auto res = constraintResidual(pol);
            return res < 1e-2;
        }
        T checkDBCStatus(zs::CudaExecutionPolicy &pol) {
            using namespace zs;
            constexpr auto space = execspace_e::cuda;
            pol(Collapse{numDofs}, [vtemp = proxy<space>({}, vtemp)] __device__(int vi) mutable {
                int BCorder = vtemp("BCorder", vi);
                if (BCorder > 0) {
                    auto BCbasis = vtemp.pack<3, 3>("BCbasis", vi);
                    auto BCtarget = vtemp.pack<3>("BCtarget", vi);
                    auto cons = vtemp.pack<3>("cons", vi);
                    auto xt = vtemp.pack<3>("xhat", vi);
                    auto x = vtemp.pack<3>("xn", vi);
                    printf("%d-th vert (order [%d]): cur (%f, %f, %f) xt (%f, %f, %f)"
                           "\n\ttar(%f, %f, %f) cons (%f, %f, %f)\n",
                           vi, BCorder, (float)x[0], (float)x[1], (float)x[2], (float)xt[0], (float)xt[1], (float)xt[2],
                           (float)BCtarget[0], (float)BCtarget[1], (float)BCtarget[2], (float)cons[0], (float)cons[1],
                           (float)cons[2]);
                }
            });
        }
        T constraintResidual(zs::CudaExecutionPolicy &pol, bool maintainFixed = false) {
            using namespace zs;
            if (projectDBC)
                return 0;
            Vector<T> num{vtemp.get_allocator(), numDofs}, den{vtemp.get_allocator(), numDofs};
            constexpr auto space = execspace_e::cuda;
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
        void updateWholeBoundingBoxSize(zs::CudaExecutionPolicy &pol) const {
            using namespace zs;
            constexpr auto space = execspace_e::cuda;
#if 1
            bv_t bv = seBvh.getTotalBox(pol);
            if (coVerts.size()) {
                auto bouBv = bouSeBvh.getTotalBox(pol);
                merge(bv, bouBv._min);
                merge(bv, bouBv._max);
            }
#else
            bv_t bv = seBvh.gbv;
            if (coVerts.size()) {
                merge(bv, bouSeBvh.gbv._min);
                merge(bv, bouSeBvh.gbv._max);
            }
#endif
            boxDiagSize2 = (bv._max - bv._min).l2NormSqr();
        }

        void computeInertialGradient(zs::CudaExecutionPolicy &cudaPol, const zs::SmallString &gTag) {
            using namespace zs;
            constexpr auto space = execspace_e::cuda;
            for (auto &primHandle : prims) {
                auto &verts = primHandle.getVerts();
                cudaPol(range(verts.size()), [vtemp = proxy<space>({}, vtemp), verts = proxy<space>({}, verts), gTag,
                                              dt = dt, vOffset = primHandle.vOffset] __device__(int i) mutable {
                    auto m = verts("m", i);
                    int BCorder = vtemp("BCorder", vOffset + i);
                    if (BCorder != 3) {
                        // no need to neg
                        vtemp.tuple<3>(gTag, vOffset + i) =
                            -m * (vtemp.pack<3>("xn", vOffset + i) - vtemp.pack<3>("xtilde", vOffset + i));
                    }
                });
            }
        }
        void initKappa(zs::CudaExecutionPolicy &pol) {
            // should be called after dHat set
            if (!s_enableContact)
                return;
            using namespace zs;
            constexpr auto space = execspace_e::cuda;
            pol(zs::range(numDofs), [vtemp = proxy<space>({}, vtemp)] __device__(int i) mutable {
                vtemp.tuple<3>("p", i) = vec3::zeros();
                vtemp.tuple<3>("q", i) = vec3::zeros();
            });
            // inertial + elasticity
            computeInertialGradient(pol, "p");
            match([&](auto &elasticModel) { computeElasticGradientAndHessian(pol, elasticModel, "p", false); })(
                models.getElasticModel());
            // contacts
            findCollisionConstraints(pol, dHat, xi);
            auto prevKappa = kappa;
            kappa = 1;
            computeBarrierGradientAndHessian(pol, "q", false);
            computeBoundaryBarrierGradientAndHessian(pol, "q", false);
            kappa = prevKappa;

            auto gsum = dot(pol, vtemp, "p", "q");
            auto gsnorm = dot(pol, vtemp, "q", "q");
            if (gsnorm < limits<T>::min())
                kappaMin = 0;
            else
                kappaMin = -gsum / gsnorm;
            fmt::print("kappaMin: {}, gsum: {}, gsnorm: {}\n", kappaMin, gsum, gsnorm);
        }
        bool updateKappaRequired(zs::CudaExecutionPolicy &pol) {
            using namespace zs;
            constexpr auto space = execspace_e::cuda;
            return false; // disable this mechanism
            Vector<int> requireUpdate{vtemp.get_allocator(), 1};
            requireUpdate.setVal(0);
            // contacts
            {
                auto activeGap2 = dHat * dHat + 2 * xi * dHat;
                pol(range(prevNumPP),
                    [vtemp = proxy<space>({}, vtemp), tempPP = proxy<space>({}, tempPP),
                     requireUpdate = proxy<space>(requireUpdate), xi2 = xi * xi] __device__(int ppi) mutable {
                        auto pp = tempPP.template pack<2>("inds_pre", ppi).template reinterpret_bits<i64>();
                        auto x0 = vtemp.pack<3>("xn", pp[0]);
                        auto x1 = vtemp.pack<3>("xn", pp[1]);
                        auto dist2 = dist2_pp(x0, x1);
                        if (dist2 - xi2 < tempPP("dist2_pre", ppi))
                            requireUpdate[0] = 1;
                    });
                pol(range(prevNumPE),
                    [vtemp = proxy<space>({}, vtemp), tempPE = proxy<space>({}, tempPE),
                     requireUpdate = proxy<space>(requireUpdate), xi2 = xi * xi] __device__(int pei) mutable {
                        auto pe = tempPE.template pack<3>("inds_pre", pei).template reinterpret_bits<Ti>();
                        auto p = vtemp.pack<3>("xn", pe[0]);
                        auto e0 = vtemp.pack<3>("xn", pe[1]);
                        auto e1 = vtemp.pack<3>("xn", pe[2]);
                        auto dist2 = dist2_pe(p, e0, e1);
                        if (dist2 - xi2 < tempPE("dist2_pre", pei))
                            requireUpdate[0] = 1;
                    });
                pol(range(prevNumPT),
                    [vtemp = proxy<space>({}, vtemp), tempPT = proxy<space>({}, tempPT),
                     requireUpdate = proxy<space>(requireUpdate), xi2 = xi * xi] __device__(int pti) mutable {
                        auto pt = tempPT.template pack<4>("inds_pre", pti).template reinterpret_bits<Ti>();
                        auto p = vtemp.pack<3>("xn", pt[0]);
                        auto t0 = vtemp.pack<3>("xn", pt[1]);
                        auto t1 = vtemp.pack<3>("xn", pt[2]);
                        auto t2 = vtemp.pack<3>("xn", pt[3]);

                        auto dist2 = dist2_pt(p, t0, t1, t2);
                        if (dist2 - xi2 < tempPT("dist2_pre", pti))
                            requireUpdate[0] = 1;
                    });
                pol(range(prevNumEE),
                    [vtemp = proxy<space>({}, vtemp), tempEE = proxy<space>({}, tempEE),
                     requireUpdate = proxy<space>(requireUpdate), xi2 = xi * xi] __device__(int eei) mutable {
                        auto ee = tempEE.template pack<4>("inds_pre", eei).template reinterpret_bits<Ti>();
                        auto ea0 = vtemp.pack<3>("xn", ee[0]);
                        auto ea1 = vtemp.pack<3>("xn", ee[1]);
                        auto eb0 = vtemp.pack<3>("xn", ee[2]);
                        auto eb1 = vtemp.pack<3>("xn", ee[3]);

                        auto dist2 = dist2_ee(ea0, ea1, eb0, eb1);
                        if (dist2 - xi2 < tempEE("dist2_pre", eei))
                            requireUpdate[0] = 1;
                    });
            }
            return requireUpdate.getVal();
        }

        void findCollisionConstraints(zs::CudaExecutionPolicy &pol, T dHat, T xi = 0) {
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

            if (coVerts.size()) {
                auto triBvs = retrieve_bounding_volumes(pol, vtemp, "xn", coEles, zs::wrapv<3>{}, coOffset);
                bouStBvh.refit(pol, triBvs);
                auto edgeBvs = retrieve_bounding_volumes(pol, vtemp, "xn", coEdges, zs::wrapv<2>{}, coOffset);
                bouSeBvh.refit(pol, edgeBvs);
                findCollisionConstraintsImpl(pol, dHat, xi, true);
            }
        }
        void findCollisionConstraintsImpl(zs::CudaExecutionPolicy &pol, T dHat, T xi, bool withBoundary = false) {
            using namespace zs;
            constexpr auto space = execspace_e::cuda;

            /// pt
            pol(Collapse{svInds.size()},
                [svInds = proxy<space>({}, svInds), eles = proxy<space>({}, withBoundary ? coEles : stInds),
                 vtemp = proxy<space>({}, vtemp), bvh = proxy<space>(withBoundary ? bouStBvh : stBvh),
                 PP = proxy<space>(PP), nPP = proxy<space>(nPP), PE = proxy<space>(PE), nPE = proxy<space>(nPE),
                 PT = proxy<space>(PT), nPT = proxy<space>(nPT), csPT = proxy<space>(csPT), ncsPT = proxy<space>(ncsPT),
                 dHat, xi, thickness = xi + dHat, voffset = withBoundary ? coOffset : 0] __device__(int vi) mutable {
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
                [seInds = proxy<space>({}, seInds), sedges = proxy<space>({}, withBoundary ? coEdges : seInds),
                 vtemp = proxy<space>({}, vtemp), bvh = proxy<space>(withBoundary ? bouSeBvh : seBvh),
                 PP = proxy<space>(PP), nPP = proxy<space>(nPP), PE = proxy<space>(PE), nPE = proxy<space>(nPE),
                 EE = proxy<space>(EE), nEE = proxy<space>(nEE),
#if s_enableMollification
                 // mollifier
                 PPM = proxy<space>(PPM), nPPM = proxy<space>(nPPM), PEM = proxy<space>(PEM), nPEM = proxy<space>(nPEM),
                 EEM = proxy<space>(EEM), nEEM = proxy<space>(nEEM),
#endif
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

#if s_enableMollification
                        // IPC (24)
                        T c = cn2_ee(v0, v1, v2, v3);
                        T epsX = mollifier_threshold_ee(rv0, rv1, rv2, rv3);
                        bool mollify = c < epsX;
#endif

                        switch (ee_distance_type(v0, v1, v2, v3)) {
                        case 0: {
                            if (auto d2 = dist2_pp(v0, v2); d2 < dHat2) {
                                csEE[atomic_add(exec_cuda, &ncsEE[0], 1)] =
                                    pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
#if s_enableMollification
                                if (mollify) {
                                    auto no = atomic_add(exec_cuda, &nPPM[0], 1);
                                    PPM[no] = pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
                                    break;
                                }
#endif
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
                                csEE[atomic_add(exec_cuda, &ncsEE[0], 1)] =
                                    pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
#if s_enableMollification
                                if (mollify) {
                                    auto no = atomic_add(exec_cuda, &nPPM[0], 1);
                                    PPM[no] = pair4_t{eiInds[0], eiInds[1], ejInds[1], ejInds[0]};
                                    break;
                                }
#endif
                                {
                                    auto no = atomic_add(exec_cuda, &nPP[0], 1);
                                    PP[no] = pair_t{eiInds[0], ejInds[1]};
                                }
                            }
                            break;
                        }
                        case 2: {
                            if (auto d2 = dist2_pe(v0, v2, v3); d2 < dHat2) {
                                csEE[atomic_add(exec_cuda, &ncsEE[0], 1)] =
                                    pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
#if s_enableMollification
                                if (mollify) {
                                    auto no = atomic_add(exec_cuda, &nPEM[0], 1);
                                    PEM[no] = pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
                                    break;
                                }
#endif
                                {
                                    auto no = atomic_add(exec_cuda, &nPE[0], 1);
                                    PE[no] = pair3_t{eiInds[0], ejInds[0], ejInds[1]};
                                }
                            }
                            break;
                        }
                        case 3: {
                            if (auto d2 = dist2_pp(v1, v2); d2 < dHat2) {
                                csEE[atomic_add(exec_cuda, &ncsEE[0], 1)] =
                                    pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
#if s_enableMollification
                                if (mollify) {
                                    auto no = atomic_add(exec_cuda, &nPPM[0], 1);
                                    PPM[no] = pair4_t{eiInds[1], eiInds[0], ejInds[0], ejInds[1]};
                                    break;
                                }
#endif
                                {
                                    auto no = atomic_add(exec_cuda, &nPP[0], 1);
                                    PP[no] = pair_t{eiInds[1], ejInds[0]};
                                }
                            }
                            break;
                        }
                        case 4: {
                            if (auto d2 = dist2_pp(v1, v3); d2 < dHat2) {
                                csEE[atomic_add(exec_cuda, &ncsEE[0], 1)] =
                                    pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
#if s_enableMollification
                                if (mollify) {
                                    auto no = atomic_add(exec_cuda, &nPPM[0], 1);
                                    PPM[no] = pair4_t{eiInds[1], eiInds[0], ejInds[1], ejInds[0]};
                                    break;
                                }
#endif
                                {
                                    auto no = atomic_add(exec_cuda, &nPP[0], 1);
                                    PP[no] = pair_t{eiInds[1], ejInds[1]};
                                }
                            }
                            break;
                        }
                        case 5: {
                            if (auto d2 = dist2_pe(v1, v2, v3); d2 < dHat2) {
                                csEE[atomic_add(exec_cuda, &ncsEE[0], 1)] =
                                    pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
#if s_enableMollification
                                if (mollify) {
                                    auto no = atomic_add(exec_cuda, &nPEM[0], 1);
                                    PEM[no] = pair4_t{eiInds[1], eiInds[0], ejInds[0], ejInds[1]};
                                    break;
                                }
#endif
                                {
                                    auto no = atomic_add(exec_cuda, &nPE[0], 1);
                                    PE[no] = pair3_t{eiInds[1], ejInds[0], ejInds[1]};
                                }
                            }
                            break;
                        }
                        case 6: {
                            if (auto d2 = dist2_pe(v2, v0, v1); d2 < dHat2) {
                                csEE[atomic_add(exec_cuda, &ncsEE[0], 1)] =
                                    pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
#if s_enableMollification
                                if (mollify) {
                                    auto no = atomic_add(exec_cuda, &nPEM[0], 1);
                                    PEM[no] = pair4_t{ejInds[0], ejInds[1], eiInds[0], eiInds[1]};
                                    break;
                                }
#endif
                                {
                                    auto no = atomic_add(exec_cuda, &nPE[0], 1);
                                    PE[no] = pair3_t{ejInds[0], eiInds[0], eiInds[1]};
                                }
                            }
                            break;
                        }
                        case 7: {
                            if (auto d2 = dist2_pe(v3, v0, v1); d2 < dHat2) {
                                csEE[atomic_add(exec_cuda, &ncsEE[0], 1)] =
                                    pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
#if s_enableMollification
                                if (mollify) {
                                    auto no = atomic_add(exec_cuda, &nPEM[0], 1);
                                    PEM[no] = pair4_t{ejInds[1], ejInds[0], eiInds[0], eiInds[1]};
                                    break;
                                }
#endif
                                {
                                    auto no = atomic_add(exec_cuda, &nPE[0], 1);
                                    PE[no] = pair3_t{ejInds[1], eiInds[0], eiInds[1]};
                                }
                            }
                            break;
                        }
                        case 8: {
                            if (auto d2 = dist2_ee(v0, v1, v2, v3); d2 < dHat2) {
                                csEE[atomic_add(exec_cuda, &ncsEE[0], 1)] =
                                    pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
#if s_enableMollification
                                if (mollify) {
                                    auto no = atomic_add(exec_cuda, &nEEM[0], 1);
                                    EEM[no] = pair4_t{eiInds[0], eiInds[1], ejInds[0], ejInds[1]};
                                    break;
                                }
#endif
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
        void precomputeFrictions(zs::CudaExecutionPolicy &pol, T dHat, T xi = 0) {
            using namespace zs;
            constexpr auto space = execspace_e::cuda;
            T activeGap2 = dHat * dHat + (T)2.0 * xi * dHat;
            nFPP.setVal(0);
            nFPE.setVal(0);
            nFPT.setVal(0);
            nFEE.setVal(0);
#if s_enableContact
#if s_enableSelfFriction
            nFPP = nPP;
            nFPE = nPE;
            nFPT = nPT;
            nFEE = nEE;

#if 1
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
#endif
#if 1
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
#endif
#if 1
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
#endif
#if 1
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
#endif
#endif
#endif
            if (s_enableGround) {
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
        bool checkSelfIntersection(zs::CudaExecutionPolicy &pol) {
            using namespace zs;
            constexpr auto space = execspace_e::cuda;
            const auto dHat2 = dHat * dHat;
            zs::Vector<int> intersected{vtemp.get_allocator(), 1};
            intersected.setVal(0);
            // self
            {
                auto edgeBvs = retrieve_bounding_volumes(pol, vtemp, "xn", seInds, zs::wrapv<2>{}, 0);
                bvh_t seBvh;
                seBvh.refit(pol, edgeBvs);
                pol(Collapse{stInds.size()}, [stInds = proxy<space>({}, stInds), seInds = proxy<space>({}, seInds),
                                              vtemp = proxy<space>({}, vtemp), intersected = proxy<space>(intersected),
                                              bvh = proxy<space>(seBvh)] __device__(int sti) mutable {
                    auto tri = stInds.template pack<3>("inds", sti).template reinterpret_bits<int>();
                    auto t0 = vtemp.pack<3>("xn", tri[0]);
                    auto t1 = vtemp.pack<3>("xn", tri[1]);
                    auto t2 = vtemp.pack<3>("xn", tri[2]);
                    auto bv = bv_t{get_bounding_box(t0, t1)};
                    merge(bv, t2);
                    bool allFixed =
                        vtemp("BCorder", tri[0]) == 3 && vtemp("BCorder", tri[1]) == 3 && vtemp("BCorder", tri[2]) == 3;
                    bvh.iter_neighbors(bv, [&](int sei) {
                        auto line = seInds.template pack<2>("inds", sei).template reinterpret_bits<int>();
                        if (tri[0] == line[0] || tri[0] == line[1] || tri[1] == line[0] || tri[1] == line[1] ||
                            tri[2] == line[0] || tri[2] == line[1])
                            return;
                        // ignore intersection under sticky boundary conditions
                        if (allFixed && vtemp("BCorder", line[0]) == 3 && vtemp("BCorder", line[1]) == 3)
                            return;
                        // ccd
                        if (et_intersected(vtemp.pack<3>("xn", line[0]), vtemp.pack<3>("xn", line[1]), t0, t1, t2))
                            if (intersected[0] == 0)
                                intersected[0] = 1;
                        // atomic_cas(exec_cuda, &intersected[0], 0, 1);
                    });
                });
            }
            // boundary
            {
                auto edgeBvs = retrieve_bounding_volumes(pol, vtemp, "xn", coEdges, zs::wrapv<2>{}, coOffset);
                bvh_t seBvh;
                seBvh.refit(pol, edgeBvs);
                pol(Collapse{stInds.size()}, [stInds = proxy<space>({}, stInds), coEdges = proxy<space>({}, coEdges),
                                              vtemp = proxy<space>({}, vtemp), intersected = proxy<space>(intersected),
                                              bvh = proxy<space>(seBvh),
                                              coOffset = coOffset] __device__(int sti) mutable {
                    auto tri = stInds.template pack<3>("inds", sti).template reinterpret_bits<int>();
                    auto t0 = vtemp.pack<3>("xn", tri[0]);
                    auto t1 = vtemp.pack<3>("xn", tri[1]);
                    auto t2 = vtemp.pack<3>("xn", tri[2]);
                    auto bv = bv_t{get_bounding_box(t0, t1)};
                    merge(bv, t2);
                    bool allFixed =
                        vtemp("BCorder", tri[0]) == 3 && vtemp("BCorder", tri[1]) == 3 && vtemp("BCorder", tri[2]) == 3;
                    bvh.iter_neighbors(bv, [&](int sei) {
                        auto line = coEdges.template pack<2>("inds", sei).template reinterpret_bits<int>() + coOffset;
                        // ignore intersection under sticky boundary conditions
                        if (allFixed && vtemp("BCorder", line[0]) == 3 && vtemp("BCorder", line[1]) == 3)
                            return;
                        // ccd
                        if (et_intersected(vtemp.pack<3>("xn", line[0]), vtemp.pack<3>("xn", line[1]), t0, t1, t2))
                            if (intersected[0] == 0)
                                intersected[0] = 1;
                        // atomic_cas(exec_cuda, &intersected[0], 0, 1);
                    });
                });
            }
            return intersected.getVal();
        }
        void findCCDConstraints(zs::CudaExecutionPolicy &pol, T alpha, T xi = 0) {
            ncsPT.setVal(0);
            ncsEE.setVal(0);
            {
                auto triBvs =
                    retrieve_bounding_volumes(pol, vtemp, "xn", stInds, zs::wrapv<3>{}, vtemp, "dir", alpha, 0);
                stBvh.refit(pol, triBvs);
                auto edgeBvs =
                    retrieve_bounding_volumes(pol, vtemp, "xn", seInds, zs::wrapv<2>{}, vtemp, "dir", alpha, 0);
                seBvh.refit(pol, edgeBvs);
            }
            findCCDConstraintsImpl(pol, alpha, xi, false);

            if (coVerts.size()) {
                auto triBvs =
                    retrieve_bounding_volumes(pol, vtemp, "xn", coEles, zs::wrapv<3>{}, vtemp, "dir", alpha, coOffset);
                bouStBvh.refit(pol, triBvs);
                auto edgeBvs =
                    retrieve_bounding_volumes(pol, vtemp, "xn", coEdges, zs::wrapv<2>{}, vtemp, "dir", alpha, coOffset);
                bouSeBvh.refit(pol, edgeBvs);
                findCCDConstraintsImpl(pol, alpha, xi, true);
            }
        }
        void findCCDConstraintsImpl(zs::CudaExecutionPolicy &pol, T alpha, T xi, bool withBoundary = false) {
            using namespace zs;
            constexpr auto space = execspace_e::cuda;
            const auto dHat2 = dHat * dHat;

            /// pt
            pol(Collapse{svInds.size()},
                [svInds = proxy<space>({}, svInds), eles = proxy<space>({}, withBoundary ? coEles : stInds),
                 vtemp = proxy<space>({}, vtemp), bvh = proxy<space>(withBoundary ? bouStBvh : stBvh),
                 PP = proxy<space>(PP), nPP = proxy<space>(nPP), PE = proxy<space>(PE), nPE = proxy<space>(nPE),
                 PT = proxy<space>(PT), nPT = proxy<space>(nPT), csPT = proxy<space>(csPT), ncsPT = proxy<space>(ncsPT),
                 xi, alpha, voffset = withBoundary ? coOffset : 0] __device__(int vi) mutable {
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
                        if (vtemp("BCorder", vi) == 3 && vtemp("BCorder", tri[0]) == 3 &&
                            vtemp("BCorder", tri[1]) == 3 && vtemp("BCorder", tri[2]) == 3)
                            return;
                        csPT[atomic_add(exec_cuda, &ncsPT[0], 1)] = pair4_t{vi, tri[0], tri[1], tri[2]};
                    });
                });
            /// ee
            pol(Collapse{seInds.size()},
                [seInds = proxy<space>({}, seInds), sedges = proxy<space>({}, withBoundary ? coEdges : seInds),
                 vtemp = proxy<space>({}, vtemp), bvh = proxy<space>(withBoundary ? bouSeBvh : seBvh),
                 PP = proxy<space>(PP), nPP = proxy<space>(nPP), PE = proxy<space>(PE), nPE = proxy<space>(nPE),
                 EE = proxy<space>(PT), nEE = proxy<space>(nPT), csEE = proxy<space>(csEE), ncsEE = proxy<space>(ncsEE),
                 xi, alpha, voffset = withBoundary ? coOffset : 0] __device__(int sei) mutable {
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
        ///
        void computeBarrierGradientAndHessian(zs::CudaExecutionPolicy &pol, const zs::SmallString &gTag = "grad",
                                              bool includeHessian = true);
        void computeFrictionBarrierGradientAndHessian(zs::CudaExecutionPolicy &pol,
                                                      const zs::SmallString &gTag = "grad", bool includeHessian = true);

        void intersectionFreeStepsize(zs::CudaExecutionPolicy &pol, T xi, T &stepSize) {
            using namespace zs;
            constexpr auto space = execspace_e::cuda;

            Vector<T> alpha{vtemp.get_allocator(), 1};
            alpha.setVal(stepSize);
            auto npt = ncsPT.getVal();
            pol(range(npt), [csPT = proxy<space>(csPT), vtemp = proxy<space>({}, vtemp), alpha = proxy<space>(alpha),
                             stepSize, xi, coOffset = (int)coOffset] __device__(int pti) {
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
            pol(range(nee), [csEE = proxy<space>(csEE), vtemp = proxy<space>({}, vtemp), alpha = proxy<space>(alpha),
                             stepSize, xi, coOffset = (int)coOffset] __device__(int eei) {
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
        void groundIntersectionFreeStepsize(zs::CudaExecutionPolicy &pol, T &stepSize) {
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
        ///
        void computeBoundaryBarrierGradientAndHessian(zs::CudaExecutionPolicy &pol,
                                                      const zs::SmallString &gTag = "grad",
                                                      bool includeHessian = true) {
            using namespace zs;
            constexpr auto space = execspace_e::cuda;
            for (auto &primHandle : prims) {
                if (primHandle.isBoundary()) // skip soft boundary
                    continue;
                const auto &svs = primHandle.getSurfVerts();
                pol(range(svs.size()), [vtemp = proxy<space>({}, vtemp), svtemp = proxy<space>({}, primHandle.svtemp),
                                        svs = proxy<space>({}, svs), gTag, gn = s_groundNormal, dHat2 = dHat * dHat,
                                        kappa = kappa, projectDBC = projectDBC, includeHessian,
                                        svOffset = primHandle.svOffset] ZS_LAMBDA(int svi) mutable {
                    const auto vi = reinterpret_bits<int>(svs("inds", svi)) + svOffset;
                    auto x = vtemp.pack<3>("xn", vi);
                    auto dist = gn.dot(x);
                    auto dist2 = dist * dist;
                    auto t = dist2 - dHat2;
                    auto g_b = t * zs::log(dist2 / dHat2) * -2 - (t * t) / dist2;
                    auto H_b = (zs::log(dist2 / dHat2) * -2.0 - t * 4.0 / dist2) + 1.0 / (dist2 * dist2) * (t * t);
                    if (dist2 < dHat2) {
                        auto grad = -gn * (kappa * g_b * 2 * dist);
                        for (int d = 0; d != 3; ++d)
                            atomic_add(exec_cuda, &vtemp(gTag, d, vi), grad(d));
                    }

                    if (!includeHessian)
                        return;
                    auto param = 4 * H_b * dist2 + 2 * g_b;
                    auto hess = mat3::zeros();
                    if (dist2 < dHat2 && param > 0) {
                        auto nn = dyadic_prod(gn, gn);
                        hess = (kappa * param) * nn;
                    }

                    // make_pd(hess);
                    mat3 BCbasis[1] = {vtemp.pack<3, 3>("BCbasis", vi)};
                    int BCorder[1] = {(int)vtemp("BCorder", vi)};
                    int BCfixed[1] = {(int)vtemp("BCfixed", vi)};
                    rotate_hessian(hess, BCbasis, BCorder, BCfixed, projectDBC);
                    svtemp.tuple<9>("H", svi) = hess;
                    for (int i = 0; i != 3; ++i)
                        for (int j = 0; j != 3; ++j) {
                            atomic_add(exec_cuda, &vtemp("P", i * 3 + j, vi), hess(i, j));
                        }
                });

#if s_enableFriction
                if (fricMu != 0) {
                    pol(range(svs.size()),
                        [vtemp = proxy<space>({}, vtemp), svtemp = proxy<space>({}, primHandle.svtemp),
                         svs = proxy<space>({}, svs), gTag, epsvh = epsv * dt, gn = s_groundNormal, fricMu = fricMu,
                         projectDBC = projectDBC, includeHessian,
                         svOffset = primHandle.svOffset] ZS_LAMBDA(int svi) mutable {
                            const auto vi = reinterpret_bits<int>(svs("inds", svi)) + svOffset;
                            auto dx = vtemp.pack<3>("xn", vi) - vtemp.pack<3>("xhat", vi);
                            auto fn = svtemp("fn", svi);
                            if (fn == 0) {
                                return;
                            }
                            auto coeff = fn * fricMu;
                            auto relDX = dx - gn.dot(dx) * gn;
                            auto relDXNorm2 = relDX.l2NormSqr();
                            auto relDXNorm = zs::sqrt(relDXNorm2);

                            vec3 grad{};
                            if (relDXNorm2 > epsvh * epsvh)
                                grad = -relDX * (coeff / relDXNorm);
                            else
                                grad = -relDX * (coeff / epsvh);
                            for (int d = 0; d != 3; ++d)
                                atomic_add(exec_cuda, &vtemp(gTag, d, vi), grad(d));

                            if (!includeHessian)
                                return;

                            auto hess = mat3::zeros();
                            if (relDXNorm2 > epsvh * epsvh) {
                                zs::vec<T, 2, 2> mat{
                                    relDX[0] * relDX[0] * -coeff / relDXNorm2 / relDXNorm + coeff / relDXNorm,
                                    relDX[0] * relDX[2] * -coeff / relDXNorm2 / relDXNorm,
                                    relDX[0] * relDX[2] * -coeff / relDXNorm2 / relDXNorm,
                                    relDX[2] * relDX[2] * -coeff / relDXNorm2 / relDXNorm + coeff / relDXNorm};
                                make_pd(mat);
                                hess(0, 0) = mat(0, 0);
                                hess(0, 2) = mat(0, 1);
                                hess(2, 0) = mat(1, 0);
                                hess(2, 2) = mat(1, 1);
                            } else {
                                hess(0, 0) = coeff / epsvh;
                                hess(2, 2) = coeff / epsvh;
                            }

                            mat3 BCbasis[1] = {vtemp.pack<3, 3>("BCbasis", vi)};
                            int BCorder[1] = {(int)vtemp("BCorder", vi)};
                            int BCfixed[1] = {(int)vtemp("BCfixed", vi)};
                            rotate_hessian(hess, BCbasis, BCorder, BCfixed, projectDBC);
                            svtemp.template tuple<9>("H", svi) = svtemp.template pack<3, 3>("H", svi) + hess;
                            for (int i = 0; i != 3; ++i)
                                for (int j = 0; j != 3; ++j) {
                                    atomic_add(exec_cuda, &vtemp("P", i * 3 + j, vi), hess(i, j));
                                }
                        });
                }
#endif
            }
            return;
        }
        template <typename Model>
        void computeElasticGradientAndHessian(zs::CudaExecutionPolicy &cudaPol, const Model &model,
                                              const zs::SmallString &gTag = "grad", bool includeHessian = true) {
            using namespace zs;
            constexpr auto space = execspace_e::cuda;
            for (auto &primHandle : prims)
                if (primHandle.category == ZenoParticles::curve) {
                    if (primHandle.isBoundary())
                        continue;
                    /// ref: Fast Simulation of Mass-Spring Systems
                    /// credits: Tiantian Liu
                    cudaPol(
                        zs::range(primHandle.getEles().size()),
                        [vtemp = proxy<space>({}, vtemp), etemp = proxy<space>({}, primHandle.etemp),
                         eles = proxy<space>({}, primHandle.getEles()), model, gTag, dt = this->dt,
                         projectDBC = projectDBC, vOffset = primHandle.vOffset, includeHessian,
                         n = primHandle.getEles().size()] __device__(int ei) mutable {
                            auto inds = eles.template pack<2>("inds", ei).template reinterpret_bits<int>() + vOffset;
                            mat3 BCbasis[2];
                            int BCorder[2];
                            int BCfixed[2];
                            for (int i = 0; i != 2; ++i) {
                                BCbasis[i] = vtemp.pack<3, 3>("BCbasis", inds[i]);
                                BCorder[i] = vtemp("BCorder", inds[i]);
                                BCfixed[i] = vtemp("BCfixed", inds[i]);
                            }

                            if (BCorder[0] == 3 && BCorder[1] == 3) {
                                etemp.tuple<6 * 6>("He", ei) = zs::vec<T, 6, 6>::zeros();
                                return;
                            }

                            auto vole = eles("vol", ei);
                            auto k = eles("k", ei);
                            auto rl = eles("rl", ei);

                            vec3 xs[2] = {vtemp.template pack<3>("xn", inds[0]), vtemp.template pack<3>("xn", inds[1])};
                            auto xij = xs[1] - xs[0];
                            auto lij = xij.norm();
                            auto dij = xij / lij;
                            auto gij = k * (lij - rl) * dij;

                            // gradient
                            auto vfdt2 = gij * (dt * dt) * vole;
                            for (int d = 0; d != 3; ++d) {
                                atomic_add(exec_cuda, &vtemp(gTag, d, inds[0]), (T)vfdt2(d));
                                atomic_add(exec_cuda, &vtemp(gTag, d, inds[1]), (T)-vfdt2(d));
                            }

                            if (!includeHessian)
                                return;
                            auto H = zs::vec<T, 6, 6>::zeros();
                            auto K = k * (mat3::identity() - rl / lij * (mat3::identity() - dyadic_prod(dij, dij)));
                            // make_pd(K);  // symmetric semi-definite positive, not
                            // necessary

                            for (int i = 0; i != 3; ++i)
                                for (int j = 0; j != 3; ++j) {
                                    H(i, j) = K(i, j);
                                    H(i, 3 + j) = -K(i, j);
                                    H(3 + i, j) = -K(i, j);
                                    H(3 + i, 3 + j) = K(i, j);
                                }
                            H *= dt * dt * vole;

                            // rotate and project
                            rotate_hessian(H, BCbasis, BCorder, BCfixed, projectDBC);
                            etemp.tuple<6 * 6>("He", ei) = H;
                            for (int vi = 0; vi != 2; ++vi) {
                                for (int i = 0; i != 3; ++i)
                                    for (int j = 0; j != 3; ++j) {
                                        atomic_add(exec_cuda, &vtemp("P", i * 3 + j, inds[vi]),
                                                   H(vi * 3 + i, vi * 3 + j));
                                    }
                            }
                        });
                } else if (primHandle.category == ZenoParticles::surface) {
                    if (primHandle.isBoundary())
                        continue;
                    cudaPol(zs::range(primHandle.getEles().size()), [vtemp = proxy<space>({}, vtemp),
                                                                     etemp = proxy<space>({}, primHandle.etemp),
                                                                     eles = proxy<space>({}, primHandle.getEles()),
                                                                     model, gTag, dt = this->dt,
                                                                     projectDBC = projectDBC,
                                                                     vOffset = primHandle.vOffset,
                                                                     includeHessian] __device__(int ei) mutable {
                        auto IB = eles.template pack<2, 2>("IB", ei);
                        auto inds = eles.template pack<3>("inds", ei).template reinterpret_bits<int>() + vOffset;
                        auto vole = eles("vol", ei);
                        vec3 xs[3] = {vtemp.template pack<3>("xn", inds[0]), vtemp.template pack<3>("xn", inds[1]),
                                      vtemp.template pack<3>("xn", inds[2])};
                        auto x1x0 = xs[1] - xs[0];
                        auto x2x0 = xs[2] - xs[0];

                        mat3 BCbasis[3];
                        int BCorder[3];
                        int BCfixed[3];
                        for (int i = 0; i != 3; ++i) {
                            BCbasis[i] = vtemp.pack<3, 3>("BCbasis", inds[i]);
                            BCorder[i] = vtemp("BCorder", inds[i]);
                            BCfixed[i] = vtemp("BCfixed", inds[i]);
                        }
                        zs::vec<T, 9, 9> H;
                        if (BCorder[0] == 3 && BCorder[1] == 3 && BCorder[2] == 3) {
                            etemp.tuple<9 * 9>("He", ei) = H.zeros();
                            return;
                        }

                        zs::vec<T, 3, 2> Ds{x1x0[0], x2x0[0], x1x0[1], x2x0[1], x1x0[2], x2x0[2]};
                        auto F = Ds * IB;

                        auto dFdX = dFdXMatrix(IB, wrapv<3>{});
                        auto dFdXT = dFdX.transpose();
                        auto f0 = col(F, 0);
                        auto f1 = col(F, 1);
                        auto f0Norm = zs::sqrt(f0.l2NormSqr());
                        auto f1Norm = zs::sqrt(f1.l2NormSqr());
                        auto f0Tf1 = f0.dot(f1);
                        zs::vec<T, 3, 2> Pstretch, Pshear;
                        for (int d = 0; d != 3; ++d) {
                            Pstretch(d, 0) = 2 * (1 - 1 / f0Norm) * F(d, 0);
                            Pstretch(d, 1) = 2 * (1 - 1 / f1Norm) * F(d, 1);
                            Pshear(d, 0) = 2 * f0Tf1 * f1(d);
                            Pshear(d, 1) = 2 * f0Tf1 * f0(d);
                        }
                        auto vecP = flatten(model.mu * Pstretch + (model.mu * 0.3) * Pshear);
                        auto vfdt2 = -vole * (dFdXT * vecP) * (dt * dt);

                        for (int i = 0; i != 3; ++i) {
                            auto vi = inds[i];
                            for (int d = 0; d != 3; ++d)
                                atomic_add(exec_cuda, &vtemp(gTag, d, vi), (T)vfdt2(i * 3 + d));
                        }

                        if (!includeHessian)
                            return;
                        /// ref: A Finite Element Formulation of Baraff-Witkin Cloth
                        // suggested by huang kemeng
                        auto stretchHessian = [&F, &model]() {
                            auto H = zs::vec<T, 6, 6>::zeros();
                            const zs::vec<T, 2> u{1, 0};
                            const zs::vec<T, 2> v{0, 1};
                            const T I5u = (F * u).l2NormSqr();
                            const T I5v = (F * v).l2NormSqr();
                            const T invSqrtI5u = (T)1 / zs::sqrt(I5u);
                            const T invSqrtI5v = (T)1 / zs::sqrt(I5v);

                            H(0, 0) = H(1, 1) = H(2, 2) = zs::max(1 - invSqrtI5u, (T)0);
                            H(3, 3) = H(4, 4) = H(5, 5) = zs::max(1 - invSqrtI5v, (T)0);

                            const auto fu = col(F, 0).normalized();
                            const T uCoeff = (1 - invSqrtI5u >= 0) ? invSqrtI5u : (T)1;
                            for (int i = 0; i != 3; ++i)
                                for (int j = 0; j != 3; ++j)
                                    H(i, j) += uCoeff * fu(i) * fu(j);

                            const auto fv = col(F, 1).normalized();
                            const T vCoeff = (1 - invSqrtI5v >= 0) ? invSqrtI5v : (T)1;
                            for (int i = 0; i != 3; ++i)
                                for (int j = 0; j != 3; ++j)
                                    H(3 + i, 3 + j) += vCoeff * fv(i) * fv(j);

                            H *= model.mu;
                            return H;
                        };
                        auto shearHessian = [&F, &model]() {
                            using mat6 = zs::vec<T, 6, 6>;
                            auto H = mat6::zeros();
                            const zs::vec<T, 2> u{1, 0};
                            const zs::vec<T, 2> v{0, 1};
                            const T I6 = (F * u).dot(F * v);
                            const T signI6 = I6 >= 0 ? 1 : -1;

                            H(3, 0) = H(4, 1) = H(5, 2) = H(0, 3) = H(1, 4) = H(2, 5) = (T)1;

                            const auto g_ = F * (dyadic_prod(u, v) + dyadic_prod(v, u));
                            zs::vec<T, 6> g{};
                            for (int j = 0, offset = 0; j != 2; ++j) {
                                for (int i = 0; i != 3; ++i)
                                    g(offset++) = g_(i, j);
                            }

                            const T I2 = F.l2NormSqr();
                            const T lambda0 = (T)0.5 * (I2 + zs::sqrt(I2 * I2 + (T)12 * I6 * I6));

                            const zs::vec<T, 6> q0 = (I6 * H * g + lambda0 * g).normalized();

                            auto t = mat6::identity();
                            t = 0.5 * (t + signI6 * H);

                            const zs::vec<T, 6> Tq = t * q0;
                            const auto normTq = Tq.l2NormSqr();

                            mat6 dPdF =
                                zs::abs(I6) * (t - (dyadic_prod(Tq, Tq) / normTq)) + lambda0 * (dyadic_prod(q0, q0));
                            dPdF *= (model.mu * 0.3);
                            return dPdF;
                        };
                        auto He = stretchHessian() + shearHessian();
                        H = dFdX.transpose() * He * dFdX;
                        H *= dt * dt * vole;

                        // rotate and project
                        rotate_hessian(H, BCbasis, BCorder, BCfixed, projectDBC);
                        etemp.tuple<9 * 9>("He", ei) = H;
                        for (int vi = 0; vi != 3; ++vi) {
                            for (int i = 0; i != 3; ++i)
                                for (int j = 0; j != 3; ++j) {
                                    atomic_add(exec_cuda, &vtemp("P", i * 3 + j, inds[vi]), H(vi * 3 + i, vi * 3 + j));
                                }
                        }
                    });
                } else if (primHandle.category == ZenoParticles::tet)
                    cudaPol(zs::range(primHandle.getEles().size()),
                            [vtemp = proxy<space>({}, vtemp), etemp = proxy<space>({}, primHandle.etemp),
                             eles = proxy<space>({}, primHandle.getEles()), model, gTag, dt = this->dt,
                             projectDBC = projectDBC, vOffset = primHandle.vOffset,
                             includeHessian] __device__(int ei) mutable {
                                auto IB = eles.template pack<3, 3>("IB", ei);
                                auto inds =
                                    eles.template pack<4>("inds", ei).template reinterpret_bits<int>() + vOffset;
                                auto vole = eles("vol", ei);
                                vec3 xs[4] = {vtemp.pack<3>("xn", inds[0]), vtemp.pack<3>("xn", inds[1]),
                                              vtemp.pack<3>("xn", inds[2]), vtemp.pack<3>("xn", inds[3])};

                                mat3 BCbasis[4];
                                int BCorder[4];
                                int BCfixed[4];
                                for (int i = 0; i != 4; ++i) {
                                    BCbasis[i] = vtemp.pack<3, 3>("BCbasis", inds[i]);
                                    BCorder[i] = vtemp("BCorder", inds[i]);
                                    BCfixed[i] = vtemp("BCfixed", inds[i]);
                                }
                                zs::vec<T, 12, 12> H;
                                if (BCorder[0] == 3 && BCorder[1] == 3 && BCorder[2] == 3 && BCorder[3] == 3) {
                                    etemp.tuple<12 * 12>("He", ei) = H.zeros();
                                    return;
                                }
                                mat3 F{};
                                {
                                    auto x1x0 = xs[1] - xs[0];
                                    auto x2x0 = xs[2] - xs[0];
                                    auto x3x0 = xs[3] - xs[0];
                                    auto Ds = mat3{x1x0[0], x2x0[0], x3x0[0], x1x0[1], x2x0[1],
                                                   x3x0[1], x1x0[2], x2x0[2], x3x0[2]};
                                    F = Ds * IB;
                                }
                                auto P = model.first_piola(F);
                                auto vecP = flatten(P);
                                auto dFdX = dFdXMatrix(IB);
                                auto dFdXT = dFdX.transpose();
                                auto vfdt2 = -vole * (dFdXT * vecP) * dt * dt;

                                for (int i = 0; i != 4; ++i) {
                                    auto vi = inds[i];
                                    for (int d = 0; d != 3; ++d)
                                        atomic_add(exec_cuda, &vtemp(gTag, d, vi), (T)vfdt2(i * 3 + d));
                                }

                                if (!includeHessian)
                                    return;
                                auto Hq = model.first_piola_derivative(F, true_c);
                                H = dFdXT * Hq * dFdX * vole * dt * dt;

                                // rotate and project
                                rotate_hessian(H, BCbasis, BCorder, BCfixed, projectDBC);
                                etemp.tuple<12 * 12>("He", ei) = H;
                                for (int vi = 0; vi != 4; ++vi) {
                                    for (int i = 0; i != 3; ++i)
                                        for (int j = 0; j != 3; ++j) {
                                            atomic_add(exec_cuda, &vtemp("P", i * 3 + j, inds[vi]),
                                                       H(vi * 3 + i, vi * 3 + j));
                                        }
                                }
                            });
        }
        void computeInertialAndGravityPotentialGradient(zs::CudaExecutionPolicy &cudaPol,
                                                        const zs::SmallString &gTag = "grad") {
            using namespace zs;
            constexpr auto space = execspace_e::cuda;
            // inertial
            cudaPol(zs::range(coOffset), [tempPB = proxy<space>({}, tempPB), vtemp = proxy<space>({}, vtemp), gTag,
                                          dt = dt, projectDBC = projectDBC] __device__(int i) mutable {
                auto m = zs::sqr(vtemp("ws", i));
                vtemp.tuple<3>(gTag, i) =
                    vtemp.pack<3>(gTag, i) - m * (vtemp.pack<3>("xn", i) - vtemp.pack<3>("xtilde", i));

                auto M = mat3::identity() * m;
                mat3 BCbasis[1] = {vtemp.template pack<3, 3>("BCbasis", i)};
                int BCorder[1] = {(int)vtemp("BCorder", i)};
                int BCfixed[1] = {(int)vtemp("BCfixed", i)};
                rotate_hessian(M, BCbasis, BCorder, BCfixed, projectDBC);
                tempPB.template tuple<9>("Hi", i) = M;
                // prepare preconditioner
                for (int r = 0; r != 3; ++r)
                    for (int c = 0; c != 3; ++c)
                        vtemp("P", r * 3 + c, i) += M(r, c);
            });
            // extforce (only grad modified)
            for (auto &primHandle : prims) {
                if (primHandle.isBoundary()) // skip soft boundary
                    continue;
                cudaPol(zs::range(primHandle.getVerts().size()),
                        [vtemp = proxy<space>({}, vtemp), extForce = extForce, gTag, dt = dt,
                         vOffset = primHandle.vOffset] __device__(int vi) mutable {
                            auto m = zs::sqr(vtemp("ws", vOffset + vi));
                            int BCorder = vtemp("BCorder", vOffset + vi);
                            if (BCorder != 3)
                                vtemp.tuple<3>(gTag, vOffset + vi) =
                                    vtemp.pack<3>(gTag, vOffset + vi) + m * extForce * dt * dt;
                        });
            }
        }
#if 1
        template <typename Model>
        T energy(zs::CudaExecutionPolicy &pol, const Model &model, const zs::SmallString tag,
                 bool includeAugLagEnergy = false) {
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
                auto &verts = primHandle.getVerts();
                auto &eles = primHandle.getEles();
                es.resize(count_warps(eles.size()));
                es.reset(0);
                if (primHandle.category == ZenoParticles::curve) {
                    if (primHandle.isBoundary())
                        continue;
                    // elasticity
                    pol(range(eles.size()), [eles = proxy<space>({}, eles), vtemp = proxy<space>({}, vtemp),
                                             es = proxy<space>(es), tag, model = model, vOffset = primHandle.vOffset,
                                             n = eles.size()] __device__(int ei) mutable {
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
                        // atomic_add(exec_cuda, &res[0], E);
                        // es[ei] = E;
                        reduce_to(ei, n, E, es[ei / 32]);
                    });
                    Es.push_back(reduce(pol, es) * dt * dt);
                } else if (primHandle.category == ZenoParticles::surface) {
                    if (primHandle.isBoundary())
                        continue;
                    // elasticity
                    pol(range(eles.size()), [eles = proxy<space>({}, eles), vtemp = proxy<space>({}, vtemp),
                                             es = proxy<space>(es), tag, model = model, vOffset = primHandle.vOffset,
                                             n = eles.size()] __device__(int ei) mutable {
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
                        // atomic_add(exec_cuda, &res[0], E);
                        // es[ei] = E;
                        reduce_to(ei, n, E, es[ei / 32]);
                    });
                    Es.push_back(reduce(pol, es) * dt * dt);
                } else if (primHandle.category == ZenoParticles::tet) {
                    pol(zs::range(eles.size()), [vtemp = proxy<space>({}, vtemp), eles = proxy<space>({}, eles),
                                                 es = proxy<space>(es), model, tag, vOffset = primHandle.vOffset,
                                                 n = eles.size()] __device__(int ei) mutable {
                        auto IB = eles.template pack<3, 3>("IB", ei);
                        auto inds = eles.template pack<4>("inds", ei).template reinterpret_bits<int>() + vOffset;
                        auto vole = eles("vol", ei);
                        vec3 xs[4] = {vtemp.pack<3>(tag, inds[0]), vtemp.pack<3>(tag, inds[1]),
                                      vtemp.pack<3>(tag, inds[2]), vtemp.pack<3>(tag, inds[3])};

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
                            auto Ds =
                                mat3{x1x0[0], x2x0[0], x3x0[0], x1x0[1], x2x0[1], x3x0[1], x1x0[2], x2x0[2], x3x0[2]};
                            F = Ds * IB;
                            E = model.psi(F) * vole;
                        }
                        // atomic_add(exec_cuda, &res[0], model.psi(F) * vole);
                        // es[ei] = model.psi(F) * vole;
                        reduce_to(ei, n, E, es[ei / 32]);
                    });
                    Es.push_back(reduce(pol, es) * dt * dt);
                }
            }
            // contacts
            {
#if s_enableContact
                {
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

#if s_enableMollification
                    auto numEEM = nEEM.getVal();
                    es.resize(count_warps(numEEM));
                    es.reset(0);
                    pol(range(numEEM), [vtemp = proxy<space>({}, vtemp), EEM = proxy<space>(EEM), es = proxy<space>(es),
                                        xi2 = xi * xi, dHat = dHat, activeGap2,
                                        n = numEEM] __device__(int eemi) mutable {
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
                                        xi2 = xi * xi, dHat = dHat, activeGap2,
                                        n = numPPM] __device__(int ppmi) mutable {
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
                                        xi2 = xi * xi, dHat = dHat, activeGap2,
                                        n = numPEM] __device__(int pemi) mutable {
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
#endif // mollification

#if s_enableFriction
                    if (fricMu != 0) {
#if s_enableSelfFriction
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
#endif
                    }
#endif // fric
                }
#endif
                if (s_enableGround) {
                    for (auto &primHandle : prims) {
                        if (primHandle.isBoundary()) // skip soft boundary
                            continue;
                        const auto &svs = primHandle.getSurfVerts();
                        // boundary
                        es.resize(count_warps(svs.size()));
                        es.reset(0);
                        pol(range(svs.size()),
                            [vtemp = proxy<space>({}, vtemp), svs = proxy<space>({}, svs), es = proxy<space>(es),
                             gn = s_groundNormal, dHat2 = dHat * dHat, n = svs.size(),
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

#if s_enableFriction
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
#endif
                    }
                }
            }
            // constraints
            if (includeAugLagEnergy) {
                computeConstraints(pol, tag);
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
#else
#endif
        void checkSPD(zs::CudaExecutionPolicy &pol, const zs::SmallString dxTag) const {
            using namespace zs;
            constexpr execspace_e space = execspace_e::cuda;
            auto checkHess = [] __device__(const auto &m, const zs::SmallString &msg = "",
                                           const int &idx = -1) -> bool {
                auto checkDet = [&msg, idx](auto &checkDet, const auto &m) -> bool {
                    using MatT = RM_CVREF_T(m);
                    using Ti = typename MatT::index_type;
                    using T = typename MatT::value_type;
                    constexpr int dim = MatT::template range_t<0>::value;
                    if (auto det = determinant(m); det < -limits<T>::epsilon()) {
                        printf("msg[%s]: %d-th eepair subblock[%d] determinant is %f\n", msg.asChars(), idx, (int)dim,
                               (float)det);
                        return true;
                    }
                    if constexpr (dim > 1) {
                        using SubMatT = typename MatT::template variant_vec<T, integer_seq<Ti, dim - 1, dim - 1>>;
                        SubMatT subm;
                        for (int i = 0; i != dim - 1; ++i)
                            for (int j = 0; j != dim - 1; ++j)
                                subm(i, j) = m(i, j);
                        return checkDet(checkDet, subm);
                    }
                    return false;
                };
                return checkDet(checkDet, m);
            };
            // inertial
            pol(zs::range(coOffset), [checkHess, tempPB = proxy<space>({}, tempPB)] __device__(int i) mutable {
                auto Hi = tempPB.template pack<3, 3>("Hi", i);
                checkHess(Hi, "inertial");
                if (Hi(0, 0) < 0 || Hi(1, 1) < 0 || Hi(2, 2) < 0)
                    printf("%d-th Inertial Hessian [%f, %f, %f; %f, %f, %f; %f, %f, %f]\n", i, (float)Hi(0, 0),
                           (float)Hi(0, 1), (float)Hi(0, 2), (float)Hi(1, 0), (float)Hi(1, 1), (float)Hi(1, 2),
                           (float)Hi(2, 0), (float)Hi(2, 1), (float)Hi(2, 2));
            });

            for (auto &primHandle : prims) {
                auto &verts = primHandle.getVerts();
                auto &eles = primHandle.getEles();
                // elasticity
                if (primHandle.category == ZenoParticles::surface) {
                    pol(range(eles.size()),
                        [checkHess, etemp = proxy<space>({}, primHandle.etemp), vtemp = proxy<space>({}, vtemp),
                         eles = proxy<space>({}, eles), vOffset = primHandle.vOffset] ZS_LAMBDA(int ei) mutable {
                            constexpr int dim = 3;
                            auto inds = eles.template pack<3>("inds", ei).template reinterpret_bits<int>() + vOffset;
                            auto He = etemp.template pack<dim * 3, dim * 3>("He", ei);
                            checkHess(He, "surf elasticity");
                            for (int d = 0; d != 3; ++d) {
                                mat3 Hi{};
                                for (int e = 0; e != 9; ++e)
                                    Hi(e / 3, e % 3) = He(d * 3 + e / 3, d * 3 + e % 3);

                                if (Hi(0, 0) < 0 || Hi(1, 1) < 0 || Hi(2, 2) < 0)
                                    printf("%d-th Elastic Hessian9 %d-th subdiagblock:\n\t[%f, "
                                           "%f, %f; %f, %f, %f; %f, "
                                           "%f, %f]\n",
                                           ei, d, (float)Hi(0, 0), (float)Hi(0, 1), (float)Hi(0, 2), (float)Hi(1, 0),
                                           (float)Hi(1, 1), (float)Hi(1, 2), (float)Hi(2, 0), (float)Hi(2, 1),
                                           (float)Hi(2, 2));
                            }
                        });
                } else if (primHandle.category == ZenoParticles::tet)
                    pol(range(eles.size()),
                        [checkHess, etemp = proxy<space>({}, primHandle.etemp), vtemp = proxy<space>({}, vtemp),
                         eles = proxy<space>({}, eles), vOffset = primHandle.vOffset] ZS_LAMBDA(int ei) mutable {
                            constexpr int dim = 3;
                            auto inds = eles.template pack<4>("inds", ei).template reinterpret_bits<int>() + vOffset;
                            auto He = etemp.template pack<dim * 4, dim * 4>("He", ei);
                            checkHess(He, "tet elasticity");
                            for (int d = 0; d != 4; ++d) {
                                mat3 Hi{};
                                for (int e = 0; e != 9; ++e)
                                    Hi(e / 3, e % 3) = He(d * 3 + e / 3, d * 3 + e % 3);

                                if (Hi(0, 0) < 0 || Hi(1, 1) < 0 || Hi(2, 2) < 0)
                                    printf("%d-th Elastic Hessian12 %d-th subdiagblock:\n\t[%f, "
                                           "%f, %f; %f, %f, %f; %f, "
                                           "%f, %f]\n",
                                           ei, d, (float)Hi(0, 0), (float)Hi(0, 1), (float)Hi(0, 2), (float)Hi(1, 0),
                                           (float)Hi(1, 1), (float)Hi(1, 2), (float)Hi(2, 0), (float)Hi(2, 1),
                                           (float)Hi(2, 2));
                            }
                        });
            }
            // contacts
            {
#if s_enableContact
                {
                    auto numPP = nPP.getVal();
                    pol(range(numPP), [checkHess, tempPP = proxy<space>({}, tempPP), vtemp = proxy<space>({}, vtemp),
                                       PP = proxy<space>(PP)] ZS_LAMBDA(int ppi) mutable {
                        auto pp = PP[ppi];
                        auto ppHess = tempPP.template pack<6, 6>("H", ppi);
                        checkHess(ppHess, "pp hess");
                        for (int d = 0; d != 2; ++d) {
                            mat3 Hi{};
                            for (int e = 0; e != 9; ++e)
                                Hi(e / 3, e % 3) = ppHess(d * 3 + e / 3, d * 3 + e % 3);

                            if (Hi(0, 0) < 0 || Hi(1, 1) < 0 || Hi(2, 2) < 0)
                                printf("%d-th Contact Hessian6 %d-th subdiagblock:\n\t[%f, "
                                       "%f, %f; %f, %f, %f; %f, "
                                       "%f, %f]\n",
                                       ppi, d, (float)Hi(0, 0), (float)Hi(0, 1), (float)Hi(0, 2), (float)Hi(1, 0),
                                       (float)Hi(1, 1), (float)Hi(1, 2), (float)Hi(2, 0), (float)Hi(2, 1),
                                       (float)Hi(2, 2));
                        }
                    });
                    auto numPE = nPE.getVal();
                    pol(range(numPE), [checkHess, tempPE = proxy<space>({}, tempPE), vtemp = proxy<space>({}, vtemp),
                                       PE = proxy<space>(PE)] ZS_LAMBDA(int pei) mutable {
                        auto pe = PE[pei];
                        auto peHess = tempPE.template pack<9, 9>("H", pei);
                        checkHess(peHess, "pe hess");
                        for (int d = 0; d != 3; ++d) {
                            mat3 Hi{};
                            for (int e = 0; e != 9; ++e)
                                Hi(e / 3, e % 3) = peHess(d * 3 + e / 3, d * 3 + e % 3);

                            if (Hi(0, 0) < 0 || Hi(1, 1) < 0 || Hi(2, 2) < 0)
                                printf("%d-th Contact Hessian9 %d-th subdiagblock:\n\t[%f, "
                                       "%f, %f; %f, %f, %f; %f, "
                                       "%f, %f]\n",
                                       pei, d, (float)Hi(0, 0), (float)Hi(0, 1), (float)Hi(0, 2), (float)Hi(1, 0),
                                       (float)Hi(1, 1), (float)Hi(1, 2), (float)Hi(2, 0), (float)Hi(2, 1),
                                       (float)Hi(2, 2));
                        }
                    });
                    auto numPT = nPT.getVal();
                    pol(range(numPT), [checkHess, tempPT = proxy<space>({}, tempPT), vtemp = proxy<space>({}, vtemp),
                                       PT = proxy<space>(PT)] ZS_LAMBDA(int pti) mutable {
                        auto pt = PT[pti];
                        auto ptHess = tempPT.template pack<12, 12>("H", pti);
                        checkHess(ptHess, "pt hess");
                        for (int d = 0; d != 4; ++d) {
                            mat3 Hi{};
                            for (int e = 0; e != 9; ++e)
                                Hi(e / 3, e % 3) = ptHess(d * 3 + e / 3, d * 3 + e % 3);

                            if (Hi(0, 0) < 0 || Hi(1, 1) < 0 || Hi(2, 2) < 0)
                                printf("%d-th Contact Hessian12 %d-th subdiagblock:\n\t[%f, "
                                       "%f, %f; %f, %f, %f; %f, "
                                       "%f, %f]\n",
                                       pti, d, (float)Hi(0, 0), (float)Hi(0, 1), (float)Hi(0, 2), (float)Hi(1, 0),
                                       (float)Hi(1, 1), (float)Hi(1, 2), (float)Hi(2, 0), (float)Hi(2, 1),
                                       (float)Hi(2, 2));
                        }
                    });
                    auto numEE = nEE.getVal();
                    pol(range(numEE), [checkHess, tempEE = proxy<space>({}, tempEE), vtemp = proxy<space>({}, vtemp),
                                       EE = proxy<space>(EE), kappa = kappa, dHat = dHat] ZS_LAMBDA(int eei) mutable {
                        auto ee = EE[eei];
                        auto eeHess = tempEE.template pack<12, 12>("H", eei);
                        {
                            auto ea0 = vtemp.template pack<3>("xn", ee[0]);
                            auto ea1 = vtemp.template pack<3>("xn", ee[1]);
                            auto eb0 = vtemp.template pack<3>("xn", ee[2]);
                            auto eb1 = vtemp.template pack<3>("xn", ee[3]);
                            auto ea0Rest = vtemp.template pack<3>("x0", ee[0]);
                            auto ea1Rest = vtemp.template pack<3>("x0", ee[1]);
                            auto eb0Rest = vtemp.template pack<3>("x0", ee[2]);
                            auto eb1Rest = vtemp.template pack<3>("x0", ee[3]);
                            auto cro = (ea1 - ea0).cross(eb1 - eb0);
                            T c = cn2_ee(ea0, ea1, eb0, eb1);
                            T epsX = mollifier_threshold_ee(ea0Rest, ea1Rest, eb0Rest, eb1Rest);
                            bool mollify = c < epsX;
                            if (mollify) {
                                auto dir0 = (ea1 - ea0).normalized();
                                auto dir1 = (eb1 - eb0).normalized();
                                printf("actually there should be mollified eepairs. c: %f, "
                                       "epsX: %f; e0dir (%f, %f, %f), e1dir (%f, %f, %f)\n",
                                       (float)c, (float)epsX, (float)dir0[0], (float)dir0[1], (float)dir0[2],
                                       (float)dir1[0], (float)dir1[1], (float)dir1[2]);
                            }
                        }
                        if (checkHess(eeHess, "ee hess", eei)) {
                            auto ea0 = vtemp.template pack<3>("xn", ee[0]);
                            auto ea1 = vtemp.template pack<3>("xn", ee[1]);
                            auto eb0 = vtemp.template pack<3>("xn", ee[2]);
                            auto eb1 = vtemp.template pack<3>("xn", ee[3]);
                            auto ea0Rest = vtemp.template pack<3>("x0", ee[0]);
                            auto ea1Rest = vtemp.template pack<3>("x0", ee[1]);
                            auto eb0Rest = vtemp.template pack<3>("x0", ee[2]);
                            auto eb1Rest = vtemp.template pack<3>("x0", ee[3]);
                            auto cro = (ea1 - ea0).cross(eb1 - eb0);
                            T c = cn2_ee(ea0, ea1, eb0, eb1);
                            T epsX = mollifier_threshold_ee(ea0Rest, ea1Rest, eb0Rest, eb1Rest);
                            bool mollify = c < epsX;
                            for (int r = 0; r != 12; ++r) {
                                printf("eehess[%d, row %d]: [%f, %f, %f, %f, %f, %f, \t%f, %f, "
                                       "%f, %f, %f, %f]\n",
                                       eei, r, (float)eeHess(r, 0), (float)eeHess(r, 1), (float)eeHess(r, 2),
                                       (float)eeHess(r, 3), (float)eeHess(r, 4), (float)eeHess(r, 5),
                                       (float)eeHess(r, 6), (float)eeHess(r, 7), (float)eeHess(r, 8),
                                       (float)eeHess(r, 9), (float)eeHess(r, 10), (float)eeHess(r, 11));
                            }
#if 0
              auto [hkmH, hkmG] =
                  get_hkm_ee_hess(ea0, ea1, eb0, eb1, kappa, dHat, eei);
              for (int r = 0; r != 12; ++r) {
                printf(
                    "diff eehess[%d, row %d]: [%f, %f, %f, %f, %f, %f, %f, %f, "
                    "%f, %f, %f, %f]\n",
                    eei, r, eeHess(r, 0) - hkmH(r, 0),
                    eeHess(r, 1) - hkmH(r, 1), eeHess(r, 2) - hkmH(r, 2),
                    eeHess(r, 3) - hkmH(r, 3), eeHess(r, 4) - hkmH(r, 4),
                    eeHess(r, 5) - hkmH(r, 5), eeHess(r, 6) - hkmH(r, 6),
                    eeHess(r, 7) - hkmH(r, 7), eeHess(r, 8) - hkmH(r, 8),
                    eeHess(r, 9) - hkmH(r, 9), eeHess(r, 10) - hkmH(r, 10),
                    eeHess(r, 11) - hkmH(r, 11));
              }
              auto dir0 = (ea1 - ea0).normalized();
              auto dir1 = (eb1 - eb0).normalized();
              printf("actually this should be mollified eepair [%d]. c: %e, "
                     "epsX: %e; e0 (%e, %e, %e) - (%e, %e, %e); e1 (%e, %e, "
                     "%e) - (%e, %e, %e)\n",
                     eei, (float)c, (float)epsX, ea0[0], ea0[1], ea0[2], ea1[0],
                     ea1[1], ea1[2], eb0[0], eb0[1], eb0[2], eb1[0], eb1[1],
                     eb1[2]);
              printf("e0 (%f, %f, %f)-(%f, %f, %f), e1 (%f, %f, %f)-(%f, %f, "
                     "%f), c (%f) < epsX (%f) ?(%d)\n",
                     (float)ea0[0], (float)ea0[1], (float)ea0[2], (float)ea1[0],
                     (float)ea1[1], (float)ea1[2], (float)eb0[0], (float)eb0[1],
                     (float)eb0[2], (float)eb1[0], (float)eb1[1], (float)eb1[2],
                     (float)c, (float)epsX, (int)mollify);
#endif
                        }
                    });
                }
#endif
            } // end contacts
            puts("done checking SPD");
        }
        void project(zs::CudaExecutionPolicy &pol, const zs::SmallString tag) {
            using namespace zs;
            constexpr execspace_e space = execspace_e::cuda;
            // projection
            pol(zs::range(numDofs),
                [vtemp = proxy<space>({}, vtemp), projectDBC = projectDBC, tag] ZS_LAMBDA(int vi) mutable {
                    int BCfixed = vtemp("BCfixed", vi);
                    if (projectDBC || (!projectDBC && BCfixed)) {
                        int BCorder = vtemp("BCorder", vi);
                        for (int d = 0; d != BCorder; ++d)
                            vtemp(tag, d, vi) = 0;
                    }
                });
        }
        void precondition(zs::CudaExecutionPolicy &pol, const zs::SmallString srcTag, const zs::SmallString dstTag) {
            using namespace zs;
            constexpr execspace_e space = execspace_e::cuda;
            // precondition
            pol(zs::range(numDofs), [vtemp = proxy<space>({}, vtemp), srcTag, dstTag] ZS_LAMBDA(int vi) mutable {
                vtemp.template tuple<3>(dstTag, vi) =
                    vtemp.template pack<3, 3>("P", vi) * vtemp.template pack<3>(srcTag, vi);
            });
        }
        void multiply(zs::CudaExecutionPolicy &pol, const zs::SmallString dxTag, const zs::SmallString bTag) {
            using namespace zs;
            constexpr execspace_e space = execspace_e::cuda;
            constexpr auto execTag = wrapv<space>{};
            // hessian rotation: trans^T hess * trans
            // left trans^T: multiplied on rows
            // right trans: multiplied on cols
#if 0
      auto checkVec = [projectDBC = projectDBC] __device__(
                          const auto &v, int BCorder[],
                          const char *msg = nullptr) -> bool {
        constexpr int numV = RM_CVREF_T(v)::extent / 3;
        static_assert(RM_CVREF_T(v)::extent % 3 == 0, "wtf??");
        bool ret = false;
        for (int vi = 0; vi != numV; ++vi) {
          for (int d = 0; d != BCorder[vi]; ++d) {
            if (projectDBC &&
                zs::abs(v(vi * 3 + d)) > limits<T>::epsilon() * 10) {
              if (msg != nullptr)
                printf("msg[%s]: vec[%d](%f) is not zeroed\n", msg, vi * 3 + d,
                       (float)v(vi * 3 + d));
              ret = true;
            }
          }
        }
        return ret;
      };
#endif
            // dx -> b
            pol(range(numDofs), [execTag, vtemp = proxy<space>({}, vtemp), bTag] ZS_LAMBDA(int vi) mutable {
                vtemp.template tuple<3>(bTag, vi) = vec3::zeros();
            });
            // inertial
            pol(zs::range(coOffset), [execTag, tempPB = proxy<space>({}, tempPB), vtemp = proxy<space>({}, vtemp),
                                      dxTag, bTag] __device__(int i) mutable {
                auto Hi = tempPB.template pack<3, 3>("Hi", i);
                auto dx = vtemp.template pack<3>(dxTag, i);
                dx = Hi * dx;
                for (int d = 0; d != 3; ++d)
                    atomic_add(execTag, &vtemp(bTag, d, i), dx(d));
            });

            for (auto &primHandle : prims) {
                auto &verts = primHandle.getVerts();
                auto &eles = primHandle.getEles();
                // elasticity
                if (primHandle.category == ZenoParticles::curve) {
                    if (primHandle.isBoundary())
                        continue;
#if 0
          pol(range(eles.size()),
              [execTag, etemp = proxy<space>({}, primHandle.etemp),
               vtemp = proxy<space>({}, vtemp), eles = proxy<space>({}, eles),
               dxTag, bTag,
               vOffset = primHandle.vOffset] ZS_LAMBDA(int ei) mutable {
                constexpr int dim = 3;
                auto inds = eles.template pack<2>("inds", ei)
                                .template reinterpret_bits<int>() +
                            vOffset;
                zs::vec<T, 2 * dim> temp{};
                for (int vi = 0; vi != 2; ++vi)
                  for (int d = 0; d != dim; ++d) {
                    temp[vi * dim + d] = vtemp(dxTag, d, inds[vi]);
                  }
                auto He = etemp.template pack<dim * 2, dim * 2>("He", ei);

                temp = He * temp;

                for (int vi = 0; vi != 2; ++vi)
                  for (int d = 0; d != dim; ++d) {
                    atomic_add(execTag, &vtemp(bTag, d, inds[vi]),
                               temp[vi * dim + d]);
                  }
              });
#else
                    pol(Collapse{eles.size(), 32},
                        [execTag, etemp = proxy<space>({}, primHandle.etemp), vtemp = proxy<space>({}, vtemp),
                         eles = proxy<space>({}, eles), dxTag, bTag,
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
#endif
                } else if (primHandle.category == ZenoParticles::surface) {
                    if (primHandle.isBoundary())
                        continue;
#if 1
                    pol(range(eles.size()), [execTag, etemp = proxy<space>({}, primHandle.etemp),
                                             vtemp = proxy<space>({}, vtemp), eles = proxy<space>({}, eles), dxTag,
                                             bTag, vOffset = primHandle.vOffset] ZS_LAMBDA(int ei) mutable {
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
                    pol(range(eles.size()), [execTag, etemp = proxy<space>({}, primHandle.etemp),
                                             vtemp = proxy<space>({}, vtemp), eles = proxy<space>({}, eles), dxTag,
                                             bTag, vOffset = primHandle.vOffset] ZS_LAMBDA(int ei) mutable {
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
            {
#if s_enableContact
                {
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
                    pol(Collapse{numPP, 32},
                        [execTag, tempPP = proxy<space>({}, tempPP), vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                         PP = proxy<space>(PP)] ZS_LAMBDA(int ppi, int tid) mutable {
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
                    pol(range(numPP * 36),
                        [execTag, tempPP = proxy<space>({}, tempPP), vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                         PP = proxy<space>(PP), n = numPP * 36] ZS_LAMBDA(int idx) mutable {
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
                        pol(Collapse{numWarps * 32}, [execTag, tempPE = proxy<space>({}, tempPE),
                                                      vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                                                      PE = proxy<space>(PE), numRows] ZS_LAMBDA(int tid) mutable {
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
                    pol(range(numPE * 81),
                        [execTag, tempPE = proxy<space>({}, tempPE), vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                         PE = proxy<space>(PE), n = numPE * 81] ZS_LAMBDA(int idx) mutable {
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
                    pol(Collapse{numPT, 32 * 3},
                        [execTag, tempPT = proxy<space>({}, tempPT), vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                         PT = proxy<space>(PT)] ZS_LAMBDA(int pti, int tid) mutable {
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
                    pol(range(numPT * 144),
                        [execTag, tempPT = proxy<space>({}, tempPT), vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                         PT = proxy<space>(PT), n = numPT * 144] ZS_LAMBDA(int idx) mutable {
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
                    pol(Collapse{numEE, 32 * 3},
                        [execTag, tempEE = proxy<space>({}, tempEE), vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                         EE = proxy<space>(EE)] ZS_LAMBDA(int eei, int tid) mutable {
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
                    pol(range(numEE * 144),
                        [execTag, tempEE = proxy<space>({}, tempEE), vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                         EE = proxy<space>(EE), n = numEE * 144] ZS_LAMBDA(int idx) mutable {
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
                }
#if s_enableMollification
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
#endif // end mollification

#if s_enableFriction
                if (fricMu != 0) {
#if s_enableSelfFriction
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
#endif
                }
#endif // end fric
#endif
                if (s_enableGround) {
                    // boundary
                    for (auto &primHandle : prims) {
                        if (primHandle.isBoundary()) // skip soft boundary
                            continue;
                        const auto &svs = primHandle.getSurfVerts();
                        pol(range(svs.size()),
                            [execTag, vtemp = proxy<space>({}, vtemp), dxTag, bTag,
                             svtemp = proxy<space>({}, primHandle.svtemp), svs = proxy<space>({}, svs),
                             svOffset = primHandle.svOffset] ZS_LAMBDA(int svi) mutable {
                                const auto vi = reinterpret_bits<int>(svs("inds", svi)) + svOffset;
                                auto dx = vtemp.template pack<3>(dxTag, vi);
                                auto pbHess = svtemp.template pack<3, 3>("H", svi);
                                dx = pbHess * dx;
                                for (int d = 0; d != 3; ++d)
                                    atomic_add(execTag, &vtemp(bTag, d, vi), dx(d));
                            });
                    }
                }
            } // end contacts

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
        void cgsolve(zs::CudaExecutionPolicy &cudaPol, bool &useGD) {
            // input "grad", multiply, constraints
            // output "dir"
            using namespace zs;
            constexpr auto space = execspace_e::cuda;
            if (useGD) {
                // project(cudaPol, "grad");
                precondition(cudaPol, "grad", "dir");
            } else {
                // solve for A dir = grad;
                cudaPol(zs::range(numDofs), [vtemp = proxy<space>({}, vtemp)] __device__(int i) mutable {
                    vtemp.tuple<3>("dir", i) = vec3::zeros();
                    vtemp.tuple<3>("temp", i) = vec3::zeros();
                });
                // initial guess for hard boundary constraints
                cudaPol(zs::range(coVerts.size()),
                        [vtemp = proxy<space>({}, vtemp), coOffset = coOffset, dt = dt] __device__(int i) mutable {
                            i += coOffset;
                            vtemp.tuple<3>("dir", i) = (vtemp.pack<3>("xtilde", i) - vtemp.pack<3>("xn", i)) * dt;
                        });
                // temp = A * dir
                multiply(cudaPol, "dir", "temp");
                // r = grad - temp
                cudaPol(zs::range(numDofs), [vtemp = proxy<space>({}, vtemp)] __device__(int i) mutable {
                    vtemp.tuple<3>("r", i) = vtemp.pack<3>("grad", i) - vtemp.pack<3>("temp", i);
                });
                // project(cudaPol, "r");
                precondition(cudaPol, "r", "q");
                cudaPol(zs::range(numDofs), [vtemp = proxy<space>({}, vtemp)] __device__(int i) mutable {
                    vtemp.tuple<3>("p", i) = vtemp.pack<3>("q", i);
                });
                T zTrk = dot(cudaPol, vtemp, "r", "q");
                auto residualPreconditionedNorm2 = zTrk;
                auto localTol2 = cgRel * cgRel * residualPreconditionedNorm2;
                int iter = 0;

                //
                auto [npp, npe, npt, nee, nppm, npem, neem, ncspt, ncsee] = getCnts();

                for (; iter != CGCap; ++iter) {
                    if (iter % 25 == 0)
                        fmt::print("cg iter: {}, norm2: {} (zTrk: {}) npp: {}, npe: {}, "
                                   "npt: {}, nee: {}, nppm: {}, npem: {}, neem: {}, ncspt: "
                                   "{}, ncsee: {}\n",
                                   iter, residualPreconditionedNorm2, zTrk, npp, npe, npt, nee, nppm, npem, neem, ncspt,
                                   ncsee);

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

#if 1
                    residualPreconditionedNorm2 = zTrk;
#else
                    if (zTrk < 0) {
                        fmt::print(fg(fmt::color::pale_violet_red),
                                   "what the heck? zTrk: {} at iteration {}. switching to "
                                   "gradient descent ftm.\n",
                                   zTrk, iter);
                        useGD = true;
                        checkSPD(cudaPol, "xn");
                        getchar();
                        break;
                    }
                    residualPreconditionedNorm = std::sqrt(zTrk);
#endif
                } // end cg step
                if (useGD == true)
                    return;
            }
        }
        void lineSearch(zs::CudaExecutionPolicy &cudaPol, T &alpha, bool CCDfiltered) {
            using namespace zs;
            constexpr auto space = execspace_e::cuda;
            // initial energy
            T E0{};
            match([&](auto &elasticModel) { E0 = energy(cudaPol, elasticModel, "xn0", !BCsatisfied); })(
                models.getElasticModel());

            T E{E0};
            T c1m = 0;
            int lsIter = 0;
            c1m = armijoParam * dot(cudaPol, vtemp, "dir", "grad");
            fmt::print(fg(fmt::color::white), "c1m : {}\n", c1m);
#if 1
            do {
                cudaPol(zs::range(vtemp.size()), [vtemp = proxy<space>({}, vtemp), alpha] __device__(int i) mutable {
                    vtemp.tuple<3>("xn", i) = vtemp.pack<3>("xn0", i) + alpha * vtemp.pack<3>("dir", i);
                });

                if constexpr (s_enableContact)
                    findCollisionConstraints(cudaPol, dHat, xi);
                match([&](auto &elasticModel) { E = energy(cudaPol, elasticModel, "xn", !BCsatisfied); })(
                    models.getElasticModel());

                fmt::print("E: {} at alpha {}. E0 {}\n", E, alpha, E0);
#if 0
        if (E < E0) break;
#else
                if (E <= E0 + alpha * c1m)
                    break;
#endif

                if (alpha < 1e-3) {
                    fmt::print(fg(fmt::color::light_yellow), "linesearch early exit with alpha {}\n", alpha);
                    break;
                }

                alpha /= 2;
                if (++lsIter > 30) {
                    auto cr = constraintResidual(cudaPol);
                    fmt::print("too small stepsize at iteration [{}]! alpha: {}, cons "
                               "res: {}\n",
                               lsIter, alpha, cr);
#if 1
                    // now pause at all small steps
                    // if (!useGD && !CCDfiltered)
                    getchar();
#endif
                }
            } while (true);
#endif
        }
        void initialize(zs::CudaExecutionPolicy &pol) {
            using namespace zs;
            constexpr auto space = execspace_e::cuda;
            stInds = tiles_t{vtemp.get_allocator(), {{"inds", 3}}, sfOffset};
            seInds = tiles_t{vtemp.get_allocator(), {{"inds", 2}}, seOffset};
            svInds = tiles_t{vtemp.get_allocator(), {{"inds", 1}}, svOffset};
            avgNodeMass = averageNodalMass(pol);
            for (auto &primHandle : prims) {
                auto &verts = primHandle.getVerts();
                // initialize BC info
                // predict pos, initialize augmented lagrangian, constrain weights
                pol(Collapse(verts.size()),
                    [vtemp = proxy<space>({}, vtemp), verts = proxy<space>({}, verts), voffset = primHandle.vOffset,
                     dt = dt, asBoundary = primHandle.isBoundary(), avgNodeMass = avgNodeMass,
                     augLagCoeff = augLagCoeff] __device__(int i) mutable {
                        auto x = verts.pack<3>("x", i);
                        auto v = verts.pack<3>("v", i);
                        int BCorder = 0;
                        auto BCtarget = x + v * dt;
                        auto BCbasis = mat3::identity();
                        int BCfixed = 0;
                        if (!asBoundary) {
                            BCorder = verts("BCorder", i);
                            BCtarget = verts.template pack<3>("BCtarget", i);
                            BCbasis = verts.template pack<3, 3>("BCbasis", i);
                            BCfixed = verts("BCfixed", i);
                        }
                        vtemp("BCorder", voffset + i) = BCorder;
                        vtemp.template tuple<3>("BCtarget", voffset + i) = BCtarget;
                        vtemp.template tuple<9>("BCbasis", voffset + i) = BCbasis;
                        vtemp("BCfixed", voffset + i) = BCfixed;
                        vtemp("BCsoft", voffset + i) = (int)asBoundary;

                        vtemp("ws", voffset + i) = asBoundary ? avgNodeMass * augLagCoeff : zs::sqrt(verts("m", i));
                        vtemp.tuple<3>("xtilde", voffset + i) = x + v * dt;
                        vtemp.tuple<3>("lambda", voffset + i) = vec3::zeros();
                        vtemp.tuple<3>("xn", voffset + i) = x;
                        vtemp.tuple<3>("xhat", voffset + i) = x;
                        if (BCorder > 0) {
                            // recover original BCtarget
                            BCtarget = BCbasis * BCtarget;
                            vtemp.tuple<3>("vn", voffset + i) = (BCtarget - x) / dt;
                        } else {
                            vtemp.tuple<3>("vn", voffset + i) = v;
                        }
                        // vtemp.tuple<3>("xt", voffset + i) = x;
                        vtemp.tuple<3>("x0", voffset + i) = verts.pack<3>("x0", i);
                    });
                // record surface (tri) indices
                if (primHandle.category != ZenoParticles::category_e::curve) {
                    auto &tris = primHandle.getSurfTris();
                    pol(Collapse(tris.size()),
                        [stInds = proxy<space>({}, stInds), tris = proxy<space>({}, tris), voffset = primHandle.vOffset,
                         sfoffset = primHandle.sfOffset] __device__(int i) mutable {
                            stInds.template tuple<3>("inds", sfoffset + i) =
                                (tris.template pack<3>("inds", i).template reinterpret_bits<int>() + (int)voffset)
                                    .template reinterpret_bits<float>();
                        });
                }
                auto &edges = primHandle.getSurfEdges();
                pol(Collapse(edges.size()),
                    [seInds = proxy<space>({}, seInds), edges = proxy<space>({}, edges), voffset = primHandle.vOffset,
                     seoffset = primHandle.seOffset] __device__(int i) mutable {
                        seInds.template tuple<2>("inds", seoffset + i) =
                            (edges.template pack<2>("inds", i).template reinterpret_bits<int>() + (int)voffset)
                                .template reinterpret_bits<float>();
                    });
                auto &points = primHandle.getSurfVerts();
                pol(Collapse(points.size()),
                    [svInds = proxy<space>({}, svInds), points = proxy<space>({}, points), voffset = primHandle.vOffset,
                     svoffset = primHandle.svOffset] __device__(int i) mutable {
                        svInds("inds", svoffset + i) =
                            reinterpret_bits<float>(reinterpret_bits<int>(points("inds", i)) + (int)voffset);
                    });
            }
#if 0
        // average nodal mass
        /// mean mass
        avgNodeMass = 0;
        T sumNodeMass = 0;
        int sumNodes = 0;
        zs::Vector<T> masses{vtemp.get_allocator(), coOffset};
        pol(zs::Collapse{coOffset},
            [masses = proxy<space>(masses),
             vtemp = proxy<space>({}, vtemp)] __device__(int vi) mutable {
              masses[vi] = zs::sqr(vtemp("ws", vi));
            });
        auto tmp = reduce(pol, masses);
        sumNodeMass += tmp;
        sumNodes = coOffset;
        avgNodeMass = sumNodeMass / sumNodes;
#endif
            if (auto coSize = coVerts.size(); coSize)
                pol(Collapse(coSize),
                    [vtemp = proxy<space>({}, vtemp), coverts = proxy<space>({}, coVerts), coOffset = coOffset, dt = dt,
                     augLagCoeff = augLagCoeff, avgNodeMass = avgNodeMass] __device__(int i) mutable {
                        auto x = coverts.pack<3>("x", i);
                        vec3 newX{};
                        if (coverts.hasProperty("BCtarget"))
                            newX = coverts.pack<3>("BCtarget", i);
                        else {
                            auto v = coverts.pack<3>("v", i);
                            newX = x + v * dt;
                        }
                        vtemp("BCorder", coOffset + i) = 3;
                        vtemp.template tuple<9>("BCbasis", coOffset + i) = mat3::identity();
                        vtemp.template tuple<3>("BCtarget", coOffset + i) = newX;
                        vtemp("BCfixed", coOffset + i) = (newX - x).l2NormSqr() == 0 ? 1 : 0;

                        vtemp("ws", coOffset + i) = avgNodeMass * augLagCoeff;
                        vtemp.tuple<3>("xtilde", coOffset + i) = newX;
                        vtemp.tuple<3>("lambda", coOffset + i) = vec3::zeros();
                        vtemp.tuple<3>("xn", coOffset + i) = x;
                        vtemp.tuple<3>("vn", coOffset + i) = (newX - x) / dt;
                        // vtemp.tuple<3>("xt", coOffset + i) = x;
                        vtemp.tuple<3>("xhat", coOffset + i) = x;
                        vtemp.tuple<3>("x0", coOffset + i) = coverts.pack<3>("x0", i);
                    });
        }
        void advanceSubstep(zs::CudaExecutionPolicy &pol, T ratio) {
            using namespace zs;
            constexpr auto space = execspace_e::cuda;
            // setup substep dt
            dt = framedt * ratio;
            curRatio += ratio;
            pol(Collapse(coOffset), [vtemp = proxy<space>({}, vtemp), coOffset = coOffset, dt = dt, ratio,
                                     localRatio = ratio / (1 - curRatio + ratio)] __device__(int vi) mutable {
                int BCorder = vtemp("BCorder", vi);
                auto BCbasis = vtemp.pack<3, 3>("BCbasis", vi);
                auto projVec = [&BCbasis, BCorder](auto &dx) {
                    dx = BCbasis.transpose() * dx;
                    for (int d = 0; d != BCorder; ++d)
                        dx[d] = 0;
                    dx = BCbasis * dx;
                };
                auto xn = vtemp.template pack<3>("xn", vi);
                vtemp.template tuple<3>("xhat", vi) = xn;
                auto deltaX = vtemp.template pack<3>("vn", vi) * dt;
                if (BCorder > 0)
                    projVec(deltaX);
                auto newX = xn + deltaX;
                vtemp.template tuple<3>("xtilde", vi) = newX;

                // update "BCfixed", "BCtarget" for dofs under boundary influence
                if (BCorder > 0) {
                    vtemp.template tuple<3>("BCtarget", vi) = BCbasis.transpose() * newX;
                    vtemp("BCfixed", vi) = deltaX.l2NormSqr() == 0 ? 1 : 0;
                }
#if 0
            if (BCorder != 3) { // only for free moving dofs
              vtemp.template tuple<3>("xt", vi) = xn;
            }
#endif
            });
            if (auto coSize = coVerts.size(); coSize)
                pol(Collapse(coSize),
                    [vtemp = proxy<space>({}, vtemp), coverts = proxy<space>({}, coVerts), coOffset = coOffset,
                     framedt = framedt, curRatio = curRatio] __device__(int i) mutable {
                        auto xhat = vtemp.template pack<3>("xhat", coOffset + i);
                        auto xn = vtemp.template pack<3>("xn", coOffset + i);
                        vtemp.template tuple<3>("xhat", coOffset + i) = xn;
                        vec3 newX{};
                        if (coverts.hasProperty("BCtarget"))
                            newX = coverts.pack<3>("BCtarget", i);
                        else {
                            auto v = coverts.pack<3>("v", i);
                            newX = xhat + v * framedt;
                        }
                        // auto xk = xhat + (newX - xhat) * curRatio;
                        auto xk = newX * curRatio + (1 - curRatio) * xhat;
                        vtemp.template tuple<3>("BCtarget", coOffset + i) = xk;
                        vtemp("BCfixed", coOffset + i) = (xk - xn).l2NormSqr() == 0 ? 1 : 0;
                        vtemp.template tuple<3>("xtilde", coOffset + i) = xk;
                    });
        }
        void updateVelocities(zs::CudaExecutionPolicy &pol) {
            using namespace zs;
            constexpr auto space = execspace_e::cuda;
            pol(zs::range(coOffset), [vtemp = proxy<space>({}, vtemp), dt = dt] __device__(int vi) mutable {
                auto newX = vtemp.pack<3>("xn", vi);
                auto dv = (newX - vtemp.pack<3>("xtilde", vi)) / dt;
                auto vn = vtemp.pack<3>("vn", vi);
                vn += dv;
                int BCorder = vtemp("BCorder", vi);
                auto BCbasis = vtemp.pack<3, 3>("BCbasis", vi);
                auto projVec = [&BCbasis, BCorder](auto &dx) {
                    dx = BCbasis.transpose() * dx;
                    for (int d = 0; d != BCorder; ++d)
                        dx[d] = 0;
                    dx = BCbasis * dx;
                };
                if (BCorder > 0)
                    projVec(vn);
                vtemp.tuple<3>("vn", vi) = vn;
            });
        }
        void updatePositionsAndVelocities(zs::CudaExecutionPolicy &pol) {
            using namespace zs;
            constexpr auto space = execspace_e::cuda;
            for (auto &primHandle : prims) {
                auto &verts = primHandle.getVerts();
                // update velocity and positions
                pol(zs::range(verts.size()),
                    [vtemp = proxy<space>({}, vtemp), verts = proxy<space>({}, verts), dt = dt,
                     vOffset = primHandle.vOffset, asBoundary = primHandle.isBoundary()] __device__(int vi) mutable {
                        verts.tuple<3>("x", vi) = vtemp.pack<3>("xn", vOffset + vi);
                        if (!asBoundary)
                            verts.tuple<3>("v", vi) = vtemp.pack<3>("vn", vOffset + vi);
                    });
            }
        }

        IPCSystem(std::vector<ZenoParticles *> zsprims, const dtiles_t &coVerts, const tiles_t &coEdges,
                  const tiles_t &coEles, T dt, const ZenoConstitutiveModel &models)
            : coVerts{coVerts}, coEdges{coEdges}, coEles{coEles}, PP{estNumCps, zs::memsrc_e::um, 0},
              nPP{zsprims[0]->getParticles<true>().get_allocator(), 1}, tempPP{{{"H", 36}},
                                                                               estNumCps,
                                                                               zs::memsrc_e::um,
                                                                               0},
              PE{estNumCps, zs::memsrc_e::um, 0}, nPE{zsprims[0]->getParticles<true>().get_allocator(), 1},
              tempPE{{{"H", 81}}, estNumCps, zs::memsrc_e::um, 0}, PT{estNumCps, zs::memsrc_e::um, 0},
              nPT{zsprims[0]->getParticles<true>().get_allocator(), 1},
              tempPT{{{"H", 144}}, estNumCps, zs::memsrc_e::um, 0}, EE{estNumCps, zs::memsrc_e::um, 0},
              nEE{zsprims[0]->getParticles<true>().get_allocator(), 1}, tempEE{{{"H", 144}},
                                                                               estNumCps,
                                                                               zs::memsrc_e::um,
                                                                               0},
              // mollify
              PPM{estNumCps, zs::memsrc_e::um, 0}, nPPM{zsprims[0]->getParticles<true>().get_allocator(), 1},
              tempPPM{{{"H", 144}}, estNumCps, zs::memsrc_e::um, 0}, PEM{estNumCps, zs::memsrc_e::um, 0},
              nPEM{zsprims[0]->getParticles<true>().get_allocator(), 1},
              tempPEM{{{"H", 144}}, estNumCps, zs::memsrc_e::um, 0}, EEM{estNumCps, zs::memsrc_e::um, 0},
              nEEM{zsprims[0]->getParticles<true>().get_allocator(), 1}, tempEEM{{{"H", 144}},
                                                                                 estNumCps,
                                                                                 zs::memsrc_e::um,
                                                                                 0},
              // friction
              FPP{estNumCps, zs::memsrc_e::um, 0}, nFPP{zsprims[0]->getParticles<true>().get_allocator(), 1},
              fricPP{{{"H", 36}, {"basis", 6}, {"fn", 1}}, estNumCps, zs::memsrc_e::um, 0},
              FPE{estNumCps, zs::memsrc_e::um, 0}, nFPE{zsprims[0]->getParticles<true>().get_allocator(), 1},
              fricPE{{{"H", 81}, {"basis", 6}, {"fn", 1}, {"yita", 1}}, estNumCps, zs::memsrc_e::um, 0},
              FPT{estNumCps, zs::memsrc_e::um, 0}, nFPT{zsprims[0]->getParticles<true>().get_allocator(), 1},
              fricPT{{{"H", 144}, {"basis", 6}, {"fn", 1}, {"beta", 2}}, estNumCps, zs::memsrc_e::um, 0},
              FEE{estNumCps, zs::memsrc_e::um, 0}, nFEE{zsprims[0]->getParticles<true>().get_allocator(), 1},
              fricEE{{{"H", 144}, {"basis", 6}, {"fn", 1}, {"gamma", 2}}, estNumCps, zs::memsrc_e::um, 0},
              //
              temp{estNumCps, zs::memsrc_e::um, zsprims[0]->getParticles<true>().devid()}, csPT{estNumCps,
                                                                                                zs::memsrc_e::um, 0},
              csEE{estNumCps, zs::memsrc_e::um, 0}, ncsPT{zsprims[0]->getParticles<true>().get_allocator(), 1},
              ncsEE{zsprims[0]->getParticles<true>().get_allocator(), 1}, dt{dt}, framedt{dt}, curRatio{0},
              models{models} {
            coOffset = sfOffset = seOffset = svOffset = 0;
            prevNumPP = prevNumPE = prevNumPT = prevNumEE = 0;
            for (auto primPtr : zsprims) {
                if (primPtr->category == ZenoParticles::category_e::curve) {
                    prims.emplace_back(*primPtr, coOffset, sfOffset, seOffset, svOffset, zs::wrapv<2>{});
                } else if (primPtr->category == ZenoParticles::category_e::surface)
                    prims.emplace_back(*primPtr, coOffset, sfOffset, seOffset, svOffset, zs::wrapv<3>{});
                else if (primPtr->category == ZenoParticles::category_e::tet)
                    prims.emplace_back(*primPtr, coOffset, sfOffset, seOffset, svOffset, zs::wrapv<4>{});
            }
            numDofs = coOffset + coVerts.size();
            vtemp = dtiles_t{zsprims[0]->getParticles<true>().get_allocator(),
                             {{"grad", 3},
                              {"P", 9},
                              // dirichlet boundary condition type; 0: NOT, 1: ZERO, 2: NONZERO
                              {"BCorder", 1},
                              {"BCbasis", 9},
                              {"BCtarget", 3},
                              {"BCfixed", 1},
                              {"BCsoft", 1}, // mark if this dof is a soft boundary vert or not
                              {"ws", 1},     // also as constraint jacobian
                              {"cons", 3},
                              {"lambda", 3},

                              {"dir", 3},
                              {"xn", 3},
                              {"vn", 3},
                              {"x0", 3}, // initial positions
                              {"xn0", 3},
                              {"xtilde", 3},
                              {"xhat", 3}, // initial positions at the current substep (constraint,
                                           // extforce)
                              {"temp", 3},
                              {"r", 3},
                              {"p", 3},
                              {"q", 3}},
                             numDofs};
            // inertial hessian
            tempPB = dtiles_t{vtemp.get_allocator(), {{"Hi", 9}}, coOffset};
            nPP.setVal(0);
            nPE.setVal(0);
            nPT.setVal(0);
            nEE.setVal(0);

            ncsPT.setVal(0);
            ncsEE.setVal(0);

            auto cudaPol = zs::cuda_exec();
            // average edge length (for CCD filtering)
            meanEdgeLength = averageSurfEdgeLength(cudaPol);
            meanSurfaceArea = averageSurfArea(cudaPol);
            initialize(cudaPol);
            fmt::print("num total obj <verts, surfV, surfE, surfT>: {}, {}, {}, {}\n", coOffset, svOffset, seOffset,
                       sfOffset);
            {
                {
                    auto triBvs = retrieve_bounding_volumes(cudaPol, vtemp, "xn", stInds, zs::wrapv<3>{}, 0);
                    stBvh.build(cudaPol, triBvs);
                    auto edgeBvs = retrieve_bounding_volumes(cudaPol, vtemp, "xn", seInds, zs::wrapv<2>{}, 0);
                    seBvh.build(cudaPol, edgeBvs);
                }
                if (coVerts.size()) {
                    auto triBvs = retrieve_bounding_volumes(cudaPol, vtemp, "xn", coEles, zs::wrapv<3>{}, coOffset);
                    bouStBvh.build(cudaPol, triBvs);
                    auto edgeBvs = retrieve_bounding_volumes(cudaPol, vtemp, "xn", coEdges, zs::wrapv<2>{}, coOffset);
                    bouSeBvh.build(cudaPol, edgeBvs);
                }
            }
        }

        std::vector<PrimitiveHandle> prims;

        // (scripted) collision objects
        const dtiles_t &coVerts;
        const tiles_t &coEdges, &coEles;
        dtiles_t vtemp;
        // self contacts
        using pair_t = zs::vec<int, 2>;
        using pair3_t = zs::vec<int, 3>;
        using pair4_t = zs::vec<int, 4>;
        using dpair_t = zs::vec<Ti, 2>;
        using dpair3_t = zs::vec<Ti, 3>;
        using dpair4_t = zs::vec<Ti, 4>;
        zs::Vector<pair_t> PP;
        zs::Vector<int> nPP;
        dtiles_t tempPP;
        zs::Vector<pair3_t> PE;
        zs::Vector<int> nPE;
        dtiles_t tempPE;
        zs::Vector<pair4_t> PT;
        zs::Vector<int> nPT;
        dtiles_t tempPT;
        zs::Vector<pair4_t> EE;
        zs::Vector<int> nEE;
        dtiles_t tempEE;
        // mollifier
        zs::Vector<pair4_t> PPM;
        zs::Vector<int> nPPM;
        dtiles_t tempPPM;
        zs::Vector<pair4_t> PEM;
        zs::Vector<int> nPEM;
        dtiles_t tempPEM;
        zs::Vector<pair4_t> EEM;
        zs::Vector<int> nEEM;
        dtiles_t tempEEM;
        // friction
        zs::Vector<pair_t> FPP;
        zs::Vector<int> nFPP;
        dtiles_t fricPP;
        zs::Vector<pair3_t> FPE;
        zs::Vector<int> nFPE;
        dtiles_t fricPE;
        zs::Vector<pair4_t> FPT;
        zs::Vector<int> nFPT;
        dtiles_t fricPT;
        zs::Vector<pair4_t> FEE;
        zs::Vector<int> nFEE;
        dtiles_t fricEE;
        //

        zs::Vector<T> temp;

        int prevNumPP, prevNumPE, prevNumPT, prevNumEE;
        // unified hessian storage
        Hessian<1> H1;
        Hessian<2> H2;
        Hessian<3> H3;
        Hessian<4> H4;

        zs::Vector<pair4_t> csPT, csEE;
        zs::Vector<int> ncsPT, ncsEE;

        // boundary contacts
        dtiles_t tempPB;
        // end contacts
        const ZenoConstitutiveModel &models;
        // auxiliary data (spatial acceleration)
        using bvs_t = zs::LBvs<3, int, T>;
        bvh_t stBvh, seBvh; // for simulated objects
        bvs_t stBvs, seBvs; // STQ
        tiles_t stInds, seInds, svInds;
        std::size_t coOffset, numDofs;
        std::size_t sfOffset, seOffset, svOffset;
        bvh_t bouStBvh, bouSeBvh; // for collision objects
        bvs_t bouStBvs, bouSeBvs; // STQ
        T meanEdgeLength, meanSurfaceArea, dt, framedt, curRatio;
    };

    void apply() override {
        using namespace zs;
        constexpr auto space = execspace_e::cuda;
        auto cudaPol = cuda_exec().sync(true);

        auto zstets = RETRIEVE_OBJECT_PTRS(ZenoParticles, "ZSParticles");
        // auto zstets = get_input<ZenoParticles>("ZSParticles");
        std::shared_ptr<ZenoParticles> zsboundary;
        if (has_input<ZenoParticles>("ZSBoundaryPrimitives"))
            zsboundary = get_input<ZenoParticles>("ZSBoundaryPrimitives");
        auto models = zstets[0]->getModel();
        auto dt = get_input2<float>("dt");

        /// solver parameters
        auto input_est_num_cps = get_input2<int>("est_num_cps");
        auto input_withGround = get_input2<int>("with_ground");
        auto input_dHat = get_input2<float>("dHat");
        auto input_kappa0 = get_input2<float>("kappa0");
        auto input_fric_mu = get_input2<float>("fric_mu");
        auto input_epsv = get_input2<float>("epsv");
        auto input_aug_coeff = get_input2<float>("aug_coeff");
        auto input_pn_rel = get_input2<float>("pn_rel");
        auto input_cg_rel = get_input2<float>("cg_rel");
        auto input_gravity = get_input2<float>("gravity");
        auto input_pn_cap = get_input2<int>("pn_iter_cap");
        auto input_cg_cap = get_input2<int>("cg_iter_cap");
        auto input_ccd_cap = get_input2<int>("ccd_iter_cap");

        int nSubsteps = get_input2<int>("num_substeps");

        s_enableGround = input_withGround;
        kappa0 = input_kappa0;
        fricMu = input_fric_mu;
        epsv = input_epsv;
        augLagCoeff = input_aug_coeff;
        pnRel = input_pn_rel;
        cgRel = input_cg_rel;
        PNCap = input_pn_cap;
        CGCap = input_cg_cap;
        CCDCap = input_ccd_cap;

        /// if there are no high precision verts, init from the low precision one
        for (auto zstet : zstets) {
            if (!zstet->hasImage(ZenoParticles::s_particleTag)) {
                auto &loVerts = zstet->getParticles();
                auto &verts = zstet->images[ZenoParticles::s_particleTag];
                verts = typename ZenoParticles::dtiles_t{loVerts.get_allocator(), loVerts.getPropertyTags(),
                                                         loVerts.size()};
                cudaPol(range(verts.size()), [loVerts = proxy<space>({}, loVerts),
                                              verts = proxy<space>({}, verts)] __device__(int vi) mutable {
                    // make sure there are no "inds"-like properties in verts!
                    for (int propid = 0; propid != verts._N; ++propid) {
                        auto propOffset = verts._tagOffsets[propid];
                        for (int chn = 0; chn != verts._tagSizes[propid]; ++chn)
                            verts(propOffset + chn, vi) = loVerts(propOffset + chn, vi);
                    }
                });
            }
        }
        if (zsboundary)
            if (!zsboundary->hasImage(ZenoParticles::s_particleTag)) {
                auto &loVerts = zsboundary->getParticles();
                auto &verts = zsboundary->images[ZenoParticles::s_particleTag];
                verts = typename ZenoParticles::dtiles_t{loVerts.get_allocator(), loVerts.getPropertyTags(),
                                                         loVerts.size()};
                cudaPol(range(verts.size()), [loVerts = proxy<space>({}, loVerts),
                                              verts = proxy<space>({}, verts)] __device__(int vi) mutable {
                    // make sure there are no "inds"-like properties in verts!
                    for (int propid = 0; propid != verts._N; ++propid) {
                        auto propOffset = verts._tagOffsets[propid];
                        for (int chn = 0; chn != verts._tagSizes[propid]; ++chn)
                            verts(propOffset + chn, vi) = loVerts(propOffset + chn, vi);
                    }
                });
            }
        const dtiles_t &coVerts = zsboundary ? zsboundary->getParticles<true>() : dtiles_t{};
        const tiles_t &coEdges = zsboundary ? (*zsboundary)[ZenoParticles::s_surfEdgeTag] : tiles_t{};
        const tiles_t &coEles = zsboundary ? zsboundary->getQuadraturePoints() : tiles_t{};

        IPCSystem A{zstets, coVerts, coEdges, coEles, dt, models};

        auto coOffset = A.coOffset;
        auto numDofs = A.numDofs;

        estNumCps = input_est_num_cps > 0 ? input_est_num_cps // if specified, overwrite
                                          : std::max(numDofs * 4, estNumCps);

        dtiles_t &vtemp = A.vtemp;

        /// time integrator
        dHat = input_dHat;
        extForce = vec3{0, input_gravity, 0};
        kappa = kappa0;
        targetGRes = pnRel;
        projectDBC = false;
        BCsatisfied = false;
        useGD = false;

#if s_enableAdaptiveSetting
        {
            A.updateWholeBoundingBoxSize(cudaPol);
            fmt::print("box diag size: {}\n", std::sqrt(boxDiagSize2));
            /// dHat
            dHat = input_dHat * std::sqrt(boxDiagSize2);
            /// grad pn residual tolerance
            targetGRes = pnRel * std::sqrt(boxDiagSize2);
            if (input_kappa0 == 0) {
                /// kappaMin
                A.initKappa(cudaPol);
                /// adaptive kappa
                { // tet-oriented
                    T H_b = computeHb((T)1e-16 * boxDiagSize2, dHat * dHat);
                    kappa = 1e11 * avgNodeMass / (4e-16 * boxDiagSize2 * H_b);
                    kappaMax = 100 * kappa;
                    if (kappa < kappaMin)
                        kappa = kappaMin;
                    if (kappa > kappaMax)
                        kappa = kappaMax;
                }
                { // surf oriented (use framedt here)
                    auto kappaSurf = dt * dt * A.meanSurfaceArea / 3 * dHat * A.largestMu();
                    fmt::print("kappaSurf: {}, auto kappa: {}\n", kappaSurf, kappa);
                    if (kappaSurf > kappa && kappaSurf < kappaMax) {
                        kappa = kappaSurf;
                    }
                }
                // boundaryKappa = kappa;
                fmt::print("average node mass: {}, auto kappa: {} ({} - {})\n", avgNodeMass, kappa, kappaMin, kappaMax);
            } else {
                fmt::print("manual kappa: {}\n", kappa);
            }
            // getchar();
        }
#endif
        if constexpr (s_enableFriction) {
            if (epsv == 0) {
                epsv = dHat;
            } else {
                epsv *= dHat;
            }
        }
        // extForce here means gravity acceleration (not actually force)
        // targetGRes = std::min(targetGRes, extForce.norm() * dt * dt * (T)0.5 /
        //                                      nSubsteps / nSubsteps);
        fmt::print("auto dHat: {}, targetGRes: {}, epsv (friction): {}\n", dHat, targetGRes, epsv);

        for (int subi = 0; subi != nSubsteps; ++subi) {
            fmt::print("processing substep {}\n", subi);

            projectDBC = false;
            BCsatisfied = false;
            useGD = false;
            A.advanceSubstep(cudaPol, (T)1 / nSubsteps);

            int numFricSolve = s_enableFriction ? 2 : 1;
        for_fric:
            /// optimizer
            for (int newtonIter = 0; newtonIter != PNCap; ++newtonIter) {
                // check constraints
                if (!BCsatisfied) {
                    A.computeConstraints(cudaPol, "xn");
                    auto cr = A.constraintResidual(cudaPol, true);
                    if (A.areConstraintsSatisfied(cudaPol)) {
                        fmt::print("satisfied cons res [{}] at newton iter [{}]\n", cr, newtonIter);
                        // A.checkDBCStatus(cudaPol);
                        // getchar();
                        projectDBC = true;
                        BCsatisfied = true;
                    }
                    fmt::print(fg(fmt::color::alice_blue), "substep {} newton iter {} cons residual: {}\n", subi,
                               newtonIter, cr);
                }

                if constexpr (s_enableContact) {
                    A.findCollisionConstraints(cudaPol, dHat, xi);
                }
                if constexpr (s_enableFriction)
                    if (fricMu != 0) {
                        A.precomputeFrictions(cudaPol, dHat, xi);
                    }
                // construct gradient, prepare hessian, prepare preconditioner
                cudaPol(zs::range(numDofs), [vtemp = proxy<space>({}, vtemp)] __device__(int i) mutable {
                    vtemp.tuple<9>("P", i) = mat3::zeros();
                    vtemp.tuple<3>("grad", i) = vec3::zeros();
                });
                A.computeInertialAndGravityPotentialGradient(cudaPol, "grad");
                match([&](auto &elasticModel) { A.computeElasticGradientAndHessian(cudaPol, elasticModel); })(
                    models.getElasticModel());
                if (s_enableGround)
                    A.computeBoundaryBarrierGradientAndHessian(cudaPol);
                if constexpr (s_enableContact) {
                    A.computeBarrierGradientAndHessian(cudaPol, "grad");
                    if constexpr (s_enableFriction)
                        if (fricMu != 0) {
                            A.computeFrictionBarrierGradientAndHessian(cudaPol, "grad");
                        }
                }

                // rotate gradient
                // here we assume boundary dofs are all STICKY, thus BCbasis is I
                cudaPol(zs::range(coOffset), [vtemp = proxy<space>({}, vtemp)] __device__(int i) mutable {
                    auto grad = vtemp.pack<3, 3>("BCbasis", i).transpose() * vtemp.pack<3>("grad", i);
                    vtemp.tuple<3>("grad", i) = grad;
                });
                // apply constraints (augmented lagrangians) after rotation!
                if (!BCsatisfied) {
                    // grad
                    cudaPol(zs::range(numDofs),
                            [vtemp = proxy<space>({}, vtemp), boundaryKappa = boundaryKappa] __device__(int i) mutable {
                                // computed during the previous constraint residual check
                                auto cons = vtemp.pack<3>("cons", i);
                                auto w = vtemp("ws", i);
                                vtemp.tuple<3>("grad", i) = vtemp.pack<3>("grad", i) + w * vtemp.pack<3>("lambda", i) -
                                                            boundaryKappa * w * cons;
                                int BCfixed = vtemp("BCfixed", i);
                                if (!BCfixed) {
                                    int BCorder = vtemp("BCorder", i);
                                    for (int d = 0; d != BCorder; ++d)
                                        vtemp("P", 4 * d, i) += boundaryKappa * w;
                                }
                            });
                    // hess (embedded in multiply)
                }
                // project
                A.project(cudaPol, "grad");

                // prepare preconditioner
                cudaPol(zs::range(numDofs), [vtemp = proxy<space>({}, vtemp)] __device__(int i) mutable {
                    auto mat = vtemp.pack<3, 3>("P", i);
                    if (zs::abs(zs::determinant(mat)) > limits<T>::epsilon() * 10)
                        vtemp.tuple<9>("P", i) = inverse(mat);
                    else
                        vtemp.tuple<9>("P", i) = mat3::identity();
                });

                // modify initial x so that it satisfied the constraint.

                // A dir = grad
                A.cgsolve(cudaPol, useGD);

                // recover rotated solution
                cudaPol(Collapse{vtemp.size()}, [vtemp = proxy<space>({}, vtemp)] __device__(int vi) mutable {
                    vtemp.tuple<3>("dir", vi) = vtemp.pack<3, 3>("BCbasis", vi) * vtemp.pack<3>("dir", vi);
                });
                // check "dir" inf norm
                T res = A.infNorm(cudaPol, vtemp, "dir") / dt;
                T cons_res = A.constraintResidual(cudaPol);
                if (!useGD && res < targetGRes && cons_res == 0) {
                    fmt::print("\t# newton optimizer ends in {} iters with residual {}\n", newtonIter, res);
                    break;
                }

                fmt::print(fg(fmt::color::aquamarine),
                           "substep {} newton iter {}: direction residual(/dt) {}, "
                           "grad residual {}\n",
                           subi, newtonIter, res, A.infNorm(cudaPol, vtemp, "grad"));

                // xn0 <- xn for line search
                cudaPol(zs::range(vtemp.size()), [vtemp = proxy<space>({}, vtemp)] __device__(int i) mutable {
                    vtemp.tuple<3>("xn0", i) = vtemp.pack<3>("xn", i);
                });

                // line search
                bool CCDfiltered = false;
                T alpha = 1.;
                T prevAlpha{limits<T>::infinity()};
                { //
#if 1
                    // average length
                    zs::Vector<T> lens{vtemp.get_allocator(), coOffset};
                    cudaPol(Collapse{coOffset},
                            [lens = proxy<space>(lens), vtemp = proxy<space>({}, vtemp)] __device__(int ei) mutable {
                                // lens[ei] = vtemp.template pack<3>("dir", ei).norm();
                                lens[ei] = vtemp.template pack<3>("dir", ei).abs().sum();
                            });
                    auto meanDirSize = (A.reduce(cudaPol, lens) / dt) / coOffset;
                    auto spanSize = meanDirSize * alpha / (A.meanEdgeLength * refStepsizeCoeff);
#else
                    // infNorm
                    auto spanSize = res * alpha / (A.meanEdgeLength * 1);
#endif
#if 0
          if (spanSize > 1) { // mainly for reducing ccd pairs
            alpha /= spanSize;
            CCDfiltered = true;
            fmt::print("\tstepsize after dir magnitude pre-filtering: {} "
                       "(spansize: {})\n",
                       alpha, spanSize);
            prevAlpha = alpha;
          }
#endif
                }
                if (s_enableGround) {
                    A.groundIntersectionFreeStepsize(cudaPol, alpha);
                    fmt::print("\tstepsize after ground: {}\n", alpha);
                }
#if s_enableContact
                {
                    // A.intersectionFreeStepsize(cudaPol, xi, alpha);
                    // fmt::print("\tstepsize after intersection-free: {}\n", alpha);
                    A.findCCDConstraints(cudaPol, alpha, xi);
                    auto [npp, npe, npt, nee, nppm, npem, neem, ncspt, ncsee] = A.getCnts();
                    A.intersectionFreeStepsize(cudaPol, xi, alpha);
                    fmt::print("\tstepsize after ccd: {}. (ncspt: {}, ncsee: {})\n", alpha, ncspt, ncsee);
/// check discrete collision
#if s_enableDCDCheck
                    while (A.checkSelfIntersection(cudaPol)) {
                        alpha /= 2;
                        cudaPol(zs::range(vtemp.size()),
                                [vtemp = proxy<space>({}, vtemp), alpha] __device__(int i) mutable {
                                    vtemp.tuple<3>("xn", i) = vtemp.pack<3>("xn0", i) + alpha * vtemp.pack<3>("dir", i);
                                });
                    }
                    fmt::print("\tstepsize after dcd: {}.\n", alpha);
#endif
                }
#endif

                A.lineSearch(cudaPol, alpha, CCDfiltered);

                if (CCDfiltered && prevAlpha == alpha) {
                    if (++numContinuousCap < 8)
                        refStepsizeCoeff++;
                } else {
                    refStepsizeCoeff = 1;
                    numContinuousCap = 0;
                }

                cudaPol(zs::range(vtemp.size()), [vtemp = proxy<space>({}, vtemp), alpha] __device__(int i) mutable {
                    vtemp.tuple<3>("xn", i) = vtemp.pack<3>("xn0", i) + alpha * vtemp.pack<3>("dir", i);
                });

/// check discrete collision
#if s_enableDCDCheck
                while (A.checkSelfIntersection(cudaPol)) {
                    alpha /= 2;
                    cudaPol(zs::range(vtemp.size()),
                            [vtemp = proxy<space>({}, vtemp), alpha] __device__(int i) mutable {
                                vtemp.tuple<3>("xn", i) = vtemp.pack<3>("xn0", i) + alpha * vtemp.pack<3>("dir", i);
                            });
                }
#endif

                if (alpha < 1e-8) {
                    useGD = true;
                } else {
                    useGD = false;
                }

#if s_enableAdaptiveSetting
                if (A.updateKappaRequired(cudaPol))
                    if (kappa < kappaMax) {
                        kappa *= 2;
                        fmt::print(fg(fmt::color::blue_violet), "increasing kappa to {} (max: {})\n", kappa, kappaMax);
                        getchar();
                        getchar();
                    }
#endif

                // update rule
                cons_res = A.constraintResidual(cudaPol);
                if (res * dt < updateZoneTol && cons_res > consTol) {
                    if (boundaryKappa < kappaMax) {
                        boundaryKappa *= 2;
                        fmt::print(fg(fmt::color::ivory),
                                   "increasing boundarykappa to {} due to constraint "
                                   "difficulty.\n",
                                   boundaryKappa);
                        // getchar();
                    } else {
                        cudaPol(Collapse{numDofs}, [vtemp = proxy<space>({}, vtemp),
                                                    boundaryKappa = boundaryKappa] __device__(int vi) mutable {
                            if (int BCorder = vtemp("BCorder", vi); BCorder > 0) {
                                vtemp.tuple<3>("lambda", vi) =
                                    vtemp.pack<3>("lambda", vi) -
                                    boundaryKappa * vtemp("ws", vi) * vtemp.pack<3>("cons", vi);
                            }
                        });
                        fmt::print(fg(fmt::color::ivory), "updating constraint lambda due to constraint difficulty.\n");
                        // getchar();
                    }
                }
            } // end newton step
            if (--numFricSolve > 0)
                goto for_fric;

            A.updateVelocities(cudaPol);
        }

        // update velocity and positions
        A.updatePositionsAndVelocities(cudaPol);
        // not sure if this is necessary for numerical reasons
        if (auto coSize = coVerts.size(); coSize)
            cudaPol(Collapse(coSize),
                    [vtemp = proxy<space>({}, vtemp), verts = proxy<space>({}, zsboundary->getParticles<true>()),
                     loVerts = proxy<space>({}, zsboundary->getParticles()), coOffset] __device__(int vi) mutable {
                        auto newX = vtemp.pack<3>("xn", coOffset + vi);
                        verts.tuple<3>("x", vi) = newX;
                        loVerts.tuple<3>("x", vi) = newX;
                        // no need to update v here. positions are moved accordingly
                        // also, boundary velocies are set elsewhere
                    });

        set_output("ZSParticles", get_input("ZSParticles"));
    }
};

ZENDEFNODE(CodimStepping, {{
                               "ZSParticles",
                               "ZSBoundaryPrimitives",
                               {"int", "est_num_cps", "0"},
                               {"int", "with_ground", "0"},
                               {"float", "dt", "0.01"},
                               {"float", "dHat", "0.001"},
                               {"float", "epsv", "0.0"},
                               {"float", "kappa0", "1e3"},
                               {"float", "fric_mu", "0"},
                               {"float", "aug_coeff", "1e3"},
                               {"float", "pn_rel", "0.01"},
                               {"float", "cg_rel", "0.0001"},
                               {"int", "pn_iter_cap", "1000"},
                               {"int", "cg_iter_cap", "500"},
                               {"int", "ccd_iter_cap", "20000"},
                               {"float", "gravity", "-9.0"},
                               {"int", "num_substeps", "1"},
                           },
                           {"ZSParticles"},
                           {},
                           {"FEM"}});

} // namespace zeno

#include "FricIpc.inl"
#include "Ipc.inl"