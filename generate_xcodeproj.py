#!/usr/bin/env python3
"""Generate SoniqueBar.xcodeproj for the macOS menu bar app."""

import os

UUIDS = {
    "project":           "BB000001000000000000001",
    "main_group":        "BB000002000000000000002",
    "products_group":    "BB000003000000000000003",
    "app_product":       "BB000004000000000000004",
    "sources_phase":     "BB000005000000000000005",
    "resources_phase":   "BB000006000000000000006",
    "frameworks_phase":  "BB000007000000000000007",
    "native_target":     "BB000008000000000000008",
    "debug_config":      "BB000009000000000000009",
    "release_config":    "BB00000A00000000000000A",
    "config_list":       "BB00000B00000000000000B",
    "target_config_list":"BB00000C00000000000000C",
    "target_debug":      "BB00000D00000000000000D",
    "target_release":    "BB00000E00000000000000E",
    "sources_group":     "BB00000F00000000000000F",
    "models_group":      "BB000010000000000000010",
    "services_group":    "BB000011000000000000011",
    "views_group":       "BB000012000000000000012",
    "resources_group":   "BB000013000000000000013",
    "entitlements_ref":  "BB000014000000000000014",
    "plist_ref":         "BB000016000000000000016",
    "plist_build":       "BB000017000000000000017",
    "app_ref":           "BB000020000000000000020",
    "app_build":         "BB000021000000000000021",
    "profile_ref":       "BB000022000000000000022",
    "profile_build":     "BB000023000000000000023",
    "settings_ref":      "BB000024000000000000024",
    "settings_build":    "BB000025000000000000025",
    "monitor_ref":       "BB000026000000000000026",
    "monitor_build":     "BB000027000000000000027",
    "status_ref":        "BB000028000000000000028",
    "status_build":      "BB000029000000000000029",
    "qr_ref":            "BB00002A00000000000000A",
    "qr_build":          "BB00002B00000000000000B",
    "onboard_ref":       "BB00002C00000000000000C",
    "onboard_build":     "BB00002D00000000000000D",
}

SOURCE_FILES = [
    ("app_ref",      "app_build",      "SoniqueBar/SoniqueBarApp.swift",           "sources_group"),
    ("profile_ref",  "profile_build",  "SoniqueBar/Models/AssistantProfile.swift", "models_group"),
    ("settings_ref", "settings_build", "SoniqueBar/Services/MacSettings.swift",    "services_group"),
    ("monitor_ref",  "monitor_build",  "SoniqueBar/Services/ServerMonitor.swift",  "services_group"),
    ("status_ref",   "status_build",   "SoniqueBar/Views/StatusPopover.swift",     "views_group"),
    ("qr_ref",       "qr_build",       "SoniqueBar/Views/QRScannerView.swift",     "views_group"),
    ("onboard_ref",  "onboard_build",  "SoniqueBar/Views/OnboardingView.swift",    "views_group"),
]

def u(key):
    return UUIDS[key]

def main():
    project_dir = os.path.dirname(os.path.abspath(__file__))
    xcodeproj_dir = os.path.join(project_dir, "SoniqueBar.xcodeproj")
    os.makedirs(xcodeproj_dir, exist_ok=True)

    file_ref_lines = []
    build_file_lines = []
    sources_build_refs = []
    group_children = {k: [] for k in ("sources_group", "models_group", "services_group", "views_group")}

    for ref_key, build_key, path, group_key in SOURCE_FILES:
        name = os.path.basename(path)
        file_ref_lines.append(
            f'\t\t{u(ref_key)} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
            f'name = "{name}"; path = "{path}"; sourceTree = SOURCE_ROOT; }};'
        )
        build_file_lines.append(
            f'\t\t{u(build_key)} = {{isa = PBXBuildFile; fileRef = {u(ref_key)}; }};'
        )
        sources_build_refs.append(f'\t\t\t\t{u(build_key)},')
        group_children[group_key].append(u(ref_key))

    def group_children_str(key):
        return "\n".join(f"\t\t\t\t{r}," for r in group_children[key])

    pbx = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 77;
