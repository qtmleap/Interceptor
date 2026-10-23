#!/usr/bin/env python3
"""Export UI screenshots from an xcresult and publish them only as verified lossless WebP.

Usage: export-ui-evidence.py --result-bundle X.xcresult --output DIR --source SHA [--environment JSON]

The output directory is created atomically and only after every required image has been
converted and re-verified. On any failure it contains a bounded failure.json and no images.
Exit status: 0 success, 1 evidence failure, 2 usage error.
"""
import argparse, hashlib, json, math, os, re, shutil, stat, struct, subprocess, sys, tempfile, time, zlib

SCHEMA_VERSION = 1
PILLOW_VERSION = "12.3.0"
CAPS = {
    "manifest_bytes": 4 * 1024 * 1024,
    "attachments": 4096,
    "images": 64,
    "encoded_bytes": 32 * 1024 * 1024,
    "image_input_bytes": 128 * 1024 * 1024,
    "dimension": 8192,
    "pixels": 16 * 1024 * 1024,
    "icc_bytes": 1024 * 1024,
    "png_chunks": 4096,
    "output_bytes": 96 * 1024 * 1024,
    "geometry_bytes": 8 * 1024,
    "nonimage_file_bytes": 256 * 1024 * 1024,
    "nonimage_total_bytes": 1024 * 1024 * 1024,
    "hash_chunk": 1024 * 1024,
    "environment_bytes": 64 * 1024,
    "seconds": 600,
    "export_seconds": 300,
    "text": 200,
}
REQUIRED_NAMES = [f"Outbound {m} {t}" for t in ("en", "ja") for m in ("GET", "POST", "PUT", "footer")]
GEOMETRY_KIND = "interceptor-ui-screen"
GEOMETRY_FIELDS = ("scale", "screenPointWidth", "screenPointHeight", "imagePixelWidth", "imagePixelHeight",
                   "osVersion", "deviceModel", "orientation", "locale")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
SAFE_FILENAME = re.compile(r"^[A-Za-z0-9._ -]{1,200}$")


class EvidenceError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


class Deadline:
    def __init__(self, seconds):
        self.end = time.monotonic() + seconds

    def check(self):
        if time.monotonic() > self.end:
            raise EvidenceError("time-cap", "evidence export exceeded its time cap")

    def remaining(self):
        return max(1.0, self.end - time.monotonic())


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def clean_text(value, limit=None):
    limit = limit or CAPS["text"]
    if not isinstance(value, str):
        return None
    return "".join(c if c.isprintable() else "?" for c in value)[:limit]


# ---------------------------------------------------------------- PNG inspection

