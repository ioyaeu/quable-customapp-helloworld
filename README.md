# CustomApp HelloWorld - Quable PIM

## 📚 Introduction

Cette application exemple démontre l'intégration avec Quable PIM via une Quable App "Custom" (non intégrée à l'app Store).

## 🎯 Fonctionnalités

- ✅ Configuration automatique de webhook `custom_app.helloworld`
- ✅ Configuration automatique d'une clé/valeur `custom_app.helloworld`
- ✅ Gestion de clé/valeur dans le PIM à la réception d'un event webhook
- ✅ Support de tous les slots de documents
- ✅ Validation HMAC pour sécurité

## 📋 Prérequis

- Node.js >= 16.0.0
- Instance Quable PIM
- Token API Quable avec permissions full_access

## 🚀 Installation

### 1. Cloner le repository
```bash
git clone https://github.com/quable/customapp-helloworld.git
cd customapp-helloworld
```

### 2. Installer les dépendances
```bash
npm install
# ou
yarn install
```

### 3. Configuration
```bash
cp .env.dist .env
```

Éditer `.env` :
```env
DATABASE_URL=file:./dev.db 
QUABLE_APP_PORT=4000
QUABLE_APP_HOST_URL=https://votre-url.com
```

Pour l'URL, n'hésitez pas à utilier un tunnel pour que le PIM puisse joidnre votre application lancée localement.

### 4. Base de données
```bash
npx prisma migrate dev --name init
npx prisma generate
```

## 🔧 Déclaration dans Quable PIM

### 1. Accéder à l'admin du PIM
1. Créer une nouvelle CustomApp
2. Renseigner bien l'URL public de votre application
3. Cocher TOUS les slots disponibles
4. Noter le secret pour la validation HMAC

### 2. Ajouter manuellement l'instance en BDD

```bash
npx prisma studio
```

## 🤖 Déploiement automatisé sur qa-ftp

Un script complémentaire au bootstrap qa-ftp (FTP/MariaDB/Nginx déjà déployé) est disponible pour installer et configurer automatiquement l'application en service systemd.

> Prérequis : le script cible Ubuntu 22.04.5 LTS (Jammy) et arrête l'exécution si l'OS détecté ne correspond pas.

> À noter : le script n'a pas besoin de Docker ni d'ajouter de dépôt tiers supplémentaire ; il se contente de rafraîchir l'APT
> existant avec l'option `Acquire::AllowReleaseinfoChange::Label=true` pour accepter automatiquement les changements d'étiquette
> des dépôts déjà configurés (par exemple un PPA PHP). Si un dépôt a changé de label, l'exécution continue sans interaction.

```bash
sudo ./scripts/install-customapp-helloworld.sh \
  --app-host-url "https://qa-ftp.quable.io/quableapps/helloworld" \
  --instance-name "mon-instance" \
  --quable-api-token "<token_full_access>" \
  --quable-app-secret "<secret_hmac>" \
  --app-port 4000
```

