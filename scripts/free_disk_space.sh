#!/bin/bash
# Free disk space for Flutter/Xcode/Gradle - run in Terminal when disk is full
# Usage: bash scripts/free_disk_space.sh

set -e
echo "=== Freeing disk space ==="

# 1. Project build folders (this repo)
echo "Cleaning project build folders..."
cd "$(dirname "$0")/.."
rm -rf build/ android/.gradle android/build android/app/build
rm -rf ios/Pods ios/build ios/.symlinks
rm -rf .dart_tool/flutter_build
echo "  Done."

# 2. Xcode DerivedData (~15GB)
if [ -d "$HOME/Library/Developer/Xcode/DerivedData" ]; then
  echo "Removing Xcode DerivedData (this may take 1-2 min)..."
  rm -rf "$HOME/Library/Developer/Xcode/DerivedData"/*
  echo "  Done."
fi

# 3. Xcode ModuleCache
if [ -d "$HOME/Library/Developer/Xcode/DerivedData/ModuleCache.noindex" ]; then
  rm -rf "$HOME/Library/Developer/Xcode/DerivedData/ModuleCache.noindex"
fi

# 4. Gradle caches (~4.5GB) - keeps gradlew stable
echo "Cleaning Gradle caches..."
if [ -d "$HOME/.gradle/caches" ]; then
  rm -rf "$HOME/.gradle/caches"/*
  echo "  Done."
fi

# 5. Flutter clean (optional - needs Flutter SDK)
echo "Running flutter clean..."
if command -v flutter &>/dev/null; then
  flutter clean 2>/dev/null || true
  echo "  Done."
else
  echo "  Skipped (flutter not in PATH)."
fi

echo ""
echo "=== Space freed. Run: flutter pub get && cd ios && pod install && cd .. ==="
echo "Then: flutter run -d <device-id>"
