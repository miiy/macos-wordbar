#!/bin/bash
set -e
cd "$(dirname "$0")"

mkdir -p WordBar.app/Contents/MacOS WordBar.app/Contents/Resources
swiftc -O -o WordBar.app/Contents/MacOS/WordBar main.swift
cp Info.plist WordBar.app/Contents/Info.plist
[ -f AppIcon.icns ] && cp AppIcon.icns WordBar.app/Contents/Resources/
codesign --force --deep -s - WordBar.app 2>/dev/null || true

echo "Built WordBar.app — run with: open WordBar.app"
