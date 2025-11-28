function normalizeHostUrl(hostUrl?: string) {
  const rawHost = (hostUrl || '').trim();
  return rawHost.replace(/\/+$/, '');
}

export function normalizeBasePath(basePath?: string) {
  const rawBasePath = (basePath || '/').trim();

  if (!rawBasePath || rawBasePath === '/') {
    return '/';
  }

  const prefixed = rawBasePath.startsWith('/')
    ? rawBasePath
    : `/${rawBasePath}`;

  const withoutTrailingSlash = prefixed.replace(/\/+$/, '');

  return withoutTrailingSlash || '/';
}

export function getAssetsBasePath(basePath: string) {
  return basePath === '/' ? '' : basePath;
}

export function buildPublicUrl(pathname: string) {
  const hostUrl = normalizeHostUrl(process.env.QUABLE_APP_HOST_URL);
  const basePath = normalizeBasePath(process.env.QUABLE_APP_BASE_PATH);

  const normalizedPath = pathname.startsWith('/') ? pathname : `/${pathname}`;
  const withBasePath =
    basePath === '/'
      ? normalizedPath
      : `${basePath}${normalizedPath}`;

  return `${hostUrl}${withBasePath}`;
}

export { normalizeHostUrl };
