// Register both shards with the cluster and shard appdb.events on a hashed key.
// Run with mongosh against a mongos router.
sh.addShard('shard1rs/shard1-node1:27017,shard1-node2:27017,shard1-node3:27017');
sh.addShard('shard2rs/shard2-node1:27017,shard2-node2:27017,shard2-node3:27017');
sh.enableSharding('appdb');
sh.shardCollection('appdb.events', { userId: 'hashed' });
printjson(db.adminCommand({ listShards: 1 }).shards.map((s) => s._id));
