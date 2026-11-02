#!/usr/bin/env python3
"""Build a signed Apple Silicon Dravion.app (Relay engine) with its resources and WidgetKit extension."""
import argparse
import ctypes
from datetime import datetime
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
ENV = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
VERSION = "1.1.0"
BUNDLE_ID = "local.relay.native"
ZSTD_VERSION = "1.5.7"


def run(*args, cwd=ROOT, capture=False):
    result = subprocess.run([str(arg) for arg in args], cwd=cwd, env=ENV, check=True,
                            stdout=subprocess.PIPE if capture else None, text=True)
    return result.stdout.strip() if capture else None


def write_plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value, sort_keys=False))


def signing_identity():
    identities = run("security", "find-identity", "-v", "-p", "codesigning", capture=True)
    selected = os.environ.get("RELAY_SIGN_IDENTITY")
    if selected is None:
        matches = re.findall(r'"(Apple Development:[^"\n]+)"', identities)
        if len(matches) != 1:
            raise RuntimeError("Set RELAY_SIGN_IDENTITY to one valid Apple Development identity; WidgetKit requires real signing.")
        selected = matches[0]
    certificate = run("security", "find-certificate", "-c", selected, "-p", capture=True)
    subject = subprocess.run(["openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253"],
                             input=certificate, text=True, capture_output=True, check=True).stdout
    team = re.search(r"(?:^|,)OU=([A-Z0-9]+)(?:,|$)", subject.strip())
    if team is None:
        raise RuntimeError("The selected signing certificate does not declare a Team ID.")
    return selected, team.group(1)


def copy_tree(source, destination):
    shutil.copytree(source, destination, symlinks=True)


