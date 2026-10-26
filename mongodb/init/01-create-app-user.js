// Runs once on first start of l1 (docker-entrypoint-initdb.d), authenticated as the root user.
const appdb = db.getSiblingDB('appdb');
appdb.createUser({
  user: 'appuser',
  pwd: process.env.MONGO_APP_PASSWORD || 'apppassword',
  roles: [{ role: 'readWrite', db: 'appdb' }, { role: 'dbAdmin', db: 'appdb' }],
});
appdb.createCollection('events');
// TTL index: documents expire 30 days after createdAt
appdb.events.createIndex({ createdAt: 1 }, { expireAfterSeconds: 2592000 });
