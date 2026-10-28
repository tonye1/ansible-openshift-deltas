# Locust Distributed Load Testing

Runs a distributed Locust test with the **master on the bastion** (`<bastion-host>`)
and **workers as Pods inside OpenShift**.

```
  Bastion <bastion-host>
  ┌──────────────────────────────┐
  │  locust --master             │  ← web UI on :8089
  │  binds 0.0.0.0:5557          │  ← workers connect here
  └──────────────┬───────────────┘
                 │ TCP 5557
        ┌────────▼────────┐
        │  OpenShift       │
        │  locust-worker   │  (3 replicas, scales up/down)
        │  Pods            │
        └─────────────────┘
```

## Prerequisites

- Podman (or Docker) on the bastion
- `oc` CLI logged in to the cluster
- Firewall on the bastion allows inbound **TCP 5557** from the cluster nodes

## Files

| File | Purpose |
|------|---------|
| `locustfile.py` | Your test script — edit this |
| `run-master.sh` | Start the master container on the bastion |
| `podman-compose.yaml` | Alternative: start master via podman-compose |
| `namespace.yaml` | OpenShift Namespace for locust resources |
| `configmap.yaml` | Mounts `locustfile.py` into worker Pods |
| `worker-deployment.yaml` | Worker Deployment (3 replicas by default) |

## Quick Start

### 1 — Edit your test script

Edit [`locustfile.py`](locustfile.py) to match your target application.

### 2 — Open firewall port on the bastion

```bash
# firewalld
sudo firewall-cmd --permanent --add-port=5557/tcp
sudo firewall-cmd --reload
```

### 3 — Start the master on the bastion

```bash
cd locust/
# set the URL of the app you want to load-test
export TARGET_HOST=http://my-app.apps.cluster.example.com
bash run-master.sh
```

The web UI is available at **http://<bastion-host>:8089**.

### 4 — Deploy workers to OpenShift

Update the `locustfile.py` inside `configmap.yaml` if you made changes, then:

```bash
oc apply -f locust/namespace.yaml
oc apply -f locust/configmap.yaml
oc apply -f locust/worker-deployment.yaml
```

Verify workers have connected — the master UI header will show
**"X workers connected"**.

### 5 — Scale workers up or down

```bash
oc scale deployment locust-worker -n locust --replicas=10
```

### 6 — Start the test

Open **http://<bastion-host>:8089**, fill in the number of users and spawn rate,
then click **Start**.

## Updating the locustfile

Edit `locustfile.py`, re-apply the ConfigMap, and restart the workers:

```bash
oc apply -f locust/configmap.yaml
oc rollout restart deployment/locust-worker -n locust
```

## Teardown

```bash
# Stop master
podman stop locust-master

# Remove OpenShift resources
oc delete namespace locust
```
