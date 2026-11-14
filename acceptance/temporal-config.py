import json

def datastore(database):
    return {"sql": {
        "pluginName": "mysql8", "databaseName": database,
        "connectAddr": "127.0.0.1:3306", "connectProtocol": "tcp",
        "user": "workbench", "password": "isolated-test-only",
        "maxConns": 12, "maxIdleConns": 4, "maxConnLifetime": "1h",
    }}

services = {}
for name, port in (("frontend", 7233), ("history", 7234), ("matching", 7235), ("worker", 7239)):
    services[name] = {"rpc": {"grpcPort": port, "membershipPort": port - 300, "bindOnLocalHost": True}}
json.dump({
    "log": {"stdout": True, "level": "warn"},
    "persistence": {
        "defaultStore": "default", "visibilityStore": "visibility", "numHistoryShards": 4,
        "datastores": {"default": datastore("temporal"), "visibility": datastore("temporal_visibility")},
    },
    "global": {"membership": {"maxJoinDuration": "30s", "broadcastAddress": "127.0.0.1"}},
    "services": services,
    "clusterMetadata": {
        "enableGlobalNamespace": False, "failoverVersionIncrement": 10,
        "masterClusterName": "active", "currentClusterName": "active",
        "clusterInformation": {"active": {
            "enabled": True, "initialFailoverVersion": 1, "rpcName": "frontend",
            "rpcAddress": "127.0.0.1:7233",
        }},
    },
    "dcRedirectionPolicy": {"policy": "noop"},
}, __import__("sys").stdout)