def inspect_png(data):
    """Validate PNG structure and metadata without decoding pixels. Returns a description dict."""
    if len(data) > CAPS["encoded_bytes"]:
        raise EvidenceError("encoded-size", "PNG exceeds the encoded size cap")
    if not data.startswith(PNG_SIGNATURE):
        raise EvidenceError("not-png", "attachment is not a PNG")
    pos, chunks, seen = len(PNG_SIGNATURE), [], {}
    ihdr = icc_raw = None
    color_chunks = {}
    while True:
        if len(chunks) >= CAPS["png_chunks"]:
            raise EvidenceError("png-chunks", "PNG has too many chunks")
        if pos + 12 > len(data):
            raise EvidenceError("png-truncated", "PNG is truncated")
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        end = pos + 8 + length
        if length > 0x7FFFFFFF or end + 4 > len(data):
            raise EvidenceError("png-truncated", "PNG chunk exceeds the file")
        body = data[pos + 8:end]
        if struct.unpack(">I", data[end:end + 4])[0] != zlib.crc32(data[pos + 4:end]):
            raise EvidenceError("png-crc", "PNG chunk CRC mismatch")
        if not chunks and kind != b"IHDR":
            raise EvidenceError("png-structure", "PNG does not start with IHDR")
        chunks.append(kind)
        seen[kind] = seen.get(kind, 0) + 1
        if kind == b"IHDR":
            if seen[kind] > 1 or length != 13:
                raise EvidenceError("png-structure", "invalid PNG IHDR")
            ihdr = struct.unpack(">IIBBBBB", body)
            # Bound dimensions before any further interpretation or decode.
            if not (0 < ihdr[0] <= CAPS["dimension"] and 0 < ihdr[1] <= CAPS["dimension"]) \
                    or ihdr[0] * ihdr[1] > CAPS["pixels"]:
                raise EvidenceError("dimension-cap", "PNG dimensions exceed caps")
        elif kind == b"iCCP":
            icc_raw = body
        elif kind in (b"sRGB", b"gAMA", b"cHRM"):
            color_chunks[kind] = body
        pos = end + 4
        if kind == b"IEND":
            break
    if pos != len(data):
        raise EvidenceError("png-structure", "trailing bytes after PNG IEND")
    width, height, depth, color_type, compression, filt, interlace = ihdr
    if depth != 8:
        raise EvidenceError("unsupported-depth", f"unsupported PNG bit depth {depth}")
    if color_type not in (2, 6):
        raise EvidenceError("unsupported-color-type", f"unsupported PNG color type {color_type}")
    if interlace != 0:
        raise EvidenceError("unsupported-interlace", "interlaced PNG is unsupported")
    for animated in (b"acTL", b"fcTL", b"fdAT"):
        if animated in seen:
            raise EvidenceError("unsupported-animation", "animated PNG is unsupported")
    for ambiguous in (b"tRNS", b"cICP"):
        if ambiguous in seen:
            raise EvidenceError("ambiguous-color", f"PNG {ambiguous.decode()} chunk is unsupported")
    if any(seen.get(kind, 0) > 1 for kind in (b"iCCP", b"sRGB", b"gAMA", b"cHRM")):
        raise EvidenceError("ambiguous-color", "duplicate PNG color profile chunk")
    if b"sRGB" in color_chunks and color_chunks[b"sRGB"] not in (b"\x00", b"\x01", b"\x02", b"\x03"):
        raise EvidenceError("ambiguous-color", "invalid sRGB rendering intent")
    expected_srgb = {b"gAMA": struct.pack(">I", 45455),
                     b"cHRM": struct.pack(">8I", 31270, 32900, 64000, 33000, 30000, 60000, 15000, 6000)}
    for kind, expected in expected_srgb.items():
        if kind in color_chunks and (b"sRGB" not in color_chunks or color_chunks[kind] != expected):
            raise EvidenceError("ambiguous-color", "unsupported or inconsistent PNG color fallback")
    if icc_raw is not None and b"sRGB" in seen:
        raise EvidenceError("ambiguous-color", "PNG has both iCCP and sRGB")
    icc = None
    if icc_raw is not None:
        name_end = icc_raw.find(b"\0")
        if name_end < 1 or name_end + 2 > len(icc_raw) or icc_raw[name_end + 1] != 0:
            raise EvidenceError("ambiguous-color", "invalid iCCP chunk")
        inflater = zlib.decompressobj()
        try:
            icc = inflater.decompress(icc_raw[name_end + 2:], CAPS["icc_bytes"] + 1)
        except zlib.error:
            raise EvidenceError("ambiguous-color", "invalid iCCP data")
        if not icc or len(icc) > CAPS["icc_bytes"] or inflater.unconsumed_tail:
            raise EvidenceError("ambiguous-color", "iCCP profile is empty or too large")
        if not inflater.eof or inflater.unused_data:
            raise EvidenceError("ambiguous-color", "iCCP data is truncated or has trailing bytes")
        policy = "icc"
    elif b"sRGB" in seen:
        policy = "standard-srgb"
    else:
        raise EvidenceError("ambiguous-color", "PNG has no explicit color metadata")
    return {"width": width, "height": height, "has_alpha": color_type == 6, "policy": policy, "icc": icc}


# ---------------------------------------------------------------- WebP conversion

