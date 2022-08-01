add_requires("openmp")
add_rules("mode.release", "mode.debug")
add_rules("qt.console")

target("zenoedit")
set_kind("binary")
set_languages("c99", "c++17")

add_files("ui/zenoedit/**.cpp")
add_files("ui/zenoedit/**.h")
add_files("ui/zenoedit/**.ui")
add_files("ui/zenoedit/**.qrc")
add_files("ui/zenoio/**.cpp")
add_files("ui/zenoio/**.h")
add_files("ui/zenoui/**.cpp")
add_files("ui/zenoui/**.h")
add_includedirs("ui/zenoedit")
add_includedirs("ui/zenoui")
add_includedirs("ui/zenoio")
add_includedirs("ui")
add_frameworks("QtGui")
add_frameworks("QtWidgets")
add_frameworks("QtOpenGL")
add_frameworks("QtSvg")

add_files("zenovis/src/**.cpp")
add_includedirs("zenovis/include")
add_files("zenovis/stbi/src/**.c")
add_files("zenovis/stbi/src/**.cpp")
add_includedirs("zenovis/stbi/include")
add_files("zenovis/glad/src/**.c")
add_includedirs("zenovis/glad/include")

add_files("zeno/src/**.cpp")
add_includedirs("zeno/include")
add_includedirs("zeno/tpls/include")
on_load(function (target)
    target:add(find_packages("openmp"))
end)
