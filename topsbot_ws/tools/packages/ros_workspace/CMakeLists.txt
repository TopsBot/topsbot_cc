cmake_minimum_required(VERSION 3.5)
project(ros_workspace NONE)

find_package(ament_cmake_core REQUIRED)

# Target python (sysroot). Prefer -DPYTHON_MAJOR_MINOR from build.sh so the
# jammy cross-image host python3 (3.10) is not used against a noble underlay.
if(NOT PYTHON_MAJOR_MINOR)
  execute_process(COMMAND python3 -c "from distutils import sysconfig; print(sysconfig.get_python_version())" OUTPUT_VARIABLE PYTHON_MAJOR_MINOR OUTPUT_STRIP_TRAILING_WHITESPACE)
endif()

# Locate ament_package template files.
if(WIN32)
  set(PYTHON_INSTALL_DIR "lib/site-packages")
  set(SHELL_EXT "bat")
else()
  set(PYTHON_INSTALL_DIR "lib/python${PYTHON_MAJOR_MINOR}/site-packages")
  set(SHELL_EXT "sh")
endif()
set(AMENT_PACKAGE_DIR "${CMAKE_INSTALL_PREFIX}/${PYTHON_INSTALL_DIR}/ament_package")
# Overlay prefix (/opt/tbros/humble): ament_package templates live in the underlay.
if(NOT EXISTS "${AMENT_PACKAGE_DIR}")
  set(AMENT_PACKAGE_DIR "/opt/ros/humble/${PYTHON_INSTALL_DIR}/ament_package")
endif()
if(NOT EXISTS "${AMENT_PACKAGE_DIR}")
  # Check for an .egg-link file and use the listed directory if it exists
  get_filename_component(AMENT_PACKAGE_EGG_LINK "${AMENT_PACKAGE_DIR}" DIRECTORY)
  set(AMENT_PACKAGE_EGG_LINK "${AMENT_PACKAGE_EGG_LINK}/ament-package.egg-link")
  if(NOT EXISTS "${AMENT_PACKAGE_EGG_LINK}")
    message(FATAL_ERROR "Could neither find '${AMENT_PACKAGE_DIR}' nor '${AMENT_PACKAGE_EGG_LINK}'")
  endif()
  file(STRINGS "${AMENT_PACKAGE_EGG_LINK}" AMENT_PACKAGE_DIR)
  list(GET AMENT_PACKAGE_DIR 0 AMENT_PACKAGE_DIR)
  set(AMENT_PACKAGE_DIR "${AMENT_PACKAGE_DIR}/ament_package")
  if(NOT EXISTS "${AMENT_PACKAGE_DIR}")
    message(FATAL_ERROR "Could not find '${AMENT_PACKAGE_DIR}' listed in '${AMENT_PACKAGE_EGG_LINK}'")
  endif()
endif()
set(AMENT_PACKAGE_TEMPLATE_DIR "${AMENT_PACKAGE_DIR}/template")
set(BINARY_PATH_HOOK "${AMENT_PACKAGE_TEMPLATE_DIR}/environment_hook/path.${SHELL_EXT}")
set(PYTHONPATH_HOOK "${AMENT_PACKAGE_TEMPLATE_DIR}/environment_hook/pythonpath.${SHELL_EXT}.in")

# register information for .dsv generation
set(
  AMENT_CMAKE_ENVIRONMENT_HOOKS_DESC_pythonpath
  "prepend-non-duplicate;PYTHONPATH;${PYTHON_INSTALL_DIR}")

# Set environment hooks for default environment.
if(WIN32)
  ament_environment_hooks("${BINARY_PATH_HOOK}" "${PYTHONPATH_HOOK}")
else()
  set(LIBRARY_PATH_HOOK "${AMENT_PACKAGE_TEMPLATE_DIR}/environment_hook/library_path.${SHELL_EXT}")
  # enable C language so that a trycompile can determine what the
  # anticipated libdir will be.
  enable_language(C)
  include(GNUInstallDirs)
  if(NOT ${CMAKE_INSTALL_LIBDIR} STREQUAL "lib")
    # register multiarch information for .dsv generation
    if(APPLE)
      set(LIBRARY_PATH_ENV_VAR "DYLD_LIBRARY_PATH")
    else()
      set(LIBRARY_PATH_ENV_VAR "LD_LIBRARY_PATH")
    endif()
    set(
      AMENT_CMAKE_ENVIRONMENT_HOOKS_DESC_multiarch_library_paths
      "prepend-non-duplicate;${LIBRARY_PATH_ENV_VAR};${CMAKE_INSTALL_LIBDIR}")
    set(MULTIARCH_LIBRARY_PATH_HOOK "env-hooks/multiarch_library_paths.sh.in")
  endif()
  ament_environment_hooks("${BINARY_PATH_HOOK}" "${LIBRARY_PATH_HOOK}" "${PYTHONPATH_HOOK}" ${MULTIARCH_LIBRARY_PATH_HOOK})
endif()

# Overlay: keep parent_prefix_path so /opt/tbros/humble chains to /opt/ros/humble.
# Stock Humble debian packages skip this because everything shares one prefix.

ament_package()
ament_generate_environment()