def load_pillow():
    try:
        import PIL
        from PIL import Image, features
    except ImportError:
        raise EvidenceError("pillow-missing", "Pillow is not installed")
    if PIL.__version__ != PILLOW_VERSION:
        raise EvidenceError("pillow-version", f"Pillow {PILLOW_VERSION} is required")
    if not features.check("webp"):
        raise EvidenceError("webp-missing", "Pillow lacks WebP support")
    Image.MAX_IMAGE_PIXELS = CAPS["pixels"]
    return Image, features


def webp_chunks(data):
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WEBP" \
            or struct.unpack("<I", data[4:8])[0] + 8 != len(data):
        raise EvidenceError("webp-structure", "invalid WebP container")
    pos, kinds = 12, []
    while pos + 8 <= len(data):
        kind, length = data[pos:pos + 4], struct.unpack("<I", data[pos + 4:pos + 8])[0]
        pos += 8 + length + (length & 1)
        kinds.append(kind)
    if pos != len(data):
        raise EvidenceError("webp-structure", "invalid WebP chunk layout")
    return kinds


def convert_to_lossless_webp(png_bytes, info, destination):
    """Write destination and prove it decodes to exactly the PNG's RGBA pixels and profile."""
    import io
    Image, _ = load_pillow()
    with Image.open(io.BytesIO(png_bytes)) as source:
        if source.format != "PNG" or getattr(source, "n_frames", 1) != 1 or getattr(source, "is_animated", False):
            raise EvidenceError("unsupported-animation", "PNG is not a single frame")
        if source.mode not in ("RGB", "RGBA") or source.size != (info["width"], info["height"]):
            raise EvidenceError("png-mismatch", "decoder disagrees with PNG header")
        source.load()
        source_icc = source.info.get("icc_profile")
        if info["policy"] == "icc" and source_icc != info["icc"]:
            raise EvidenceError("ambiguous-color", "decoded ICC profile differs from the PNG chunk")
        if info["policy"] == "standard-srgb" and source_icc:
            raise EvidenceError("ambiguous-color", "unexpected ICC profile")
        rgba = source.convert("RGBA")
    source_pixels = rgba.tobytes()
    save_args = {"format": "WEBP", "lossless": True, "exact": True, "quality": 100, "method": 6}
    if info["policy"] == "icc":
        save_args["icc_profile"] = info["icc"]
    rgba.save(destination, **save_args)
    with open(destination, "rb") as handle:
        encoded = handle.read(CAPS["encoded_bytes"] + 1)
    if len(encoded) > CAPS["encoded_bytes"]:
        raise EvidenceError("encoded-size", "WebP exceeds the encoded size cap")
    kinds = webp_chunks(encoded)
    if b"VP8L" not in kinds or b"VP8 " in kinds or b"ANIM" in kinds or b"ANMF" in kinds:
        raise EvidenceError("webp-not-lossless", "WebP is not a single lossless frame")
    with Image.open(destination) as output:
        if output.format != "WEBP" or getattr(output, "n_frames", 1) != 1 or output.size != rgba.size:
            raise EvidenceError("webp-mismatch", "WebP dimensions or frames differ")
        output.load()
        output_icc = output.info.get("icc_profile")
        if (output_icc if info["policy"] == "icc" else (output_icc or None)) != (info["icc"] if info["policy"] == "icc" else None):
            raise EvidenceError("webp-profile", "WebP ICC profile differs from the PNG")
        output_pixels = output.convert("RGBA").tobytes()
    if output_pixels != source_pixels:
        raise EvidenceError("webp-pixels", "WebP pixels differ from the PNG (including RGB under alpha)")
    return {"sha256": sha256(encoded), "bytes": len(encoded)}


# ---------------------------------------------------------------- manifest handling

def read_bounded(path, limit, what):
    try:
        info = os.lstat(path)
    except OSError:
        raise EvidenceError("missing-file", f"{what} is missing")
    if not stat.S_ISREG(info.st_mode):
        raise EvidenceError("unsafe-path", f"{what} is not a regular file")
    if info.st_size > limit:
        raise EvidenceError("encoded-size", f"{what} exceeds its size cap")
    with open(path, "rb") as handle:
        return handle.read(limit + 1)


