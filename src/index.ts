import express, { Request, Response } from 'express';
import expressLayouts from 'express-ejs-layouts';

import { join } from 'path';
import appRouter from './routes/app.routes';
import cors from 'cors';
import cookieParser from 'cookie-parser';
import { setupAppConfig } from './helper/config';
import { httpLoggerMiddleware } from './middlewares/http-logger.middleware';
import { sessionMiddleware } from './middlewares/session.middleware';
import webhookRouter from './routes/webhook.routes';
import slotRouter from './routes/slot.routes';
import { rawBody } from './middlewares/raw-body';
import { getAssetsBasePath, normalizeBasePath } from './helper/base-path';

async function bootstrapApp() {
  const app = express();

  const basePath = normalizeBasePath(process.env.QUABLE_APP_BASE_PATH);
  const assetsBasePath = getAssetsBasePath(basePath);
  const withBasePath = (path = '/') =>
    basePath === '/' ? path : `${basePath}${path}`;

  app.locals.basePath = basePath;
  app.locals.assetsBasePath = assetsBasePath;

  await setupAppConfig(app);
  
  // Security
  app.use(withBasePath(), cors());
  app.use(withBasePath(), rawBody());
  app.use(withBasePath(), express.json());
  app.use(withBasePath(), cookieParser());
  app.use(withBasePath(), express.urlencoded({ extended: true }));

  // Middleware
  app.use(withBasePath(), httpLoggerMiddleware);
  app.use(withBasePath(), sessionMiddleware);

  // Views
  app.use(withBasePath(), expressLayouts);
  app.use(withBasePath(), express.static(join(__dirname, '..', 'public')));
  app.set('view engine', 'ejs');
  app.set('views', join(__dirname, '..', 'public', 'views'));
  app.set('layout', 'layouts/layout');

  // Routes
  app.use(withBasePath('/'), appRouter);
  app.use(withBasePath('/webhook'), webhookRouter);
  app.use(withBasePath('/slot'), slotRouter);

  // 404
  app.use(withBasePath(), (_req: Request, res: Response) => {
    return res.status(404).send({ message: 'Not found' });
  });

  // 500
  app.use(withBasePath(), (_error: any, _req: Request, res: Response) => {
    return res.status(500).send({ message: 'Internal server error' });
  });

  const PORT = parseInt(process.env.QUABLE_APP_PORT || '4000');
  app.listen(PORT, () =>
    console.info(
      `Server started on port: ${PORT} and host: ${process.env.QUABLE_APP_HOST_URL}`,
    ),
  );
}

bootstrapApp();
