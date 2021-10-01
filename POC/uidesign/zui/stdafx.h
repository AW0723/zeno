#pragma once

#include <cmath>
#include <cstdio>
#include <thread>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <variant>
#include <optional>
#include <functional>
#if defined(__linux__)
#include <unistd.h>
#endif
#include <glad/glad.h>
#include <GLFW/glfw3.h>
#include <FTGL/ftgl.h>
#include <memory>
#include <string>
#include <vector>
#include <tuple>
#include <list>
#include <set>
#include <map>
#include <any>
#include "ztd/containers.h"


//#ifdef __CLANGD__
//#define nclangd(...)
//#else
//#define nclangd(...) __VA_ARGS__
//#endif


#define typenameof(x) typeid(*(x)).name()