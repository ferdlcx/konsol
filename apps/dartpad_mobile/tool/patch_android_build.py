#!/usr/bin/env python3
"""Patches generated AndroidManifest.xml and Gradle build files for dartpad_mobile.

Adds:
1. Required runtime/network/haptic/OTA permissions (CAMERA, INTERNET, VIBRATE, REQUEST_INSTALL_PACKAGES, Wi-Fi/Multicast)
2. android:usesCleartextTraffic="true" for local LAN/USB HTTP discovery (:42101)
3. dartpad://connect deep link intent-filter + ota_update FileProvider & filepaths.xml
4. Java 8+ core library desugaring required by ota_update ^7.1.0
5. Consistent release keystore signing (android_signing/dartpad_release.jks) so every
   future APK update cleanly overwrites ("timpa") previous installs without uninstalling.
"""

import pathlib
import re


def patch_manifest(app_dir: pathlib.Path, manifest_path: pathlib.Path) -> None:
    manifest = manifest_path.read_text(encoding="utf-8")

    perms = [
        '<uses-permission android:name="android.permission.INTERNET"/>',
        '<uses-permission android:name="android.permission.CAMERA"/>',
        '<uses-permission android:name="android.permission.VIBRATE"/>',
        '<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>',
        '<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>',
        '<uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>',
        '<uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE"/>',
        '<uses-feature android:name="android.hardware.camera" android:required="false"/>',
    ]
    missing_perms = [p for p in perms if p.split('"')[1] not in manifest]
    if missing_perms:
        manifest = re.sub(
            r"(<manifest[^>]*>)",
            r"\1\n    " + "\n    ".join(missing_perms),
            manifest,
            count=1,
        )

    if "usesCleartextTraffic" not in manifest:
        manifest = re.sub(
            r"<application\b",
            '<application android:usesCleartextTraffic="true"',
            manifest,
            count=1,
        )

    if 'android:scheme="dartpad"' not in manifest:
        deep_link = """
            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="dartpad" android:host="connect"/>
            </intent-filter>"""
        manifest = manifest.replace("</activity>", deep_link + "\n        </activity>", 1)

    if "OtaUpdateFileProvider" not in manifest:
        provider_block = """
        <provider
            android:name="sk.fourq.otaupdate.OtaUpdateFileProvider"
            android:authorities="${applicationId}.ota_update_provider"
            android:exported="false"
            android:grantUriPermissions="true">
            <meta-data
                android:name="android.support.FILE_PROVIDER_PATHS"
                android:resource="@xml/filepaths" />
        </provider>"""
        manifest = manifest.replace("</application>", provider_block + "\n    </application>", 1)

    xml_dir = app_dir / "android/app/src/main/res/xml"
    xml_dir.mkdir(parents=True, exist_ok=True)
    filepaths_xml = xml_dir / "filepaths.xml"
    filepaths_xml.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<paths xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <files-path name="internal_apk_storage" path="ota_update/"/>\n'
        "</paths>\n",
        encoding="utf-8",
    )

    manifest_path.write_text(manifest, encoding="utf-8")
    print(f"Patched {manifest_path} and {filepaths_xml}")


