import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "checks", Path(__file__).with_name("check-project-settings.py")
)
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)


class ProjectSettingsTests(unittest.TestCase):
    def test_wrong_entitlement_mapping_fails(self):
        objects = target_objects("HardPause", "com.apple.product-type.application", "HardPause.app")
        objects["debug"]["buildSettings"]["CODE_SIGN_ENTITLEMENTS"] = "Other.entitlements"

        with self.assertRaises(ValueError):
            checks.validate_target_mappings(objects, {"HardPause": "App/HardPause.entitlements"})

    def test_mascot_folder_and_root_first_frame_are_required(self):
        objects = target_objects("HardPause", "com.apple.product-type.application", "HardPause.app")
        objects.update(
            {
                "resources": {"isa": "PBXResourcesBuildPhase", "files": ["folder-build", "frame-build"]},
                "folder-build": {"fileRef": "folder"},
                "frame-build": {"fileRef": "frame"},
                "folder": {"path": "../web/mascot"},
                "frame": {"path": "../web/mascot/first-frame.svg"},
            }
        )
        objects["target"]["buildPhases"] = ["resources"]
        checks.validate_mascot_resources(objects, require_root_first_frame=True)

        objects["resources"]["files"] = ["folder-build"]
        with self.assertRaises(ValueError):
            checks.validate_mascot_resources(objects, require_root_first_frame=True)

    def test_macos_products_require_service_cli_tests_and_no_filter(self):
        objects = {}
        for index, (name, (product_type, product_path)) in enumerate(
            checks.MACOS_PRODUCTS.items()
        ):
            append_target(objects, name, product_type, product_path, str(index))
        checks.validate_macos_products(objects)

        objects["retired"] = {
            "isa": "PBXNativeTarget",
            "name": "HardPauseFilter",
            "productType": "com.apple.product-type.system-extension",
        }
        with self.assertRaises(ValueError):
            checks.validate_macos_products(objects)

    def test_all_target_configs_require_current_deployment_minimum(self):
        objects = target_objects("HardPause", "com.apple.product-type.application", "HardPause.app")
        add_project_settings(objects, "26.0", "macosx")
        objects["debug"]["buildSettings"]["MACOSX_DEPLOYMENT_TARGET"] = "26.0"
        objects["debug"]["buildSettings"]["SDKROOT"] = "macosx"
        checks.validate_deployment(objects, "macos", "26.0")

        objects["debug"]["buildSettings"]["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
        with self.assertRaises(ValueError):
            checks.validate_deployment(objects, "macos", "26.0")

        objects["debug"]["buildSettings"]["MACOSX_DEPLOYMENT_TARGET"] = "26.0"
        objects["debug"]["buildSettings"]["SDKROOT"] = "macosx26.2"
        with self.assertRaises(ValueError):
            checks.validate_deployment(objects, "macos", "26.0")

    def test_target_deployment_settings_can_inherit_from_project(self):
        objects = target_objects("HardPause", "com.apple.product-type.application", "HardPause.app")
        add_project_settings(objects, "26.0", "macosx")

        checks.validate_deployment(objects, "macos", "26.0")

        objects["project-debug"]["buildSettings"]["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
        with self.assertRaises(ValueError):
            checks.validate_deployment(objects, "macos", "26.0")

    def test_macos_entitlements_require_unsandboxed_browser_capabilities(self):
        settings = {
            "com.apple.security.automation.apple-events": True,
            "com.apple.security.network.client": True,
        }
        checks.validate_macos_entitlements(settings)

        sandboxed = dict(settings)
        sandboxed["com.apple.security.app-sandbox"] = True
        with self.assertRaises(ValueError):
            checks.validate_macos_entitlements(sandboxed)

        for required_key in (
            "com.apple.security.automation.apple-events",
            "com.apple.security.network.client",
        ):
            with self.subTest(required_key=required_key):
                missing = dict(settings)
                del missing[required_key]
                with self.assertRaises(ValueError):
                    checks.validate_macos_entitlements(missing)

                disabled = dict(settings)
                disabled[required_key] = False
                with self.assertRaises(ValueError):
                    checks.validate_macos_entitlements(disabled)

        for retired_key in (
            "com.apple.developer.networking.networkextension",
            "com.apple.developer.system-extension.install",
            "com.apple.security.application-groups",
        ):
            invalid = dict(settings)
            invalid[retired_key] = True
            with self.subTest(retired_key=retired_key), self.assertRaises(ValueError):
                checks.validate_macos_entitlements(invalid)

    def test_macos_service_packaging_requires_exact_bounded_outputs(self):
        objects = target_objects("HardPause", "com.apple.product-type.application", "HardPause.app")
        objects["bundle"] = {
            "isa": "PBXShellScriptBuildPhase",
            "name": "Bundle production service",
            "outputPaths": sorted(checks.MACOS_BUNDLED_SERVICE_FILES),
        }
        objects["target"]["buildPhases"] = ["bundle"]
        checks.validate_macos_service_packaging(objects)

        objects["bundle"]["outputPaths"] = []
        with self.assertRaises(ValueError):
            checks.validate_macos_service_packaging(objects)


def target_objects(name, product_type, product_path):
    objects = {}
    append_target(objects, name, product_type, product_path, "")
    objects["target"] = objects.pop("target-")
    objects["list"] = objects.pop("list-")
    objects["debug"] = objects.pop("debug-")
    objects["product"] = objects.pop("product-")
    objects["target"]["buildConfigurationList"] = "list"
    objects["target"]["productReference"] = "product"
    objects["list"]["buildConfigurations"] = ["debug"]
    return objects


def append_target(objects, name, product_type, product_path, suffix):
    objects[f"target-{suffix}"] = {
        "isa": "PBXNativeTarget",
        "name": name,
        "productType": product_type,
        "productReference": f"product-{suffix}",
        "buildConfigurationList": f"list-{suffix}",
    }
    objects[f"product-{suffix}"] = {"path": product_path}
    objects[f"list-{suffix}"] = {"buildConfigurations": [f"debug-{suffix}"]}
    objects[f"debug-{suffix}"] = {
        "name": "Debug",
        "buildSettings": {"CODE_SIGN_ENTITLEMENTS": "App/HardPause.entitlements"},
    }


def add_project_settings(objects, deployment, sdk):
    objects["project"] = {
        "isa": "PBXProject",
        "buildConfigurationList": "project-list",
    }
    objects["project-list"] = {"buildConfigurations": ["project-debug"]}
    objects["project-debug"] = {
        "name": "Debug",
        "buildSettings": {
            "MACOSX_DEPLOYMENT_TARGET": deployment,
            "SDKROOT": sdk,
        },
    }


if __name__ == "__main__":
    unittest.main()
