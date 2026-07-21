#!/bin/bash
# Add new files to Xcode project

PROJECT="SoniqueBar.xcodeproj/project.pbxproj"

# Generate UUIDs for new files
UUID_MODEL=$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | cut -c1-24 | tr '[:lower:]' '[:upper:]')
UUID_SERVICE=$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | cut -c1-24 | tr '[:lower:]' '[:upper:]')

echo "Adding UserPermission.swift..."
echo "Adding PermissionManager.swift..."

# For now, just note that files need manual Xcode addition
echo "✓ Files created - add manually to Xcode:"
echo "  1. SoniqueBar/Models/UserPermission.swift"
echo "  2. SoniqueBar/Services/PermissionManager.swift"
