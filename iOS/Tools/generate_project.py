#!/usr/bin/env python3
"""Writes iOS/MochiPocket.xcodeproj/project.pbxproj (Xcode 16+ synchronized folders).

Targets: MochiPocket (app: MochiPocket/, Shared/, SharedArt/, SharedData/ + the TamagotchiCore package product) and
MochiLiveActivity (widget extension: MochiLiveActivity/, Shared/, SharedData/) and MochiNotifications (notification
service extension: MochiNotifications/, SharedData/). All three share the app group group.com.insideedge.mochi.
Run again after changing settings here.
"""
import pathlib

R = pathlib.Path(__file__).resolve().parent.parent
TEAM = "CZDJF6N2RH"
ids = {}


def i(name):
    if name not in ids:
        ids[name] = "4D4F43484900" + format(len(ids) + 1, "012X")
    return ids[name]


nids = {}


def j(name):
    """Ids for the notification extension's objects (a range of their own)."""
    if name not in nids:
        nids[name] = "4D4F43484901" + format(len(nids) + 1, "012X")
    return nids[name]


kids = {}


def k(name):
    """Ids for objects added later (a range of their own, so earlier ids stay put)."""
    if name not in kids:
        kids[name] = "4D4F43484902" + format(len(kids) + 1, "012X")
    return kids[name]


common = {
    "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "CODE_SIGN_STYLE": "Automatic",
    "DEVELOPMENT_TEAM": TEAM, "ENABLE_USER_SCRIPT_SANDBOXING": "YES", "IPHONEOS_DEPLOYMENT_TARGET": "17.2",
    "SDKROOT": "iphoneos", "SWIFT_VERSION": "5.0", "MARKETING_VERSION": "1.1", "CURRENT_PROJECT_VERSION": "2",
    "TARGETED_DEVICE_FAMILY": "1", "ENABLE_PREVIEWS": "NO",
}
debug = {**common, "ONLY_ACTIVE_ARCH": "YES", "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"', "DEBUG_INFORMATION_FORMAT": "dwarf",
         "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG", "ENABLE_TESTABILITY": "YES"}
release = {**common, "SWIFT_COMPILATION_MODE": "wholemodule", "VALIDATE_PRODUCT": "YES",
           "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"'}
app = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "CODE_SIGN_ENTITLEMENTS": "Config/MochiPocket.entitlements", "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_FILE": '"Config/MochiPocket-Info.plist"', "INFOPLIST_KEY_CFBundleDisplayName": "Mochi",
    "INFOPLIST_KEY_NSMicrophoneUsageDescription": '"Mochi listens while you hold its ear, then sends what you said to your Mac."',
    "INFOPLIST_KEY_NSSpeechRecognitionUsageDescription": '"Your words are turned into text on this iPhone."',
    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES", "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations": "UIInterfaceOrientationPortrait",
    "INFOPLIST_KEY_UIUserInterfaceStyle": "Light",
    "LD_RUNPATH_SEARCH_PATHS": '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t)',
    "PRODUCT_BUNDLE_IDENTIFIER": "com.insideedge.mochi", "PRODUCT_NAME": '"$(TARGET_NAME)"', "SWIFT_EMIT_LOC_STRINGS": "YES",
}
ext = {
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor", "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_FILE": '"Config/MochiLiveActivity-Info.plist"', "INFOPLIST_KEY_CFBundleDisplayName": "Mochi",
    "LD_RUNPATH_SEARCH_PATHS": '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t\t"@executable_path/../../Frameworks",\n\t\t\t\t)',
    "PRODUCT_BUNDLE_IDENTIFIER": "com.insideedge.mochi.LiveActivity", "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SKIP_INSTALL": "YES", "APPLICATION_EXTENSION_API_ONLY": "YES", "SWIFT_EMIT_LOC_STRINGS": "YES",
    "CODE_SIGN_ENTITLEMENTS": "Config/MochiLiveActivity.entitlements",
}
nse = {
    "GENERATE_INFOPLIST_FILE": "YES", "INFOPLIST_FILE": '"Config/MochiNotifications-Info.plist"',
    "INFOPLIST_KEY_CFBundleDisplayName": "Mochi",
    "LD_RUNPATH_SEARCH_PATHS": '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t\t"@executable_path/../../Frameworks",\n\t\t\t\t)',
    "PRODUCT_BUNDLE_IDENTIFIER": "com.insideedge.mochi.Notifications", "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SKIP_INSTALL": "YES", "APPLICATION_EXTENSION_API_ONLY": "YES", "SWIFT_EMIT_LOC_STRINGS": "YES",
    "CODE_SIGN_ENTITLEMENTS": "Config/MochiNotifications.entitlements",
}


def settings(d):
    return "".join(f"\t\t\t\t{k} = {v};\n" for k, v in sorted(d.items()))


def config(name, label, d):
    return (f"\t\t{i(name)} /* {label} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n"
            f"{settings(d)}\t\t\t}};\n\t\t\tname = {label};\n\t\t}};\n")


