/**
 * Lightweight, dependency-free User-Agent parser. Recognizes the
 * browsers and platforms that account for ~99% of real-world web
 * traffic — Chrome/Edge/Firefox/Safari/Opera/Samsung Internet on
 * Windows/macOS/Linux/iOS/Android/ChromeOS.
 *
 * Order of checks matters (WebKit impersonates Gecko, Edge/Opera
 * impersonate Chrome, etc.) — don't reorder without care.
 */

export type DeviceType = 'desktop' | 'mobile' | 'tablet';

export interface ParsedUserAgent {
  browser: string;
  browserVersion: string;
  os: string;
  osVersion: string;
  deviceType: DeviceType;
  /** Short descriptor like "Chrome 128 on macOS 14". */
  label: string;
  /** Stable signature for grouping — same browser + OS + device. */
  signature: string;
}

const UNKNOWN: ParsedUserAgent = {
  browser: 'Unknown browser',
  browserVersion: '',
  os: 'Unknown OS',
  osVersion: '',
  deviceType: 'desktop',
  label: 'Unknown device',
  signature: 'unknown',
};

export function parseUserAgent(ua: string | null | undefined): ParsedUserAgent {
  if (!ua) return UNKNOWN;

  const os = parseOS(ua);
  const browser = parseBrowser(ua);
  const deviceType = parseDeviceType(ua, os.name);

  const label = buildLabel(browser, os);
  const signature = [
    browser.name.toLowerCase(),
    os.name.toLowerCase(),
    deviceType,
  ]
    .join(':')
    .replace(/\s+/g, '-');

  return {
    browser: browser.name,
    browserVersion: browser.version,
    os: os.name,
    osVersion: os.version,
    deviceType,
    label,
    signature,
  };
}

function parseBrowser(ua: string): { name: string; version: string } {
  // Order matters — more specific first.
  const patterns: Array<[string, RegExp]> = [
    ['Edge', /Edg(?:e|A|iOS)?\/([\d.]+)/],
    ['Opera', /(?:OPR|Opera)\/([\d.]+)/],
    ['Samsung Internet', /SamsungBrowser\/([\d.]+)/],
    ['Brave', /Brave\/([\d.]+)/],
    ['Vivaldi', /Vivaldi\/([\d.]+)/],
    ['Firefox', /Firefox\/([\d.]+)/],
    ['Chrome', /(?:Chrome|CriOS)\/([\d.]+)/],
    ['Safari', /Version\/([\d.]+).*Safari/],
    ['Safari', /Safari\/([\d.]+)/],
  ];

  for (const [name, re] of patterns) {
    const m = ua.match(re);
    if (m) {
      const major = m[1].split('.')[0];
      return { name, version: major };
    }
  }

  return { name: 'Unknown browser', version: '' };
}

function parseOS(ua: string): { name: string; version: string } {
  // iPadOS 13+ reports as Macintosh — disambiguate via touch hint later.
  if (/iPhone OS ([\d_]+)/.test(ua)) {
    const v = ua.match(/iPhone OS ([\d_]+)/)![1].replace(/_/g, '.');
    return { name: 'iOS', version: majorOnly(v) };
  }
  if (/CPU OS ([\d_]+) like Mac OS X/.test(ua) || /iPad/.test(ua)) {
    const m = ua.match(/CPU OS ([\d_]+)/);
    return {
      name: 'iPadOS',
      version: m ? majorOnly(m[1].replace(/_/g, '.')) : '',
    };
  }
  if (/Android ([\d.]+)/.test(ua)) {
    return { name: 'Android', version: ua.match(/Android ([\d.]+)/)![1] };
  }
  if (/Windows NT ([\d.]+)/.test(ua)) {
    const v = ua.match(/Windows NT ([\d.]+)/)![1];
    // Win11 uses NT 10.0 too — UA parity forces us to call it "Windows 10/11".
    const label = v === '10.0' ? '10/11' : v;
    return { name: 'Windows', version: label };
  }
  if (/Mac OS X ([\d_.]+)/.test(ua)) {
    const raw = ua.match(/Mac OS X ([\d_.]+)/)![1].replace(/_/g, '.');
    return { name: 'macOS', version: majorOnly(raw) };
  }
  if (/CrOS/.test(ua)) return { name: 'ChromeOS', version: '' };
  if (/Linux/.test(ua)) return { name: 'Linux', version: '' };

  return { name: 'Unknown OS', version: '' };
}

function parseDeviceType(ua: string, osName: string): DeviceType {
  if (/iPad|Tablet|Kindle|PlayBook/.test(ua)) return 'tablet';
  if (osName === 'iPadOS') return 'tablet';
  // Android phones have "Mobile" in the UA; Android tablets don't.
  if (osName === 'Android') {
    return /Mobile/.test(ua) ? 'mobile' : 'tablet';
  }
  if (osName === 'iOS') return 'mobile';
  if (/Mobile|iPhone|iPod/.test(ua)) return 'mobile';
  return 'desktop';
}

function buildLabel(
  browser: { name: string; version: string },
  os: { name: string; version: string },
): string {
  const b = browser.version ? `${browser.name} ${browser.version}` : browser.name;
  const o = os.version ? `${os.name} ${os.version}` : os.name;
  return `${b} on ${o}`;
}

function majorOnly(v: string): string {
  return v.split('.').slice(0, 2).join('.');
}
