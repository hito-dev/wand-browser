#!/usr/bin/env python3
"""Verify actual signed archive/export contents, not source build settings."""
import argparse
import datetime
import json
import pathlib
import plistlib
import subprocess
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent

def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args):
    return subprocess.run(args, check=True, capture_output=True).stdout


def verify(app, build, distribution):
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    require(info['CFBundleIdentifier'] == 'ai.hito.wand.dev', 'Wrong bundle ID')
    require(info['CFBundleShortVersionString'] == '0.1.0', 'Wrong marketing version')
    require(info['CFBundleVersion'] == build, 'Wrong build number')
    require(info.get('ITSAppUsesNonExemptEncryption') is False, 'Missing encryption declaration')
    require(info.get('MinimumOSVersion') == '18.0', 'Unexpected deployment target')
    require(info.get('UIDeviceFamily') == [1], 'Unexpected device family')
    require(bool(info.get('NSBluetoothAlwaysUsageDescription')), 'Missing Bluetooth usage description')
    require(bool(info.get('NFCReaderUsageDescription')), 'Missing NFC usage description')
    require(info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {}).get('CFBundleIconName') == 'AppIcon', 'Missing primary icon')
    require((app / 'Assets.car').is_file(), 'Missing compiled assets')
    manifest = plistlib.loads((app / 'PrivacyInfo.xcprivacy').read_bytes())
    require(manifest.get('NSPrivacyTracking') is False, 'Unexpected app tracking declaration')
    require(manifest.get('NSPrivacyTrackingDomains') == [], 'Unexpected tracking domains')
    require(manifest.get('NSPrivacyCollectedDataTypes') == [], 'Unexpected collected-data declaration')
    require(manifest.get('NSPrivacyAccessedAPITypes') == [{
        'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategoryUserDefaults',
        'NSPrivacyAccessedAPITypeReasons': ['CA92.1'],
    }], 'Incorrect required-reason API declaration')
    require((app / 'PrivacyPolicy.html').read_bytes() == (ROOT / 'ios/WandBrowser/Resources/PrivacyPolicy.html').read_bytes(), 'Policy differs from hosting source')
    run('codesign', '--verify', '--deep', '--strict', str(app))
    entitlements = plistlib.loads(run('codesign', '-d', '--entitlements', '-', '--xml', str(app)))
    require(entitlements.get('application-identifier') == 'KUV9LF7VX6.ai.hito.wand.dev', 'Wrong signed application ID')
    require(entitlements.get('com.apple.developer.team-identifier') == 'KUV9LF7VX6', 'Wrong signing team')
    require(entitlements.get('com.apple.developer.nfc.readersession.formats') == ['NDEF'], 'Missing NDEF entitlement')
    profile = plistlib.loads(run('security', 'cms', '-D', '-i', str(app / 'embedded.mobileprovision')))
    require(profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Expired profile')
    require(profile['Entitlements'].get('application-identifier') == 'KUV9LF7VX6.ai.hito.wand.dev', 'Wrong profile application ID')
    if distribution:
        require(entitlements.get('get-task-allow') is False, 'Distribution build allows debugging')
        require(entitlements.get('beta-reports-active') is True, 'Missing TestFlight entitlement')
        require(not profile.get('ProvisionedDevices') and not profile.get('ProvisionsAllDevices'), 'Profile is not App Store distribution')
        require(profile['Entitlements'].get('get-task-allow') is False, 'Profile allows debugging')
    return {'bundleID': info['CFBundleIdentifier'], 'version': info['CFBundleShortVersionString'],
            'build': build, 'distribution': distribution, 'profile': profile['Name'],
            'profileExpires': profile['ExpirationDate'].isoformat(), 'entitlements': entitlements,
            'privacyManifest': manifest, 'verification': 'passed'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path', type=pathlib.Path)
    parser.add_argument('--build', required=True)
    parser.add_argument('--distribution', action='store_true')
    args = parser.parse_args()
    if args.path.suffix == '.ipa':
        with tempfile.TemporaryDirectory(prefix='wand-verify-') as directory:
            with zipfile.ZipFile(args.path) as package:
                package.extractall(directory)
            apps = list((pathlib.Path(directory) / 'Payload').glob('*.app'))
            require(len(apps) == 1, 'Expected one application in the IPA')
            result = verify(apps[0], args.build, args.distribution)
    else:
        result = verify(args.path, args.build, args.distribution)
    print(json.dumps(result, indent=2))
