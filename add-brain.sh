#!/bin/bash
# Add SoniqueBrain.swift to Xcode project via command line

# Generate random IDs for Xcode
FILE_REF=$(openssl rand -hex 12 | tr '[:lower:]' '[:upper:]')
BUILD_FILE=$(openssl rand -hex 12 | tr '[:lower:]' '[:upper:]')

# Add to PBXFileReference section
sed -i '' "/Begin PBXFileReference section/a\\
\\		$FILE_REF /* SoniqueBrain.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SoniqueBrain.swift; sourceTree = \"<group>\"; };\\
" SoniqueBar.xcodeproj/project.pbxproj

# Add to PBXBuildFile section  
sed -i '' "/Begin PBXBuildFile section/a\\
\\		$BUILD_FILE /* SoniqueBrain.swift in Sources */ = {isa = PBXBuildFile; fileRef = $FILE_REF /* SoniqueBrain.swift */; };\\
" SoniqueBar.xcodeproj/project.pbxproj

# Add to Sources build phase
sed -i '' "/ClaudeCodeBridge.swift in Sources/a\\
\\				$BUILD_FILE /* SoniqueBrain.swift in Sources */,\\
" SoniqueBar.xcodeproj/project.pbxproj

echo "Added SoniqueBrain.swift to Xcode project"
echo "FILE_REF: $FILE_REF"
echo "BUILD_FILE: $BUILD_FILE"