def safe_export_path(directory, name):
    if not isinstance(name, str) or not SAFE_FILENAME.match(name) or name in (".", "..", "manifest.json") \
            or name.startswith("."):
        raise EvidenceError("unsafe-path", "exported file name is not a plain file name")
    path = os.path.join(directory, name)
    if os.path.dirname(os.path.realpath(path)) != os.path.realpath(directory):
        raise EvidenceError("unsafe-path", "exported file escapes the export directory")
    return path


def collect_attachments(directory):
    manifest = json.loads(read_bounded(os.path.join(directory, "manifest.json"), CAPS["manifest_bytes"], "manifest.json"))
    if not isinstance(manifest, list):
        raise EvidenceError("manifest-schema", "manifest is not a list")
    attachments, seen = [], set()
    for test in manifest:
        if not isinstance(test, dict) or not isinstance(test.get("attachments"), list):
            raise EvidenceError("manifest-schema", "manifest test entry is malformed")
        for entry in test["attachments"]:
            if not isinstance(entry, dict) or not isinstance(entry.get("suggestedHumanReadableName"), str) \
                    or not isinstance(entry.get("deviceId"), str):
                raise EvidenceError("manifest-schema", "manifest attachment entry is malformed")
            exported = entry.get("exportedFileName")
            path = safe_export_path(directory, exported)
            if exported in seen:
                raise EvidenceError("duplicate-file", "duplicate exported file name")
            seen.add(exported)
            if len(attachments) >= CAPS["attachments"]:
                raise EvidenceError("file-count", "too many attachments")
            attachments.append({"path": path, "entry": entry, "test": test.get("testIdentifier")})
    return attachments


def parse_geometry(data, name):
    try:
        raw = json.loads(data)
    except ValueError:
        raise EvidenceError("geometry-schema", f"geometry for {name} is not JSON")
    if not isinstance(raw, dict) or raw.get("schemaVersion") != 1 or raw.get("kind") != GEOMETRY_KIND:
        raise EvidenceError("geometry-schema", f"geometry for {name} has an unexpected schema")
    geometry = {}
    for key in GEOMETRY_FIELDS:
        value = raw.get(key)
        if key in ("scale", "screenPointWidth", "screenPointHeight"):
            ok = isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and 0 < value < 100000
        elif key in ("imagePixelWidth", "imagePixelHeight"):
            ok = isinstance(value, int) and not isinstance(value, bool) and 0 < value <= CAPS["dimension"]
        else:
            ok = isinstance(value, str) and 0 < len(value) <= 64
        if not ok:
            raise EvidenceError("geometry-schema", f"geometry for {name} has an invalid {key}")
        geometry[key] = value
    if geometry["orientation"] not in ("portrait", "landscape"):
        raise EvidenceError("geometry-schema", f"geometry for {name} has an invalid orientation")
    return geometry


def dims_match(width, height, geometry):
    pair = sorted((width, height))
    return pair == sorted((geometry["imagePixelWidth"], geometry["imagePixelHeight"]))


UUID_PATTERN = r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"


def attachment_name_matches(actual, base, extension):
    """True for exactly `base` or `base` + Xcode's generated `_<digits>_<UUID>` + extension."""
    if actual == base:
        return True
    return re.fullmatch(re.escape(base) + r"_[0-9]+_" + UUID_PATTERN + re.escape(extension), actual,
                        re.ASCII) is not None


def image_name_matches(actual, name):
    return attachment_name_matches(actual, name, ".png")


def geometry_name_matches(actual, name):
    # Xcode inserts its suffix before the custom extension, independently of the JSON file UTI.
    return actual == name + ".geometry" or re.fullmatch(
        re.escape(name) + r"_[0-9]+_" + UUID_PATTERN + r"\.geometry", actual, re.ASCII) is not None


def stream_hash(path, deadline):
    """SHA-256 of a regular file read in bounded chunks; never holds the contents."""
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            deadline.check()
            block = handle.read(CAPS["hash_chunk"])
            if not block:
                return digest.hexdigest()
            digest.update(block)


