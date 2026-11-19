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

    if "com.google.mlkit.vision.DEPENDENCIES" not in manifest:
        mlkit_meta = """
        <meta-data
            android:name="com.google.mlkit.vision.DEPENDENCIES"
            android:value="barcode_ui" />"""
        manifest = manifest.replace("</application>", mlkit_meta + "\n    </application>", 1)

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

    proguard_path = app_dir / "android/app/proguard-rules.pro"
    proguard_path.write_text(
        "-keep class com.google.mlkit.** { *; }\n"
        "-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }\n"
        "-keep class androidx.camera.** { *; }\n"
        "-keep class dev.steenbakker.mobile_scanner.** { *; }\n"
        "-dontwarn com.google.mlkit.**\n"
        "-dontwarn androidx.camera.**\n",
        encoding="utf-8",
    )
    print(f"Wrote {proguard_path}")

    if kts_path.exists():
        g = kts_path.read_text(encoding="utf-8")
        g = re.sub(
            r"minSdk\s*=\s*flutter\.minSdkVersion",
            "minSdk = maxOf(flutter.minSdkVersion, 23)",
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

        if "play-services-code-scanner" not in g:
            g = re.sub(
                r"(dependencies\s*\{)",
                r'\1\n    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")',
                g,
                count=1,
            )

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
        if "proguard-rules.pro" not in g:
            g = re.sub(
                r'((?:getByName\("release"\)|release)\s*\{)',
                r'\1\n            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")',
                g,
                count=1,
            )
        kts_path.write_text(g, encoding="utf-8")
        print(f"Patched {kts_path}")
    elif groovy_path.exists():
        g = groovy_path.read_text(encoding="utf-8")
        g = re.sub(
            r"minSdkVersion\s+flutter\.minSdkVersion",
            "minSdkVersion Math.max(flutter.minSdkVersion, 23)",
            g,
        )
        g = re.sub(
            r"minSdk\s*=\s*flutter\.minSdkVersion",
            "minSdk = Math.max(flutter.minSdkVersion, 23)",
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

        if "play-services-code-scanner" not in g:
            g = re.sub(
                r"(dependencies\s*\{)",
                r"\1\n    implementation 'com.google.android.gms:play-services-code-scanner:16.1.0'",
                g,
                count=1,
            )

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


def patch_main_activity(app_dir: pathlib.Path) -> None:
    kt_candidates = list((app_dir / "android/app/src/main/kotlin").rglob("MainActivity.kt"))
    if not kt_candidates:
        print("Warning: MainActivity.kt not found; skipping Google Code Scanner MethodChannel patch.")
        return
    kt_path = kt_candidates[0]
    existing = kt_path.read_text(encoding="utf-8")
    pkg_match = re.search(r"^package\s+([^\s]+)", existing, flags=re.M)
    pkg_line = f"package {pkg_match.group(1)}" if pkg_match else "package com.ferdlcx.dartpad.dartpad_mobile"

    kt_code = f"""{pkg_line}

import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {{
    private val channelName = "com.ferdlcx.dartpad/google_qr"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {{
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler {{ call, result ->
                if (call.method == "scanQr") {{
                    try {{
                        val options = GmsBarcodeScannerOptions.Builder()
                            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                            .enableAutoZoom()
                            .build()
                        val scanner = GmsBarcodeScanning.getClient(this, options)
                        scanner.startScan()
                            .addOnSuccessListener {{ barcode ->
                                result.success(barcode.rawValue)
                            }}
                            .addOnCanceledListener {{
                                result.success(null)
                            }}
                            .addOnFailureListener {{ e ->
                                result.error("GOOGLE_SCAN_ERROR", e.message ?: "Scanner gagal", null)
                            }}
                    }} catch (e: Exception) {{
                        result.error("GOOGLE_SCAN_ERROR", e.message ?: "Scanner gagal", null)
                    }}
                }} else {{
                    result.notImplemented()
                }}
            }}
    }}
}}
"""
    kt_path.write_text(kt_code, encoding="utf-8")
    print(f"Patched {kt_path} with Google Code Scanner MethodChannel")


def main() -> None:
    app_dir = pathlib.Path.cwd()
    manifest_path = app_dir / "android/app/src/main/AndroidManifest.xml"
    keystore_abs = str((app_dir / "android_signing/dartpad_release.jks").resolve())
    if not manifest_path.exists():
        raise FileNotFoundError(f"Missing {manifest_path}")
    patch_manifest(app_dir, manifest_path)
    patch_gradle(app_dir, keystore_abs)
    patch_main_activity(app_dir)


if __name__ == "__main__":
    main()
