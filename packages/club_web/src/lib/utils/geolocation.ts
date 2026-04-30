/**
 * Formats the location fields captured server-side at session creation
 * into a short human string. Location is resolved via ipwho.is inside
 * the Dart server; the frontend just renders the result.
 *
 * Private/loopback IPs (local dev) are never geolocated, so fall back
 * to "Local network" based on the IP pattern alone. Public IPs that
 * the provider couldn't resolve fall back to "Unknown location".
 */

export interface SessionLocationFields {
  city: string | null;
  country: string | null;
  countryCode: string | null;
  ip: string | null;
}

export function formatLocation(s: SessionLocationFields): string {
  const parts = [s.city, s.country].filter(Boolean) as string[];
  if (parts.length > 0) return parts.join(', ');
  if (s.ip && isPrivateIp(s.ip)) return 'Local network';
  return 'Unknown location';
}

function isPrivateIp(ip: string): boolean {
  if (ip === '::1' || ip === '127.0.0.1' || ip.startsWith('127.')) return true;
  if (ip.startsWith('10.')) return true;
  if (ip.startsWith('192.168.')) return true;
  if (/^172\.(1[6-9]|2\d|3[01])\./.test(ip)) return true;
  if (ip.startsWith('fe80:') || ip.startsWith('fc') || ip.startsWith('fd')) {
    return true;
  }
  return false;
}