\tobjects = {{

/* Begin PBXBuildFile section */
{chr(10).join(build_file_lines)}
\t\t{u('plist_build')} = {{isa = PBXBuildFile; fileRef = {u('plist_ref')}; }};
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{chr(10).join(file_ref_lines)}
\t\t{u('entitlements_ref')} = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = SoniqueBar.entitlements; sourceTree = SOURCE_ROOT; }};
\t\t{u('plist_ref')} = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; name = Info.plist; path = SoniqueBar/Resources/Info.plist; sourceTree = SOURCE_ROOT; }};
\t\t{u('app_product')} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = SoniqueBar.app; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXGroup section */
\t\t{u('main_group')} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{u('sources_group')},
\t\t\t\t{u('entitlements_ref')},
\t\t\t\t{u('products_group')},
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{u('products_group')} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{u('app_product')},
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{u('sources_group')} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{u('app_ref')},
\t\t\t\t{u('models_group')},
\t\t\t\t{u('services_group')},
\t\t\t\t{u('views_group')},
\t\t\t\t{u('resources_group')},
\t\t\t);
\t\t\tname = SoniqueBar;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{u('models_group')} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{group_children_str('models_group')}
\t\t\t);
\t\t\tname = Models;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{u('services_group')} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{group_children_str('services_group')}
\t\t\t);
\t\t\tname = Services;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{u('views_group')} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{group_children_str('views_group')}
\t\t\t);
\t\t\tname = Views;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{u('resources_group')} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{u('plist_ref')},
\t\t\t);
\t\t\tname = Resources;
\t\t\tsourceTree = "<group>";
\t\t}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t{u('native_target')} = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {u('target_config_list')};
\t\t\tbuildPhases = (
\t\t\t\t{u('sources_phase')},
\t\t\t\t{u('frameworks_phase')},
\t\t\t\t{u('resources_phase')},
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = SoniqueBar;
\t\t\tproductName = SoniqueBar;
\t\t\tproductReference = {u('app_product')};
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{u('project')} = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1600;
\t\t\t\tLastUpgradeCheck = 1600;
\t\t\t}};
\t\t\tbuildConfigurationList = {u('config_list')};
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {u('main_group')};
\t\t\tproductRefGroup = {u('products_group')};
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{u('native_target')},
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
\t\t{u('resources_phase')} = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{u('plist_build')},
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t{u('sources_phase')} = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{chr(10).join(sources_build_refs)}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXSourcesBuildPhase section */

/* Begin PBXFrameworksBuildPhase section */
\t\t{u('frameworks_phase')} = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */

/* Begin XCBuildConfiguration section */
\t\t{u('debug_config')} = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (
\t\t\t\t\t"DEBUG=1",
\t\t\t\t\t"$(inherited)",
\t\t\t\t);
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{u('release_config')} = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tSDKROOT = macosx;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t{u('target_debug')} = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tCODE_SIGN_ENTITLEMENTS = SoniqueBar.entitlements;
\t\t\t\tCODE_SIGN_IDENTITY = "Apple Development";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tENABLE_HARDENED_RUNTIME = YES;
\t\t\t\tINFOPLIST_FILE = "SoniqueBar/Resources/Info.plist";
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/../Frameworks",
\t\t\t\t);
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 13.0;
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "com.seayniclabs.soniquebar";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{u('target_release')} = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tCODE_SIGN_ENTITLEMENTS = SoniqueBar.entitlements;
\t\t\t\tCODE_SIGN_IDENTITY = "Apple Development";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tENABLE_HARDENED_RUNTIME = YES;
\t\t\t\tINFOPLIST_FILE = "SoniqueBar/Resources/Info.plist";
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/../Frameworks",
\t\t\t\t);
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 13.0;
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "com.seayniclabs.soniquebar";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{u('config_list')} = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{u('debug_config')},
\t\t\t\t{u('release_config')},
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{u('target_config_list')} = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{u('target_debug')},
\t\t\t\t{u('target_release')},
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */
\t}};
\trootObject = {u('project')};
}}
"""
    pbxproj_path = os.path.join(xcodeproj_dir, "project.pbxproj")
    with open(pbxproj_path, "w") as f:
        f.write(pbx)
    print(f"Generated {pbxproj_path}")
    print("Next: open SoniqueBar.xcodeproj in Xcode, set your team, build.")

if __name__ == "__main__":
    main()
