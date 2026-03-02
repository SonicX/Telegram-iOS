load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")

filegroup(
    name = "yasm_sources",
    srcs = glob([
        "yasm-1.3.0/**/*"
    ]),
)

genrule(
    name = "yasm",
    srcs = [
        ":yasm_sources",
        "@cmake_tar_gz//file",
    ],
    cmd_bash =
"""
set -x
    core_count=`PATH="$$PATH:/usr/sbin" sysctl -n hw.logicalcpu`
    BUILD_DIR="$(RULEDIR)/build"
    rm -rf "$$BUILD_DIR"
    mkdir -p "$$BUILD_DIR"

    CMAKE_DIR="$$(pwd)/$$BUILD_DIR/cmake"
    rm -rf "$$CMAKE_DIR"
    mkdir -p "$$CMAKE_DIR"

    CMAKE_BIN=""
    if command -v cmake >/dev/null 2>&1; then
        CMAKE_BIN="$$(command -v cmake)"
    elif [ -x "/opt/homebrew/bin/cmake" ]; then
        CMAKE_BIN="/opt/homebrew/bin/cmake"
    else
        COPYFILE_DISABLE=1 tar --no-mac-metadata -xf "$(location @cmake_tar_gz//file)" -C "$$CMAKE_DIR" 2>/dev/null || \
        tar -xf "$(location @cmake_tar_gz//file)" -C "$$CMAKE_DIR"
        CMAKE_BIN="$$CMAKE_DIR/cmake-4.1.2-macos-universal/CMake.app/Contents/bin/cmake"
    fi
    
    SOURCE_PATH="third-party/yasm/yasm-1.3.0"
    cp -R "$$SOURCE_PATH" "$$BUILD_DIR/"

    pushd "$$BUILD_DIR/yasm-1.3.0"
    mkdir build
    cd build
    "$$CMAKE_BIN" .. -DYASM_BUILD_TESTS=OFF -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DPYTHON_EXECUTABLE="$$(which python3)"
    make -j $$core_count
    popd

    tar -cf "$(location yasm.tar)" -C "$$BUILD_DIR/yasm-1.3.0/build" .
""",
    outs = [
        "yasm.tar",
    ],
    visibility = [
        "//visibility:public",
    ]
)
