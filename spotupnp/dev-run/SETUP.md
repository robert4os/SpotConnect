# Clone

```
cd ~/dev

# clone only latest commit
git clone --depth 1 --recurse-submodules --remote-submodules https://github.com/robert4os/spotconnect
```

**Submodule cloning notes:**
- `--remote` gets the latest version of each submodule
- `--recommend-shallow` ensures ALL nested submodules use shallow clones (minimal git history)
- `--depth 1` alone only works for top-level submodules, not deeply nested ones
- `--recursive` clones all nested submodules in the hierarchy

```
# clone submodules 
cd ~/dev/spotconnect && git submodule update --init --remote --depth 1

# clone submodule cspot recursively 
cd ~/dev/spotconnect/common/cspot && git submodule update --init --recursive --remote --depth 1 --recommend-shallow

# clone submodule libpupnp recursively
cd ~/dev/spotconnect/common/libpupnp && git submodule update --init --recursive --remote --depth 1 --recommend-shallow

# clone submodule libcodecs recursively
cd ~/dev/spotconnect/common/libcodecs && git submodule update --init --recursive --remote --depth 1 --recommend-shallow
```

# Setup conda for python libraries
```
conda create -n spotconnect_py3_12 python=3.12
conda activate spotconnect_py3_12
conda install protobuf=3.20.3

# confirm its working 
python -c "import google.protobuf; print('Success')"
```

# Libraries and tools
```
# Core build tools
sudo apt-get install cmake
sudo apt-get install build-essential

# Protocol buffers (for building)
sudo apt-get install python3-protobuf
sudo apt-get install protobuf-compiler

# Development libraries
sudo apt-get install libmbedtls-dev
sudo apt-get install libupnp-dev

# Debugging and analysis tools
sudo apt-get install gdb

# Clipboard utilities  
sudo apt-get install xclip

# Additional utilities
sudo apt install diffstat
```

# Build for aarch64 on Ubuntu (WSL under WIndows 11)

## Prepare compilation toolchain

1. Cross compiler
```
# Cross-compilation toolchain
sudo apt-get install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu
```

2. Enable multi-arch if not already done
```
sudo dpkg --add-architecture arm64
```

## Build
```
cd ~/dev/spotconnect/spotupnp


mkdir -p build && rm -rf ./build/*
bash build.sh aarch64 static [clean]
# Note: static is a new option in build.sh
# NOte: Without clean, it does incremental builds - only recompiling changed files, which is much faster.
```

# Build for x86_64 on Ubuntu (WSL under WIndows 11)
```
bash build.sh x86_64 static [clean]
# Note: static is a new option in build.sh
```

# Running
If you run spotupnp without a config file and without these flags, it will just use defaults and not create a config file. You'll see the message "no config file, using defaults" in the logs.

## x86_64 on Ubuntu
mkdir -p /home/rober/.spotconnect
cd ~/dev/spotconnect/spotupnp/build/linux-x86_64
./spotupnp-linux-x86_64-static -x ~/dev/spotconnect/RH/conf/config.xml
