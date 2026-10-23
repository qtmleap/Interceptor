// Shared byte vectors from the SDK icon contract fixture; entropy is intentionally opaque.
let pluginIconVectorJSON = #"""
[
 {
  "name": "png-1x1",
  "format": "png",
  "path": "icon.png",
  "base64": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAEElEQVR4AQEFAPr/AAAAAAAABQABZHiVOAAAAABJRU5ErkJggg==",
  "expectedValid": true,
  "width": 1,
  "height": 1
 },
 {
  "name": "png-1024x1024",
  "format": "png",
  "path": "icon.png",
  "base64": "iVBORw0KGgoAAAANSUhEUgAABAAAAAQACAYAAAB/HSuDAAAAEElEQVR4AQEFAPr/AAAAAAAABQABZHiVOAAAAABJRU5ErkJggg==",
  "expectedValid": true,
  "width": 1024,
  "height": 1024
 },
 {
  "name": "webp-1x1",
  "format": "webp",
  "path": "icon.webp",
  "base64": "UklGRhIAAABXRUJQVlA4TAUAAAAvAAAAAAA=",
  "expectedValid": true,
  "width": 1,
  "height": 1
 },
 {
  "name": "webp-1024x1024",
  "format": "webp",
  "path": "icon.webp",
  "base64": "UklGRhIAAABXRUJQVlA4TAUAAAAv/8P/AAA=",
  "expectedValid": true,
  "width": 1024,
  "height": 1024
 },
 {
  "name": "png-width-1025",
  "format": "png",
  "path": "icon.png",
  "base64": "iVBORw0KGgoAAAANSUhEUgAABAEAAAABCAYAAACvzLcLAAAAEElEQVR4AQEFAPr/AAAAAAAABQABZHiVOAAAAABJRU5ErkJggg==",
  "expectedValid": false,
  "width": 1025,
  "height": 1
 },
 {
  "name": "png-bad-crc",
  "format": "png",
  "path": "icon.png",
  "base64": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAeFcSJAAAAEElEQVR4AQEFAPr/AAAAAAAABQABZHiVOAAAAABJRU5ErkJggg==",
  "expectedValid": false,
  "width": 1,
  "height": 1
 },
 {
  "name": "png-truncated",
  "format": "png",
  "path": "icon.png",
  "base64": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAEElEQVR4AQEFAPr/AAAAAAAABQABZHiVOAAAAABJRU5E",
  "expectedValid": false,
  "width": 1,
  "height": 1
 },
 {
  "name": "webp-height-1025",
  "format": "webp",
  "path": "icon.webp",
  "base64": "UklGRhIAAABXRUJQVlA4TAUAAAAvAAAAAQA=",
  "expectedValid": false,
  "width": 1,
  "height": 1025
 },
 {
  "name": "webp-animated",
  "format": "webp",
  "path": "icon.webp",
  "base64": "UklGRiQAAABXRUJQVlA4WAoAAAACAAAAAAAAAAAAVlA4TAUAAAAvAAAAAAA=",
  "expectedValid": false,
  "width": 1,
  "height": 1
 },
 {
  "name": "webp-wrong-magic",
  "format": "webp",
  "path": "icon.webp",
  "base64": "UklGWBIAAABXRUJQVlA4TAUAAAAvAAAAAAA=",
  "expectedValid": false,
  "width": 1,
  "height": 1
 }
]

"""#
