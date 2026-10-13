#!/usr/bin/env python3
"""Check a signed IPA against what the release lane meant to build, before upload.

Standard library only, plus the macOS `codesign` and `security` tools, so it must run on a Mac.
Metadata in Info.plist and embedded.mobileprovision is only a claim; this verifies the signature:

  * the ZIP is validated (no traversal, symlinks, duplicates, ambiguous .app) before extraction;
  * `codesign --verify --deep --strict` passes for the app and every embedded extension;
  * the signing identity is an Apple distribution certificate of the expected team;
  * the profile is CMS-decoded by `security cms -D`, unexpired, an App Store profile, and its
    DeveloperCertificates contain the exact leaf certificate that signed the code;
  * the signed entitlements name the expected application-identifier and team and do not allow debugging.

It never reads signing keys and never talks to Apple. A mismatch exits 1 with every problem listed.
"""
import argparse
import datetime
import os
import plistlib
import posixpath
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import unicodedata
import zipfile

PLATFORMS = {
    "ios": ("iPhoneOS", "iphoneos", "iOS"),
    "tvos": ("AppleTVOS", "appletvos", "tvOS"),
}

DISTRIBUTION_AUTHORITIES = ("Apple Distribution:", "iPhone Distribution:")
MAX_UNCOMPRESSED_BYTES = 16 * 1024 ** 3
ARM64_CPU_TYPE = 0x0100000C


class ToolError(Exception):
    pass


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa")
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--min-os", required=True)
    parser.add_argument("--platform", choices=sorted(PLATFORMS), required=True)
    parser.add_argument("--families", required=True, help="comma separated UIDeviceFamily values")
    parser.add_argument("--team", required=True)
    parser.add_argument(
        "--extension",
        action="append",
        default=[],
        metavar="BUNDLE_ID:MIN_OS",
        help="an app extension that must be embedded with this exact bundle id",
    )
    return parser.parse_args(argv)


def run_tool(argv):
    """Run a signing tool. Returns (returncode, stdout bytes, stderr text)."""
    try:
        done = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
    except FileNotFoundError:
        raise ToolError(f"{argv[0]} is not available; the IPA signature can only be verified on macOS")
    except subprocess.TimeoutExpired:
        raise ToolError(f"{argv[0]} timed out")
    return done.returncode, done.stdout, done.stderr.decode("utf-8", "replace")


def short(text, limit=300):
    text = " ".join(text.split())
    return text if len(text) <= limit else text[:limit] + "..."


# --- ZIP ------------------------------------------------------------------------------------


def validate_zip(archive):
    """Structural checks on the entry list. Returns (problems, app_name); nothing is extracted yet."""
    problems = []
    seen = {}
    files = set()
    total = 0
    apps = set()
    for info in archive.infolist():
        name = info.filename
        is_dir = name.endswith("/")
        parts = name.rstrip("/").split("/")
        if (not name or name.startswith("/") or "\\" in name or "\x00" in name
                or re.match(r"^[A-Za-z]:", name) or any(part in ("", ".", "..") for part in parts)):
            problems.append(f"unsafe path in IPA: {name!r}")
            continue
        mode = info.external_attr >> 16
        kind = stat.S_IFMT(mode)
        if kind == stat.S_IFLNK:
            problems.append(f"symlink in IPA: {name!r}")
        elif kind not in (0, stat.S_IFREG, stat.S_IFDIR):
            problems.append(f"special file in IPA: {name!r}")
        if info.flag_bits & 0x1:
            problems.append(f"encrypted entry in IPA: {name!r}")
        key = unicodedata.normalize("NFC", name.rstrip("/")).casefold()
        if key in seen:
            problems.append(f"duplicate entry in IPA: {name!r} (and {seen[key]!r})")
        seen[key] = name
        if not is_dir:
            files.add(key)
        total += info.file_size
        if parts[0].casefold() == "payload" and parts[0] != "Payload":
            problems.append(f"noncanonical Payload directory in IPA: {name!r}")
        if parts[0] == "Payload" and len(parts) > 1:
            if not parts[1].endswith(".app") or (len(parts) == 2 and not is_dir):
                problems.append(f"unexpected entry in Payload/: {name!r}")
            else:
                apps.add(parts[1])
    for key in seen:
        segments = key.split("/")
        for end in range(1, len(segments)):
            if "/".join(segments[:end]) in files:
                problems.append(f"entry {seen[key]!r} lies below a file")
                break
    if total > MAX_UNCOMPRESSED_BYTES:
        problems.append("IPA uncompressed size is implausibly large")
    app_name = None
    if len(apps) != 1:
        problems.append(f"expected exactly one app in Payload/, found {sorted(apps)}")
    else:
        app_name = next(iter(apps))
    return problems, app_name


