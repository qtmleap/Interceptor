#!/usr/bin/env python3
"""Fixture tests for verify-ipa.py. The signing tools are faked, except in the unsigned-IPA test,
which runs on macOS through the default main() using the real signing tools."""
import contextlib
import datetime
import importlib.util
import io
import os
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("verify_ipa", os.path.join(os.path.dirname(__file__), "verify-ipa.py"))
verify_ipa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_ipa)

TEAM = "ABCDE12345"
APP = "com.example.app"
EXT = "com.example.app.tunnel"
LEAF = b"leaf-certificate-der"
NOW = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)
ARM64 = struct.pack("<II", 0xFEEDFACF, 0x0100000C) + b"\0" * 24


def info(bundle_id, min_os="17.0", **extra):
    base = {"CFBundleIdentifier": bundle_id, "CFBundleShortVersionString": "1.0", "CFBundleVersion": "7",
            "MinimumOSVersion": min_os, "CFBundleExecutable": "Main"}
    base.update(extra)
    return base


APP_INFO = info(APP, CFBundleSupportedPlatforms=["iPhoneOS"], DTPlatformName="iphoneos", UIDeviceFamily=[1, 2])


def profile(bundle_id=APP, **override):
    value = {"TeamIdentifier": [TEAM], "ExpirationDate": NOW + datetime.timedelta(days=30),
             "Platform": ["iOS"], "DeveloperCertificates": [LEAF],
             "Entitlements": {"application-identifier": f"{TEAM}.{bundle_id}",
                              "com.apple.developer.team-identifier": TEAM}}
    value.update(override)
    return value


def make_ipa(path, extra_entries=(), extensions=(EXT,), app_info=APP_INFO, executable=ARM64, profile_bytes=None):
    with zipfile.ZipFile(path, "w") as archive:
        base = "Payload/App.app/"
        archive.writestr(base + "Info.plist", plistlib.dumps(app_info))
        archive.writestr(base + "Main", executable)
        archive.writestr(base + "embedded.mobileprovision", plistlib.dumps(profile()) if profile_bytes is None else profile_bytes)
        for ext in extensions:
            ext_base = f"{base}PlugIns/T.appex/"
            archive.writestr(ext_base + "Info.plist", plistlib.dumps(info(ext)))
            archive.writestr(ext_base + "Main", executable)
            archive.writestr(ext_base + "embedded.mobileprovision", plistlib.dumps(profile(ext)))
        for entry in extra_entries:
            if isinstance(entry, zipfile.ZipInfo):
                archive.writestr(entry, "x")
            else:
                archive.writestr(entry, "x")


class FakeTools:
    """Answers like codesign/security for a correctly signed IPA, with per-test overrides."""

    def __init__(self, profiles=None, verify_ok=True, team=TEAM, authority="Apple Distribution: Me (%s)" % TEAM,
                 leaf=LEAF, entitlements=None):
        self.profiles, self.verify_ok, self.team, self.authority, self.leaf = profiles or {}, verify_ok, team, authority, leaf
        self.entitlements = entitlements or {}
        self.calls = []

    def bundle_id(self, path):
        with open(os.path.join(path, "Info.plist"), "rb") as handle:
            return plistlib.loads(handle.read())["CFBundleIdentifier"]

    def __call__(self, argv):
        self.calls.append(argv)
        if argv[0] == "security":
            path = os.path.dirname(argv[-1])
            override = self.profiles.get(self.bundle_id(path))
            if override is not None:
                return 0, plistlib.dumps(override), ""
            with open(argv[-1], "rb") as handle:
                return 0, handle.read(), ""
        target = argv[-1]
        if "--verify" in argv:
            return (0, b"", "") if self.verify_ok else (1, b"", "code object is not signed at all")
        if "-dvv" in argv:
            return 0, b"", f"Authority={self.authority}\nAuthority=Apple Worldwide Developer Relations\n" \
                           f"Authority=Apple Root CA\nTeamIdentifier={self.team}\n"
        if any(item.startswith("--extract-certificates=") for item in argv):
            prefix = [item for item in argv if item.startswith("--extract-certificates=")][0].split("=", 1)[1]
            with open(prefix + "0", "wb") as handle:
                handle.write(self.leaf)
            return 0, b"", ""
        bundle = self.bundle_id(target)
        signed = {"application-identifier": f"{TEAM}.{bundle}", "com.apple.developer.team-identifier": TEAM}
        signed.update(self.entitlements.get(bundle, {}))
        return 0, plistlib.dumps(signed), ""


class VerifyIpaTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.ipa = os.path.join(self.dir.name, "a.ipa")

    def run_verify(self, tools=None, ipa=None, extra=(), min_os="17.0", extensions=(f"{EXT}:17.0",)):
        argv = [ipa or self.ipa, "--bundle-id", APP, "--version", "1.0", "--build", "7", "--min-os", min_os,
                "--platform", "ios", "--families", "1,2", "--team", TEAM, *extra]
        for item in extensions:
            argv += ["--extension", item]
        problems, _summary = verify_ipa.verify(verify_ipa.parse_args(argv), tools or FakeTools(), NOW)
        return problems

    def assertRejects(self, problems, fragment):
        self.assertTrue(any(fragment in problem for problem in problems), problems)

    def test_accepts_correctly_signed_ipa(self):
        make_ipa(self.ipa)
        self.assertEqual(self.run_verify(), [])

    def test_accepts_legacy_iphone_distribution_and_newer_min_os(self):
        make_ipa(self.ipa, app_info=dict(APP_INFO, MinimumOSVersion="17.2"))
        tools = FakeTools(authority=f"iPhone Distribution: Me ({TEAM})")
        self.assertEqual(self.run_verify(tools), [])

    @unittest.skipUnless(sys.platform == "darwin", "Requires native macOS signing tools")
    def test_unsigned_forged_zip_rejected_by_default_main(self):
        make_ipa(self.ipa, profile_bytes=plistlib.dumps(profile(DeveloperCertificates=[b"Apple Distribution"])))
        argv = [self.ipa, "--bundle-id", APP, "--version", "1.0", "--build", "7", "--min-os", "17.0",
                "--platform", "ios", "--families", "1,2", "--team", TEAM, "--extension", f"{EXT}:17.0"]
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors):
            self.assertEqual(verify_ipa.main(argv), 1)
        self.assertIn("codesign verification failed", errors.getvalue())
        self.assertNotIn("duplicate entry", errors.getvalue())

    def test_case_variant_payload_folder_rejected_before_tools(self):
        make_ipa(self.ipa, extra_entries=["payload/Evil.app/Info.plist"])
        with zipfile.ZipFile(self.ipa) as archive:
            problems, _ = verify_ipa.validate_zip(archive)
        self.assertRejects(problems, "noncanonical Payload")

    def test_codesign_failure_rejected(self):
        make_ipa(self.ipa)
        self.assertRejects(self.run_verify(FakeTools(verify_ok=False)), "codesign verification failed")

    def test_wrong_signing_team_and_identity_rejected(self):
        make_ipa(self.ipa)
        problems = self.run_verify(FakeTools(team="ZZZZZZZZZZ", authority="Apple Development: Me (X)"))
        self.assertRejects(problems, "signed by team")
        self.assertRejects(problems, "not an Apple distribution certificate")

    def test_leaf_certificate_missing_from_profile_rejected(self):
        make_ipa(self.ipa)
        self.assertRejects(self.run_verify(FakeTools(leaf=b"other-cert")), "not in the profile")

    def test_expired_profile_rejected(self):
        make_ipa(self.ipa)
        expired = profile(ExpirationDate=NOW - datetime.timedelta(seconds=1))
        self.assertRejects(self.run_verify(FakeTools({APP: expired})), "expired")

    def test_non_app_store_profiles_rejected(self):
        make_ipa(self.ipa)
        for key, value, fragment in (("ProvisionedDevices", ["udid"], "lists devices"),
                                     ("ProvisionsAllDevices", True, "all devices")):
            self.assertRejects(self.run_verify(FakeTools({APP: profile(**{key: value})})), fragment)
        debug = profile(Entitlements={"application-identifier": f"{TEAM}.{APP}", "get-task-allow": True})
        self.assertRejects(self.run_verify(FakeTools({APP: debug})), "get-task-allow")

    def test_wildcard_profile_and_wrong_team_rejected(self):
        make_ipa(self.ipa)
        wildcard = profile(Entitlements={"application-identifier": f"{TEAM}.*"})
        self.assertRejects(self.run_verify(FakeTools({EXT: wildcard})), "application-identifier")
        self.assertRejects(self.run_verify(FakeTools({APP: profile(TeamIdentifier=["OTHER"])})), "profile team")

    def test_signed_entitlements_mismatch_rejected(self):
        make_ipa(self.ipa)
        tools = FakeTools(entitlements={EXT: {"application-identifier": f"{TEAM}.com.other", "get-task-allow": True}})
        problems = self.run_verify(tools)
        self.assertRejects(problems, "signed application-identifier")
        self.assertRejects(problems, "signed entitlements allow debugging")

    def test_metadata_mismatch_and_min_os_comparison(self):
        make_ipa(self.ipa, app_info=dict(APP_INFO, CFBundleVersion="8", MinimumOSVersion="16.0"))
        problems = self.run_verify()
        self.assertRejects(problems, "CFBundleVersion")
        self.assertRejects(problems, "MinimumOSVersion")

    def test_unexpected_and_missing_extensions_rejected(self):
        make_ipa(self.ipa, extensions=("com.example.other",))
        problems = self.run_verify()
        self.assertRejects(problems, "unexpected extension")
        self.assertRejects(problems, "is not embedded")

    def test_executable_without_arm64_rejected(self):
        make_ipa(self.ipa, executable=struct.pack("<II", 0xFEEDFACF, 7) + b"\0" * 24)
        self.assertRejects(self.run_verify(), "no arm64 slice")

    def test_fat_executable_with_arm64_slice_accepted(self):
        fat = b"\xca\xfe\xba\xbe" + struct.pack(">I", 2)
        fat += struct.pack(">iiIII", 7, 3, 0, 0, 0) + struct.pack(">iiIII", 0x0100000C, 0, 0, 0, 0)
        make_ipa(self.ipa, executable=fat)
        self.assertEqual(self.run_verify(), [])

    def test_malicious_zips_rejected_before_extraction(self):
        link = zipfile.ZipInfo("Payload/App.app/link")
        link.external_attr = 0o120777 << 16
        for entry, fragment in (("../evil", "unsafe path"), ("/abs", "unsafe path"),
                                ("Payload/App.app/a/../../x", "unsafe path"),
                                ("Payload/Other.app/Info.plist", "exactly one app"),
                                ("Payload/App.app/Info.plist", "duplicate"),
                                ("Payload/APP.app/Info.plist", "exactly one app"),
                                (link, "symlink")):
            with self.subTest(entry=getattr(entry, "filename", entry)):
                make_ipa(self.ipa, extra_entries=[entry])
                tools = FakeTools()
                self.assertRejects(self.run_verify(tools), fragment)
                self.assertEqual(tools.calls, [])

    def test_not_a_zip_rejected(self):
        with open(self.ipa, "wb") as handle:
            handle.write(b"nope")
        self.assertRejects(self.run_verify(), "cannot open IPA")


if __name__ == "__main__":
    unittest.main()
