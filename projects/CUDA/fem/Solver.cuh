#pragma once
#include "../Structures.hpp"
#include "zensim/container/Bvh.hpp"
#include "zensim/container/Bvs.hpp"
#include "zensim/container/HashTable.hpp"
#include "zensim/container/Vector.hpp"
#include "zensim/cuda/Cuda.h"
#include "zensim/cuda/execution/ExecutionPolicy.cuh"
#include "zensim/math/Vec.h"
#include <zeno/types/PrimitiveObject.h>
#include <zeno/utils/logger.h>
#include <zeno/zeno.h>

namespace zeno {

struct IPCSystem : IObject {
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
    using pair4_t = zs::vec<int, 4>;
    using dpair_t = zs::vec<Ti, 2>;
    using dpair3_t = zs::vec<Ti, 3>;
    using dpair4_t = zs::vec<Ti, 4>;
    using bvh_t = zs::LBvh<3, 32, int, T>;
    using bv_t = zs::AABBBox<3, T>;

    inline static const char s_meanMassTag[] = "MeanMass";
    inline static const char s_meanSurfEdgeLengthTag[] = "MeanSurfEdgeLength";
    inline static const char s_meanSurfAreaTag[] = "MeanSurfArea";
    static constexpr T s_constraint_residual = 1e-2;

    struct PrimitiveHandle {
        PrimitiveHandle(ZenoParticles &zsprim, std::size_t &vOffset, std::size_t &sfOffset, std::size_t &seOffset,
                        std::size_t &svOffset, zs::wrapv<2>);
        PrimitiveHandle(ZenoParticles &zsprim, std::size_t &vOffset, std::size_t &sfOffset, std::size_t &seOffset,
                        std::size_t &svOffset, zs::wrapv<3>);
        PrimitiveHandle(ZenoParticles &zsprim, std::size_t &vOffset, std::size_t &sfOffset, std::size_t &seOffset,
                        std::size_t &svOffset, zs::wrapv<4>);
        // soft springs: only elasticity matters
        PrimitiveHandle(dtiles_t &vtemp, std::shared_ptr<tiles_t> elesPtr);
        T averageNodalMass(zs::CudaExecutionPolicy &pol) const;
        T averageSurfEdgeLength(zs::CudaExecutionPolicy &pol) const;
        T averageSurfArea(zs::CudaExecutionPolicy &pol) const;

        auto getModelLameParams() const {
            T mu, lam;
            zs::match([&](const auto &model) {
                mu = model.mu;
                lam = model.lam;
            })(models.getElasticModel());
            return zs::make_tuple(mu, lam);
        }

        decltype(auto) getVerts() const {
            return *vertsPtr;
        }
        decltype(auto) getEles() const {
            return *elesPtr;
        }
        decltype(auto) getSurfTris() const {
            return *surfTrisPtr;
        }
        decltype(auto) getSurfEdges() const {
            return *surfEdgesPtr;
        }
        decltype(auto) getSurfVerts() const {
            return *surfVertsPtr;
        }
        bool isBoundary() const noexcept {
            return zsprimPtr->asBoundary;
        }

        std::shared_ptr<ZenoParticles> zsprimPtr{}; // nullptr if it is an auxiliary
        const ZenoConstitutiveModel &models;
        std::shared_ptr<ZenoParticles::dtiles_t> vertsPtr;
        std::shared_ptr<ZenoParticles::particles_t> elesPtr;
        typename ZenoParticles::dtiles_t etemp;
        std::shared_ptr<ZenoParticles::particles_t> surfTrisPtr;
        std::shared_ptr<ZenoParticles::particles_t> surfEdgesPtr;
        std::shared_ptr<ZenoParticles::particles_t> surfVertsPtr;
        typename ZenoParticles::dtiles_t svtemp;
        const std::size_t vOffset, sfOffset, seOffset, svOffset;
        ZenoParticles::category_e category;
    };

    T averageNodalMass(zs::CudaExecutionPolicy &pol);
    T averageSurfEdgeLength(zs::CudaExecutionPolicy &pol);
    T averageSurfArea(zs::CudaExecutionPolicy &pol);
    T largestMu() const {
        T mu = 0;
        for (auto &&primHandle : prims) {
            auto [m, l] = primHandle.getModelLameParams();
            if (m > mu)
                mu = m;
        }
        return mu;
    }

    void updateWholeBoundingBoxSize(zs::CudaExecutionPolicy &pol);
    void initKappa(zs::CudaExecutionPolicy &pol);
    void initialize(zs::CudaExecutionPolicy &pol);
    IPCSystem(std::vector<ZenoParticles *> zsprims, const dtiles_t *coVerts, const tiles_t *coLowResVerts,
              const tiles_t *coEdges, const tiles_t *coEles, T dt, std::size_t ncps, bool withGround, bool withContact,
              bool withMollification, T augLagCoeff, T pnRel, T cgRel, int PNCap, int CGCap, int CCDCap, T kappa0,
              T fricMu, T dHat, T epsv, zeno::vec3f gn, T gravity);

    void reinitialize(zs::CudaExecutionPolicy &pol, T framedt);
    void suggestKappa(zs::CudaExecutionPolicy &pol);
    void advanceSubstep(zs::CudaExecutionPolicy &pol, T ratio);
    void updateVelocities(zs::CudaExecutionPolicy &pol);
    void writebackPositionsAndVelocities(zs::CudaExecutionPolicy &pol);

