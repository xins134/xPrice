#!/usr/bin/env python3
"""Regenerate the dependency-free Xcode project after adding/removing Swift files."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "xPrice.xcodeproj"
OBJECTS: dict[str, dict] = {}


def oid(name: str) -> str:
    return hashlib.sha1(("xPrice:" + name).encode()).hexdigest()[:24].upper()


def obj(key: str, **values) -> str:
    identifier = oid(key)
    OBJECTS[identifier] = values
    return identifier


def encode(value, level=0) -> str:
    indent = "\t" * level
    if isinstance(value, dict):
        entries = [f"{indent}\t{encode(key)} = {encode(item, level + 1)};" for key, item in value.items()]
        return "{\n" + "\n".join(entries) + "\n" + indent + "}"
    if isinstance(value, list):
        return "(\n" + "\n".join(f"{indent}\t{encode(item, level + 1)}," for item in value) + "\n" + indent + ")"
    if isinstance(value, int):
        return str(value)
    text = str(value)
    return text if re.fullmatch(r"[A-Za-z0-9_./]+", text) else json.dumps(text, ensure_ascii=False)


def reference(path: str, file_type: str | None = None) -> str:
    if file_type is None:
        file_type = {".swift": "sourcecode.swift", ".plist": "text.plist.xml", ".xcconfig": "text.xcconfig", ".entitlements": "text.plist.entitlements", ".md": "net.daringfireball.markdown"}.get(Path(path).suffix, "text")
    return obj("file:" + path, isa="PBXFileReference", lastKnownFileType=file_type, path=path, sourceTree="SOURCE_ROOT")


def files_under(folder: str) -> list[str]:
    return sorted(str(p.relative_to(ROOT)) for p in (ROOT / folder).rglob("*.swift"))


def build_file(target: str, path: str) -> str:
    return obj(f"build:{target}:{path}", isa="PBXBuildFile", fileRef=oid("file:" + path))


def write_scheme(name: str, product: str):
    scheme = ET.Element("Scheme", LastUpgradeVersion="2700", version="1.3")
    build = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
    entries = ET.SubElement(build, "BuildActionEntries")
    entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES", buildForProfiling="YES", buildForArchiving="YES", buildForAnalyzing="YES")
    attrs = dict(BuildableIdentifier="primary", BlueprintIdentifier=oid("target:" + name), BuildableName=product, BlueprintName=name, ReferencedContainer="container:xPrice.xcodeproj")
    ET.SubElement(entry, "BuildableReference", **attrs)
    test = ET.SubElement(scheme, "TestAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB", selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", shouldUseLaunchSchemeArgsEnv="YES")
    ET.SubElement(test, "Testables")
    launch = ET.SubElement(scheme, "LaunchAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB", selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", launchStyle="0", useCustomWorkingDirectory="NO", ignoresPersistentStateOnLaunch="NO", debugDocumentVersioning="YES", debugServiceExtension="internal", allowLocationSimulation="YES")
    runnable = ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0")
    ET.SubElement(runnable, "BuildableReference", **attrs)
    profile = ET.SubElement(scheme, "ProfileAction", buildConfiguration="Release", shouldUseLaunchSchemeArgsEnv="YES", savedToolIdentifier="", useCustomWorkingDirectory="NO", debugDocumentVersioning="YES")
    runnable = ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0")
    ET.SubElement(runnable, "BuildableReference", **attrs)
    ET.SubElement(scheme, "AnalyzeAction", buildConfiguration="Debug")
    ET.SubElement(scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
    destination = PROJECT / "xcshareddata" / "xcschemes" / f"{name}.xcscheme"
    destination.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(scheme)
    ET.ElementTree(scheme).write(destination, encoding="UTF-8", xml_declaration=True)


def generate():
    shared = files_under("Shared")
    widget_shared = ["Shared/" + name for name in ["MarketModels.swift", "TencentMarketDataProvider.swift", "EastmoneyMarketDataProvider.swift", "SinaMarketDataProvider.swift", "MarketDataProviders.swift", "AppSettings.swift", "SnapshotStore.swift", "QuoteFormatting.swift", "TradingSchedule.swift", "QuoteStatus.swift"] if (ROOT / "Shared" / name).exists()]
    targets = {
        "xPrice": dict(folder="iOSApp", product="xPrice.app", bundle="$(XPRICE_IOS_BUNDLE_ID)", sdk="iphoneos", platforms="iphoneos iphonesimulator", family="1", sources=files_under("iOSApp") + shared, product_type="com.apple.product-type.application"),
        "xPriceWatch": dict(folder="WatchApp", product="xPriceWatch.app", bundle="$(XPRICE_WATCH_BUNDLE_ID)", sdk="watchos", platforms="watchos watchsimulator", family="4", sources=files_under("WatchApp") + shared, product_type="com.apple.product-type.application"),
        "xPriceWatchWidgets": dict(folder="WatchWidgets", product="xPriceWatchWidgets.appex", bundle="$(XPRICE_WIDGET_BUNDLE_ID)", sdk="watchos", platforms="watchos watchsimulator", family="4", sources=files_under("WatchWidgets") + widget_shared, product_type="com.apple.product-type.app-extension"),
    }
    groups = []
    for folder in ["iOSApp", "WatchApp", "WatchWidgets", "Shared", "Configuration", "Tests"]:
        paths = sorted(str(p.relative_to(ROOT)) for p in (ROOT / folder).rglob("*") if p.is_file() and not any(part.endswith(".xcassets") for part in p.parts))
        children = [reference(path) for path in paths]
        assets = ROOT / folder / "Assets.xcassets"
        if assets.exists():
            children.append(reference(str(assets.relative_to(ROOT)), "folder.assetcatalog"))
        groups.append(obj("group:" + folder, isa="PBXGroup", name=folder, children=children, sourceTree="<group>"))
    config_file = oid("file:Configuration/Local.xcconfig")
    products = []
    for name, target in targets.items():
        products.append(obj("product:" + name, isa="PBXFileReference", explicitFileType="wrapper.app-extension" if name.endswith("Widgets") else "wrapper.application", includeInIndex=0, path=target["product"], sourceTree="BUILT_PRODUCTS_DIR"))
    products_group = obj("group:Products", isa="PBXGroup", name="Products", children=products, sourceTree="<group>")
    main_group = obj("group:Main", isa="PBXGroup", children=groups + [reference("README.md"), reference("Package.swift"), reference("Scripts/generate_project.py", "text.script.python"), products_group], sourceTree="<group>")

    for name, target in targets.items():
        phases = [obj("sources:" + name, isa="PBXSourcesBuildPhase", buildActionMask=2147483647, files=[build_file(name, path) for path in target["sources"]], runOnlyForDeploymentPostprocessing=0)]
        phases.append(obj("frameworks:" + name, isa="PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0))
        asset_path = target["folder"] + "/Assets.xcassets"
        resources = [build_file(name, asset_path)] if (ROOT / asset_path).exists() else []
        phases.append(obj("resources:" + name, isa="PBXResourcesBuildPhase", buildActionMask=2147483647, files=resources, runOnlyForDeploymentPostprocessing=0))
        dependencies = []
        dependency_name = {"xPrice": "xPriceWatch", "xPriceWatch": "xPriceWatchWidgets"}.get(name)
        if dependency_name:
            proxy = obj("proxy:" + name, isa="PBXContainerItemProxy", containerPortal=oid("project"), proxyType=1, remoteGlobalIDString=oid("target:" + dependency_name), remoteInfo=dependency_name)
            dependencies.append(obj("dependency:" + name, isa="PBXTargetDependency", target=oid("target:" + dependency_name), targetProxy=proxy))
            embedded = obj("embedfile:" + name, isa="PBXBuildFile", fileRef=oid("product:" + dependency_name), settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
            phases.append(obj("embed:" + name, isa="PBXCopyFilesBuildPhase", buildActionMask=2147483647, dstPath="$(CONTENTS_FOLDER_PATH)/Watch" if name == "xPrice" else "", dstSubfolderSpec=16 if name == "xPrice" else 13, files=[embedded], name="Embed Watch Content" if name == "xPrice" else "Embed App Extensions", runOnlyForDeploymentPostprocessing=0))
        configurations = []
        for configuration in ["Debug", "Release"]:
            settings = {
                "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": target["bundle"],
                "INFOPLIST_FILE": target["folder"] + "/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
                "CODE_SIGN_ENTITLEMENTS": "Configuration/xPrice.entitlements", "SDKROOT": target["sdk"],
                "SUPPORTED_PLATFORMS": target["platforms"], "TARGETED_DEVICE_FAMILY": target["family"],
                "SWIFT_VERSION": "5.0", "MARKETING_VERSION": "0.1.0", "CURRENT_PROJECT_VERSION": "1",
                "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
                "SKIP_INSTALL": "NO" if name == "xPrice" else "YES", "ENABLE_PREVIEWS": "YES",
                "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
                "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "NO",
                "SWIFT_EMIT_LOC_STRINGS": "YES", "STRING_CATALOG_GENERATE_SYMBOLS": "NO",
            }
            if target["sdk"] == "watchos":
                settings["WATCHOS_DEPLOYMENT_TARGET"] = "26.0"
            else:
                settings.update({"IPHONEOS_DEPLOYMENT_TARGET": "26.0", "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO"})
            if name.endswith("Widgets"):
                settings.update({"APPLICATION_EXTENSION_API_ONLY": "YES", "ASSETCATALOG_COMPILER_WIDGET_BACKGROUND_COLOR_NAME": "WidgetBackground", "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"]})
            else:
                settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
            configurations.append(obj(f"config:{name}:{configuration}", isa="XCBuildConfiguration", baseConfigurationReference=config_file, buildSettings=settings, name=configuration))
        config_list = obj("configs:" + name, isa="XCConfigurationList", buildConfigurations=configurations, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
        obj("target:" + name, isa="PBXNativeTarget", buildConfigurationList=config_list, buildPhases=phases, buildRules=[], dependencies=dependencies, name=name, productName=name, productReference=oid("product:" + name), productType=target["product_type"])

    project_configs = []
    common = {"ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES", "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE", "COPY_PHASE_STRIP": "NO", "ENABLE_STRICT_OBJC_MSGSEND": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "YES", "GCC_C_LANGUAGE_STANDARD": "gnu17", "GCC_NO_COMMON_BLOCKS": "YES", "SWIFT_VERSION": "5.0"}
    for configuration in ["Debug", "Release"]:
        settings = dict(common)
        if configuration == "Debug":
            settings.update({"DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES", "GCC_OPTIMIZATION_LEVEL": "0", "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"], "ONLY_ACTIVE_ARCH": "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)", "SWIFT_OPTIMIZATION_LEVEL": "-Onone"})
        else:
            settings.update({"DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "SWIFT_COMPILATION_MODE": "wholemodule", "SWIFT_OPTIMIZATION_LEVEL": "-O", "VALIDATE_PRODUCT": "YES"})
        project_configs.append(obj("config:project:" + configuration, isa="XCBuildConfiguration", baseConfigurationReference=config_file, buildSettings=settings, name=configuration))
    config_list = obj("configs:project", isa="XCConfigurationList", buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    obj("project", isa="PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastSwiftUpdateCheck": "2700", "LastUpgradeCheck": "2700", "TargetAttributes": {oid("target:" + name): {"CreatedOnToolsVersion": "27.1", "ProvisioningStyle": "Automatic", "SystemCapabilities": {"com.apple.ApplicationGroups.iOS": {"enabled": 1}}} for name in targets}}, buildConfigurationList=config_list, compatibilityVersion="Xcode 14.0", developmentRegion="zh-Hans", hasScannedForEncodings=0, knownRegions=["zh-Hans", "en", "Base"], mainGroup=main_group, productRefGroup=products_group, projectDirPath="", projectRoot="", targets=[oid("target:" + name) for name in targets])
    PROJECT.mkdir(exist_ok=True)
    document = dict(archiveVersion=1, classes={}, objectVersion=56, objects=OBJECTS, rootObject=oid("project"))
    (PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode(document) + "\n")
    for name in ["xPrice", "xPriceWatch"]:
        write_scheme(name, targets[name]["product"])
    workspace = PROJECT / "project.xcworkspace"
    workspace.mkdir(exist_ok=True)
    (workspace / "contents.xcworkspacedata").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="self:"></FileRef></Workspace>\n')
    print(f"Generated {PROJECT.name}: " + ", ".join(f"{name} ({len(target['sources'])} Swift files)" for name, target in targets.items()))


if __name__ == "__main__":
    generate()
