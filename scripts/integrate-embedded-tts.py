#!/usr/bin/env python3
"""
Add EmbeddedTTSProvider.swift and sonique-tts binary to Xcode project.
This script modifies the .pbxproj file directly.
"""

import os
import sys
import uuid
import shutil
from pathlib import Path

def generate_uuid():
    """Generate a unique ID for Xcode (24 uppercase hex chars)."""
    return uuid.uuid4().hex[:24].upper()

def add_file_reference(lines, file_path, file_type, source_tree="<group>"):
    """Add a PBXFileReference entry."""
    file_name = os.path.basename(file_path)
    file_uuid = generate_uuid()

    # Find the /* Begin PBXFileReference section */ marker
    for i, line in enumerate(lines):
        if "Begin PBXFileReference section" in line:
            # Insert after the marker
            insert_idx = i + 1

            if file_type == "swift":
                ref_line = f"\t\t{file_uuid} /* {file_name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {file_name}; sourceTree = {source_tree}; }};\n"
            else:  # binary
                ref_line = f"\t\t{file_uuid} /* {file_name} */ = {{isa = PBXFileReference; lastKnownFileType = \"compiled.mach-o.executable\"; name = {file_name}; path = \"tts-engine/dist/{file_name}\"; sourceTree = SOURCE_ROOT; }};\n"

            lines.insert(insert_idx, ref_line)
            print(f"✅ Added PBXFileReference for {file_name}: {file_uuid}")
            return file_uuid, lines

    print(f"❌ Could not find PBXFileReference section")
    return None, lines

def add_to_group(lines, file_uuid, file_name, group_name="Voice"):
    """Add file to a PBXGroup."""
    in_group = False
    group_depth = 0

    for i, line in enumerate(lines):
        # Look for the Voice group or root group
        if f"/* {group_name} */" in line and "= {" in line:
            in_group = True
            group_depth = 1
            continue

        if in_group:
            if "{" in line:
                group_depth += 1
            if "}" in line:
                group_depth -= 1
                if group_depth == 0:
                    in_group = False

            # Find the children array
            if "children = (" in line:
                # Insert after this line
                insert_idx = i + 1
                child_line = f"\t\t\t\t{file_uuid} /* {file_name} */,\n"
                lines.insert(insert_idx, child_line)
                print(f"✅ Added {file_name} to {group_name} group")
                return lines

    print(f"⚠️  Could not find {group_name} group, file reference added but not in group")
    return lines

def add_to_sources_build_phase(lines, file_uuid, file_name):
    """Add Swift file to PBXSourcesBuildPhase."""
    for i, line in enumerate(lines):
        if "Begin PBXSourcesBuildPhase section" in line:
            # Find the files array in this section
            for j in range(i, min(i + 100, len(lines))):
                if "files = (" in lines[j]:
                    build_file_uuid = generate_uuid()
                    insert_idx = j + 1
                    build_line = f"\t\t\t\t{build_file_uuid} /* {file_name} in Sources */,\n"
                    lines.insert(insert_idx, build_line)
                    print(f"✅ Added {file_name} to Sources build phase")

                    # Now add the PBXBuildFile entry
                    lines = add_build_file(lines, build_file_uuid, file_uuid, file_name)
                    return lines

    print(f"⚠️  Could not add {file_name} to Sources build phase")
    return lines

def add_to_resources_build_phase(lines, file_uuid, file_name):
    """Add binary to PBXResourcesBuildPhase."""
    for i, line in enumerate(lines):
        if "Begin PBXResourcesBuildPhase section" in line:
            # Find the files array
            for j in range(i, min(i + 100, len(lines))):
                if "files = (" in lines[j]:
                    build_file_uuid = generate_uuid()
                    insert_idx = j + 1
                    build_line = f"\t\t\t\t{build_file_uuid} /* {file_name} in Resources */,\n"
                    lines.insert(insert_idx, build_line)
                    print(f"✅ Added {file_name} to Resources build phase")

                    # Add the PBXBuildFile entry
                    lines = add_build_file(lines, build_file_uuid, file_uuid, file_name)
                    return lines

    print(f"⚠️  Could not add {file_name} to Resources build phase")
    return lines

def add_build_file(lines, build_file_uuid, file_ref_uuid, file_name):
    """Add PBXBuildFile entry."""
    for i, line in enumerate(lines):
        if "Begin PBXBuildFile section" in line:
            insert_idx = i + 1
            build_entry = f"\t\t{build_file_uuid} /* {file_name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_uuid} /* {file_name} */; }};\n"
            lines.insert(insert_idx, build_entry)
            print(f"✅ Added PBXBuildFile for {file_name}")
            return lines

    print(f"⚠️  Could not add PBXBuildFile for {file_name}")
    return lines

