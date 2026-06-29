#!/usr/bin/env ruby
# Add files to Xcode project using xcodeproj gem
# This is the proper way to modify Xcode projects programmatically

require 'xcodeproj'

project_path = File.expand_path('~/Projects/sonique-mac/SoniqueBar.xcodeproj')
swift_file = File.expand_path('~/Projects/sonique-mac/SoniqueBar/Core/Voice/EmbeddedTTSProvider.swift')
binary_file = File.expand_path('~/Projects/sonique-mac/tts-engine/dist/sonique-tts')

puts "🔧 Adding files to Xcode project..."
puts "   Project: #{project_path}"
puts "   Swift: #{swift_file}"
puts "   Binary: #{binary_file}"
puts ""

# Open project
project = Xcodeproj::Project.open(project_path)

# Find the SoniqueBar target
target = project.targets.find { |t| t.name == 'SoniqueBar' }
if target.nil?
  puts "❌ Could not find SoniqueBar target"
  exit 1
end

# Find the Voice group
voice_group = project.main_group.find_subpath('SoniqueBar/Core/Voice', true)
if voice_group.nil?
  puts "⚠️  Could not find Voice group, using SoniqueBar group"
  voice_group = project.main_group.find_subpath('SoniqueBar', true)
end

# Add Swift file
swift_ref = voice_group.new_file(swift_file)
target.add_file_references([swift_ref])
puts "✅ Added EmbeddedTTSProvider.swift to project"

# Add binary to resources
binary_ref = project.main_group.new_file(binary_file)
target.resources_build_phase.add_file_reference(binary_ref)
puts "✅ Added sonique-tts to Copy Bundle Resources"

# Add run script phase
run_script_phase = target.new_shell_script_build_phase('Make TTS Binary Executable')
run_script_phase.shell_script = 'chmod +x "$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Resources/sonique-tts"'
puts "✅ Added Run Script phase"

# Save
project.save
puts ""
puts "✅ Xcode project updated successfully!"
puts ""
puts "Next: Build the project"
puts "  cd ~/Projects/sonique-mac"
puts "  xcodebuild -project SoniqueBar.xcodeproj -scheme SoniqueBar clean build"
