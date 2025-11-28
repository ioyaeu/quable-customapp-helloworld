import { QuableInstance } from '@prisma/client';
import { Request } from 'express';

export interface SessionData {
  quableInstanceName: string;
  dataLocale: string;
  interfaceLocale: string;
  userId: string;
}

export interface CustomRequest extends Request {
  customer: string | undefined;
  quableInstance: QuableInstance;
  rawBody: Buffer<ArrayBuffer> | undefined;
  pathWithoutBase?: string;
}