def add_run_script_phase(lines):
    """Add Run Script build phase to make binary executable."""
    script_uuid = generate_uuid()
    build_phase_uuid = generate_uuid()

    # Add to PBXShellScriptBuildPhase section
    for i, line in enumerate(lines):
        if "Begin PBXShellScriptBuildPhase section" in line:
            insert_idx = i + 1
            script_entry = f'''\t\t{script_uuid} /* Make TTS Binary Executable */ = {{
\t\t\tisa = PBXShellScriptBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\tinputFileListPaths = (
\t\t\t);
\t\t\tinputPaths = (
\t\t\t);
\t\t\tname = "Make TTS Binary Executable";
\t\t\toutputFileListPaths = (
\t\t\t);
\t\t\toutputPaths = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t\tshellPath = /bin/sh;
\t\t\tshellScript = "chmod +x \\"$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Resources/sonique-tts\\"\\n";
\t\t}};
'''
            lines.insert(insert_idx, script_entry)
            print(f"✅ Added Run Script build phase")
            return script_uuid, lines

    return None, lines

def add_script_to_target(lines, script_uuid):
    """Add the run script phase to the target's buildPhases."""
    for i, line in enumerate(lines):
        if "Begin PBXNativeTarget section" in line:
            # Find buildPhases array
            for j in range(i, min(i + 200, len(lines))):
                if "buildPhases = (" in lines[j]:
                    # Find the end of the array
                    for k in range(j, min(j + 20, len(lines))):
                        if ");" in lines[k]:
                            # Insert before the closing
                            insert_idx = k
                            phase_line = f"\t\t\t\t{script_uuid} /* Make TTS Binary Executable */,\n"
                            lines.insert(insert_idx, phase_line)
                            print(f"✅ Added script to target buildPhases")
                            return lines

    print(f"⚠️  Could not add script to target buildPhases")
    return lines

def main():
    project_dir = Path.home() / "Projects" / "sonique-mac"
    pbxproj_path = project_dir / "SoniqueBar.xcodeproj" / "project.pbxproj"

    swift_file = project_dir / "SoniqueBar" / "Core" / "Voice" / "EmbeddedTTSProvider.swift"
    binary_file = project_dir / "tts-engine" / "dist" / "sonique-tts"

    # Verify files exist
    if not swift_file.exists():
        print(f"❌ Swift file not found: {swift_file}")
        sys.exit(1)

    if not binary_file.exists():
        print(f"❌ Binary not found: {binary_file}")
        sys.exit(1)

    if not pbxproj_path.exists():
        print(f"❌ Xcode project file not found: {pbxproj_path}")
        sys.exit(1)

    print("🔧 Adding Embedded TTS to Xcode project...")
    print(f"   Project: {pbxproj_path}")
    print(f"   Swift file: {swift_file.name}")
    print(f"   Binary: {binary_file.name} ({binary_file.stat().st_size / 1024 / 1024:.1f} MB)")
    print()

    # Backup original
    backup_path = pbxproj_path.with_suffix(".pbxproj.backup")
    shutil.copy(pbxproj_path, backup_path)
    print(f"✅ Backed up project to: {backup_path}")

    # Read project file
    with open(pbxproj_path, 'r') as f:
        lines = f.readlines()

    original_line_count = len(lines)

    # Add Swift file
    swift_uuid, lines = add_file_reference(lines, swift_file, "swift")
    if swift_uuid:
        lines = add_to_group(lines, swift_uuid, swift_file.name, "Voice")
        lines = add_to_sources_build_phase(lines, swift_uuid, swift_file.name)

    # Add binary file
    binary_uuid, lines = add_file_reference(lines, binary_file, "binary")
    if binary_uuid:
        lines = add_to_resources_build_phase(lines, binary_uuid, binary_file.name)

    # Add run script phase
    script_uuid, lines = add_run_script_phase(lines)
    if script_uuid:
        lines = add_script_to_target(lines, script_uuid)

    # Write modified project
    with open(pbxproj_path, 'w') as f:
        f.writelines(lines)

    print()
    print(f"✅ Modified project file: {len(lines) - original_line_count} lines added")
    print(f"✅ Integration complete!")
    print()
    print("📝 Next steps:")
    print(f"   1. Open Xcode: open {project_dir}/SoniqueBar.xcodeproj")
    print("   2. Build the project (⌘+B)")
    print("   3. Check Build Phases to verify 'Make TTS Binary Executable' script exists")
    print("   4. Test the integration")

if __name__ == "__main__":
    main()
