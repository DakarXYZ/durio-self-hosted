// One-shot initialisation for the `database` service (run by `database-init`):
//   1. rs.initiate() of the single-node replica set rs0 (transactions, mongodump --oplog);
//   2. application user `revolt` (readWrite + dbAdmin on `revolt`), password synced from secrets.env.
// Idempotent: runs on every `scripts/compose up`.
// The member host is the compose service name, so changing the server address never touches Mongo.

const NOT_YET_INITIALIZED = 94;

// The server may still be switching from the first-start init mongod to the real one: retry.
let conn;
for (let attempt = 1; !conn; attempt++) {
  try {
    conn = new Mongo("mongodb://database:27017/?directConnection=true");
  } catch (e) {
    if (attempt >= 60) throw e;
    sleep(1000);
  }
}
const admin = conn.getDB("admin");
admin.auth("root", process.env.MONGO_ROOT_PASSWORD);

function command(cmd) {
  // assign before returning: mongosh only awaits the call inside try when it is not `return`ed directly
  try {
    const res = admin.runCommand(cmd);
    return res;
  } catch (e) {
    return { ok: 0, code: e.code, errmsg: e.message };
  }
}

const status = command({ replSetGetStatus: 1 });
if (!status.ok) {
  if (status.code !== NOT_YET_INITIALIZED) {
    throw new Error(`replSetGetStatus failed: ${status.errmsg}`);
  }
  const res = command({
    replSetInitiate: { _id: "rs0", members: [{ _id: 0, host: "database:27017" }] },
  });
  if (!res.ok) throw new Error(`replSetInitiate failed: ${res.errmsg}`);
  print("replica set rs0 initiated");
}

let primary = false;
for (let i = 0; i < 60 && !primary; i++) {
  primary = command({ hello: 1 }).isWritablePrimary === true;
  if (!primary) sleep(1000);
}
if (!primary) throw new Error("rs0 has no writable primary after 60s");

const roles = [
  { role: "readWrite", db: "revolt" },
  { role: "dbAdmin", db: "revolt" },
];
const pwd = process.env.MONGO_REVOLT_PASSWORD;
if (!pwd) throw new Error("MONGO_REVOLT_PASSWORD is empty");

if (admin.getUser("revolt")) {
  admin.updateUser("revolt", { pwd, roles });
  print("user revolt updated");
} else {
  admin.createUser({ user: "revolt", pwd, roles });
  print("user revolt created");
}