Options utiles pour la CI : `--install-dir` (chemin d'installation), `--service-name` (nom systemd), `--service-user` (utilisateur système), `--database-url` (URL Prisma), `--node-major` (version Node.js minimale), `--source-dir` (chemin du dépôt à recopier si le script est lancé depuis un autre dossier, défaut : `/var/www/source-quable-customapp-helloworld`), `--base-path` (chemin d'exposition par défaut `/quableapps/helloworld`), `--reset-sqlite-db`/`--keep-sqlite-db` (forcer ou empêcher la suppression du fichier SQLite existant avant les migrations). Le script recopie le dépôt vers l'hôte (en essayant d'abord de dézipper `/var/www/quable-customapp-helloworld.zip` vers `/var/www/source-quable-customapp-helloworld` si nécessaire), installe les dépendances, exécute les migrations Prisma (en supprimant par défaut un fichier SQLite déjà présent pour éviter l'erreur Prisma `P3005`), injecte l'instance Quable fournie et démarre le service. **Attention :** l'URL d'exposition ne doit pas être `/automation/quableapp` car cette route est déjà servie par Nginx/PHP sur qa-ftp ; utilisez une route dédiée placée en dehors du préfixe `/automation`, par exemple `/quableapps/helloworld` (valeur proposée par défaut). Si le script est copié seul en dehors du dépôt,fournissez `--source-dir` pour pointer vers la racine du projet (celle qui contient `package.json`). S'il n'y a qu'un `package-lock.json` dans le dossier source, recopiez le dépôt complet ou un artefact de build contenant aussi `package.json` avant de lancer le script.

Ajoutez ensuite manuellement le reverse proxy Nginx pointant vers le port du service (à placer avant les blocs `/automation`) :

```nginx
location /quableapps/helloworld {
    proxy_pass http://127.0.0.1:4000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection 'upgrade';
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```


## 🏃 Utilisation

### Démarrage
```bash
// Mode développement
npm run dev
// Mode production
npm run build && npm start
```

### Endpoints

| Endpoint | Méthode | Description |
|----------|---------|-------------|
| `/` | GET | Page de configuration |
| `/` | POST | Lancement de slot |
| `/webhook/{instance}` | POST | Réception webhooks |
| `/slot/{slotName}` | GET | Affichage slot iframe |

### Flow de fonctionnement

1. **Accès à la page de configuration depuis l'administration des Quable App**
   - L'app vérifie/crée le webhook `custom_app.helloworld`
   - L'app vérifie/crée la key/value `custom_app.helloworld`

2. **Webhook document.update**
   - Réception du webhook
   - Mise à jour key/value avec datetime

3. **Affichage slots**
   - Validation HMAC de la requête
   - Retour URL iframe
   - Affichage "Hello World"

## 🔐 Sécurité

- Validation HMAC sur tous les endpoints
- Tokens stockés en base de données
- Utilisation de `timingSafeEqual` contre timing attacks

## 🔧 Erreurs avec la base de Données

### ❌ Erreur Identifiée

```json
{
    "statusCode": 500,
    "message": "Invalid `databaseService.quableInstance.findFirst()` invocation...
    Inconsistent column data: Conversion failed: premature end of input"
}
```

### 🔍 Diagnostic

L'erreur provient de la base de données SQLite qui contient des données corrompues ou mal formatées dans la table `quable_instance`.

### ✅ Solutions

#### Solution 1: Réinitialiser la Base de Données (RECOMMANDÉ)

```bash
# 1. Arrêter l'application
# 2. Sauvegarder l'ancienne base (optionnel)
cp database/dev.db database/dev.db.backup

# 3. Supprimer la base corrompue
rm database/dev.db

# 4. Recréer la base avec Prisma
npx prisma migrate dev --name init
npx prisma generate

# 5. Ajouter une instance de test
npx prisma studio
# OU utiliser un script SQL
```

#### Solution 2: Script d'Initialisation

Créer un fichier `scripts/init-db.js`:

```javascript
const { PrismaClient } = require('@prisma/client');
const prisma = new PrismaClient();

async function initDatabase() {
  try {
    // Nettoyer la table existante
    await prisma.quableInstance.deleteMany();
    
    // Créer une instance de test
    const instance = await prisma.quableInstance.create({
      data: {
        name: 'test-instance',
        authToken: 'your-api-token-here',
        quableAppSecret: 'your-hmac-secret-here'
      }
    });
    
    console.log('✅ Base de données initialisée avec succès');
    console.log('Instance créée:', instance);
    
  } catch (error) {
    console.error('❌ Erreur lors de l\'initialisation:', error);
  } finally {
    await prisma.$disconnect();
  }
}

initDatabase();
```

Puis exécuter:
```bash
node scripts/init-db.js
```

#### Solution 3: Vérifier le Schéma Prisma

Vérifier que `database/schema.prisma` est correct:

```prisma
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "sqlite"
  url      = env("DATABASE_URL")
}

model QuableInstance {
  id              Int      @id @default(autoincrement())
  name            String
  authToken       String
  quableAppSecret String
  createdAt       DateTime @default(now())
  updatedAt       DateTime @updatedAt

  @@map("quable_instance")
}
```

#### Solution 4: Migration Complète

```bash
# 1. Nettoyer tout
rm -rf database/dev.db
rm -rf node_modules/.prisma
rm -rf node_modules/@prisma

# 2. Réinstaller les dépendances
npm install

# 3. Générer Prisma
npx prisma generate

# 4. Créer la base
npx prisma db push

# 5. Vérifier avec Prisma Studio
npx prisma studio
```

### 🛠️ Script de Test Complet

Créer `scripts/test-db.js`:

```javascript
const { PrismaClient } = require('@prisma/client');

async function testDatabase() {
  const prisma = new PrismaClient({
    log: ['query', 'error', 'warn']
  });

  try {
    // Test de connexion
    await prisma.$connect();
    console.log('✅ Connexion à la base réussie');

    // Test de lecture
    const count = await prisma.quableInstance.count();
    console.log(`📊 Nombre d'instances: ${count}`);

    // Test de création
    const testInstance = await prisma.quableInstance.create({
      data: {
        name: `test-${Date.now()}`,
        authToken: 'test-token',
        quableAppSecret: 'test-secret'
      }
    });
    console.log('✅ Instance créée:', testInstance.name);

    // Test de lecture après création
    const instances = await prisma.quableInstance.findMany();
    console.log(`✅ ${instances.length} instance(s) trouvée(s)`);

    // Nettoyage
    await prisma.quableInstance.delete({
      where: { id: testInstance.id }
    });
    console.log('✅ Instance de test supprimée');

  } catch (error) {
    console.error('❌ Erreur:', error);
  } finally {
    await prisma.$disconnect();
  }
}

testDatabase();
```

### 📝 Vérifications Supplémentaires

#### 1. Vérifier les Variables d'Environnement

`.env`:
```env
DATABASE_URL="file:./dev.db"
# Chemin relatif depuis la racine du projet
```

#### 2. Vérifier les Permissions

```bash
# Vérifier les permissions du dossier database
ls -la database/

# Si nécessaire, corriger les permissions
chmod 755 database/
chmod 644 database/dev.db
```

#### 3. Vérifier la Version de SQLite

```bash
# Installer sqlite3 si nécessaire
npm install sqlite3

# Vérifier l'intégrité de la base
sqlite3 database/dev.db "PRAGMA integrity_check;"
```

### 🚨 Points d'Attention

1. **Données de Production**: Si c'est en production, sauvegarder TOUJOURS avant modification
2. **Tokens Sensibles**: Ne pas commiter les vrais tokens dans le code
3. **Migration**: Utiliser les migrations Prisma pour tracer les changements

### ✅ Validation Finale

Après correction, tester avec:

```bash
# 1. Lancer l'application
npm run dev

# 2. Tester l'endpoint
curl -X POST http://localhost:4000/ \
  -H "Content-Type: application/json" \
  -H "X-Signature: [signature]" \
  -H "X-Timestamp: [timestamp]" \
  -d '{
    "instance": "test-instance",
    "slot": "document.page.tab",
    "data": {
      "dataLocale": "fr_FR",
      "interfaceLocale": "fr_FR",
      "userId": "123"
    }
  }'
```


## 📝 License

MIT - Quable 2025