#!/bin/bash

cd lib/expat/build

cmake .. \
	-DBUILD_SHARED_LIBS=OFF \
	-DCMAKE_INSTALL_PREFIX=../../build \
	-DCMAKE_BUILD_TYPE=Release && \
	cmake --build . --config Release && \
	cmake --install . --config Release

cd ../..

