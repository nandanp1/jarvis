# Smart Home and Google Home Compatibility

Jarvis performs smart-home actions through Home Assistant. This gives a macOS
11 app a stable, local-network HTTP(S)/REST boundary while keeping Gemini and
the voice UI independent of any one device vendor.

## What “Google Home compatible” means

Google's current Home APIs do not provide Jarvis with a supported native macOS
11 control SDK. Google's Swift Home APIs package targets iOS (currently iOS 17+
with Xcode 15.3+), not a Big Sur AppKit process. Jarvis therefore uses this
working path:

```text
Jarvis -> Home Assistant REST API -> Home Assistant integration -> device
```

The device may also appear in Google Home, but Google Home is not itself a
general device-import API for Home Assistant. A device merely appearing in the
Google Home app does **not** automatically make it controllable by Jarvis.

At least one of these paths must expose the device to Home Assistant:

- Add the manufacturer's Home Assistant integration.
- Add the device directly with a local protocol supported by Home Assistant.
- For compatible Matter devices, use multi-admin commissioning so Home
  Assistant and Google Home are both fabrics/controllers.
- Use an appropriate official integration for supported Google/Nest products.
- Expose Home Assistant entities *to* Google Assistant when desired. Note that
  this direction does not import arbitrary Google Home entities into Home
  Assistant.

Once an entity is visible and controllable in Home Assistant, Jarvis can
discover and act on it. Jarvis must not report a generic “Google connected”
state unless this end-to-end path has been tested.

## Home Assistant setup

1. Install and update Home Assistant on a machine reachable from the Mac.
2. Add the integrations for the room's devices.
3. In Home Assistant, verify each entity can be controlled from its dashboard.
4. Create a long-lived access token from the Home Assistant user profile.
5. In **Jarvis Settings > Smart Home**, enter:

   ```text
   Home Assistant URL:          http://homeassistant.local:8123
   Home Assistant Access Token: <long-lived access token>
   ```

6. Select **Test Connection**, then refresh connected devices.

The URL is stored as a non-secret preference. The token is stored only in the
macOS Keychain. HTTPS is strongly recommended whenever traffic leaves a trusted
local network; plain HTTP exposes the bearer token to anyone able to observe
that network.

Home Assistant's `.local` name depends on multicast DNS. If it does not resolve,
use a stable LAN hostname or reserved IP address. Jarvis should not continuously
retry a bad address.

## Transport contract

`HomeAssistantService` uses `URLSession` and Home Assistant's REST API. Requests
carry the token in an HTTP header:

```text
Authorization: Bearer <token from Keychain>
Content-Type: application/json
```

The header and token are always redacted from logs. The core endpoints are:

| Purpose | Method and path |
| --- | --- |
| Connection check | `GET /api/` |
| Entity discovery | `GET /api/states` |
| One entity's state | `GET /api/states/<entity_id>` |
| Execute service | `POST /api/services/<domain>/<service>` |

A successful HTTP response is not always enough to prove the intended state.
For state-changing commands, the provider parses Home Assistant's returned
state and, when needed, reads the entity again before reporting success.
Timeouts, non-2xx responses, malformed JSON, and authentication failures are
typed errors.

## Device model

Home Assistant entity IDs are transport identifiers, not names people should
have to speak. Discovery maps an entity and its attributes to `SmartDevice`:

```swift
struct SmartDevice {
    let id: String
    let name: String
    let room: String?
    let type: DeviceType
    let capabilities: Set<DeviceCapability>
}
```

The friendly name comes from `friendly_name` when available. Area/room metadata
is retained when the API supplies it or when the user adds a local alias. The
raw entity ID remains stable for tool execution.

Supported domains and expected operations are:

| Home Assistant domain | Operations |
| --- | --- |
| `light` | on, off, brightness, RGB/HS color, color temperature |
| `switch` | on, off |
| `fan` | on, off, percentage/preset when advertised |
| `climate` | target temperature, supported HVAC modes, current state |
| `scene` | activate |
| `script` | run |
| `media_player` | on/off, play/pause, volume when advertised |
| `cover` | open, close, stop, position when advertised |

Capabilities come from attributes and supported-feature flags. Jarvis does not
offer a brightness or color tool for a light that does not advertise that
capability.

Common service payloads look like this:

```json
{
  "entity_id": "light.bedroom_ceiling"
}
```

```json
{
  "entity_id": "light.desk_lamp",
  "brightness_pct": 25
}
```

```json
{
  "entity_id": "light.led_strip",
  "rgb_color": [0, 80, 255]
}
```

No real hostnames, tokens, or personal device inventories belong in committed
fixtures.

## Natural device references

