import request from 'supertest';
import { createApp } from '../src/index';
import { QuableInstance } from '@prisma/client';

const mockInstance: QuableInstance = {
  id: 'instance-id',
  name: 'dev-igor',
  authToken: 'token',
  quableAppSecret: 'secret',
  createdAt: new Date(),
  updatedAt: new Date(),
};

const findFirstOrThrow = jest.fn(async ({ where }) => {
  if (where.name === mockInstance.name) {
    return mockInstance;
  }
  throw new Error('not found');
});

const findFirst = jest.fn(async ({ where }) => {
  if (where.name === mockInstance.name) {
    return mockInstance;
  }
  return null;
});

jest.mock('../src/services/database.service', () => ({
  __esModule: true,
  databaseService: {
    quableInstance: {
      findFirstOrThrow: (...args: any[]) => findFirstOrThrow(...args),
      findFirst: (...args: any[]) => findFirst(...args),
    },
  },
}));

jest.mock('../src/services/keyvalue.service', () => ({
  __esModule: true,
  keyValueService: {
    registerKeyValue: jest.fn().mockResolvedValue({}),
  },
}));

jest.mock('../src/services/webhook.service', () => ({
  __esModule: true,
  webhookService: {
    registerWebhook: jest.fn().mockResolvedValue({}),
    processWebhook: jest.fn(),
  },
}));

describe('base path + session handling', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    process.env.QUABLE_PARTNER_API_SECRET = 'secret';
    process.env.QUABLE_APP_HOST_URL = 'https://qa-ftp.quable.io';
  });

  const makeApp = async (basePath?: string) => {
    process.env.APP_BASE_PATH = basePath;
    process.env.QUABLE_APP_BASE_PATH = undefined;
    return createApp();
  };

  const query =
    '?applicationType=AppStore&quableInstanceName=dev-igor&interfaceLocale=fr-FR&dataLocale=en_GB&userId=34';

  it('serves the AppStore GET at root base path', async () => {
    const app = await makeApp('/');
    const response = await request(app).get(`/${query}`);

    expect(response.status).toBe(200);
    expect(findFirstOrThrow).toHaveBeenCalled();
    expect(response.headers['set-cookie']).toBeDefined();
  });

  it('serves the AppStore GET under a sub-path base path', async () => {
    const basePath = '/quableapps/helloworld';
    const app = await makeApp(basePath);
    const response = await request(app).get(`${basePath}/${query}`);

    expect(response.status).toBe(200);
    expect(findFirstOrThrow).toHaveBeenCalled();
  });

  it('keeps HMAC validation using the full originalUrl', async () => {
    const basePath = '/quableapps/helloworld';
    const app = await makeApp(basePath);
    const agent = request.agent(app);

    await agent.get(`${basePath}/${query}`);

    const body = {
      instance: 'dev-igor',
      slot: 'document.page.tab',
      data: { dataLocale: 'en_GB', interfaceLocale: 'fr-FR', userId: '34' },
    };

    const response = await agent
      .post(`${basePath}/`)
      .set('x-signature', 'invalid')
      .set('x-timestamp', `${Date.now()}`)
      .send(body);

    expect(response.status).toBe(400);
    expect(response.text).toContain('Invalid signature');
  });
});
