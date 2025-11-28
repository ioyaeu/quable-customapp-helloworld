import { Response, NextFunction } from 'express';
import { SessionData } from '../helper/types';
import {
  isPublicRoute,
  isNewThirdPartyCall,
  finalizeRequest,
} from '../helper/session/route';
import {
  generateNewAuthToken,
  handleTokenError,
  verifyAuthToken,
} from '../helper/session/auth';
import { stripBasePath } from '../helper/base-path';

export async function sessionMiddleware(
  req: any,
  res: Response,
  next: NextFunction,
) {
  const basePath = req.app?.get('basePath') || '/';
  const pathWithoutBase = stripBasePath(req.path, basePath);
  const isAppStoreLoad =
    pathWithoutBase === '/' &&
    req.method === 'GET' &&
    req.query.applicationType === 'AppStore';

  req.pathWithoutBase = pathWithoutBase;

  if (isPublicRoute(req, pathWithoutBase) && !isAppStoreLoad) {
    next();
    return;
  }

  try {
    await handleAuthAndSession(req, res, pathWithoutBase);
    next();
  } catch (error) {
    const logLevel = (process.env.LOG_LEVEL || '').toLowerCase();
    if (logLevel !== 'silent') {
      console.warn('Unauthorized request', {
        path: req.path,
        pathWithoutBase,
        basePath,
        query: req.query,
        hasInstance: Boolean(req.quableInstance),
        isAppStoreLoad,
        message: error.message,
      });
    }
    res.status(401).send(`Unauthorized: ${error.message}`);
  }
}

async function handleAuthAndSession(req: any, res: Response, pathWithoutBase: string) {
  let authToken = req.cookies.token;
  let decoded: SessionData | undefined;

  try {
    if (isNewThirdPartyCall(req, pathWithoutBase) || !authToken) {
      authToken = generateNewAuthToken(req.query);
    }
    decoded = verifyAuthToken(authToken) as SessionData;
  } catch (error) {
    authToken = handleTokenError(error, authToken);
  }
  await finalizeRequest(req, res, decoded!, authToken, pathWithoutBase);
}