Resolution is deterministic and happens before execution. The resolver
normalizes case and punctuation, considers friendly names, entity IDs, room,
type, and configured aliases, and then ranks exact matches above token matches.

For example:

```text
entity_id:     light.nandan_bedroom_ceiling_01
friendly_name: Bedroom Ceiling
room:          Bedroom
aliases:       ceiling light
```

may match “turn off my ceiling light” or “turn off the bedroom ceiling.” If two
devices remain equally plausible, Jarvis asks for clarification. It must never
silently choose a security-sensitive device.

“All” commands first resolve a bounded device set, such as all lights in the
bedroom, then execute and report per-device outcomes. Partial success is not
summarized as complete success.

## Gemini tools

Gemini sees a small typed tool surface rather than raw Home Assistant URLs:

```text
list_home_devices
get_device_state
turn_on_device
turn_off_device
set_light_brightness
set_light_color
set_temperature
activate_scene
run_home_script
```

The tool router validates identifiers, ranges, supported capabilities, and
confirmation state. Brightness is accepted as 0–100 percent; colors are
normalized before producing a provider command; temperatures preserve the Home
Assistant unit system.

A multi-action request is one assistant turn with multiple tool results:

```text
User: Turn off the desk light, turn on the fan, and tell me the weather.

1. resolve desk light
2. execute turn-off and capture result
3. resolve fan
4. execute turn-on and capture result
5. obtain the informational answer
6. give Gemini all outcomes for one concise spoken response
```

Execution may be parallel only when actions are independent. Routine order is
preserved when one step depends on another.

## Sensitive actions

Locks, garage doors, alarm/security controls, and equivalent operations require
an explicit confirmation. The pending confirmation stores a typed, short-lived
command—not an arbitrary model string—and expires on timeout, cancellation, or
an unrelated request.

```text
User:   Unlock the front door.
Jarvis: Are you sure you want me to unlock the front door?
User:   Yes.
Jarvis: [executes the stored command, checks its result, then responds]
```

A plain “yes” with no live pending command performs nothing.

## Local fallback

The local parser intentionally handles a narrow set of unambiguous phrases:

```text
turn <device or room device> on
turn <device or room device> off
turn all lights off
set <light> to <0...100> percent
turn <fan> on|off
activate <routine or scene>
```

This path does not require Gemini. It still requires speech transcription and a
reachable Home Assistant server. A local-network Home Assistant call can work
when the public internet is unavailable.

## Routines

Routines expand a stable name such as `Goodnight` into typed steps. A routine
may include home commands, safe Mac commands, scene/script activation, and a
final spoken phrase. Device IDs are validated against discovery when the
routine runs, because entities can be renamed or removed.

Recommended behavior on partial failure:

1. Continue independent, non-sensitive cleanup steps when safe.
2. Stop dependent steps after their prerequisite fails.
3. Report which actions failed without exposing response bodies or tokens.
4. Never say the full routine completed when it did not.

## End-to-end verification

Use non-security-critical room devices for initial testing. Observe both the
physical device and its Home Assistant entity after each request:

```text
Turn my bedroom light on.
Turn it off.
Set it to 25 percent.
What lights are currently on?
Turn all lights off.
Turn my fan on.
Goodnight.
```

Also test these failures separately:

- Home Assistant host offline or DNS failure
- wrong URL or port
- invalid/expired token (`401`)
- device unavailable
- unsupported brightness/color capability
- ambiguous friendly names
- one failure inside a multi-action request
- internet unavailable while Home Assistant remains reachable

CI cannot validate physical device behavior. A successful build or mock-provider
test must not be reported as a working Home Assistant or Google Home setup.

## Security notes

- Give the Home Assistant account only the access Jarvis needs when possible.
- Treat a long-lived token like a password; rotate it after suspected exposure.
- Prefer TLS for remote access and do not disable certificate validation.
- Do not expose Home Assistant directly to the public internet solely for
  Jarvis; use a properly secured remote-access or VPN design.
- Do not log authorization headers, request bodies containing secrets, or a
  complete private device inventory.
- **Clear Credentials** deletes Keychain entries. **Clear Conversation** is a
  separate operation.

Useful upstream references:

- [Home Assistant REST API](https://developers.home-assistant.io/docs/api/rest/)
- [Home Assistant authentication](https://developers.home-assistant.io/docs/auth_api/)
- [Home Assistant Google Assistant integration](https://www.home-assistant.io/integrations/google_assistant/)
- [Home Assistant Matter integration](https://www.home-assistant.io/integrations/matter/)
- [Google Home APIs for iOS](https://developers.home.google.com/apis/ios/overview)
- [Google Home APIs iOS release requirements](https://developers.home.google.com/apis/ios/release-notes)
