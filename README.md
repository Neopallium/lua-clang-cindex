lua-clang-cindex
================

LuaJIT 2 FFI bindings for libClang's CIndex inteface.  Includes a C++ to C interface generator.


Build
-----

* run ./make.sh to build FFI callback wrapper.


C++ to C Interface generator
----------------------------

The `cpp_to_c_generator.lua` script creates C bindings to C++ classes.

Usage:

    luajit-2 cpp_to_c_generator.lua output_name input_cpp_header.h

