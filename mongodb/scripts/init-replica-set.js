// Idempotent replica-set initializer, run with mongosh against the first member.
// Env: RS_ID, RS_HOSTS (comma separated host:port, first = preferred primary),
//      RS_CONFIGSVR=true for a config-server replica set,
//      APP_DB + MONGO_APP_PASSWORD to also create an application user.
const id = process.env.RS_ID;
const hosts = process.env.RS_HOSTS.split(',');
const cfg = {
  _id: id,
  members: hosts.map((host, i) => ({ _id: i, host, priority: i === 0 ? 2 : 1 })),
};
if (process.env.RS_CONFIGSVR === 'true') cfg.configsvr = true;

let initiated = true;
try {
  rs.status();
} catch (e) {
  if (e.codeName !== 'NotYetInitialized') throw e;
  initiated = false;
}
if (!initiated) printjson(rs.initiate(cfg));

for (let i = 0; i < 60 && !db.hello().isWritablePrimary; i++) sleep(1000);
if (!db.hello().isWritablePrimary) throw new Error(`${id}: no primary elected within 60s`);
print(`${id}: primary is ${db.hello().me}`);

if (process.env.APP_DB) {
  const appdb = db.getSiblingDB(process.env.APP_DB);
  if (!appdb.getUser('appuser')) {
    appdb.createUser({
      user: 'appuser',
      pwd: process.env.MONGO_APP_PASSWORD,
      roles: [{ role: 'readWrite', db: process.env.APP_DB }],
    });
  }
}
