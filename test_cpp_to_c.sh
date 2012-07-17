#!/bin/sh
#
OUT=Parser_c

luajit cpp_to_c_generator.lua $OUT /usr/include/clang/Parse/Parser.h

clang -c `llvm-config --cflags` -o ${OUT}.o ${OUT}.cpp

