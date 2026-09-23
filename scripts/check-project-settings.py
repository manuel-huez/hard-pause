#!/usr/bin/env python3
"""Validate generated native target, capability, deployment, and resource mappings."""

import json
import plistlib
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENTITLED_TARGETS = {
    "ios": {
        "HardPause": "App/HardPause.entitlements",
        "HardPauseMonitor": "Extensions/Monitor/Monitor.entitlements",
        "HardPauseShieldConfiguration": "Extensions/ShieldConfiguration/ShieldConfiguration.entitlements",
        "HardPauseShieldAction": "Extensions/ShieldAction/ShieldAction.entitlements",
    },
    "macos": {
        "HardPause": "App/HardPause.entitlements",
        "HardPauseBrowserWorker": "App/HardPause.entitlements",
    },
}
MACOS_PRODUCTS = {
    "HardPause": ("com.apple.product-type.application", "HardPause.app"),
    "HardPauseBrowserWorker": (
        "com.apple.product-type.application",
        "HardPauseBrowserWorker.app",
    ),
    "HardPauseService": ("com.apple.product-type.tool", "hard-pause-service"),
    "HardPauseCLI": ("com.apple.product-type.tool", "hard-pause"),
    "HardPauseTests": ("com.apple.product-type.bundle.unit-test", "HardPauseTests.xctest"),
    "HardPauseServiceTests": (
        "com.apple.product-type.bundle.unit-test",
        "HardPauseServiceTests.xctest",
    ),
}
MACOS_BUNDLED_SERVICE_FILES = {
    "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/install-macos-service.sh",
    "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/uninstall-macos-service.sh",
    "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/service-dry-run.sh",
    "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/org.hardpause.service.plist",
    "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/hard-pause-service",
    "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/hard-pause",
    "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/HardPauseBrowserWorker.app",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def native_targets(objects):
    return {
        item["name"]: item
        for item in objects.values()
        if item.get("isa") == "PBXNativeTarget"
    }


def validate_target_mappings(objects, expected):
    targets = native_targets(objects)
    for name, path in expected.items():
        require(name in targets, f"{name}: target is missing")
        configs = objects[targets[name]["buildConfigurationList"]]["buildConfigurations"]
        require(configs, f"{name}: no build configurations")
        for config_id in configs:
            config = objects[config_id]
            actual = config["buildSettings"].get("CODE_SIGN_ENTITLEMENTS")
            require(actual == path, f'{name}/{config["name"]}: expected {path}, found {actual}')


def resource_paths(objects, target_name="HardPause"):
    target = native_targets(objects)[target_name]
    resources = [
        objects[phase]
        for phase in target.get("buildPhases", [])
        if objects[phase].get("isa") == "PBXResourcesBuildPhase"
    ]
    return {
        objects[objects[item]["fileRef"]].get("path")
        for phase in resources
        for item in phase.get("files", [])
        if "fileRef" in objects[item]
    }


def validate_mascot_resources(objects, require_root_first_frame=False):
    paths = resource_paths(objects)
    require("../web/mascot" in paths, "HardPause: shared mascot folder is not a resource")
    if require_root_first_frame:
        require(
            bool({"../web/mascot/first-frame.svg", "first-frame.svg"} & paths),
            "HardPause: first-frame SVG is not a root bundle resource",
        )


def validate_macos_products(objects):
    targets = native_targets(objects)
    require("HardPauseFilter" not in targets, "HardPauseFilter: retired target must not be generated")
    for name, (product_type, product_path) in MACOS_PRODUCTS.items():
        require(name in targets, f"{name}: production target is missing")
        target = targets[name]
        require(target.get("productType") == product_type, f"{name}: wrong product type")
        reference = objects.get(target.get("productReference"), {})
        require(reference.get("path") == product_path, f"{name}: wrong product name")


def validate_macos_service_packaging(objects):
    app = native_targets(objects)["HardPause"]
    scripts = [
        objects[phase]
        for phase in app.get("buildPhases", [])
        if objects[phase].get("isa") == "PBXShellScriptBuildPhase"
        and objects[phase].get("name") == "Bundle production service"
    ]
    require(len(scripts) == 1, "HardPause: production service bundle phase is missing")
    outputs = set(scripts[0].get("outputPaths", []))
    require(
        outputs == MACOS_BUNDLED_SERVICE_FILES,
        "HardPause: bundled service outputs are incomplete or unexpected",
    )


def validate_deployment(objects, platform, minimum):
    targets = native_targets(objects)
    key = "MACOSX_DEPLOYMENT_TARGET" if platform == "macos" else "IPHONEOS_DEPLOYMENT_TARGET"
    expected_sdk = "macosx" if platform == "macos" else "iphoneos"
    project = next(item for item in objects.values() if item.get("isa") == "PBXProject")
    project_configs = {
        objects[config_id]["name"]: objects[config_id]["buildSettings"]
        for config_id in objects[project["buildConfigurationList"]]["buildConfigurations"]
    }
    for name, target in targets.items():
        configs = objects[target["buildConfigurationList"]]["buildConfigurations"]
        for config_id in configs:
            config = objects[config_id]
            inherited = project_configs.get(config["name"], {})
            deployment = config["buildSettings"].get(key, inherited.get(key))
            sdk = config["buildSettings"].get("SDKROOT", inherited.get("SDKROOT"))
            require(
                deployment == minimum,
                f'{name}/{config["name"]}: expected {key}={minimum}',
            )
            require(
                sdk == expected_sdk,
                f'{name}/{config["name"]}: expected SDKROOT={expected_sdk}',
            )


def validate_macos_entitlements(settings):
    require(
        "com.apple.security.app-sandbox" not in settings,
        "Mac app must remain unsandboxed for Firefox Accessibility",
    )
    require(
        settings.get("com.apple.security.automation.apple-events") is True,
        "Mac app needs Automation access for Safari and Chrome",
    )
    require(
        settings.get("com.apple.security.network.client") is True,
        "Mac app needs network client access for the local pause page",
    )
    require(
        "com.apple.developer.networking.networkextension" not in settings,
        "Retired Network Extension entitlement must not remain",
    )
    require(
        "com.apple.developer.system-extension.install" not in settings,
        "Retired system-extension entitlement must not remain",
    )
    require(
        "com.apple.security.application-groups" not in settings,
        "Mac GUI must not use the retired shared policy container",
    )


def load_objects(platform):
    project = ROOT / platform / "HardPause.xcodeproj/project.pbxproj"
    data = subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(project)])
    return json.loads(data)["objects"]


def main():
    checks = 0
    for platform, entitled_targets in ENTITLED_TARGETS.items():
        objects = load_objects(platform)
        validate_target_mappings(objects, entitled_targets)
        validate_mascot_resources(objects, require_root_first_frame=platform == "macos")
        validate_deployment(objects, platform, "26.0")
        if platform == "macos":
            validate_macos_products(objects)
            validate_macos_service_packaging(objects)
        for relative in entitled_targets.values():
            path = ROOT / platform / relative
            settings = plistlib.loads(path.read_bytes())
            if platform == "ios":
                require(
                    settings.get("com.apple.security.application-groups")
                    == ["group.com.hardpause.shared"],
                    path,
                )
                require(settings.get("com.apple.developer.family-controls") is True, path)
            else:
                validate_macos_entitlements(settings)
            checks += 1
    print(f"Validated {checks} capability files and generated production target settings.")


if __name__ == "__main__":
    main()
