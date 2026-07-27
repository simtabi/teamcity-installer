# Change the port

Move the TeamCity web UI to a different host port.

The port is `TC_PORT` in `stack/.env`. Either edit it and restart, or use **Reconfigure** in the
menu, which validates the new port as you type.

```sh
$EDITOR stack/.env     # TC_PORT='8112'
./tc restart
```

The port must be 1024 or above — TeamCity runs as uid 1000 inside the container and cannot bind
privileged ports — and must not be taken by another container or a host process. A port your own
stack is already publishing is not treated as a conflict, so restarts work normally.

If the port is unavailable the restart stops before changing anything:

```
error  Port 8112 is already published by container 'something-else'.
error  stack/.env failed validation; refusing to render a broken stack.
```

Agents are unaffected. They reach the server at `http://server:8111` on the stack network, which is
independent of the published port.

---

[← Docs index](../../README.md#documentation)
