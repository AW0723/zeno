#pragma once

#include <zeno/utils/api.h>
#include <spdlog/spdlog.h>
#include <memory>

namespace zeno {

ZENO_API spdlog::logger &logger();

static inline spdlog::logger &logger(const char *key) {
    return *spdlog::get(key);
}

}