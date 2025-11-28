import { QuableInstance } from '@prisma/client';
import { QuablePimClient } from '@quable/quable-pim-js';
import { databaseService } from './database.service';
import { RESOURCES_ID } from '../helper/constants';
import { keyValueService } from './keyvalue.service';
import { applyBasePath, normalizeBasePath } from '../helper/base-path';

class WebhookService {

    public registerWebhook = async (quableInstance: QuableInstance) => {
        const { authToken, name } = quableInstance;
        const quablePIMClient = new QuablePimClient({ apiKey: authToken, instanceName: name });
        const webhooks = await quablePIMClient.PimApi.Webhook.getAll({
            limit: 1,
            name: RESOURCES_ID,
        });
        let webhook = webhooks.length ? webhooks[0] : null;
        const basePath = normalizeBasePath(
            process.env.APP_BASE_PATH || process.env.QUABLE_APP_BASE_PATH,
        );
        const hostWithBasePath = applyBasePath(
            process.env.QUABLE_APP_HOST_URL || '',
            basePath,
        );
        const payload = {
            name: RESOURCES_ID,
            active: true,
            url: `${hostWithBasePath}/webhook/${name}`,
            events: ['document.update'],
        };
        if (!webhook) {
            webhook = await quablePIMClient.PimApi.Webhook.create({ ...payload });
        } else {
            webhook = await quablePIMClient.PimApi.Webhook.update(webhook.id, { ...payload });
        }
        return webhook;
    };

    public processWebhook = async (quableInstanceName: string, payload: Record<string, any>) => {
        const instance = await databaseService.quableInstance.findFirst({
            where: { name: quableInstanceName },
        });
        if (!instance) {
            console.log(`Instance ${quableInstanceName} not found in database.`);
            return;
        }
        console.log(`Received webhook from ${quableInstanceName} payload:`, payload);
        await keyValueService.registerKeyValue(instance, new Date().toISOString());
    };

}

export const webhookService = new WebhookService();