def classify(attachments, deadline):
    """Split attachments into PNG images and non-images.

    Images are read whole (strictly capped). Non-images are streamed: only size, sniffed type and hash are
    kept, plus the bytes of files small enough to be geometry metadata. Non-images beyond the per-file or
    aggregate hashing caps are recorded metadata-only (hash None, explicit skip reason), never failing evidence.
    """
    images, others, hashed_total, image_total = [], [], 0, 0
    for item in attachments:
        deadline.check()
        try:
            info = os.lstat(item["path"])
        except OSError:
            raise EvidenceError("missing-file", "attachment is missing")
        if not stat.S_ISREG(info.st_mode):
            raise EvidenceError("unsafe-path", "attachment is not a regular file")
        with open(item["path"], "rb") as handle:
            head = handle.read(4096)
        if head.startswith(PNG_SIGNATURE):
            if info.st_size > CAPS["encoded_bytes"]:
                raise EvidenceError("encoded-size", "attachment exceeds the encoded size cap")
            image_total += info.st_size
            if image_total > CAPS["image_input_bytes"]:
                raise EvidenceError("input-bytes", "image attachments exceed the aggregate input cap")
            item["data"] = read_bounded(item["path"], CAPS["encoded_bytes"], "attachment")
            images.append(item)
            if len(images) > CAPS["images"]:
                raise EvidenceError("file-count", "too many image attachments")
            continue
        names = (item["entry"]["exportedFileName"], item["entry"]["suggestedHumanReadableName"])
        if any(os.path.splitext(name)[1].lower() in (".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".tif", ".tiff")
               for name in names) or head.startswith(b"\xff\xd8\xff"):
            raise EvidenceError("unsupported-image", "image attachment is not a supported PNG")
        item["size"], item["type"], item["data"] = info.st_size, sniff_type(head), None
        if info.st_size <= CAPS["geometry_bytes"]:
            item["data"] = read_bounded(item["path"], CAPS["geometry_bytes"], "attachment")
        if info.st_size > CAPS["nonimage_file_bytes"]:
            item["sha256"], item["skipped"] = None, "file-size-cap"
        elif hashed_total + info.st_size > CAPS["nonimage_total_bytes"]:
            item["sha256"], item["skipped"] = None, "aggregate-size-cap"
        else:
            hashed_total += info.st_size
            item["sha256"], item["skipped"] = stream_hash(item["path"], deadline), None
        others.append(item)
    return images, others


def sniff_type(data):
    head = data[:16].lstrip()
    if head[:1] in (b"{", b"["):
        return "json"
    if data[:3] == b"\xff\xd8\xff":
        return "jpeg"
    if data[:4] in (b"RIFF", b"%PDF"):
        return data[:4].decode("latin1").lower()
    try:
        data[:4096].decode("utf-8")
        return "text"
    except UnicodeDecodeError:
        return "binary"


def check_environment(raw):
    if raw is None:
        return {}
    if len(raw.encode()) > CAPS["environment_bytes"]:
        raise EvidenceError("environment", "environment JSON exceeds its size cap")
    try:
        value = json.loads(raw)
    except ValueError:
        raise EvidenceError("environment", "environment is not valid JSON")
    if not isinstance(value, dict) or len(value) > 64:
        raise EvidenceError("environment", "environment must be a small JSON object")
    result = {}
    for key, item in value.items():
        if not re.match(r"^[A-Za-z0-9_.-]{1,64}$", key) or not isinstance(item, (str, int, float, bool)) \
                or isinstance(item, float) and not math.isfinite(item):
            raise EvidenceError("environment", "environment entries must be simple scalars")
        result[key] = clean_text(item, 256) if isinstance(item, str) else item
    return result


def tool_versions(runner):
    versions = {"python": sys.version.split()[0]}
    try:
        Image, features = load_pillow()
        import PIL
        versions.update(pillow=PIL.__version__, libwebp=features.version("webp"))
    except EvidenceError:
        raise
    try:
        out = runner(["xcrun", "xcresulttool", "version"])
        versions["xcresulttool"] = clean_text(out.strip().splitlines()[0]) if out.strip() else None
    except Exception:
        versions["xcresulttool"] = None
    return versions


def run_command(args, timeout=30):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=timeout).stdout


