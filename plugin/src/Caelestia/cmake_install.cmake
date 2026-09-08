# Install script for directory: /home/luisp/.config/minerva_shell/plugin/src/Caelestia

# Set the install prefix
if(NOT DEFINED CMAKE_INSTALL_PREFIX)
  set(CMAKE_INSTALL_PREFIX "/usr/local")
endif()
string(REGEX REPLACE "/$" "" CMAKE_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")

# Set the install configuration name.
if(NOT DEFINED CMAKE_INSTALL_CONFIG_NAME)
  if(BUILD_TYPE)
    string(REGEX REPLACE "^[^A-Za-z0-9_]+" ""
           CMAKE_INSTALL_CONFIG_NAME "${BUILD_TYPE}")
  else()
    set(CMAKE_INSTALL_CONFIG_NAME "")
  endif()
  message(STATUS "Install configuration: \"${CMAKE_INSTALL_CONFIG_NAME}\"")
endif()

# Set the component getting installed.
if(NOT CMAKE_INSTALL_COMPONENT)
  if(COMPONENT)
    message(STATUS "Install component: \"${COMPONENT}\"")
    set(CMAKE_INSTALL_COMPONENT "${COMPONENT}")
  else()
    set(CMAKE_INSTALL_COMPONENT)
  endif()
endif()

# Install shared libraries without execute permission?
if(NOT DEFINED CMAKE_INSTALL_SO_NO_EXE)
  set(CMAKE_INSTALL_SO_NO_EXE "0")
endif()

# Is this installation the result of a crosscompile?
if(NOT DEFINED CMAKE_CROSSCOMPILING)
  set(CMAKE_CROSSCOMPILING "FALSE")
endif()

# Set path to fallback-tool for dependency-resolution.
if(NOT DEFINED CMAKE_OBJDUMP)
  set(CMAKE_OBJDUMP "/usr/bin/objdump")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  if(EXISTS "$ENV{DESTDIR}/Caelestia/lib/libcaelestia.so" AND
     NOT IS_SYMLINK "$ENV{DESTDIR}/Caelestia/lib/libcaelestia.so")
    file(RPATH_CHECK
         FILE "$ENV{DESTDIR}/Caelestia/lib/libcaelestia.so"
         RPATH [[$ORIGIN:$ORIGIN/../lib]])
  endif()
  list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES
   "/Caelestia/lib/libcaelestia.so")
  if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  file(INSTALL DESTINATION "/Caelestia/lib" TYPE SHARED_LIBRARY FILES "/home/luisp/.config/minerva_shell/plugin/src/Caelestia/libcaelestia.so")
  if(EXISTS "$ENV{DESTDIR}/Caelestia/lib/libcaelestia.so" AND
     NOT IS_SYMLINK "$ENV{DESTDIR}/Caelestia/lib/libcaelestia.so")
    file(RPATH_CHANGE
         FILE "$ENV{DESTDIR}/Caelestia/lib/libcaelestia.so"
         OLD_RPATH "::::::::::::::::::::::"
         NEW_RPATH [[$ORIGIN:$ORIGIN/../lib]])
    if(CMAKE_INSTALL_DO_STRIP)
      execute_process(COMMAND "/usr/bin/strip" "$ENV{DESTDIR}/Caelestia/lib/libcaelestia.so")
    endif()
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  if(EXISTS "$ENV{DESTDIR}/Caelestia/libcaelestiaplugin.so" AND
     NOT IS_SYMLINK "$ENV{DESTDIR}/Caelestia/libcaelestiaplugin.so")
    file(RPATH_CHECK
         FILE "$ENV{DESTDIR}/Caelestia/libcaelestiaplugin.so"
         RPATH [[$ORIGIN:$ORIGIN/../lib:$ORIGIN/lib]])
  endif()
  list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES
   "/Caelestia/libcaelestiaplugin.so")
  if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  file(INSTALL DESTINATION "/Caelestia" TYPE MODULE FILES "/home/luisp/.config/minerva_shell/plugin/qml/Caelestia/libcaelestiaplugin.so")
  if(EXISTS "$ENV{DESTDIR}/Caelestia/libcaelestiaplugin.so" AND
     NOT IS_SYMLINK "$ENV{DESTDIR}/Caelestia/libcaelestiaplugin.so")
    file(RPATH_CHANGE
         FILE "$ENV{DESTDIR}/Caelestia/libcaelestiaplugin.so"
         OLD_RPATH "/home/luisp/.config/minerva_shell/plugin/src/Caelestia:"
         NEW_RPATH [[$ORIGIN:$ORIGIN/../lib:$ORIGIN/lib]])
    if(CMAKE_INSTALL_DO_STRIP)
      execute_process(COMMAND "/usr/bin/strip" "$ENV{DESTDIR}/Caelestia/libcaelestiaplugin.so")
    endif()
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES
   "/Caelestia/qmldir")
  if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  file(INSTALL DESTINATION "/Caelestia" TYPE FILE FILES "/home/luisp/.config/minerva_shell/plugin/qml/Caelestia/qmldir")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES
   "/Caelestia/caelestia.qmltypes")
  if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  file(INSTALL DESTINATION "/Caelestia" TYPE FILE FILES "/home/luisp/.config/minerva_shell/plugin/qml/Caelestia/caelestia.qmltypes")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/luisp/.config/minerva_shell/plugin/src/Caelestia/Components/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/luisp/.config/minerva_shell/plugin/src/Caelestia/Config/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/luisp/.config/minerva_shell/plugin/src/Caelestia/Internal/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/luisp/.config/minerva_shell/plugin/src/Caelestia/Models/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/luisp/.config/minerva_shell/plugin/src/Caelestia/Services/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/luisp/.config/minerva_shell/plugin/src/Caelestia/Blobs/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/luisp/.config/minerva_shell/plugin/src/Caelestia/Images/cmake_install.cmake")
endif()

string(REPLACE ";" "\n" CMAKE_INSTALL_MANIFEST_CONTENT
       "${CMAKE_INSTALL_MANIFEST_FILES}")
if(CMAKE_INSTALL_LOCAL_ONLY)
  file(WRITE "/home/luisp/.config/minerva_shell/plugin/src/Caelestia/install_local_manifest.txt"
     "${CMAKE_INSTALL_MANIFEST_CONTENT}")
endif()
