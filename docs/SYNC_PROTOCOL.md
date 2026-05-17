# SyncClipboard Wire Protocol

This document specifies the on-the-wire protocol and persisted-data formats used
by the Flutter Android client to talk to a [SyncClipboard](https://github.com/Jeric-X/SyncClipboard)
server. It is the **authoritative reference for any new client implementation**
(SwiftUI / iOS, Web, etc.). It is derived from, and must be kept in sync with,
the Flutter implementation under `lib/dio/`, `lib/service/`, `lib/utils/` and
`lib/model/`.

If the code and this document disagree, the code wins until this document is
updated to match — the only acceptable resolution is to update this document.

Worked examples are checked in under [`examples/`](./examples/). They double
as round-trip test fixtures for any new client implementation.

---

## 1. Transport

| Concern | Value |
|---|---|
| Protocol | HTTP/1.1 or HTTP/2 over TCP, optionally TLS |
| Methods | `GET`, `PUT` |
| Authentication | HTTP Basic (`Authorization: Basic <base64(username + ":" + password)>`) on **every** request |
| TLS | Both `http://` and `https://` schemes are accepted. The client MAY offer a "trust insecure cert" toggle that disables certificate validation entirely (development/LAN only). |
| Connect timeout | 5 s |
| Send timeout | 10 min (large file uploads) |
| Receive timeout | 5 min (large file downloads) |
| Status codes treated as success | `200`, `201`, `204` |
| Status code treated as auth failure | `401` |
| Status code treated as not-found | `404` |
| Other `< 500` | Surface as a generic protocol error (do not retry automatically) |
| `>= 500` | Surface as transport error (the Flutter client uses `validateStatus: status < 500`, so dio raises) |

### 1.1 Base URL normalization

Before issuing requests the client MUST normalize the configured server URL:

1. Trim leading/trailing whitespace.
2. If the result does not end in `/`, append `/`.

All endpoint paths in §2 are relative paths joined onto this base URL.

### 1.2 Authorization header

```
Authorization: Basic <base64(utf8(username + ":" + password))>
```

The header is added to every request via an interceptor. There is no token
exchange, no session, and no refresh.

---

## 2. Endpoints

There are exactly three logical resources. The server is a thin WebDAV-style
key/value store.

### 2.1 `GET SyncClipboard.json` — pull current clipboard state

Retrieves the JSON describing the most recently synced clipboard entry.

- **Method:** `GET`
- **Path:** `SyncClipboard.json`
- **Request body:** none
- **Response headers:** `Content-Type` SHOULD be `application/json` but the
  client also accepts a string body and parses it as JSON.
- **Response body:** see §3 (Clipboard JSON schema)
- **Status codes:**
  - `200 OK` — body is the Clipboard JSON
  - `401 Unauthorized` — credentials wrong
  - `404 Not Found` — no clipboard has ever been published yet
  - other — error

### 2.2 `PUT SyncClipboard.json` — publish clipboard state

Publishes a new clipboard entry. If the entry has an associated payload file,
that file MUST be uploaded **first** (§2.3) before `PUT SyncClipboard.json` is
called, otherwise other clients will see a metadata pointer to a file that does
not yet exist on the server.

- **Method:** `PUT`
- **Path:** `SyncClipboard.json`
- **Request `Content-Type`:** `application/json`
- **Request body:** Clipboard JSON (§3)
- **Response body:** ignored
- **Status codes:**
  - `200 OK` / `201 Created` / `204 No Content` — success
  - `401` — auth failure
  - other — error

### 2.3 `PUT file/<filename>` — upload payload file

Uploads the binary payload referred to by a Clipboard JSON whose `hasData` is
`true`. Used for images, generic files, large-text overflow, and group ZIPs.

- **Method:** `PUT`
- **Path:** `file/<filename>` where `<filename>` is exactly the value of
  `Clipboard.dataName` (§3.2). It MUST NOT contain path separators.
- **Request `Content-Type`:** `application/octet-stream`
- **Request `Content-Length`:** the byte length of the body
- **Request body:** raw bytes of the file
- **Status codes:** as in §2.2

### 2.4 `GET file/<filename>` — download payload file

- **Method:** `GET`
- **Path:** `file/<filename>` (the value of `Clipboard.dataName` from the most
  recent `GET SyncClipboard.json`)
- **Response body:** raw bytes
- **Status codes:**
  - `200` — bytes
  - `401` — auth failure
  - `404` — payload missing (this is a server inconsistency: metadata says
    `hasData=true` but the file is absent — surface as an error)

---

## 3. Clipboard JSON schema

The Clipboard JSON is the heart of the protocol. It describes exactly one
clipboard "snapshot": its kind, an optional content hash for de-duplication, a
short preview text, and an optional payload file.

### 3.1 Schema

```jsonc
{
  "type":     "Text" | "Image" | "File" | "Group",   // required
  "hash":     "SHA256-UPPER-HEX-STRING" | null,      // optional, see §4
  "text":     "string",                              // required, see §3.2
  "hasData":  true | false,                          // required
  "dataName": "string",                              // present iff hasData=true
  "size":     1234                                   // optional, see §3.2
}
```

#### JSON encoding rules

- `null` for `hash`, `dataName`, or `size` fields MUST be **omitted entirely**
  rather than serialized as `null`. (Flutter uses `includeIfNull: false`.)
- `hash`: when non-null, MUST be uppercase hexadecimal SHA-256. When parsing,
  empty string and pure whitespace MUST be normalized to `null`.
- All string fields are UTF-8.

### 3.2 Field semantics

| Field | Meaning |
|---|---|
| `type` | One of the four enum values from §3.3. Determines how the payload (if any) is to be interpreted. |
| `hash` | Content fingerprint used by all clients to detect "same content as last time" and skip re-applying. Computed per §4. May be omitted/`null` if the publisher chose not to compute one (e.g. legacy data). |
| `text` | For `Text` type: the clipboard text (or a preview prefix if too long, see §3.4). For `Image`/`File`/`Group`: a human-readable label, typically `basename(dataName)`. NEVER the full payload for non-text types. |
| `hasData` | `true` ⇔ a companion file exists at `file/<dataName>`. `false` ⇔ everything is in `text`. |
| `dataName` | Required when `hasData=true`. The exact filename to use under `file/<…>`. MUST NOT contain `/` or `\`. |
| `size` | Optional descriptive size. For `Text`: the **character count** of the original text (not byte length). For `Image`/`File`: the **byte length** of the payload. For `Group`: byte length of the ZIP. May be omitted if unknown. |

### 3.3 `type` enum

The type is serialized as a capitalized string:

| Wire value | Semantics |
|---|---|
| `"Text"` | Plain UTF-8 text. Payload (if `hasData=true`) is the full text as UTF-8 bytes; `text` then holds a preview prefix only (§3.4). |
| `"Image"` | Single image. `dataName` carries the filename with extension (`png`, `jpg`, `gif`, `webp`, `bmp`, `tiff`, `heic`, `heif`). |
| `"File"` | Single arbitrary file. `dataName` carries the original filename. |
| `"Group"` | Multiple files packaged as a ZIP archive. `dataName` is the ZIP filename. The current Flutter client only **reads** Group entries (downloads + verifies hash); it does not currently produce them. |

### 3.4 Long-text overflow rule

Implementations MUST apply the following rule when uploading text:

```
threshold = 10240    // characters (NOT bytes)

if text.length > threshold:
    preview     = text[0:threshold]              // first 10240 chars
    payloadName = "text_<HASH>.txt"              // <HASH> = computeTextHash(text), §4.1
    payloadBody = utf8(text)                     // FULL text, UTF-8 encoded
    => upload PUT file/<payloadName>             // §2.3
    => publish: { type: "Text", hash: <HASH>, text: preview, hasData: true,
                  dataName: payloadName, size: text.length }
else:
    => publish: { type: "Text", hash: <HASH>, text: text, hasData: false,
                  size: text.length }
```

When downloading, an implementation that sees `type=Text`, `hasData=true` SHOULD
fetch `file/<dataName>` and decode as UTF-8 to recover the full text. The
`text` field alone is only a preview in that case.

### 3.5 Upload sequencing

For an entry with `hasData=true`:

1. `PUT file/<dataName>` with the payload bytes.
2. `PUT SyncClipboard.json` with the metadata.

If step 1 fails, step 2 MUST NOT be attempted. There is no transaction; an
implementation that crashes between (1) and (2) leaves an orphan file on the
server, which is harmless (it will be overwritten on next publish).

---

## 4. Hash computation

All hashes are **SHA-256, lowercase hex transformed to uppercase** (i.e. the
canonical hex digest, then `.toUpperCase()`).

### 4.1 Text hash

```
computeTextHash(text: string) -> string:
    return SHA256(utf8(text)).hex.upper
```

### 4.2 File / image hash

The hash binds **both** the filename basename and the bytes, so renaming a file
without changing its content produces a different hash:

```
computeFileHash(filename: string, bytes: bytes) -> string:
    contentHash = SHA256(bytes).hex.upper
    combined    = basename(filename) + "|" + contentHash
    return SHA256(utf8(combined)).hex.upper
```

`basename(filename)` MUST strip any path components and keep the final segment,
extension included.

### 4.3 Group (ZIP) hash

Used to verify a downloaded `Group` ZIP against the server-supplied hash. The
hash is computed over a deterministic textual manifest of the archive, so
implementations MUST agree on byte-perfect output.

#### Algorithm

1. Walk every entry in the archive. Normalize each entry name by replacing
   every `\` with `/`.
2. Maintain a set `entries` of normalized names.
3. For each entry:
   - **File entry:** add the normalized name to `entries`. Remember the bytes.
   - **Directory entry:** ensure the name ends with `/`; add to `entries`.
4. For every entry name added in (3), also synthesize its parent directory
   names (each trailing-slash form, e.g. `a/b/` from `a/b/c.txt`) and add them
   to `entries`.
5. Sort `entries` by **UTF-8 byte order** (not by Unicode code point — strings
   must be encoded to UTF-8 first and compared byte by byte; the Flutter
   implementation calls this `_compareByUtf8Bytes`).
6. Build a manifest string by iterating sorted entries and appending one record
   per entry, terminated by a single NUL byte (`\x00`):
   - Directory: `D|<name>` where `<name>` ends in `/`
   - File:     `F|<name>|<sizeBytes>|<contentHashUpper>` where `<contentHashUpper> = SHA256(bytes).hex.upper`
7. Final hash = `SHA256(utf8(manifest)).hex.upper`.

#### Pseudocode

```
def computeGroupHashFromArchive(archive):
    names = set()
    files = {}
    for entry in archive:
        name = entry.name.replace("\\", "/")
        if entry.is_file:
            names.add(name); files[name] = entry
            add_parents(names, name)
        else:
            if not name.endswith("/"): name += "/"
            names.add(name)
            add_parents(names, name)

    sorted_names = sorted(names, key=lambda s: s.encode("utf-8"))   # byte-wise

    buf = bytearray()
    for name in sorted_names:
        if name.endswith("/"):
            buf += f"D|{name}".encode("utf-8")
        else:
            entry = files[name]
            content_hash = sha256(entry.bytes).hexdigest().upper()
            buf += f"F|{name}|{len(entry.bytes)}|{content_hash}".encode("utf-8")
        buf += b"\x00"
    return sha256(buf).hexdigest().upper()
```

`add_parents(names, name)` for `a/b/c.txt` adds `a/`, `a/b/`. For `a/b/`
it adds `a/`. Empty path components are skipped.

### 4.4 Hash comparison

When an implementation needs to compare two hashes (e.g. local content vs
server-supplied):

```
hashMatches(expected, actual):
    if expected is null or whitespace-only: return true   // no expectation
    return expected.trim().toUpperCase() == actual.toUpperCase()
```

A `null`/empty `expected` MUST be treated as "match anything" — this is what
allows publishers to omit hashes for data they cannot fingerprint.

---

## 5. Multi-server configuration & auto-switch (client-only)

This section is **not** part of the wire protocol — it describes data the
client persists locally to manage multiple servers and automatic profile
switching. iOS implementations should be able to import/export a config file
following the same JSON shape so users can migrate between platforms.

### 5.1 `ServerConfig`

```jsonc
{
  "id":                   "uuid-v4-string",   // required
  "name":                 "string | null",    // optional, user-chosen label
  "url":                  "https://...",      // required, raw (not normalized)
  "username":             "string",           // required
  "password":             "string",           // required
  "autoSwitchWifiNames":  ["SSID-1", "SSID-2"]  // default: []
}
```

- `id`: stable UUID v4. Two configs with the same `id` are the same config.
- `name`: human-readable label. If null/empty, the UI falls back to `url`.
- `autoSwitchWifiNames`: when the device is connected to one of these SSIDs,
  the client SHOULD activate this config automatically (§5.3).

#### SSID normalization rule

Both stored SSIDs and the system-reported current SSID MUST be normalized
identically before comparison:

1. Trim whitespace.
2. If empty after trim → treat as "no SSID".
3. If wrapped in matching ASCII double quotes (`"foo"`), strip them and trim
   the inner string. (Some platforms — notably Android — return SSIDs wrapped
   in quotes.)
4. Reject the magic strings `<unknown ssid>` and `0x` (Android privacy
   placeholders): treat as "no SSID".

### 5.2 `ServerConfigList`

```jsonc
{
  "configs":         [ ServerConfig, ... ],   // default: []
  "activeConfigId":  "uuid-v4-string | null"
}
```

If `activeConfigId` is set but no config in `configs` has that id, the client
falls back to `configs[0]`. If `configs` is empty, there is no active config
and the client MUST refuse to make network calls.

### 5.3 Auto-switch resolution algorithm

```
def getActiveConfig(list, currentSsid):
    if list.configs is empty: return None
    default_cfg = first config whose id == list.activeConfigId,
                  else list.configs[0]

    if currentSsid is None:                    # WiFi unknown / off / no perm
        return default_cfg

    # Prefer a non-default config that matches the SSID
    for cfg in list.configs:
        if cfg.id == default_cfg.id: continue
        if cfg.matchesWifiName(currentSsid): return cfg

    # Otherwise, the default wins (whether or not it matches the SSID)
    return default_cfg
```

`cfg.matchesWifiName(ssid)` returns `true` iff the normalized `ssid` is
contained in the normalized `cfg.autoSwitchWifiNames`.

### 5.4 `AppSettings`

```jsonc
{
  "trustInsecureCert":        false,    // disable TLS cert validation
  "autoCheckUpdate":          true,     // check for app update on launch
  "manualUploadDialogShown":  false,    // user dismissed first-run hint
  "downloadRelativePath":     "",       // subdirectory under the platform Downloads dir
  "logViewLevelFilter":       "info",   // last-used log level filter
  "ignoredVersion":           null      // version string the user chose to skip
}
```

- All fields have defaults (shown). A missing key MUST be filled with its
  default; the file MUST still parse if extra unknown keys are present
  (forward compatibility).

### 5.5 Persistence keys

The Flutter client uses Android `SharedPreferences` (a `String → String` KV
store). For an iOS port using `UserDefaults`, the same keys SHOULD be reused so
that an export-from-Android / import-to-iOS round trip is straightforward.

| Key | Value (UTF-8 string) |
|---|---|
| `server_config_list` | `serverConfigListToJson(...)` (§5.2) |
| `app_settings` | `appSettingsToJson(...)` (§5.4) |
| `server_config` | **legacy**, single-config format. If `server_config_list` is absent and `server_config` is present, the client MUST migrate: wrap the legacy single config into a `ServerConfigList` (allocate a fresh UUID, set it as active), write the new key, delete the old key. |

Legacy `server_config` shape (read-only, write-once-on-migrate):

```jsonc
{ "url": "...", "username": "...", "password": "..." }
```

### 5.6 QR-code import payload (UniClipboard extension)

UniClipboard supports importing a server configuration by scanning a QR
code from the **Settings → Servers → Add → "从二维码填充"** flow. This is
a UniClipboard-only convention; upstream SyncClipboard has no QR format
and other clients are not required to interoperate with it.

A scanned barcode is decoded as a UTF-8 string and dispatched, in
priority order:

1. **JSON object** (preferred — can carry an alias)
2. **URL with userinfo** (fallback — fits any QR generator)

Anything else fails parsing and surfaces an inline alert; the scanner
keeps running so the user can try another code.

#### Format 1: JSON object

```jsonc
{
  "url":      "https://clip.home.lan:5033/",   // required, non-empty
  "username": "alice",                          // required, non-empty
  "password": "p4ssw0rd!",                      // required, non-empty
  "name":     "Home NAS"                        // optional
}
```

Rules:

- `url`, `username`, `password` are required and MUST be non-empty
  strings. A payload missing any of them, or with empty-string values,
  is rejected.
- `name` is optional. When absent, the consumer falls back to a
  generated alias (see [`ServerNameGenerator`](../UniClipboard/Models/ServerNameGenerator.swift)).
- Unknown keys are tolerated and ignored. A future revision can add
  fields (e.g. an explicit `trustInsecureCert` hint) without breaking
  older scanners.
- A `type` discriminator field is NOT required. If a future version
  introduces one, scanners SHOULD still accept payloads without it.

#### Format 2: URL with userinfo

```
https://alice:p4ssw0rd!@clip.home.lan:5033/
```

Rules:

- The URL MUST parse as a valid `URL` and carry both a `user` and a
  `password` component. Missing either component rejects the payload.
- The reconstructed `url` field (passed to the Add form) is the URL
  **without** the userinfo segment — i.e. `https://clip.home.lan:5033/`.
- `name` is always nil for this format (URL syntax has no slot for it).
- Special characters in user/password MUST be percent-encoded by the
  generator. The scanner percent-decodes both before assigning to the
  draft.

#### Receiver behavior

After a successful parse, the scanner:

1. Dismisses the camera cover.
2. Opens the Add Server sheet pre-filled with the payload's fields.
3. Leaves `trustInsecureCert` at the app-wide default — the QR format
   does not carry it deliberately, so the user can confirm.
4. Leaves the autoSwitch SSID list empty — auto-switch is per-device
   network state, not a portable identity, and shouldn't be cloned.

The user can edit any field before tapping **保存**, and **测试连接**
runs against the in-form draft using the shared `ConnectionTester`.

#### Worked examples

See [`examples/server_qr_payload.json`](./examples/server_qr_payload.json)
and [`examples/server_qr_payload_url.txt`](./examples/server_qr_payload_url.txt).

---

## 6. Error model

Implementations SHOULD surface errors with at minimum:

- a `statusCode` (when the error is HTTP-related, otherwise null),
- a localized human message,
- the underlying exception for debugging/log.

Recommended message mapping (mirrors `_handleDioException` in
`lib/dio/sync_clipboard_client.dart`):

| Condition | Message (suggested) |
|---|---|
| Connect timeout | "Connection timed out — check the server URL" |
| Receive timeout | "Receive timed out" |
| TLS handshake / connection refused / DNS failure | "Cannot reach server — check network and URL" |
| HTTP 401 | "Authentication failed — username or password wrong" |
| HTTP 404 on `SyncClipboard.json` | "No clipboard published yet" |
| HTTP 404 on `file/<name>` | "Payload `<name>` not found on server" |
| Other `4xx` | "Server returned HTTP `<code>`" |
| Other `5xx` | "Server error `<code>`" |

Authentication failures (`401`) MUST NOT trigger automatic retries.

---

## 7. Client implementation checklist (SwiftUI port)

Use this list when porting to iOS. Each item maps directly to a section above.

- [ ] HTTP client with Basic Auth interceptor on every request (§1.2)
- [ ] Per-request `Content-Type` discipline: `application/json` for the JSON
      endpoint, `application/octet-stream` for file uploads (§2.2, §2.3)
- [ ] Trust-insecure-cert toggle wired to `URLSessionDelegate`
      `urlSession(_:didReceive:completionHandler:)` (§1)
- [ ] Base URL normalization (trailing slash) (§1.1)
- [ ] `Codable` types for `Clipboard`, `ServerConfig`, `ServerConfigList`,
      `AppSettings` matching §3.1, §5.1, §5.2, §5.4
- [ ] `JSONEncoder` configured to **omit `nil`** for `hash`, `dataName`, `size`
      (Swift default already does this for optionals; just don't set
      `nilEncodingStrategy = .null`) (§3.1)
- [ ] `type` enum encoded as `"Text" | "Image" | "File" | "Group"` (§3.3) —
      use raw-value enum
- [ ] `CryptoKit.SHA256` for all hashes; manual `.uppercased()` (§4)
- [ ] Long-text threshold = `10240` **characters**, not bytes (§3.4) — be
      careful with `String.count` vs UTF-8 byte length
- [ ] Group hash: walk archive, synthesize parent dirs, sort by UTF-8 bytes
      (§4.3). Use ZIPFoundation; iterate `Archive` entries; encode manifest as
      `Data`; remember `\x00` between records.
- [ ] SSID normalization parity (strip outer `"…"`, reject `<unknown ssid>`
      and `0x`) (§5.1) — required for cross-platform config import to behave
      identically.
- [ ] WiFi auto-switch resolver (§5.3) using `NEHotspotNetwork.fetchCurrent`
      (requires Access WiFi Information entitlement). When the entitlement is
      not granted, treat current SSID as `nil` — this is the documented
      degenerate path and just falls back to the active config.
- [ ] Persistence under `UserDefaults`, keys per §5.5; if you also need to
      share with a Share Extension, use an App Group `UserDefaults(suiteName:)`
      and use the **same keys** inside the suite.
- [ ] Legacy `server_config` migration if you ship an Android→iOS export
      flow (§5.5).
