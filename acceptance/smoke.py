from pathlib import Path
import http.cookiejar
import json
import os
import sys
import time
import urllib.request

root, phase = Path(sys.argv[1]), sys.argv[2]
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

def connect(request, timeout=15):
    return opener.open(request, timeout=timeout)

def request(port, path, data=None, *, origin=None, mcp=False):
    headers = {"Content-Type": "application/json"}
    if port in (7381, 7382):
        headers["Authorization"] = "Bearer " + os.environ["WORKBENCH_HOST_TOKEN"]
        if port == 7381:
            headers.update({"X-Workbench-Kind":"owner", "X-Workbench-Session":"clean-install-check"})
    if origin:
        headers["Origin"] = origin
    if mcp:
        headers["Accept"] = "application/json, text/event-stream"
    with connect(urllib.request.Request(f"http://127.0.0.1:{port}"+path,
         None if data is None else json.dumps(data).encode(), headers)) as result:
        body = result.read().decode()
        if result.headers.get_content_type() == "text/event-stream":
            body = next(line.removeprefix("data: ") for line in body.splitlines() if line.startswith("data: "))
        return json.loads(body)

connect(os.environ["TEST_LAUNCH_URL"]).close()
api = lambda path, body=None: request(3082, "/workbench-api"+path, body, origin="http://127.0.0.1:3082")
worker = lambda path, body=None: request(7381, path, body)
catalog = api("/catalog")
session = catalog["personalSessionId"]
assert session and api("/project-list")["expertManagement"]
assert isinstance(api("/decisions"), list) and isinstance(api("/runs"), list)
assert worker("/personal/settings")["sessionId"] == session
assert worker("/health") == {"ready":True,"backgroundReady":True}

def asset_version(resource):
    return next(r.get("currentVersion", "") for r in worker("/resources") if r["id"] == resource)

def page(resource, version, section):
    return worker(f"/resource-page?resourceId={resource}&version={version}&section={section}")

if phase == "first":
    assert catalog["projects"] == [] and catalog["resources"] == []
    for path in ("/operations/projects", "/reply-projects"):
        assert worker(path) == []
    initialized = request(7381, "/mcp", {"jsonrpc":"2.0","id":1,"method":"initialize","params":{
        "protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"clean-install-check","version":"1"}}}, mcp=True)
    assert "result" in initialized
    tools = request(7381,"/mcp",{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}},mcp=True)
    names = {r["name"] for r in tools["result"]["tools"]}
    assert {"resource_list","batch_generate","program_run","run_get"} <= names, sorted(names)
    result = request(7381, "/mcp", {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{
        "name":"resource_list","arguments":{}}}, mcp=True)
    assert result["result"]["structuredContent"]["resources"] == [], result
    print("Standard MCP tools discovery and resource_list passed")
    model = request(7382,"/model",{"lane":"batch","method":{"instructions":"Return the fixture marker","maxOutputTokens":80},"input":{}})
    assert model["text"] == "CLEAN-LINUX-MODEL-OK", model
    print("Harness model bridge passed with a local provider fixture")
    worker("/connections",{"id":"install-mysql","name":"Install source","kind":"mysql","secretEnv":"WORKBENCH_SOURCE_INSTALL_MYSQL_DSN"})
    worker("/resources",{"id":"install-library","name":"Install database","kind":"database","connectionId":"install-mysql",
        "relation":"install_fixture","keyField":"id","sections":[{"id":"rows","name":"Rows","fields":["id","title"]}]})
    run = worker("/resource-sync-start",{"operationKey":"clean-install-sync","destination":"install-library"})
    assert run["runId"]
    for _ in range(60):
        version = asset_version("install-library")
        if version:
            break
        time.sleep(1)
    assert version == run["runId"], (version,run,worker("/resource-sync-status?resourceId=install-library"))
    data=page("install-library",version,"rows")
    assert data["count"]==2 and data["records"][0]["fields"]["title"]=="clean-install-marker"
    (root/"state.json").write_text(json.dumps({"session":session,"version":version}))
    print("Real MySQL source sync completed through Temporal and published two records")
else:
    state = json.loads((root/"state.json").read_text())
    assert state["session"]==session
    assert asset_version("install-library")==state["version"]
    assert page("install-library",state["version"],"rows")["count"]==2
    assert any(r.get("id")==state["version"] or r.get("runId")==state["version"] for r in api("/runs")), "recent Temporal run missing after restart"
    print("Worker, Temporal and Harness restart preserved the original session and published run")
