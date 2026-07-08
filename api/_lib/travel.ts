// Travel-time estimate via the Google Routes API — the server-side twin of the Mac's TravelTimeService.
// On the Mac, driving/walking use Apple's MKDirections (unavailable off-device), so in the cloud we use
// Google for every mode. Transit falls back to walking (mirroring the Mac) so a nudge still fires when
// there's no transit route. The origin is a lat/lng (the phone fix); the destination is passed as the
// event's raw LOCATION text — Routes geocodes address strings itself, so no separate geocoding step.
//
// Needs GOOGLE_MAPS_KEY (the same key the Mac keeps in Keychain "googlemaps") with the Routes API
// enabled. Returns null if the key is missing or no route is found.

export type TravelMode = "walking" | "driving" | "transit" | "bicycling";

const GOOGLE_MODE: Record<TravelMode, string> = {
  walking: "WALK",
  driving: "DRIVE",
  transit: "TRANSIT",
  bicycling: "BICYCLE",
};

export interface TravelEstimate {
  seconds: number;
  usedMode: TravelMode; // may differ from requested (transit → walking fallback)
}

export function parseMode(setting: string | undefined): TravelMode {
  const m = (setting || "").toLowerCase();
  return m === "driving" || m === "walking" || m === "bicycling" || m === "transit" ? (m as TravelMode) : "transit";
}

async function computeOnce(
  origin: { lat: number; lng: number },
  destination: string,
  mode: TravelMode,
  key: string,
): Promise<number | null> {
  const body: Record<string, unknown> = {
    origin: { location: { latLng: { latitude: origin.lat, longitude: origin.lng } } },
    destination: { address: destination },
    travelMode: GOOGLE_MODE[mode],
  };
  // routingPreference is only valid for DRIVE/TWO_WHEELER; Google rejects it on walk/transit/bicycle.
  if (mode === "driving") body.routingPreference = "TRAFFIC_UNAWARE";

  try {
    const res = await fetch("https://routes.googleapis.com/directions/v2:computeRoutes", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": key,
        "X-Goog-FieldMask": "routes.duration",
      },
      body: JSON.stringify(body),
    });
    if (res.status !== 200) return null;
    const json: any = await res.json();
    const dur: string | undefined = json?.routes?.[0]?.duration; // e.g. "1234s"
    if (!dur) return null;
    const secs = Number(String(dur).replace("s", ""));
    return Number.isFinite(secs) ? secs : null;
  } catch {
    return null;
  }
}

/** Travel time from `origin` to the `destination` address in `mode`, or null. Transit → walking fallback. */
export async function estimateTravel(
  origin: { lat: number; lng: number },
  destination: string,
  mode: TravelMode,
): Promise<TravelEstimate | null> {
  const key = process.env.GOOGLE_MAPS_KEY;
  if (!key || !destination) return null;

  const primary = await computeOnce(origin, destination, mode, key);
  if (primary != null) return { seconds: primary, usedMode: mode };

  if (mode === "transit") {
    const walk = await computeOnce(origin, destination, "walking", key);
    if (walk != null) return { seconds: walk, usedMode: "walking" };
  }
  return null;
}
