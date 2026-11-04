# The Rust worker owns native handles. Flutter only loads the narrow desktop ABI.
get_filename_component(VHDX_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
find_program(VHDX_CARGO cargo REQUIRED)
add_custom_target(vhdx_rust
  COMMAND "${VHDX_CARGO}" build --release --locked
          --manifest-path "${VHDX_ROOT}/Cargo.toml"
          --target-dir "${VHDX_ROOT}/target/windows" -p vhdx-app
  WORKING_DIRECTORY "${VHDX_ROOT}"
  VERBATIM)
add_dependencies(${BINARY_NAME} vhdx_rust)
install(FILES "${VHDX_ROOT}/target/windows/release/vhdx_app.dll"
        DESTINATION "${CMAKE_INSTALL_PREFIX}/native" COMPONENT Runtime)
foreach(VHDX_LIBRARY libbfio libvhdi libbde libfsntfs)
  install(FILES "${VHDX_ROOT}/.native/build-windows/bin/Release/${VHDX_LIBRARY}.dll"
          DESTINATION "${CMAKE_INSTALL_PREFIX}/native" COMPONENT Runtime)
endforeach()
