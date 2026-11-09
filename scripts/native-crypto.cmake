# Included by both native CMake generators. EVP keeps CPU dispatch inside OpenSSL.
option(VHDX_OPENSSL "Use the pinned static OpenSSL EVP backend for BitLocker" ON)
option(VHDX_CRYPTO_BENCHMARK "Build isolated sector-sized AES correctness/bench tools" OFF)
set(VHDX_OPENSSL_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.native/openssl-windows-x64" CACHE PATH "Pinned OpenSSL build")
file(READ "${CMAKE_CURRENT_LIST_DIR}/openssl-source.json" openssl_manifest)
string(JSON openssl_version GET "${openssl_manifest}" version)
set(openssl_source "${CMAKE_CURRENT_LIST_DIR}/../.native/src/openssl-${openssl_version}")
function(vhdx_use_openssl target)
  if(NOT EXISTS "${VHDX_OPENSSL_ROOT}/libcrypto.lib")
    message(FATAL_ERROR "Run scripts/build-openssl-windows.ps1 first")
  endif()
  target_include_directories(${target} PRIVATE "${VHDX_OPENSSL_ROOT}/include" "${openssl_source}/include")
  target_compile_definitions(${target} PRIVATE HAVE_LIBCRYPTO=1 HAVE_OPENSSL_EVP_H=1
    HAVE_EVP_CRYPTO_AES_ECB=1 HAVE_EVP_CRYPTO_AES_CBC=1 HAVE_EVP_CRYPTO_AES_XTS=1
    # OpenSSL 3 branch explicitly disables padding. The legacy EVP branch
    # enables PKCS padding and is NOT valid for raw CBC/ECB disk sectors.
    HAVE_EVP_CIPHERINIT_EX2=1)
  target_link_libraries(${target} PRIVATE "${VHDX_OPENSSL_ROOT}/libcrypto.lib" ws2_32 crypt32 advapi32 user32 bcrypt)
endfunction()
if(VHDX_OPENSSL)
  vhdx_use_openssl(libbde)
endif()
if(VHDX_CRYPTO_BENCHMARK)
  file(READ "${CMAKE_CURRENT_LIST_DIR}/native-sources.json" native_manifest)
  string(JSON bde_version GET "${native_manifest}" 2 version)
  set(bde_source "${CMAKE_CURRENT_LIST_DIR}/../.native/src/libbde-${bde_version}")
  foreach(backend builtin openssl)
    add_executable(crypto_${backend} "${CMAKE_CURRENT_LIST_DIR}/benchmarks/crypto.c"
      "${bde_source}/libcaes/libcaes_context.c" "${bde_source}/libcaes/libcaes_tweaked_context.c"
      "${bde_source}/libcerror/libcerror_error.c" "${bde_source}/libcerror/libcerror_system.c")
    target_include_directories(crypto_${backend} PRIVATE "${bde_source}/common" "${bde_source}/include"
      "${bde_source}/libcaes" "${bde_source}/libcerror")
    target_compile_definitions(crypto_${backend} PRIVATE HAVE_LOCAL_LIBCAES HAVE_LOCAL_LIBCERROR
      _CRT_SECURE_NO_DEPRECATE _CRT_NONSTDC_NO_WARNINGS)
    if(backend STREQUAL "openssl")
      vhdx_use_openssl(crypto_${backend})
    endif()
  endforeach()
endif()