def xcresult_export(bundle, destination, deadline):
    try:
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", bundle,
                        "--output-path", destination], check=True, capture_output=True,
                       timeout=min(CAPS["export_seconds"], deadline.remaining()))
    except subprocess.TimeoutExpired:
        raise EvidenceError("export-timeout", "xcresulttool export timed out")
    except (subprocess.CalledProcessError, OSError):
        raise EvidenceError("export-failed", "xcresulttool export failed")


# ---------------------------------------------------------------- orchestration

def build_evidence(bundle, staging, source, environment, export_fn=xcresult_export, runner=run_command, deadline=None):
    """Populate staging with verified WebP files and manifest.json. Raises EvidenceError on any problem."""
    deadline = deadline or Deadline(CAPS["seconds"])
    load_pillow()
    exported = tempfile.mkdtemp(prefix=".export-", dir=os.path.dirname(os.path.abspath(staging)))
    try:
        export_fn(bundle, exported, deadline)
        deadline.check()
        attachments = collect_attachments(exported)
        images, others = classify(attachments, deadline)

        geometries, required_items = {}, {}
        for name in REQUIRED_NAMES:
            matches = [i for i in images if image_name_matches(i["entry"]["suggestedHumanReadableName"], name)]
            geo_matches = [i for i in attachments
                           if geometry_name_matches(i["entry"]["suggestedHumanReadableName"], name)]
            if len(matches) != 1:
                raise EvidenceError("required-missing" if not matches else "required-duplicate",
                                    f"required screenshot '{name}' found {len(matches)} times")
            if len(geo_matches) != 1:
                raise EvidenceError("required-missing" if not geo_matches else "required-duplicate",
                                    f"geometry for '{name}' found {len(geo_matches)} times")
            if geo_matches[0] in images:
                raise EvidenceError("geometry-schema", f"geometry for {name} is an image")
            geo_data = geo_matches[0]["data"]
            if geo_data is None:
                raise EvidenceError("geometry-schema", f"geometry for {name} is too large")
            geometries[name] = parse_geometry(geo_data, name)
            if geo_matches[0]["entry"]["deviceId"] != matches[0]["entry"]["deviceId"]:
                raise EvidenceError("geometry-device", f"geometry for {name} is from another device")
            required_items[id(matches[0])] = name

        # Observed scale per device, only where every observation agrees.
        scales = {}
        for name, item in ((n, next(i for i in images if id(i) in required_items and required_items[id(i)] == n))
                           for n in REQUIRED_NAMES):
            scales.setdefault(item["entry"]["deviceId"], set()).add(geometries[name]["scale"])

        records, total, version_info = [], 0, tool_versions(runner)
        for index, item in enumerate(sorted(images, key=lambda i: i["entry"]["suggestedHumanReadableName"] + i["entry"]["exportedFileName"])):
            deadline.check()
            data, entry = item["data"], item["entry"]
            info = inspect_png(data)
            name = required_items.get(id(item))
            record = {"index": index, "required_name": name, "source_png_sha256": sha256(data),
                      "attachment_name": clean_text(entry["suggestedHumanReadableName"]),
                      "test_identifier": clean_text(item["test"]),
                      "source_png_bytes": len(data), "pixel_width": info["width"], "pixel_height": info["height"],
                      "has_alpha": info["has_alpha"], "color_policy": info["policy"],
                      "icc_sha256": sha256(info["icc"]) if info["icc"] else None,
                      "device_id": clean_text(entry["deviceId"]), "device_name": clean_text(entry.get("deviceName")),
                      "configuration": clean_text(entry.get("configurationName")),
                      "associated_with_failure": bool(entry.get("isAssociatedWithFailure")),
                      "timestamp": entry.get("timestamp") if isinstance(entry.get("timestamp"), (int, float)) else None,
                      "original_disposition": "retained-only-in-xcresult"}
            if name:
                geometry = geometries[name]
                if not dims_match(info["width"], info["height"], geometry):
                    raise EvidenceError("geometry-mismatch", f"geometry for {name} does not match the image")
                record.update(display_scale=geometry["scale"], display_scale_source="observed", geometry=geometry)
            else:
                device_scales = scales.get(entry["deviceId"], set())
                # Element screenshots can be cropped; the observed display scale is still device-wide.
                if len(device_scales) == 1:
                    record.update(display_scale=next(iter(device_scales)),
                                  display_scale_source="inferred-from-same-device-required-geometry")
                else:
                    record.update(display_scale=None, display_scale_source="unknown")
            output_name = f"{index:03d}-{record['source_png_sha256'][:16]}.webp"
            record["file"] = output_name
            destination = os.path.join(staging, output_name)
            record.update(webp_sha256=None)
            result = convert_to_lossless_webp(data, info, destination)
            total += result["bytes"]
            if total > CAPS["output_bytes"]:
                raise EvidenceError("output-bytes", "verified output exceeds the byte cap")
            record.update(webp_sha256=result["sha256"], webp_bytes=result["bytes"], verified_lossless_exact=True)
            os.remove(item["path"])  # the verified WebP replaces the exported PNG
            item["data"] = None
            records.append(record)

        non_images = [{"index": i, "sha256": o["sha256"], "bytes": o["size"], "type": o["type"], "hash_skipped": o["skipped"],
                       "published": False} for i, o in enumerate(others)]
        manifest = {"schemaVersion": SCHEMA_VERSION, "status": "complete", "source": source,
                    "required_names": REQUIRED_NAMES, "images": records, "non_image_attachments": non_images,
                    "toolchain": version_info, "environment": environment,
                    "webp_options": {"lossless": True, "exact": True, "method": 6, "icc": "retained exact bytes"},
                    "total_webp_bytes": total}
        with open(os.path.join(staging, "manifest.json"), "w") as handle:
            json.dump(manifest, handle, indent=2, sort_keys=True)  # completion marker, written last
    finally:
        shutil.rmtree(exported, ignore_errors=True)


