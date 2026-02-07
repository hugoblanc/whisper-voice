#!/bin/bash
#
# Build universal binary for whisper-server (arm64 + x86_64)
# This creates a single binary that works on both Apple Silicon and Intel Macs
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHISPER_CPP_DIR="${WHISPER_CPP_DIR:-$HOME/Documents/dev/whisper.cpp}"
OUTPUT_DIR="$SCRIPT_DIR/WhisperVoice/Resources"

echo -e "${BLUE}${BOLD}"
echo "========================================"
echo "  Build whisper-server Universal Binary"
echo "========================================"
echo -e "${NC}"

# Check if whisper.cpp exists
if [ ! -d "$WHISPER_CPP_DIR" ]; then
    echo -e "${YELLOW}whisper.cpp not found at $WHISPER_CPP_DIR${NC}"
    echo "Cloning whisper.cpp..."
    git clone https://github.com/ggerganov/whisper.cpp "$WHISPER_CPP_DIR"
fi

cd "$WHISPER_CPP_DIR"

# Clean previous builds
echo -e "${YELLOW}[1/4]${NC} Cleaning previous builds..."
rm -rf build-arm64 build-x86_64

# Build for ARM64 (Apple Silicon)
echo -e "${YELLOW}[2/4]${NC} Building for Apple Silicon (arm64)..."
cmake -B build-arm64 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_BUILD_TYPE=Release \
    -DWHISPER_METAL=ON \
    -DWHISPER_COREML=OFF
cmake --build build-arm64 --config Release -j$(sysctl -n hw.ncpu)

# Build for x86_64 (Intel)
echo -e "${YELLOW}[3/4]${NC} Building for Intel (x86_64)..."
cmake -B build-x86_64 \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 \
    -DCMAKE_BUILD_TYPE=Release \
    -DWHISPER_METAL=OFF \
    -DWHISPER_COREML=OFF
cmake --build build-x86_64 --config Release -j$(sysctl -n hw.ncpu)

# Create universal binary
echo -e "${YELLOW}[4/4]${NC} Creating universal binary..."
mkdir -p "$OUTPUT_DIR"

lipo -create \
    build-arm64/bin/whisper-server \
    build-x86_64/bin/whisper-server \
    -output "$OUTPUT_DIR/whisper-server"

chmod +x "$OUTPUT_DIR/whisper-server"

# Verify
echo ""
echo -e "${GREEN}${BOLD}Build complete!${NC}"
echo ""
echo "Universal binary created at:"
echo -e "  ${BLUE}$OUTPUT_DIR/whisper-server${NC}"
echo ""
echo "Architectures included:"
lipo -info "$OUTPUT_DIR/whisper-server"
echo ""
echo "Size: $(du -h "$OUTPUT_DIR/whisper-server" | cut -f1)"
