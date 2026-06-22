# Remove-Item -Path "lib/build" -Recurse -Force -ErrorAction Ignore
# Remove-Item -Path "lib/expat/build" -Recurse -Force -ErrorAction Ignore
# New-Item -Path "lib/build" -ItemType Directory -Force | Out-Null
# New-Item -Path "lib/expat/build" -ItemType Directory -Force | Out-Null
Set-Location "lib/expat/build"

cmake .. `
    -DBUILD_SHARED_LIBS=OFF `
    -DCMAKE_INSTALL_PREFIX="../../build" `
    -DCMAKE_BUILD_TYPE=Release `
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded `
    -DEXPAT_MSVC_STATIC_CRT=ON

if ($LASTEXITCODE -eq 0) {
    cmake --build . --config Release
    
    if ($LASTEXITCODE -eq 0) {
        cmake --install . --config Release
    }
}
Set-Location "../../"
