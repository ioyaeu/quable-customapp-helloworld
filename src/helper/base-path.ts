const sanitizeSegment = (segment: string) => segment.replace(/^\/+|\/+$/g, '');

export const normalizeBasePath = (
  basePath: string = process.env.QUABLE_APP_BASE_PATH || '',
) => {
  const cleanSegment = sanitizeSegment(basePath);
  return cleanSegment ? `/${cleanSegment}` : '';
};

export const applyBasePath = (path: string, basePath?: string) => {
  const normalizedBase = normalizeBasePath(basePath);
  const normalizedPath = path.startsWith('/') ? path : `/${path}`;

  return `${normalizedBase}${normalizedPath}`.replace(/\/{2,}/g, '/');
};

export const stripBasePath = (path: string, basePath?: string) => {
  const normalizedBase = normalizeBasePath(basePath);
  if (!normalizedBase) return path;

  return path.startsWith(normalizedBase) ? path.slice(normalizedBase.length) || '/' : path;
};
