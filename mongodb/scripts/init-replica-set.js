// Idempotent replica-set initializer. Runs inside the network namespace of the first
// member (compose `network_mode: service:<member>`), so it connects over localhost and the
// MongoDB "localhost exception" lets it create the first user while auth is already on.
//
// Env: RS_ID, RS_HOSTS (comma separated host:port, first = preferred primary),
//      RS_CONFIGSVR=true for a config-server replica set,
//      ROOT_USER + ROOT_PASSWORD to create the root user,
//      APP_DB + APP_PASSWORD to also create an `appuser` with readWrite on that database.
const id = process.env.RS_ID;
const hosts = process.env.RS_HOSTS.split(',');
const cfg = {
  _id: id,
  members: hosts.map((host, i) => ({ _id: i, host, priority: i === 0 ? 2 : 1 })),
};
if (process.env.RS_CONFIGSVR === 'true') cfg.configsvr = true;

// Members may still be starting: keep trying until all of them answer
let initiated = false;
for (let i = 0; i < 60 && !initiated; i++) {
  try {
    printjson(rs.initiate(cfg));
    initiated = true;
  } catch (e) {
    if (e.codeName === 'AlreadyInitialized') {
      initiated = true;
    } else {
      print(`${id}: not ready yet (${e.message}), retrying`);
      sleep(3000);
    }
  }
}
if (!initiated) throw new Error(`${id}: rs.initiate never succeeded`);

for (let i = 0; i < 60 && !db.hello().isWritablePrimary; i++) sleep(1000);
if (!db.hello().isWritablePrimary) throw new Error(`${id}: no primary elected within 60s`);
print(`${id}: primary is ${db.hello().me}`);

if (process.env.ROOT_USER) {
  const admin = db.getSiblingDB('admin');
  admin.createUser({
    user: process.env.ROOT_USER,
    pwd: process.env.ROOT_PASSWORD,
    roles: [{ role: 'root', db: 'admin' }],
  });
  admin.auth(process.env.ROOT_USER, process.env.ROOT_PASSWORD);
  if (process.env.APP_DB) {
    db.getSiblingDB(process.env.APP_DB).createUser({
      user: 'appuser',
      pwd: process.env.APP_PASSWORD,
      roles: [{ role: 'readWrite', db: process.env.APP_DB }],
    });
  }
  print(`${id}: users created`);
}
