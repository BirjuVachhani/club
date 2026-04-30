import { browser } from '$app/environment';

export class ApiError extends Error {
  constructor(
    public status: number,
    public statusText: string,
    public body: unknown
  ) {
    super(`API Error ${status}: ${statusText}`);
    this.name = 'ApiError';
  }
}

/**
 * Extract a human-friendly message from a thrown error. If the value is
 * an [ApiError] whose body matches the server's standard
 * `{error: {message}}` envelope, the server message is returned.
 * Otherwise [fallback] is returned. Keeps the `(err.body as any)?...`
 * cast in exactly one place.
 */
export function apiErrorMessage(err: unknown, fallback: string): string {
  if (err instanceof ApiError) {
    const body = err.body as { error?: { message?: string } } | undefined;
    return body?.error?.message ?? fallback;
  }
  return fallback;
}

interface RequestOptions {
  headers?: Record<string, string>;
  params?: Record<string, string>;
}

// Double-submit CSRF cookie. The server sets `club_csrf` at login time;
// the SPA reads it and echoes it in `X-CSRF-Token` on state-changing
// requests. Cookie is NOT HttpOnly precisely so JS can read it.
const CSRF_COOKIE = 'club_csrf';
const CSRF_HEADER = 'X-CSRF-Token';

function readCsrfToken(): string | null {
  if (!browser) return null;
  for (const part of document.cookie.split(';')) {
    const trimmed = part.trim();
    if (trimmed.startsWith(`${CSRF_COOKIE}=`)) {
      return decodeURIComponent(trimmed.slice(CSRF_COOKIE.length + 1));
    }
  }
  return null;
}

function needsCsrf(method: string): boolean {
  const m = method.toUpperCase();
  return m === 'POST' || m === 'PUT' || m === 'PATCH' || m === 'DELETE';
}

async function request<T>(
  method: string,
  path: string,
  body?: unknown,
  options?: RequestOptions
): Promise<T> {
  let url = path;

  if (options?.params) {
    const searchParams = new URLSearchParams(options.params);
    url += `?${searchParams.toString()}`;
  }

  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...options?.headers
  };

  if (needsCsrf(method)) {
    const csrf = readCsrfToken();
    if (csrf) headers[CSRF_HEADER] = csrf;
  }

  const response = await fetch(url, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
    // Send the HttpOnly session cookie on same-origin API calls. We never
    // attach an Authorization header from the browser — the session lives
    // in the cookie and is invisible to JS (XSS-resistant).
    credentials: 'include'
  });

  if (!response.ok) {
    let errorBody: unknown;
    try {
      errorBody = await response.json();
    } catch {
      errorBody = await response.text();
    }
    throw new ApiError(response.status, response.statusText, errorBody);
  }

  if (response.status === 204) {
    return undefined as T;
  }

  return response.json() as Promise<T>;
}

export const api = {
  get<T>(path: string, options?: RequestOptions): Promise<T> {
    return request<T>('GET', path, undefined, options);
  },

  post<T>(path: string, body?: unknown, options?: RequestOptions): Promise<T> {
    return request<T>('POST', path, body, options);
  },

  put<T>(path: string, body?: unknown, options?: RequestOptions): Promise<T> {
    return request<T>('PUT', path, body, options);
  },

  patch<T>(path: string, body?: unknown, options?: RequestOptions): Promise<T> {
    return request<T>('PATCH', path, body, options);
  },

  delete<T>(path: string, options?: RequestOptions): Promise<T> {
    return request<T>('DELETE', path, undefined, options);
  },

  async upload<T>(path: string, formData: FormData): Promise<T> {
    const headers: Record<string, string> = {};
    const csrf = readCsrfToken();
    if (csrf) headers[CSRF_HEADER] = csrf;

    const response = await fetch(path, {
      method: 'POST',
      headers,
      body: formData,
      credentials: 'include'
    });

    if (!response.ok) {
      let errorBody: unknown;
      try {
        errorBody = await response.json();
      } catch {
        errorBody = await response.text();
      }
      throw new ApiError(response.status, response.statusText, errorBody);
    }

    if (response.status === 204) {
      return undefined as T;
    }

    return response.json() as Promise<T>;
  }
};
