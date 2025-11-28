export function normalizeBasePath(rawBasePath?: string): string {
  if (!rawBasePath || rawBasePath.trim() === '') {
    return '/';
  }

  let basePath = rawBasePath.trim();

  if (!basePath.startsWith('/')) {
    basePath = `/${basePath}`;
  }

  if (basePath.length > 1 && basePath.endsWith('/')) {
    basePath = basePath.slice(0, -1);
  }

  return basePath;
}

export function stripBasePath(path: string, basePath: string): string {
  if (!basePath || basePath === '/') {
    return path || '/';
  }

  if (path === basePath) {
    return '/';
  }

  if (path.startsWith(basePath)) {
    const stripped = path.slice(basePath.length);
    return stripped === '' ? '/' : stripped;
  }

  return path || '/';
}

export function applyBasePath(hostUrl: string, basePath: string): string {
  const normalizedHost = (hostUrl || '').replace(/\/$/, '');
  const normalizedBasePath = normalizeBasePath(basePath);

  if (!normalizedBasePath || normalizedBasePath === '/') {
    return normalizedHost;
  }

  if (normalizedHost.endsWith(normalizedBasePath)) {
    return normalizedHost;
  }

  return `${normalizedHost}${normalizedBasePath}`;
}