def zstd_dependency():
    prefix = Path(run("/opt/homebrew/bin/brew", "--prefix", "zstd", capture=True))
    library, license_file = prefix / "lib/libzstd.1.dylib", prefix / "LICENSE"
    if not library.is_file() or not license_file.is_file():
        raise RuntimeError("Zstandard and its BSD license are required; install zstd with Homebrew before packaging.")
    version = ctypes.CDLL(str(library)).ZSTD_versionString
    version.restype = ctypes.c_char_p
    if version().decode("ascii") != ZSTD_VERSION:
        raise RuntimeError(f"Expected Zstandard {ZSTD_VERSION}; review and update the pinned version before packaging another release.")
    if run("lipo", "-archs", library, capture=True).split() != ["arm64"]:
        raise RuntimeError("The bundled Zstandard library must be arm64.")
    return library, license_file


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--configuration", choices=["debug", "release"], default="release")
    parser.add_argument("--open", action="store_true")
    args = parser.parse_args()
    identity, team = signing_identity()
    zstd_source, zstd_license = zstd_dependency()
    group = f"{team}.local.relay.native"
    build_number = datetime.now().strftime("%Y%m%d%H%M%S")
    print(f"Building Relay {VERSION} ({args.configuration}), team {team}", flush=True)
    run("swift", "build", "-c", args.configuration, "--product", "Relay")
    built = Path(run("swift", "build", "-c", args.configuration, "--show-bin-path", capture=True))
    executable = built / "Relay"
    architectures = run("lipo", "-archs", executable, capture=True).split()
    sidecar = ROOT / ".sidecars/opencode"
    if not sidecar.exists():
        run(ROOT / "Scripts/prepare-sidecars.sh")
    if architectures != ["arm64"] or run("lipo", "-archs", sidecar, capture=True).split() != ["arm64"]:
        raise RuntimeError("This local distribution requires arm64 app and OpenCode sidecar binaries.")
    load_commands = run("otool", "-l", executable, capture=True)
    stamp = re.search(r"cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform \d+\s+minos [\d.]+\s+sdk ([\d.]+)", load_commands)
    if stamp is None or int(stamp.group(1).split(".")[0]) < 26:
        raise RuntimeError("The application must record macOS SDK 26 or newer for its native appearance.")

    release = ROOT / "release"
    release.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".relay-build-", dir=release))
    app = staging / "Dravion.app"
    contents = app / "Contents"
    resources = contents / "Resources"
    (contents / "MacOS").mkdir(parents=True)
    resources.mkdir()
    shutil.copy2(executable, contents / "MacOS/Relay")
    copy_tree(built / "RelayNative_Relay.bundle", resources / "RelayNative_Relay.bundle")
    # The core is a prebuilt binary (Binaries/): its resources and the App bridges come from there.
    copy_tree(ROOT / "Binaries/RelayNative_RelayCore.bundle", resources / "RelayNative_RelayCore.bundle")
    shutil.copy2(ROOT / "Assets/AppIcon.icns", resources / "AppIcon.icns")
    (resources / "sidecars").mkdir()
    shutil.copy2(sidecar, resources / "sidecars/opencode")
    # 豆包 App 直连: Lancer's Accessibility bridge (MIT), run as Dravion's child so the permission is Dravion's.
    shutil.copy2(ROOT / "Binaries/sidecars/doubao-bridge", resources / "sidecars/doubao-bridge")
    shutil.copy2(ROOT / "Binaries/sidecars/workbuddy-bridge", resources / "sidecars/workbuddy-bridge")
    copy_tree(ROOT / ".sidecars/licenses", resources / "Licenses/sidecars")
    shutil.copy2(ROOT / "Vendor/APIUse-LICENSE", resources / "Licenses/APIUse-LICENSE")
    shutil.copy2(ROOT / "Vendor/Lancer-LICENSE", resources / "Licenses/Lancer-LICENSE")
    shutil.copy2(ROOT / "Binaries/LICENSE-RelayCore.md", resources / "Licenses/RelayCore-LICENSE.md")
    shutil.copy2(ROOT / "Vendor/Lancer-Light-UI-LICENSE", resources / "Licenses/Lancer-Light-UI-LICENSE")
    shutil.copy2(ROOT / "Vendor/Lancer-Light-UI-NOTICE", resources / "Licenses/Lancer-Light-UI-NOTICE")
    shutil.copy2(ROOT / "Vendor/NOTICE.md", resources / "Licenses/NOTICE.md")
    copy_tree(ROOT / "Vendor/Integrations", resources / "Integrations")
    core = contents / "Frameworks/RelayCore.framework"
    copy_tree(ROOT / "Binaries/RelayCore.xcframework/macos-arm64/RelayCore.framework", core)
    framework = contents / "Frameworks/Sparkle.framework"
    framework.parent.mkdir(exist_ok=True)
    copy_tree(built / "Sparkle.framework", framework)
    zstd = framework.parent / "libzstd.1.dylib"
    shutil.copy2(zstd_source, zstd)
    run("install_name_tool", "-id", "@rpath/libzstd.1.dylib", zstd)
    shutil.copy2(zstd_license, resources / "Licenses/Zstandard-LICENSE")
    if "@executable_path/../Frameworks" not in load_commands:
        run("install_name_tool", "-add_rpath", "@executable_path/../Frameworks", contents / "MacOS/Relay")
    info = {
        "CFBundleName": "Dravion", "CFBundleDisplayName": "Dravion", "CFBundleExecutable": "Relay",
        "CFBundleIdentifier": BUNDLE_ID, "CFBundleIconFile": "AppIcon", "CFBundlePackageType": "APPL",
        "CFBundleInfoDictionaryVersion": "6.0", "CFBundleShortVersionString": VERSION, "CFBundleVersion": build_number,
        "CFBundleDevelopmentRegion": "en", "CFBundleLocalizations": ["en", "zh-Hans", "zh-Hant", "ja", "ko", "ru"],
        "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
        "NSMicrophoneUsageDescription": "将你主动输入的语音转写为任务目标。",
        "NSSpeechRecognitionUsageDescription": "在你点击语音输入后，将听写内容加入任务。",
        "NSHumanReadableCopyright": "Dravion; API Use © 2026 qunqin24 (Apache-2.0).",
        "CFBundleURLTypes": [{"CFBundleURLName": BUNDLE_ID + ".navigation", "CFBundleTypeRole": "Viewer", "CFBundleURLSchemes": ["relay"]}],
        "PulseAppGroup": group,
    }
    write_plist(contents / "Info.plist", info)

    run("/opt/homebrew/bin/xcodegen", "generate", "--quiet", cwd=ROOT / "Widget")
    widget_build = ROOT / ".build/widget"
    run("xcodebuild", "-project", ROOT / "Widget/PulseWidget.xcodeproj", "-scheme", "PulseWidget",
        "-configuration", "Release", "-derivedDataPath", widget_build, "CODE_SIGNING_ALLOWED=NO",
        "ARCHS=arm64", "ONLY_ACTIVE_ARCH=NO", f"RELAY_APP_GROUP={group}", f"RELAY_TEAM_ID={team}", "build", "-quiet")
    widget = contents / "PlugIns/PulseWidget.appex"
    widget.parent.mkdir()
    copy_tree(widget_build / "Build/Products/Release/PulseWidget.appex", widget)
    widget_info = widget / "Contents/Info.plist"
    metadata = plistlib.loads(widget_info.read_bytes())
    metadata.update(CFBundleVersion=build_number, CFBundleShortVersionString=VERSION)
    write_plist(widget_info, metadata)
    entitlement_directory = ROOT / ".build/relay-entitlements"
    write_plist(entitlement_directory / "app.plist", {"com.apple.security.application-groups": [group], "com.apple.security.device.audio-input": True})
    write_plist(entitlement_directory / "widget.plist", {"com.apple.security.app-sandbox": True, "com.apple.security.application-groups": [group]})
    write_plist(entitlement_directory / "sidecar.plist", {"com.apple.security.cs.allow-jit": True, "com.apple.security.cs.allow-unsigned-executable-memory": True})
    # Sign nested code before its container. The original vendor signatures are not retained.
    for nested in sorted(framework.rglob("*"), key=lambda path: len(path.parts), reverse=True):
        if not nested.is_symlink() and nested.suffix in [".app", ".xpc"]:
            run("codesign", "--force", "--options", "runtime", "--sign", identity, nested)
    run("codesign", "--force", "--options", "runtime", "--sign", identity, framework)
    run("codesign", "--force", "--options", "runtime", "--sign", identity, zstd)
    run("codesign", "--force", "--options", "runtime", "--sign", identity, core)
    run("codesign", "--force", "--options", "runtime", "--sign", identity, resources / "sidecars/doubao-bridge")
    run("codesign", "--force", "--options", "runtime", "--sign", identity, resources / "sidecars/workbuddy-bridge")
    for target, entitlements in [(resources / "sidecars/opencode", "sidecar"), (widget, "widget"), (app, "app")]:
        run("codesign", "--force", "--options", "runtime", "--sign", identity,
            "--entitlements", entitlement_directory / f"{entitlements}.plist", target)
    run("codesign", "--verify", "--deep", "--strict", "--verbose=2", app)
    run("plutil", "-lint", contents / "Info.plist", widget_info)
    destination = release / "Dravion.app"
    if destination.exists():
        backup = release / "previous" / f"Dravion-{build_number}.app"
        backup.parent.mkdir(parents=True, exist_ok=True)
        destination.rename(backup)
    app.rename(destination)
    staging.rmdir()
    print(f"SIGNED_NATIVE_APP {destination}", flush=True)
    if args.open:
        run("open", destination)


if __name__ == "__main__":
    main()