def publish(output, source, environment_raw, bundle, **kwargs):
    """Stage and atomically promote. Returns True on success; failure.json is published on failure."""
    output = os.path.abspath(output)
    parent = os.path.dirname(output)
    os.makedirs(parent, exist_ok=True)
    if os.path.lexists(output):
        raise EvidenceError("output-exists", "output path already exists")
    staging = tempfile.mkdtemp(prefix=".staging-", dir=parent)
    try:
        build_evidence(bundle, staging, source, check_environment(environment_raw), **kwargs)
        os.rename(staging, output)
        return True
    except BaseException as error:
        shutil.rmtree(staging, ignore_errors=True)
        if isinstance(error, EvidenceError):
            code, message = error.code, error.message[:CAPS["text"]]
        else:
            code, message = "internal-error", type(error).__name__
        failure = tempfile.mkdtemp(prefix=".failure-", dir=parent)
        with open(os.path.join(failure, "failure.json"), "w") as handle:
            json.dump({"schemaVersion": SCHEMA_VERSION, "status": "failed", "source": source,
                       "code": code, "message": message}, handle, indent=2, sort_keys=True)
        os.rename(failure, output)
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise
        return False


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--result-bundle", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--environment", help="JSON object (inline or a path to a JSON file)")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[0-9a-f]{40}", args.source):
        parser.error("--source must be a 40-character lowercase git SHA")
    environment = args.environment
    if environment is not None and not environment.lstrip().startswith("{"):
        try:
            environment = read_bounded(environment, CAPS["environment_bytes"], "environment file").decode()
        except (EvidenceError, UnicodeDecodeError) as error:
            parser.error(f"unreadable --environment: {getattr(error, 'message', 'invalid text')}")
    try:
        ok = publish(args.output, args.source, environment, args.result_bundle)
    except EvidenceError as error:
        print(f"error: {error.message}", file=sys.stderr)
        return 1
    if not ok:
        print("error: UI evidence export failed; see failure.json", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
