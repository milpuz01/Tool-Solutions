#!/usr/bin/env bash

# *******************************************************************************
# Copyright 2020-2023 Arm Limited and affiliates.
# Copyright 2022 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# *******************************************************************************

set -euo pipefail

cd $PACKAGE_DIR
readonly package=pytorch
readonly version=$TORCH_VERSION
readonly src_host=https://github.com/pytorch
readonly src_repo=pytorch
readonly num_cpus=$(nproc)

# Clone PyTorch
git clone ${src_host}/${src_repo}.git
cd ${src_repo}
git checkout v$version -b v$version
git submodule sync
git submodule update --init --recursive

export USE_MKLDNN="OFF"
export USE_MKLDNN_ACL="OFF"
if [[ $ONEDNN_BUILD ]]; then
  export USE_MKLDNN="ON"
  case $ONEDNN_BUILD in
    reference )
    ;;
    acl )
    export USE_MKLDNN_ACL="ON"
    ;;
  esac
fi

# Update the oneDNN tag in third_party/ideep
cd third_party/ideep/mkl-dnn
rm -rf third_party/* && cd third_party
git clone https://github.com/oneapi-src/oneDNN.git oneDNN
cd oneDNN
git checkout $ONEDNN_VERSION

# Do not add C++11 CMake CXX flag when building with ACL and
# rename test_api to test_api_dnnl so it does not clash with PyTorch test_api
patch -p1 < $PACKAGE_DIR/onednn.patch

# Remove unsupported winograd kernel
patch -p1 < $PACKAGE_DIR/onednn_acl_remove_winograd.patch

# Support for fixed format kernels
patch -p1 < $PACKAGE_DIR/onednn_acl_fixed_format_kernels.patch

# Support for depthwise convolution
patch -p1 < $PACKAGE_DIR/onednn_acl_depthwise_convolution.patch

# Support for jitted padded reordering
patch -p1 < $PACKAGE_DIR/onednn_reorder_padded.patch
wget https://github.com/oneapi-src/oneDNN/commit/b84c533dad4db495a92fc6d390a7db5ebd938a88.patch -O $PACKAGE_DIR/onednn_reorder_update.patch
patch -p1 < $PACKAGE_DIR/onednn_reorder_update.patch

# Enable depthwise convolution with dilation
patch -p1 < $PACKAGE_DIR/onednn_acl_depthwise_convolution_dilation.patch

# Support for jitted reordering to BF16
patch -p1 < $PACKAGE_DIR/onednn_reorder_to_bf16.patch

cd $PACKAGE_DIR/$src_repo
# Call into ACL for some BLAS calls
patch -p1 < $PACKAGE_DIR/blas_to_mkl_acl.patch

if [[ $XLA_BUILD ]]; then
  readonly xla_version=$TORCHXLA_VERSION
  readonly xla_repo=xla

  # Clone torch xla
  git clone ${src_host}/${xla_repo}.git
  cd ${xla_repo}
  git checkout v$xla_version -b v$xla_version
  git submodule sync
  git submodule update --init --recursive

  cd $PACKAGE_DIR/$src_repo
  # Patch up the torch with the xla support. This is the patch list from upstream pytorch/xla repo
  xla/scripts/apply_patches.sh
fi

MAX_JOBS=${NP_MAKE:-$((num_cpus / 2))} PYTORCH_BUILD_VERSION=$TORCH_VERSION \
  PYTORCH_BUILD_NUMBER=1 OpenBLAS_HOME=$OPENBLAS_DIR BLAS="OpenBLAS" \
  CXX_FLAGS="$BASE_CFLAGS -O3 -mcpu=$CPU" LDFLAGS=$BASE_LDFLAGS USE_OPENMP=1 \
  USE_LAPACK=1 USE_CUDA=0 USE_FBGEMM=0 USE_DISTRIBUTED=0 python setup.py bdist_wheel

# Install the PyTorch python wheel via pip
pip install $(ls -tr dist/*.whl | tail)

# Move the whl into venv for easy extraction from container
mkdir -p $VIRTUAL_ENV/$package/wheel
mv $(ls -tr dist/*.whl | tail) $VIRTUAL_ENV/$package/wheel

# Check the installation was sucessfull
cd $HOME

# Check the wheel has installed ocrrectly.
# Note: only checks the major.minor version numbers, and not the point release
check_version=$(python -c 'import torch; print(torch.__version__)' | cut -f1,2 -d'.')
required_version=$(echo $version | cut -f1,2 -d'.')
if [[ "$check_version" == "$required_version" ]]; then
  echo "PyTorch $required_version package installed."
else
  echo "PyTorch package installation failed."
  exit 1
fi

if [[ $XLA_BUILD ]]; then
  # Now build the torch-xla wheel
  cd $PACKAGE_DIR/$src_repo/$xla_repo

  MAX_JOBS=${NP_MAKE:-$((num_cpus / 2))} TORCH_XLA_VERSION=$TORCHXLA_VERSION \
     VERSIONED_XLA_BUILD=1 BUILD_CPP_TESTS=0 XLA_CPU_USE_ACL=1 \
  CXX_FLAGS="$BASE_CFLAGS -O3 -mcpu=$CPU" LDFLAGS=$BASE_LDFLAGS python setup.py bdist_wheel

  # Install the PyTorch XLA python wheel via pip
  pip install $(ls -tr dist/*.whl | tail)

  # Move the whl into venv for easy extraction from container
  mkdir -p $VIRTUAL_ENV/$package/wheel
  mv $(ls -tr dist/*.whl | tail) $VIRTUAL_ENV/$package/wheel

  # Check the installation was sucessfull
  cd $HOME

  # Check the wheel has installed correctly.
  # Note: only checks the major.minor version numbers, and not the point release
  check_xla_version=$(python -c 'import torch_xla; print(torch_xla.__version__)' | cut -f1,2 -d'.')
  required_xla_version=$(echo $xla_version | cut -f1,2 -d'.')
  if [[ "$check_xla_version" == "$required_xla_version" ]]; then
    echo "PyTorch XLA $required_xla_version package installed."
  else
    echo "PyTorch XLA package installation failed."
    exit 1
  fi
fi