def patch_gradle(app_dir: pathlib.Path, keystore_abs: str) -> None:
    kts_path = app_dir / "android/app/build.gradle.kts"
    groovy_path = app_dir / "android/app/build.gradle"

    if kts_path.exists():
        g = kts_path.read_text(encoding="utf-8")
        g = re.sub(
            r"minSdk\s*=\s*flutter\.minSdkVersion",
            "minSdk = maxOf(flutter.minSdkVersion, 21)",
            g,
        )

        # Enable core library desugaring for ota_update ^7.1.0
        if "isCoreLibraryDesugaringEnabled" not in g:
            if "compileOptions {" in g:
                g = g.replace(
                    "compileOptions {",
                    "compileOptions {\n        isCoreLibraryDesugaringEnabled = true",
                    1,
                )
            else:
                g = re.sub(
                    r"(android\s*\{)",
                    r"\1\n    compileOptions {\n        isCoreLibraryDesugaringEnabled = true\n        sourceCompatibility = JavaVersion.VERSION_1_8\n        targetCompatibility = JavaVersion.VERSION_1_8\n    }",
                    g,
                    count=1,
                )
        if "desugar_jdk_libs" not in g:
            if re.search(r"dependencies\s*\{", g):
                g = re.sub(
                    r"(dependencies\s*\{)",
                    r'\1\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")',
                    g,
                    count=1,
                )
            else:
                g += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n'

        if not re.search(r"signingConfigs\s*\{", g):
            signing_block = (
                "    signingConfigs {\n"
                '        create("release") {\n'
                f'            storeFile = file("{keystore_abs}")\n'
                '            storePassword = "dartpad_release_key"\n'
                '            keyAlias = "dartpad"\n'
                '            keyPassword = "dartpad_release_key"\n'
                "        }\n"
                "    }\n"
            )
            g = re.sub(r"([ \t]*)buildTypes\s*\{", signing_block + r"\1buildTypes {", g, count=1)
        elif 'create("release")' not in g:
            signing_block = (
                '        create("release") {\n'
                f'            storeFile = file("{keystore_abs}")\n'
                '            storePassword = "dartpad_release_key"\n'
                '            keyAlias = "dartpad"\n'
                '            keyPassword = "dartpad_release_key"\n'
                "        }\n"
            )
            g = re.sub(r"(signingConfigs\s*\{)", r"\1\n" + signing_block, g, count=1)

        g = re.sub(
            r'((?:getByName\("release"\)|release)\s*\{[^}]*?)signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)',
            r'\1signingConfig = signingConfigs.getByName("release")',
            g,
            flags=re.S,
        )
        if 'signingConfigs.getByName("release")' not in g:
            g = re.sub(
                r'((?:getByName\("release"\)|release)\s*\{)',
                r'\1\n            signingConfig = signingConfigs.getByName("release")',
                g,
                count=1,
            )
        kts_path.write_text(g, encoding="utf-8")
        print(f"Patched {kts_path}")
    elif groovy_path.exists():
        g = groovy_path.read_text(encoding="utf-8")
        g = re.sub(
            r"minSdkVersion\s+flutter\.minSdkVersion",
            "minSdkVersion Math.max(flutter.minSdkVersion, 21)",
            g,
        )
        g = re.sub(
            r"minSdk\s*=\s*flutter\.minSdkVersion",
            "minSdk = Math.max(flutter.minSdkVersion, 21)",
            g,
        )
        if "coreLibraryDesugaringEnabled" not in g:
            if "compileOptions {" in g:
                g = g.replace(
                    "compileOptions {",
                    "compileOptions {\n        coreLibraryDesugaringEnabled true",
                    1,
                )
            else:
                g = re.sub(
                    r"(android\s*\{)",
                    r"\1\n    compileOptions {\n        coreLibraryDesugaringEnabled true\n        sourceCompatibility JavaVersion.VERSION_1_8\n        targetCompatibility JavaVersion.VERSION_1_8\n    }",
                    g,
                    count=1,
                )
        if "desugar_jdk_libs" not in g:
            if re.search(r"dependencies\s*\{", g):
                g = re.sub(
                    r"(dependencies\s*\{)",
                    r"\1\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'",
                    g,
                    count=1,
                )
            else:
                g += "\ndependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'\n}\n"

        if not re.search(r"signingConfigs\s*\{", g):
            signing_block = (
                "    signingConfigs {\n"
                "        release {\n"
                f'            storeFile file("{keystore_abs}")\n'
                '            storePassword "dartpad_release_key"\n'
                '            keyAlias "dartpad"\n'
                '            keyPassword "dartpad_release_key"\n'
                "        }\n"
                "    }\n"
            )
            g = re.sub(r"([ \t]*)buildTypes\s*\{", signing_block + r"\1buildTypes {", g, count=1)
        g = g.replace(
            "signingConfig signingConfigs.debug",
            "signingConfig signingConfigs.release",
        )
        g = g.replace(
            "signingConfig = signingConfigs.debug",
            "signingConfig = signingConfigs.release",
        )
        groovy_path.write_text(g, encoding="utf-8")
        print(f"Patched {groovy_path}")


def main() -> None:
    app_dir = pathlib.Path.cwd()
    manifest_path = app_dir / "android/app/src/main/AndroidManifest.xml"
    keystore_abs = str((app_dir / "android_signing/dartpad_release.jks").resolve())
    if not manifest_path.exists():
        raise FileNotFoundError(f"Missing {manifest_path}")
    patch_manifest(app_dir, manifest_path)
    patch_gradle(app_dir, keystore_abs)


if __name__ == "__main__":
    main()
