#!/bin/bash

# Agent Monitor - Release Script
# Creates a distributable DMG file

set -e

echo "🧹 Cleaning previous build..."
rm -rf AgentMonitor.app dmg_staging AgentMonitor.dmg
swift package clean

echo "🔨 Building release..."
swift build -c release

echo "📦 Creating app bundle..."
iconutil -c icns AppIcon.iconset -o AppIcon.icns
mkdir -p AgentMonitor.app/Contents/{MacOS,Resources}
cp .build/release/AgentMonitor AgentMonitor.app/Contents/MacOS/
cp Info.plist AgentMonitor.app/Contents/
cp AppIcon.icns AgentMonitor.app/Contents/Resources/

echo "💿 Creating DMG..."
mkdir -p dmg_staging
mv AgentMonitor.app dmg_staging/
ln -s /Applications dmg_staging/Applications
hdiutil create -volname "Agent Monitor" -srcfolder dmg_staging -ov -format UDZO AgentMonitor.dmg

echo "🧹 Cleaning up..."
rm -rf dmg_staging AppIcon.icns

echo ""
echo "✅ Release created: AgentMonitor.dmg"
ls -lh AgentMonitor.dmg
