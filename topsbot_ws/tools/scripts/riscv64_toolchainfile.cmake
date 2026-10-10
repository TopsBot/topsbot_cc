# TOPSBOT RISC-V64 交叉编译 toolchain

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_VERSION 1)
set(CMAKE_SYSTEM_PROCESSOR riscv64)

set(CMAKE_C_COMPILER $ENV{CROSS_COMPILE}gcc)
set(CMAKE_CXX_COMPILER $ENV{CROSS_COMPILE}g++)

if(NOT DEFINED ENV{TOPSBOT_SYSROOT} OR "$ENV{TOPSBOT_SYSROOT}" STREQUAL "")
  message(FATAL_ERROR "TOPSBOT_SYSROOT is required (tb injects it from JSON sysroot.dir / url)")
endif()
set(TOPSBOT_SYSROOT "$ENV{TOPSBOT_SYSROOT}")
get_filename_component(TOPSBOT_SYSROOT "${TOPSBOT_SYSROOT}" ABSOLUTE)

set(TOPSBOT_WS_ROOT "${CMAKE_CURRENT_LIST_DIR}/../..")

set(TOPSBOT_ROS_PREFIXES "")
if(EXISTS "${TOPSBOT_SYSROOT}/opt/tbros/humble")
  list(APPEND TOPSBOT_ROS_PREFIXES "${TOPSBOT_SYSROOT}/opt/tbros/humble")
endif()
if(EXISTS "${TOPSBOT_SYSROOT}/opt/ros/humble")
  list(APPEND TOPSBOT_ROS_PREFIXES "${TOPSBOT_SYSROOT}/opt/ros/humble")
endif()

set(CMAKE_FIND_ROOT_PATH
  ${TOPSBOT_WS_ROOT}/install
  ${TOPSBOT_WS_ROOT}/build
  ${TOPSBOT_ROS_PREFIXES}
  ${TOPSBOT_SYSROOT}
)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)

# Run cross-compiled probes/tests under qemu with the sysroot as the target
# root: without -L the emulated binary cannot find
# /lib/ld-linux-riscv64-lp64d.so.1 (the target libs live under ${TOPSBOT_SYSROOT}),
# every try_run() then reports FAILED_TO_RUN and projects silently fall back to
# non-target feature detection (e.g. Fast-DDS "Forcing third party shared_mutex"),
# which changes public class layouts and breaks ABI against the OBS-built packages.
set(CMAKE_CROSSCOMPILING_EMULATOR qemu-riscv64-static -L ${TOPSBOT_SYSROOT})
set(CMAKE_SYSROOT ${TOPSBOT_SYSROOT})

set(BUILD_TESTING OFF)
set(BUILD_HBMEM ON)
if(DEFINED ENV{PYTHON_SOABI} AND NOT "$ENV{PYTHON_SOABI}" STREQUAL "")
  set(PYTHON_SOABI "$ENV{PYTHON_SOABI}")
else()
  set(PYTHON_SOABI cpython-310-riscv64-linux-gnu)
endif()

set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS}")
foreach(_ros_prefix IN LISTS TOPSBOT_ROS_PREFIXES)
  set(CMAKE_EXE_LINKER_FLAGS
    "${CMAKE_EXE_LINKER_FLAGS} -Wl,-rpath-link=${_ros_prefix}/lib/riscv64-linux-gnu -Wl,-rpath-link=${_ros_prefix}/lib/")
endforeach()

set(THREADS_PTHREAD_ARG "0" CACHE STRING "Result from TRY_RUN" FORCE)