    /// pipeline
    void newtonKrylov(zs::CudaExecutionPolicy &pol);
    // constraint
    void computeConstraints(zs::CudaExecutionPolicy &pol);
    bool areConstraintsSatisfied(zs::CudaExecutionPolicy &pol);
    T constraintResidual(zs::CudaExecutionPolicy &pol, bool maintainFixed = false);
    // contacts
    auto getCnts() const {
        return zs::make_tuple(nPP.getVal(), nPE.getVal(), nPT.getVal(), nEE.getVal(), nPPM.getVal(), nPEM.getVal(),
                              nEEM.getVal(), ncsPT.getVal(), ncsEE.getVal());
    }
    void findCollisionConstraints(zs::CudaExecutionPolicy &pol, T dHat, T xi = 0);
    void findCollisionConstraintsImpl(zs::CudaExecutionPolicy &pol, T dHat, T xi, bool withBoundary = false);
    void precomputeFrictions(zs::CudaExecutionPolicy &pol, T dHat, T xi = 0);
    void findCCDConstraints(zs::CudaExecutionPolicy &pol, T alpha, T xi = 0);
    void findCCDConstraintsImpl(zs::CudaExecutionPolicy &pol, T alpha, T xi, bool withBoundary = false);
    // linear system setup
    void computeInertialAndGravityPotentialGradient(zs::CudaExecutionPolicy &cudaPol);
    void computeInertialPotentialGradient(zs::CudaExecutionPolicy &cudaPol,
                                          const zs::SmallString &gTag); // for kappaMin
    void computeElasticGradientAndHessian(zs::CudaExecutionPolicy &cudaPol, const zs::SmallString &gTag,
                                          bool includeHessian = true);
    void computeBoundaryBarrierGradientAndHessian(zs::CudaExecutionPolicy &pol, bool includeHessian = true);
    void computeBarrierGradientAndHessian(zs::CudaExecutionPolicy &pol, const zs::SmallString &gTag,
                                          bool includeHessian = true);
    void computeFrictionBarrierGradientAndHessian(zs::CudaExecutionPolicy &pol, const zs::SmallString &gTag,
                                                  bool includeHessian = true);
    // krylov solver
    void project(zs::CudaExecutionPolicy &pol, const zs::SmallString tag);
    void precondition(zs::CudaExecutionPolicy &pol, const zs::SmallString srcTag, const zs::SmallString dstTag);
    void multiply(zs::CudaExecutionPolicy &pol, const zs::SmallString dxTag, const zs::SmallString bTag);
    T energy(zs::CudaExecutionPolicy &pol, const zs::SmallString tag, bool includeAugLagEnergy = false);
    void cgsolve(zs::CudaExecutionPolicy &cudaPol);
    void groundIntersectionFreeStepsize(zs::CudaExecutionPolicy &pol, T &stepSize);
    void intersectionFreeStepsize(zs::CudaExecutionPolicy &pol, T xi, T &stepSize);
    void lineSearch(zs::CudaExecutionPolicy &cudaPol, T &alpha);

    // sim params
    int substep = -1;
    std::size_t estNumCps = 1000000;
    bool enableGround = false;
    bool enableContact = true;
    bool enableMollification = true;
    bool s_enableFriction = true;
    bool s_enableSelfFriction = true;
    vec3 s_groundNormal{0, 1, 0};
    T augLagCoeff = 1e4;
    T pnRel = 1e-2;
    T cgRel = 1e-2;
    int PNCap = 1000;
    int CGCap = 500;
    int CCDCap = 20000;
    T kappa0 = 1e4;
    T fricMu = 0;
    T &boundaryKappa = kappa;
    T xi = 0; // 1e-2; // 2e-3;
    T dHat = 0.0025;
    T epsv = 0.0;
    vec3 extForce;

    T kappaMax = 1e8;
    T kappaMin = 1e4;
    T kappa = kappa0;
    bool projectDBC = false;
    bool BCsatisfied = false;
    T updateZoneTol = 1e-1;
    T consTol = 1e-2;
    T armijoParam = 1e-4;
    T boxDiagSize2 = 0;
    T meanEdgeLength = 0, meanSurfaceArea = 0, avgNodeMass = 0;
    T targetGRes = 1e-2;

    //
    std::vector<PrimitiveHandle> prims;
    std::size_t coOffset, numDofs;
    std::size_t sfOffset, seOffset, svOffset;

    // (scripted) collision objects
    const dtiles_t *coVerts;
    const tiles_t *coLowResVerts, *coEdges, *coEles;
    dtiles_t vtemp;
    dtiles_t tempI;

    // self contacts
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
    // end contacts

    zs::Vector<T> temp;

    zs::Vector<pair4_t> csPT, csEE;
    zs::Vector<int> ncsPT, ncsEE;

    // boundary contacts
    // auxiliary data (spatial acceleration)
    tiles_t stInds, seInds, svInds;
    using bvs_t = zs::LBvs<3, int, T>;
    bvh_t stBvh, seBvh;       // for simulated objects
    bvs_t stBvs, seBvs;       // STQ
    bvh_t bouStBvh, bouSeBvh; // for collision objects
    bvs_t bouStBvs, bouSeBvs; // STQ
    T dt, framedt, curRatio;
};

} // namespace zeno

#include "SolverUtils.cuh"