def extract_zip(archive, root):
    """Extract an already validated archive, keeping the mode bits (executables) codesign relies on."""
    root = os.path.realpath(root)
    for info in archive.infolist():
        target = os.path.realpath(os.path.join(root, info.filename))
        if os.path.commonpath([root, target]) != root:
            raise ValueError(f"unsafe path in IPA: {info.filename!r}")
        if info.filename.endswith("/"):
            os.makedirs(target, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with archive.open(info) as source, open(target, "xb") as sink:
            shutil.copyfileobj(source, sink)
        os.chmod(target, ((info.external_attr >> 16) & 0o777) | 0o600)


# --- metadata -------------------------------------------------------------------------------


def version_tuple(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+(\.\d+)*", value):
        return None
    numbers = [int(part) for part in value.split(".")]
    while len(numbers) > 1 and numbers[-1] == 0:
        numbers.pop()
    return tuple(numbers)


def load_info(bundle_dir, label, problems):
    try:
        with open(os.path.join(bundle_dir, "Info.plist"), "rb") as handle:
            return plistlib.loads(handle.read())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        problems.append(f"{label}: cannot read Info.plist: {error}")
        return None


def check_bundle(info, expected, min_os, problems, label):
    for key, want in expected.items():
        got = info.get(key)
        if got != want:
            problems.append(f"{label}: {key} is {got!r}, expected {want!r}")
    got = info.get("MinimumOSVersion")
    got_version, want_version = version_tuple(got), version_tuple(min_os)
    if got_version is None or want_version is None or got_version < want_version:
        problems.append(f"{label}: MinimumOSVersion is {got!r}, expected at least {min_os!r}")


def macho_has_arm64(path):
    """True when the file is arm64 Mach-O, thin or as one slice of a fat binary."""
    with open(path, "rb") as handle:
        head = handle.read(8)
        if head[:4] == bytes.fromhex("cffaedfe"):  # thin 64-bit little endian
            return struct.unpack("<i", head[4:8])[0] == ARM64_CPU_TYPE
        if head[:4] in (bytes.fromhex("cafebabe"), bytes.fromhex("cafebabf")):
            count = struct.unpack(">I", head[4:8])[0]
            entry = 32 if head[3] == 0xBF else 20  # fat_arch_64 vs fat_arch
            if count > 64:
                return False
            for _ in range(count):
                record = handle.read(entry)
                if len(record) < 4:
                    return False
                if struct.unpack(">i", record[:4])[0] == ARM64_CPU_TYPE:
                    return True
    return False


def check_executable(bundle_dir, info, problems, label):
    name = info.get("CFBundleExecutable")
    if not isinstance(name, str) or "/" in name or name in ("", ".", ".."):
        problems.append(f"{label}: CFBundleExecutable is {name!r}")
        return
    path = os.path.join(bundle_dir, name)
    if not os.path.isfile(path) or os.path.islink(path):
        problems.append(f"{label}: executable {name!r} is missing")
    elif not macho_has_arm64(path):
        problems.append(f"{label}: executable {name!r} has no arm64 slice")


# --- signature ------------------------------------------------------------------------------


def aware(moment):
    return moment if moment.tzinfo else moment.replace(tzinfo=datetime.timezone.utc)


def decode_profile(run, bundle_dir):
    path = os.path.join(bundle_dir, "embedded.mobileprovision")
    if not os.path.isfile(path):
        raise ValueError("no embedded.mobileprovision")
    code, out, err = run(["security", "cms", "-D", "-i", path])
    if code != 0:
        raise ValueError(f"security cms could not decode the profile: {short(err)}")
    try:
        return plistlib.loads(out)
    except (ValueError, plistlib.InvalidFileException) as error:
        raise ValueError(f"decoded profile is not a plist: {error}")


def check_profile(profile, bundle_id, team, platform, label, problems, now):
    if profile.get("TeamIdentifier") != [team]:
        problems.append(f"{label}: profile team is {profile.get('TeamIdentifier')!r}, expected {[team]!r}")
    entitlements = profile.get("Entitlements") or {}
    wanted = f"{team}.{bundle_id}"
    # A wildcard profile would also satisfy a prefix match, so the identifier is compared whole.
    if entitlements.get("application-identifier") != wanted:
        problems.append(f"{label}: profile application-identifier is "
                        f"{entitlements.get('application-identifier')!r}, expected {wanted!r}")
    profile_team = entitlements.get("com.apple.developer.team-identifier")
    if profile_team is not None and profile_team != team:
        problems.append(f"{label}: profile entitlement team is {profile_team!r}, expected {team!r}")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, datetime.datetime):
        problems.append(f"{label}: profile has no ExpirationDate")
    elif aware(expiry) <= now:
        problems.append(f"{label}: profile expired at {aware(expiry).isoformat()}")
    created = profile.get("CreationDate")
    if isinstance(created, datetime.datetime) and aware(created) > now + datetime.timedelta(days=1):
        problems.append(f"{label}: profile CreationDate is in the future")
    if entitlements.get("get-task-allow"):
        problems.append(f"{label}: profile allows debugging (get-task-allow); not a distribution profile")
    if profile.get("ProvisionedDevices"):
        problems.append(f"{label}: profile lists devices; not an App Store profile")
    if profile.get("ProvisionsAllDevices"):
        problems.append(f"{label}: profile provisions all devices (enterprise); not an App Store profile")
    platforms = profile.get("Platform")
    if platforms is not None and platform not in platforms:
        problems.append(f"{label}: profile platform is {platforms!r}, expected {platform!r}")


def check_signature(run, bundle_dir, profile, bundle_id, team, scratch, label, problems):
    code, _out, err = run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", bundle_dir])
    if code != 0:
        problems.append(f"{label}: codesign verification failed: {short(err)}")
        return
    code, _out, err = run(["codesign", "-dvv", bundle_dir])
    if code != 0:
        problems.append(f"{label}: codesign could not describe the signature: {short(err)}")
        return
    teams = re.findall(r"^TeamIdentifier=(.*)$", err, re.MULTILINE)
    if teams != [team]:
        problems.append(f"{label}: signed by team {teams!r}, expected {[team]!r}")
    authorities = re.findall(r"^Authority=(.*)$", err, re.MULTILINE)
    if not authorities or not authorities[0].startswith(DISTRIBUTION_AUTHORITIES):
        problems.append(f"{label}: signing identity is {authorities[:1]!r}, not an Apple distribution certificate")
    elif authorities[-1] != "Apple Root CA":
        problems.append(f"{label}: signing chain does not end at Apple Root CA")

    os.makedirs(scratch, exist_ok=True)
    prefix = os.path.join(scratch, "leaf")
    code, _out, err = run(["codesign", "-d", f"--extract-certificates={prefix}", bundle_dir])
    leaf_path = prefix + "0"
    if code != 0 or not os.path.isfile(leaf_path):
        problems.append(f"{label}: could not extract the signing certificate: {short(err)}")
    elif profile is not None:
        with open(leaf_path, "rb") as handle:
            leaf = handle.read()
        if leaf not in [bytes(item) for item in profile.get("DeveloperCertificates") or []]:
            problems.append(f"{label}: the certificate that signed the code is not in the profile")

    code, out, err = run(["codesign", "-d", "--entitlements", ":-", bundle_dir])
    start = out.find(b"<?xml")
    try:
        if code != 0 or start < 0:
            raise ValueError("none found")
        signed = plistlib.loads(out[start:])
    except (ValueError, plistlib.InvalidFileException) as error:
        problems.append(f"{label}: cannot read signed entitlements: {error} {short(err)}".rstrip())
        return
    wanted = f"{team}.{bundle_id}"
    if signed.get("application-identifier") != wanted:
        problems.append(f"{label}: signed application-identifier is "
                        f"{signed.get('application-identifier')!r}, expected {wanted!r}")
    if signed.get("com.apple.developer.team-identifier") != team:
        problems.append(f"{label}: signed team identifier is "
                        f"{signed.get('com.apple.developer.team-identifier')!r}, expected {team!r}")
    if signed.get("get-task-allow"):
        problems.append(f"{label}: signed entitlements allow debugging (get-task-allow)")


def check_bundle_signing(run, bundle_dir, bundle_id, team, platform, scratch, label, problems, now):
    profile = None
    try:
        profile = decode_profile(run, bundle_dir)
    except ValueError as error:
        problems.append(f"{label}: {error}")
    if profile is not None:
        check_profile(profile, bundle_id, team, platform, label, problems, now)
    check_signature(run, bundle_dir, profile, bundle_id, team, scratch, label, problems)


# --- main -----------------------------------------------------------------------------------


def verify(args, run, now):
    """Returns (problems, summary). Raises nothing for bad input; tool absence is a problem."""
    platform_name, dt_platform, profile_platform = PLATFORMS[args.platform]
    families = [int(value) for value in args.families.split(",")]
    wanted = {}
    for item in args.extension:
        ext_id, _, ext_min = item.partition(":")
        wanted[ext_id] = ext_min

    try:
        archive = zipfile.ZipFile(args.ipa)
    except (OSError, zipfile.BadZipFile) as error:
        return [f"cannot open IPA: {error}"], None
    with archive:
        problems, app_name = validate_zip(archive)
        if problems:
            return problems, None
        with tempfile.TemporaryDirectory(prefix="verify-ipa-") as work:
            extract_zip(archive, os.path.join(work, "ipa"))
            app_dir = os.path.join(work, "ipa", "Payload", app_name)

            info = load_info(app_dir, "app", problems)
            if info is None:
                return problems, None
            expected = {
                "CFBundleIdentifier": args.bundle_id,
                "CFBundleShortVersionString": args.version,
                "CFBundleVersion": args.build,
                "CFBundleSupportedPlatforms": [platform_name],
                "DTPlatformName": dt_platform,
                "UIDeviceFamily": families,
            }
            check_bundle(info, expected, args.min_os, problems, "app")
            check_executable(app_dir, info, problems, "app")

            extensions = {}
            plugins = os.path.join(app_dir, "PlugIns")
            for entry in sorted(os.listdir(plugins)) if os.path.isdir(plugins) else []:
                if not entry.endswith(".appex"):
                    continue
                ext_dir = os.path.join(plugins, entry)
                ext_info = load_info(ext_dir, entry, problems)
                if ext_info is None:
                    continue
                ext_id = ext_info.get("CFBundleIdentifier")
                if ext_id in extensions:
                    problems.append(f"extension {ext_id!r} is embedded more than once")
                extensions[ext_id] = (ext_dir, ext_info)
            for ext_id in sorted(set(extensions) - set(wanted), key=str):
                problems.append(f"unexpected extension {ext_id!r}")
            for ext_id, ext_min in wanted.items():
                if ext_id not in extensions:
                    problems.append(f"extension {ext_id!r} is not embedded")
                    continue
                ext_dir, ext_info = extensions[ext_id]
                ext_expected = {
                    "CFBundleIdentifier": ext_id,
                    "CFBundleShortVersionString": args.version,
                    "CFBundleVersion": args.build,
                }
                check_bundle(ext_info, ext_expected, ext_min, problems, ext_id)
                check_executable(ext_dir, ext_info, problems, ext_id)

            try:
                check_bundle_signing(run, app_dir, args.bundle_id, args.team, profile_platform,
                                     os.path.join(work, "cert-app"), "app", problems, now)
                for number, ext_id in enumerate(sorted(set(wanted) & set(extensions))):
                    check_bundle_signing(run, extensions[ext_id][0], ext_id, args.team, profile_platform,
                                         os.path.join(work, f"cert-ext{number}"), ext_id, problems, now)
            except ToolError as error:
                problems.append(str(error))
    return problems, f"{args.bundle_id} {args.version} ({args.build}), {args.platform}, families {families}"


def main(argv, run=run_tool):
    args = parse_args(argv)
    problems, summary = verify(args, run, datetime.datetime.now(datetime.timezone.utc))
    if problems:
        print("IPA verification failed:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    print(f"IPA verified: {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
