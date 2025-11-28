import express, { Request, Response, Router } from 'express';
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
import { normalizeBasePath } from './helper/base-path';

export async function createApp() {
  const app = express();

  await setupAppConfig(app);

  const basePath = normalizeBasePath(
    process.env.APP_BASE_PATH ||
      process.env.QUABLE_APP_BASE_PATH ||
      app.get('basePath'),
  );

  app.set('basePath', basePath);

  // Security
  app.use(cors());
  app.use(rawBody());
  app.use(express.json());
  app.use(cookieParser());
  app.use(express.urlencoded({ extended: true }));

  // Middleware
  app.use(httpLoggerMiddleware);
  app.use(sessionMiddleware);

  // Views
  app.use(expressLayouts);
  app.use(basePath, express.static(join(__dirname, '..', 'public')));
  app.set('view engine', 'ejs');
  app.set('views', join(__dirname, '..', 'public', 'views'));
  app.set('layout', 'layouts/layout');

  // Routes
  const router = Router();
  router.use('/', appRouter);
  router.use('/webhook', webhookRouter);
  router.use('/slot', slotRouter);

  router.use((_req: Request, res: Response) => {
    return res.status(404).send({ message: 'Not found' });
  });

  router.use((_error: any, _req: Request, res: Response) => {
    return res.status(500).send({ message: 'Internal server error' });
  });

  app.use(basePath, router);

  return app;
}

if (require.main === module) {
  createApp().then((app) => {
    const PORT = parseInt(process.env.QUABLE_APP_PORT || '4000');
    app.listen(PORT, () =>
      console.info(
        `Server started on port: ${PORT} and host: ${process.env.QUABLE_APP_HOST_URL}`,
      ),
    );
  });
}