def phase(kind, name, files=""):
    return (f"\t\t{i(name)} = {{\n\t\t\tisa = {kind};\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{files}\t\t\t);\n"
            f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")


groups = {"app": ["MochiPocket", "Shared", "SharedArt", "SharedData"], "ext": ["MochiLiveActivity", "Shared", "SharedData"],
          "nse": ["MochiNotifications"]}


def gid(g):
    return k("groupSharedData") if g == "SharedData" else i("group" + g)

P = ["// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 77;\n\tobjects = {\n\n"]
P.append("/* Begin PBXBuildFile section */\n")
P.append(f"\t\t{i('embedFile')} = {{isa = PBXBuildFile; fileRef = {i('extProduct')}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};\n")
P.append(f"\t\t{j('embedFile')} = {{isa = PBXBuildFile; fileRef = {j('product')}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};\n")
P.append(f"\t\t{i('coreFile')} = {{isa = PBXBuildFile; productRef = {i('coreProduct')}; }};\n")
P.append(f"\t\t{i('wireFile')} = {{isa = PBXBuildFile; productRef = {i('wireProduct')}; }};\n")
P.append("/* End PBXBuildFile section */\n\n")
P.append(f"\t\t{i('proxy')} = {{\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = {i('project')};\n\t\t\tproxyType = 1;\n"
         f"\t\t\tremoteGlobalIDString = {i('extTarget')};\n\t\t\tremoteInfo = MochiLiveActivity;\n\t\t}};\n")
P.append(f"\t\t{j('proxy')} = {{\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = {i('project')};\n\t\t\tproxyType = 1;\n"
         f"\t\t\tremoteGlobalIDString = {j('target')};\n\t\t\tremoteInfo = MochiNotifications;\n\t\t}};\n")
P.append(f"\t\t{i('embedPhase')} = {{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tdstPath = \"\";\n"
         f"\t\t\tdstSubfolderSpec = 13;\n\t\t\tfiles = (\n\t\t\t\t{i('embedFile')},\n\t\t\t\t{j('embedFile')},\n\t\t\t);\n\t\t\tname = \"Embed Foundation Extensions\";\n"
         f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
P.append(f"\t\t{i('appProduct')} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = MochiPocket.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
P.append(f"\t\t{i('extProduct')} = {{isa = PBXFileReference; explicitFileType = \"wrapper.app-extension\"; includeInIndex = 0; path = MochiLiveActivity.appex; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
P.append(f"\t\t{j('product')} = {{isa = PBXFileReference; explicitFileType = \"wrapper.app-extension\"; includeInIndex = 0; path = MochiNotifications.appex; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
for g in ("MochiPocket", "MochiLiveActivity", "Shared", "SharedArt"):
    P.append(f"\t\t{i('group' + g)} = {{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n\t\t\tpath = {g};\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
P.append(f"\t\t{j('groupMochiNotifications')} = {{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n\t\t\tpath = MochiNotifications;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
P.append(f"\t\t{k('groupSharedData')} = {{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n\t\t\tpath = SharedData;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
P.append(phase("PBXFrameworksBuildPhase", "nseFrameworks"))
P.append(phase("PBXFrameworksBuildPhase", "appFrameworks", f"\t\t\t\t{i('coreFile')},\n\t\t\t\t{i('wireFile')},\n"))
P.append(phase("PBXFrameworksBuildPhase", "extFrameworks"))
children = "".join(f"\t\t\t\t{i('group' + g)},\n" for g in ("Shared", "SharedArt", "MochiPocket", "MochiLiveActivity"))
children += f"\t\t\t\t{j('groupMochiNotifications')},\n\t\t\t\t{k('groupSharedData')},\n"
P.append(f"\t\t{i('mainGroup')} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{children}\t\t\t\t{i('products')},\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
P.append(f"\t\t{i('products')} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{i('appProduct')},\n\t\t\t\t{i('extProduct')},\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")


def target(key, name, phases, deps, product, ptype, packages=""):
    sync = "".join(f"\t\t\t\t{gid(g)},\n" for g in groups[key])
    return (f"\t\t{i(key + 'Target')} = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {i(key + 'Configs')};\n"
            f"\t\t\tbuildPhases = (\n{phases}\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n{deps}\t\t\t);\n"
            f"\t\t\tfileSystemSynchronizedGroups = (\n{sync}\t\t\t);\n\t\t\tname = {name};\n"
            f"\t\t\tpackageProductDependencies = (\n{packages}\t\t\t);\n\t\t\tproductName = {name};\n"
            f"\t\t\tproductReference = {i(product)};\n\t\t\tproductType = \"{ptype}\";\n\t\t}};\n")


P.append(target("app", "MochiPocket",
                f"\t\t\t\t{i('appSources')},\n\t\t\t\t{i('appFrameworks')},\n\t\t\t\t{i('appResources')},\n\t\t\t\t{i('embedPhase')},\n",
                f"\t\t\t\t{i('dependency')},\n\t\t\t\t{j('dependency')},\n", "appProduct", "com.apple.product-type.application",
                f"\t\t\t\t{i('coreProduct')},\n\t\t\t\t{i('wireProduct')},\n"))
P.append(target("ext", "MochiLiveActivity", f"\t\t\t\t{i('extSources')},\n\t\t\t\t{i('extFrameworks')},\n\t\t\t\t{i('extResources')},\n",
                "", "extProduct", "com.apple.product-type.app-extension"))
P.append(f"\t\t{j('target')} = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {j('configs')};\n"
         f"\t\t\tbuildPhases = (\n\t\t\t\t{j('sources')},\n\t\t\t\t{i('nseFrameworks')},\n\t\t\t\t{j('resources')},\n\t\t\t);\n"
         f"\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n"
         f"\t\t\tfileSystemSynchronizedGroups = (\n\t\t\t\t{j('groupMochiNotifications')},\n\t\t\t\t{k('groupSharedData')},\n\t\t\t);\n\t\t\tname = MochiNotifications;\n"
         f"\t\t\tpackageProductDependencies = (\n\t\t\t);\n\t\t\tproductName = MochiNotifications;\n"
         f"\t\t\tproductReference = {j('product')};\n\t\t\tproductType = \"com.apple.product-type.app-extension\";\n\t\t}};\n")
P.append(f"\t\t{i('project')} = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
         f"\t\t\t\tLastSwiftUpdateCheck = 2700;\n\t\t\t\tLastUpgradeCheck = 2700;\n\t\t\t}};\n\t\t\tbuildConfigurationList = {i('projectConfigs')};\n"
         f"\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
         f"\t\t\tmainGroup = {i('mainGroup')};\n\t\t\tminimizedProjectReferenceProxies = 1;\n"
         f"\t\t\tpackageReferences = (\n\t\t\t\t{i('localPackage')},\n\t\t\t);\n\t\t\tpreferredProjectObjectVersion = 77;\n"
         f"\t\t\tproductRefGroup = {i('products')};\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n"
         f"\t\t\ttargets = (\n\t\t\t\t{i('appTarget')},\n\t\t\t\t{i('extTarget')},\n\t\t\t\t{j('target')},\n\t\t\t);\n\t\t}};\n")
for t in ("app", "ext"):
    P.append(phase("PBXResourcesBuildPhase", t + "Resources"))
    P.append(phase("PBXSourcesBuildPhase", t + "Sources"))
P.append(f"\t\t{i('dependency')} = {{\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = {i('extTarget')};\n\t\t\ttargetProxy = {i('proxy')};\n\t\t}};\n")
P.append(phase("PBXResourcesBuildPhase", "nseResourcesUnused").replace(i("nseResourcesUnused"), j("resources")))
P.append(phase("PBXSourcesBuildPhase", "nseSourcesUnused").replace(i("nseSourcesUnused"), j("sources")))
P.append(f"\t\t{j('dependency')} = {{\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = {j('target')};\n\t\t\ttargetProxy = {j('proxy')};\n\t\t}};\n")
P.append(config("projDebug", "Debug", debug) + config("projRelease", "Release", release))
P.append(config("appDebug", "Debug", app) + config("appRelease", "Release", app))
P.append(config("extDebug", "Debug", ext) + config("extRelease", "Release", ext))
P.append(config("nseDebugUnused", "Debug", nse).replace(i("nseDebugUnused"), j("debug"))
         + config("nseReleaseUnused", "Release", nse).replace(i("nseReleaseUnused"), j("release")))
P.append(f"\t\t{j('configs')} = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{j('debug')},\n\t\t\t\t{j('release')},\n\t\t\t);\n"
         f"\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n")
for lst, (d, r) in (("projectConfigs", ("projDebug", "projRelease")), ("appConfigs", ("appDebug", "appRelease")),
                    ("extConfigs", ("extDebug", "extRelease"))):
    P.append(f"\t\t{i(lst)} = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{i(d)},\n\t\t\t\t{i(r)},\n\t\t\t);\n"
             f"\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n")
P.append(f"\t\t{i('localPackage')} = {{\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = ..;\n\t\t}};\n")
P.append(f"\t\t{i('coreProduct')} = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tpackage = {i('localPackage')};\n\t\t\tproductName = TamagotchiCore;\n\t\t}};\n")
P.append(f"\t\t{i('wireProduct')} = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tpackage = {i('localPackage')};\n\t\t\tproductName = TamagotchiWire;\n\t\t}};\n")
P.append("\t};\n\trootObject = " + i("project") + ";\n}\n")
(R / "MochiPocket.xcodeproj" / "project.pbxproj").write_text("".join(P))
print("wrote", R / "MochiPocket.xcodeproj" / "project.pbxproj", f"({len(ids)} objects)")
