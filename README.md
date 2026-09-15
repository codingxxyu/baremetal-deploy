# Alauda Immutable Infrastructure Bare Metal PoC

> 本 README 是本项目的完整部署文档。

本项目用于从零搭建一套 **Alauda Immutable Infrastructure Bare Metal 部署环境**，包括：

1. Bare Metal Global 集群控制面（Control Plane）；
2. Bare Metal Global 集群 Worker Nodes；
3. Bare Metal Workload 业务集群控制面；
4. Bare Metal Workload 业务集群 Worker Nodes；
5. 平台安装、Global handoff、验证和临时 Bootstrap 退役。

---

## 1. 先确认项目边界

### 1.1 Bare Metal 部署架构

本方案使用 Cluster API、Kubeadm Provider、Bare Metal Provider 和 Elemental 物理机生命周期管理：

```text
传统 Linux Bootstrap Host
  └─ 临时 KIND / minialauda
      ├─ 临时 Registry
      ├─ Cluster API
      ├─ Kubeadm Provider
      ├─ Bare Metal Provider
      └─ Installer
          │
          ├─ MachineRegistration
          ├─ SeedImage
          ├─ MachineInventory
          ├─ MachineInventoryPool
          ├─ BaremetalCluster
          ├─ BaremetalMachineTemplate
          ├─ KubeadmControlPlane
          ├─ KubeadmConfigTemplate
          └─ MachineDeployment

最终 Global Cluster
  └─ 重新安装 Kubeadm/Bare Metal Provider
      └─ 创建和管理 Bare Metal Workload Cluster
```

Bare Metal Provider 不创建或销毁物理服务器。物理服务器通过 ISO 启动并注册为长期存在的 `MachineInventory`，之后通过 `MachineInventoryPool` 分配给 CAPI `Machine`，由 `reprovision` 和 `clean` plan 管理 attach、join、detach 和重装。

### 1.2 交付边界

本 README 只描述 **Alauda Immutable Infrastructure Bare Metal 部署方案**：物理服务器通过 Elemental ISO 注册为 `MachineInventory`，再由 Cluster API 和 Bare Metal Provider 创建 Global/Workload 集群。

本次交付基线为 `linux/amd64`。真实客户密码、Token、BMC 凭证、私钥、kubeconfig、签名 URL 不进入仓库；物理机、数据盘和最终集群不由本项目自动清理。

### 1.3 本次 PoC 固定部署基线

本次部署明确使用 **ACP Core 4.3.2**，并固定使用以下 OS、Kubernetes 和镜像 Tag：

| 项目 | 本次部署值 | 说明 |
|---|---|---|
| CPU 架构 | `amd64` / `linux/amd64` | 当前交付包只支持 x86_64 |
| ACP Core | `v4.3.2` | 本次目标平台版本 |
| Kubernetes | `v1.34.5` | 必须与 OS image catalog key 一致 |
| Alauda OS | `v4.3.2-1-1.34.5-3` | 与本次 Bare Metal OS 镜像配套 |
| Bare Metal OS image Tag | `v4.3.2-1-1.34.5-3` | `base-image` 与 `base-image-iso` 共用 |
| Kubeadm Provider | `v1.0.14` | 以 ACP 4.3.2 交付矩阵最终确认 |
| Bare Metal Provider | `v0.0.0-beta.20.g6ad733a3` | 以 ACP 4.3.2 交付矩阵最终确认 |

本次文档中的镜像 Tag 不再作为待确认变量。仍需在现场确认 Provider chart/package 与 ACP 4.3.2 完全匹配，并记录实际 digest。不能只修改 Kubernetes 版本字段；ACP、Alauda OS、Kubernetes、Provider、镜像和架构必须属于同一验证组合。

---

## 2. 统一参数表

在客户批准的 Linux 管理机上建立参数表。密码、Token、BMC 凭证和私钥不能写入 Git 或普通参数文件。

```bash
export NAMESPACE=cpaas-system
export ARCHITECTURE=amd64
export KUBERNETES_VERSION=v1.34.5
export OS_IMAGE_TAG=v4.3.2-1-1.34.5-3
export TARGET_REGISTRY=registry.customer.example:11443
export BASE_IMAGE=${TARGET_REGISTRY}/tkestack/baremetal-base-image:${OS_IMAGE_TAG}
export BASE_IMAGE_ISO=${TARGET_REGISTRY}/tkestack/baremetal-base-image-iso:${OS_IMAGE_TAG}
export GLOBAL_NAME=global
export WORKLOAD_NAME=workload-poc
export GLOBAL_API_HOST=global-api.customer.example
export WORKLOAD_API_HOST=workload-api.customer.example
export GLOBAL_API_PORT=6443
export WORKLOAD_API_PORT=6443
export PODS_CIDR=100.3.0.0/16
export SERVICES_CIDR=100.4.0.0/16
export KUBE_OVN_JOIN_CIDR=100.5.0.0/16
```

### 参数含义

- `NAMESPACE`：Bare Metal 资源命名空间，固定为 `cpaas-system`；
- `ARCHITECTURE`：当前只能为 `amd64`；ARM64/aarch64/Kunpeng 必须停止；
- `KUBERNETES_VERSION`：必须在 `elemental-image-catalog` 中存在；
- `OS_IMAGE_TAG`：`base-image` 和 `base-image-iso` 的配套 Tag；
- `TARGET_REGISTRY`：最终 Global/Workload 节点访问的 Registry；
- `GLOBAL_API_HOST`/`WORKLOAD_API_HOST`：API 稳定入口，必须和 DNS、LB、证书 SAN 一致；
- 三个 CIDR：不能与物理机网段、管理网、存储网、业务网或同一 Global 上其他 CAPI 集群重叠。

---

## 4. 第 0 步：版本和兼容性冻结

执行部署前取得并归档：

- ACP Core 版本；
- Alauda OS 版本和架构；
- Kubernetes 版本；
- Kubeadm Provider chart/package 版本；
- Bare Metal Provider chart/package 版本；
- 两个 OS 镜像的 Tag 和 digest；
- Provider/Core Package checksum；
- 官方 OS/Provider Support Matrix。

如果客户是 ARM64/Kunpeng：当前项目直接停止，不把 `amd64` 改成 `arm64` 继续执行。必须取得完整 ARM64 OS、Provider、Core、平台组件和兼容矩阵后另行建立交付基线。

---

## 5. 第 1 步：客户基础设施前置条件

### 5.1 Bootstrap Host

准备一台传统 64-bit Linux 机器：

- root 权限；
- Bash；
- Docker 或 containerd；
- KIND、kubectl、curl、jq、nerdctl、gzip、sha256sum；
- 固定 IP；
- 建议至少 8 CPU、16 GB RAM、300 GB 可用空间；
- 能访问客户网络、目标 Registry、物理机和最终 Global API；
- 能为待安装节点提供 Bootstrap Registry。

Bootstrap Host 只运行临时 `minialauda`，不会加入最终 Global Cluster。

### 5.2 物理主机

为 Global CP、Global Worker、Workload CP、Workload Worker 分别准备物理机清单：

- 主机名或 SMBIOS/UUID；
- 管理网络和节点网络；
- 安装盘；
- 是否存在真实 TPM；
- BIOS/UEFI 启动 ISO；
- BMC/控制台访问；
- 硬件时钟；
- 数据盘和 `COS_STATE` 规划。

首次启动 SeedImage ISO 前完成硬件时钟设置。集群节点时间差不得超过 10 秒。无 TPM 的物理机才设置 `emulate-tpm: true` 和 `emulated-tpm-seed: -1`。

安装盘必须明确，不能在多盘主机上盲目使用 `/dev/sda`。清理所有旧的 `COS_STATE`、`COS_PERSISTENT`、`COS_OEM`、`COS_RECOVERY` 标签；需要保留的数据盘不能误擦除。

### 5.3 网络、DNS、NTP、Registry 和 LB

至少准备并放通：

| 流量 | 端口 | 用途 |
|---|---:|---|
| 节点 → 平台 | TCP 443 | 注册和 system-agent |
| 节点 → Registry | TCP 11443 | OS 和平台镜像 |
| 节点 → Global/Workload API | TCP 6443 | kubeadm 和 kubelet |
| CP ↔ CP | TCP 2379/2380 | etcd |
| 节点间 CNI | UDP 6081 | 默认 Kube-OVN Geneve |
| Bootstrap → 平台/IaaS | 按官方文档 | Provider 和 installer |

只开放 443 不足以完成部署。客户还要提供：

- DNS 正向解析；
- 站点 NTP；
- Registry CA；
- Global API LB；
- Workload API LB；
- Internal VIP/VRID 或 External 四层 TCP LB 二选一；
- Pod/Service/Kube-OVN Join CIDR；
- 网关和防火墙流量方向。

---

## 6. 第 2 步：离线导入两个 Bare Metal OS 镜像

必须同时导入两个配套镜像：

- `baremetal-base-image-iso:<tag>`：给 `SeedImage.spec.baseImage`，用于首次 ISO 启动；
- `baremetal-base-image:<tag>`：给 `elemental-image-catalog`，用于 reprovision/升级。

两者必须同版本、同架构、可从目标 Registry pull。离线包当前是 amd64-only。

### 6.1 校验、解压和 load

```bash
sha256sum -c baremetal-os-v4.3.2-1-1.34.5-3-amd64.tar.gz.sha256
gzip -dk baremetal-os-v4.3.2-1-1.34.5-3-amd64.tar.gz
sudo nerdctl --namespace default load \
  -i baremetal-os-v4.3.2-1-1.34.5-3-amd64.tar
sudo nerdctl --namespace default images | grep baremetal-base-image
```

checksum 失败时停止，不继续导入。

### 6.2 Tag、Push、Pull 验证

```bash
sudo nerdctl --namespace default tag \
  build-harbor.alauda.cn/tkestack/baremetal-base-image-iso:${OS_IMAGE_TAG} \
  ${BASE_IMAGE_ISO}

sudo nerdctl --namespace default tag \
  build-harbor.alauda.cn/tkestack/baremetal-base-image:${OS_IMAGE_TAG} \
  ${BASE_IMAGE}

sudo nerdctl --namespace default login "${TARGET_REGISTRY}"
sudo nerdctl --namespace default push "${BASE_IMAGE_ISO}"
sudo nerdctl --namespace default push "${BASE_IMAGE}"
sudo nerdctl --namespace default pull "${BASE_IMAGE_ISO}"
sudo nerdctl --namespace default pull "${BASE_IMAGE}"
```

生产环境优先把 Registry CA 安装到 containerd 信任目录。`--insecure-registry` 只可用于临时验证。最终 YAML 不得引用 `build-harbor.alauda.cn`。

成功标准：目标 Registry 中两个镜像均可 pull，并记录 digest。

---

## 7. 第 3 步：创建临时 Bootstrap 管理集群

在 Bootstrap Host 上执行官方 Core Package 的 `setup.sh`：

```bash
mkdir -p /root/cpaas-install
# tar -xf <core-package> -C /root/cpaas-install
cd /root/cpaas-install/installer
bash setup.sh
cp /var/cpaas/data/alauda.kubeconfig ~/.kube/config
kubectl config current-context
kubectl cluster-info
kubectl get nodes
```

成功标准：

- `minialauda` API 可访问；
- 临时 Registry 正常；
- installer Pod 正常；
- Bootstrap CAPI 基础组件正常；
- 保存 Bootstrap kubeconfig，并与最终 Global kubeconfig 分开。

---

## 8. 第 4 步：在 Bootstrap 上安装 Provider

### 8.1 执行的资源

准备并执行最终版本对应的：

1. Kubeadm Provider AppRelease；
2. Bare Metal Provider umbrella chart/AppRelease（包含 Bare Metal manager 和 `elemental-operator`）。

不要把旧 DCS AppRelease 直接改名为 Bare Metal Provider 资源。

### 8.2 需要修改/确认的参数

| 参数 | 现场值 | 说明 |
|---|---|---|
| chart `targetRevision` | 最终交付包版本 | 不能复制历史版本 |
| `repoURL` | Bootstrap Registry | Provider Pod 拉 chart 的地址 |
| `global.cluster.name` | `global` | 平台 Global 标识 |
| `global.registry.address` | Bootstrap Registry | 仅用于临时 provisioning |
| `global.host/platformUrl` | 客户平台域名 | 必须匹配 DNS/TLS |
| imagePullSecrets | 按 Registry 模式 | 不把密码写进 YAML |

### 8.3 执行和检查

```bash
kubectl apply -f <kubeadm-provider-apprelease.yaml>
kubectl apply -f <baremetal-provider-apprelease.yaml>
kubectl -n cpaas-system get deploy,pods
kubectl get crd | grep -E \
  'baremetal|machineinventory|machineregistration|seedimage|kubeadmcontrolplane'
kubectl -n cpaas-system get configmap elemental-image-catalog -o yaml
```

成功标准：Provider controllers Running、CRD Established、image catalog 存在且有目标 Kubernetes 版本 key。

---

## 9. 第 5 步：创建 Bare Metal Global 控制面

Global CP 和 Global Worker 使用不同的物理机、Inventory、Pool 和 MachineDeployment。

### 9.1 创建 Global CP Registration 和 SeedImage

使用版本确认后的 `MachineRegistration`/`SeedImage` YAML。以下字段必须替换：

| YAML 字段 | 替换为 | 含义 |
|---|---|---|
| `metadata.name` | `global-registration` | Global CP 注册资源名 |
| `metadata.namespace` | `cpaas-system` | 固定命名空间 |
| `spec.config.elemental.install.device` | 客户稳定安装盘 | 不能随意使用 `/dev/sda` |
| `spec.config.elemental.registration.emulate-tpm` | true/false | 依据真实 TPM |
| `spec.baseImage` | `${BASE_IMAGE_ISO}` | 首次 ISO 镜像 |
| `targetPlatform` | `linux/amd64` | 当前支持平台 |

执行：

```bash
kubectl apply -f global-machine-registration.yaml
kubectl -n cpaas-system get machineregistration,seedimage
```

将 SeedImage 写入客户物理机的虚拟介质或启动介质。逐台 Global CP 启动 ISO，等待 Inventory：

```bash
kubectl -n cpaas-system get machineinventories.elemental.cattle.io -o wide
kubectl -n cpaas-system describe machineinventory <global-cp-inventory-name>
```

成功标准：每个 Global CP Inventory 为 Available/Ready，网络观察值正确，无 Registration、TPM、磁盘或镜像错误。

### 9.2 创建 Global CP MachineInventoryPool

执行版本确认后的 CP pool YAML，只填 Global CP Inventory：

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: MachineInventoryPool
metadata:
  name: global-control-plane-pool
  namespace: cpaas-system
spec:
  clusterName: global
  inventoryRefs:
    - name: <global-cp-01-inventory>
    - name: <global-cp-02-inventory>
    - name: <global-cp-03-inventory>
```

检查每个 Inventory 只在一个 active pool 中，pool capacity 不小于 KCP replicas，然后执行：

```bash
kubectl apply -f global-cp-pool.yaml
kubectl -n cpaas-system get machineinventorypool
```

### 9.3 创建 Global BaremetalCluster、CP Template、Cluster、KCP

按依赖顺序准备并执行四类 YAML：

1. `global-baremetal-cluster.yaml`：API VIP/LB、端口、Internal/External 模式；
2. `global-cp-machine-template.yaml`：引用 `global-control-plane-pool`；
3. `global-cluster.yaml`：引用 Global `BaremetalCluster` 和 KCP；
4. `global-kubeadm-control-plane.yaml`：replicas、Kubernetes version、bootstrap data、CP template。

必须修改/确认：

- `metadata.name` 和所有 cross-reference 完全一致；
- 所有资源 namespace 为 `cpaas-system`；
- `spec.controlPlaneLoadBalancer.type` 只能是 `Internal` 或 `External`；
- `host/port` 对应客户 Global API VIP/LB 和 6443；
- KCP replicas 不超过 CP pool capacity；
- KCP `spec.version` 与 image catalog、OS image、兼容矩阵一致；
- KCP `machineTemplate.infrastructureRef.name` 与 CP template metadata name 一致。

执行：

```bash
kubectl apply -f global-baremetal-cluster.yaml
kubectl apply -f global-cp-machine-template.yaml
kubectl apply -f global-cluster.yaml
kubectl apply -f global-kubeadm-control-plane.yaml
kubectl -n cpaas-system get \
  cluster,baremetalcluster,kubeadmcontrolplane,machine,baremetalmachine
```

### 9.4 Global CP 成功标准

- `BaremetalCluster` Ready；
- CP Inventory 进入 allocated/reprovisioning；
- CP plans Applied；
- KCP replicas 达标；
- Global API VIP/LB 从 Bootstrap Host 可达；
- Global CP 节点全部 Ready；
- Global kubeconfig 可以访问 API。

---

## 10. 第 6 步：添加 Bare Metal Global Worker Nodes

Global Worker 不是 KCP replicas，必须通过单独的 Worker pool、Worker template、KubeadmConfigTemplate 和 MachineDeployment 创建。

### 10.1 注册 Global Worker

使用 Global Worker 专用 Registration/SeedImage。逐台物理机启动并等待：

```bash
kubectl -n cpaas-system get machineinventories.elemental.cattle.io -o wide
kubectl -n cpaas-system describe machineinventory <global-worker-inventory-name>
```

Worker Inventory 必须 Available，且不属于 Global CP pool。

### 10.2 创建 Global Worker Pool

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: MachineInventoryPool
metadata:
  name: global-worker-pool
  namespace: cpaas-system
spec:
  clusterName: global
  inventoryRefs:
    - name: <global-worker-01-inventory>
    - name: <global-worker-02-inventory>
```

执行：

```bash
kubectl apply -f global-worker-pool.yaml
kubectl -n cpaas-system get machineinventorypool
```

### 10.3 创建 Global Worker Template、Bootstrap Config、Deployment

准备并修改：

1. `global-worker-machine-template.yaml`：`machineInventoryPoolRef.name` 指向 `global-worker-pool`；
2. `global-worker-kubeadm-config-template.yaml`：join configuration、SSH key、版本；
3. `global-worker-machine-deployment.yaml`：`clusterName: global`、replicas、Worker template 引用、bootstrap config 引用、version。

所有 `metadata.name` 和 `infrastructureRef/configRef` 必须一致。Worker replicas 不得超过 Worker pool capacity。

```bash
kubectl apply -f global-worker-machine-template.yaml
kubectl apply -f global-worker-kubeadm-config-template.yaml
kubectl apply -f global-worker-machine-deployment.yaml
kubectl -n cpaas-system get \
  machinedeployment,machine,baremetalmachine
kubectl get nodes -o wide
```

### 10.4 Global Worker 成功标准

- MachineDeployment available replicas 达标；
- 每个 Worker plan Applied；
- Worker `Machine`/`BaremetalMachine` Running；
- Global CP 和 Worker 全部 Ready；
- Worker 能从目标 Registry 拉取系统镜像；
- Global 平台、CNI、Registry 组件可以正常调度。

---

## 11. 第 7 步：安装平台并完成 Global Handoff

Global CP 和 Worker 都 Ready 后，执行最终版本的 ACP installer。保存 installer progress、installer Pod logs、`cpaas-system`、ClusterModule 和节点状态。

之后切换到**最终 Global kubeconfig**：

1. 在 final Global 重新安装 Kubeadm Provider 和 Bare Metal Provider；
2. 等待 manager、`elemental-operator` 和 CRD Ready；
3. 将 Workload 所需 OS 镜像从 Bootstrap Registry 复制至 final Registry；
4. 在 final Global 创建/确认 `elemental-image-catalog`；
5. 确认 Provider、Inventory、Pool、plan 和必要 Secret 已在 final Global；
6. 确认 final Global 不再依赖 Bootstrap Registry；
7. 执行 Bare Metal handoff probe/gate，保存证据。

只有以下条件全部满足，才可以退役 `minialauda`：

- final Global Provider 正常；
- final Registry 可达；
- Global 主机由 final Global endpoint/probe 管理；
- imported resources、plan Secret 和 handoff 状态完整；
- final Global 可以独立创建和管理 Workload。

`KubeadmControlPlane Ready`、installer 成功或 handoff Job Complete 单独都不是退役条件。不要删除最终 `Cluster` 或 `BaremetalCluster`。

---

## 12. 第 8 步：创建 Bare Metal Workload 控制面

此阶段必须使用最终 Global kubeconfig。Workload 名称不能为 `global`。Workload CP 与 Global CP 使用独立的物理机、Inventory 和 pool。

### 12.1 注册 Workload CP

为 Workload CP 创建专用 `MachineRegistration` 和 `SeedImage`，使用 `${BASE_IMAGE_ISO}`。物理机从 ISO 启动后：

```bash
kubectl --kubeconfig <global-kubeconfig> \
  -n cpaas-system get machineregistration,seedimage,machineinventory -o wide
```

等待所有 Workload CP Inventory Available/Ready。

### 12.2 创建 Workload CP Pool

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: MachineInventoryPool
metadata:
  name: workload-poc-control-plane-pool
  namespace: cpaas-system
spec:
  clusterName: workload-poc
  inventoryRefs:
    - name: <workload-cp-01-inventory>
    - name: <workload-cp-02-inventory>
    - name: <workload-cp-03-inventory>
```

修改 `clusterName`、pool name 和 Inventory refs。Workload CP Inventory 不能属于 Global pool。

```bash
kubectl --kubeconfig <global-kubeconfig> apply -f workload-cp-pool.yaml
```

### 12.3 创建 Workload Cluster、BaremetalCluster、CP Template、KCP

按依赖顺序执行：

1. `workload-baremetal-cluster.yaml`：Workload API VIP/LB、端口、LB mode；
2. `workload-cp-machine-template.yaml`：引用 Workload CP pool；
3. `workload-cluster.yaml`：引用 Workload BaremetalCluster；
4. `workload-kcp.yaml`：replicas、version、CP template。

必须修改/确认：

- Workload name 不是 `global`；
- Workload API VIP/LB 已由客户准备；
- Workload CP pool capacity 足够；
- Cluster、BaremetalCluster、KCP、CP template 所有引用一致；
- Workload Pod/Service/Join CIDR 不冲突；
- Kubernetes version 与 Global/OS image catalog 一致。

```bash
kubectl --kubeconfig <global-kubeconfig> apply -f workload-baremetal-cluster.yaml
kubectl --kubeconfig <global-kubeconfig> apply -f workload-cp-machine-template.yaml
kubectl --kubeconfig <global-kubeconfig> apply -f workload-cluster.yaml
kubectl --kubeconfig <global-kubeconfig> apply -f workload-kcp.yaml
kubectl --kubeconfig <global-kubeconfig> -n cpaas-system get \
  cluster,baremetalcluster,kubeadmcontrolplane,machine,baremetalmachine
```

### 12.4 Workload CP 成功标准

- Workload `BaremetalCluster` Ready；
- CP plans Applied；
- KCP replicas 达标；
- Workload API VIP/LB 可达；
- Workload CP Nodes Ready；
- Workload kubeconfig Secret 产生；
- Global 能通过 Workload API 管理它。

---

## 13. 第 9 步：添加 Bare Metal Workload Worker Nodes

Workload Worker 必须独立创建，不能因为 Workload CP Ready 就省略。

### 13.1 注册 Workload Worker

使用 Workload Worker 专用 Registration/SeedImage。启动物理机并等待：

```bash
kubectl --kubeconfig <global-kubeconfig> \
  -n cpaas-system get machineinventory -o wide
```

确认 Worker Inventory 不属于 Global 或 Workload CP pool。

### 13.2 创建 Workload Worker Pool

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: MachineInventoryPool
metadata:
  name: workload-poc-worker-pool
  namespace: cpaas-system
spec:
  clusterName: workload-poc
  inventoryRefs:
    - name: <workload-worker-01-inventory>
    - name: <workload-worker-02-inventory>
```

```bash
kubectl --kubeconfig <global-kubeconfig> apply -f workload-worker-pool.yaml
```

### 13.3 创建 Workload Worker Template、ConfigTemplate、Deployment

修改并执行：

1. `workload-worker-machine-template.yaml`：`machineInventoryPoolRef.name` 指向 Workload Worker pool；
2. `workload-worker-kubeadm-config-template.yaml`：join configuration、SSH key、版本；
3. `workload-worker-machine-deployment.yaml`：`clusterName: workload-poc`、replicas、template/config 引用、version。

```bash
kubectl --kubeconfig <global-kubeconfig> \
  apply -f workload-worker-machine-template.yaml
kubectl --kubeconfig <global-kubeconfig> \
  apply -f workload-worker-kubeadm-config-template.yaml
kubectl --kubeconfig <global-kubeconfig> \
  apply -f workload-worker-machine-deployment.yaml
kubectl --kubeconfig <global-kubeconfig> -n cpaas-system get \
  machinedeployment,machine,baremetalmachine
```

### 13.4 Workload Worker 成功标准

```bash
kubectl --kubeconfig <workload-kubeconfig> get nodes -o wide
```

必须满足：

- MachineDeployment desired/available replicas 达标；
- 每个 Worker plan Applied；
- Workload CP 和 Worker 全部 Ready；
- 节点能从 final Registry 拉取 CoreDNS、kube-proxy、Kube-OVN 等镜像；
- Global 可以管理 Workload；
- API、Registry、平台管理端口连通。

---

## 14. 最终验收和证据

### 14.1 Global 集群

```bash
kubectl --kubeconfig <global-kubeconfig> -n cpaas-system get deploy,pods
kubectl --kubeconfig <global-kubeconfig> -n cpaas-system get \
  cluster,baremetalcluster,kubeadmcontrolplane,machine,machinedeployment
kubectl --kubeconfig <global-kubeconfig> get nodes -o wide
```

### 14.2 Workload 集群

```bash
kubectl --kubeconfig <workload-kubeconfig> get nodes -o wide
kubectl --kubeconfig <workload-kubeconfig> get pods -A
```

### 14.3 必须保存的证据

- 版本和架构矩阵；
- 两个 OS 镜像 checksum 和 digest；
- Registry push/pull 结果；
- Provider controller/CRD 状态；
- Registration、SeedImage、Inventory、Pool、plan 状态；
- Global CP/Worker 节点状态；
- Workload CP/Worker 节点状态；
- Global/Workload API 和 LB 检查；
- installer progress 和日志；
- handoff probe/gate；
- 故障、恢复和清理记录。

---

## 15. 常见故障排查

| 症状 | 首查位置 | 常见原因 |
|---|---|---|
| 没有 Inventory | Registration、SeedImage、elemental operator logs | ISO、443、DNS、TPM、TLS |
| 注册成功但安装失败 | 主机 console、Registry、NetworkManager | 11443、安装盘、硬件时钟、残留 COS 标签 |
| `ImageCatalogMiss` | image catalog、BaremetalMachine events | Kubernetes key 缺失；修复后按官方方式重建失败 Machine |
| Pool 无可用容量 | InventoryPool、Inventory labels | 名称/标签错误或 Inventory 已被其他 pool 占用 |
| Global CP 不 Ready | KCP/Machine/BaremetalMachine events | API LB、kubeadm、镜像、时钟、bootstrap data |
| Global Worker 不加入 | MachineDeployment/KubeadmConfigTemplate | 引用名、API 6443、Registry 或 join 配置错误 |
| Workload CP 不 Ready | Workload KCP/BaremetalCluster events | Workload LB、CP pool、CIDR、image catalog 或版本错误 |
| Workload Worker 不加入 | Workload MachineDeployment/events | Worker pool、config/template 引用或 Registry 问题 |
| plan Failed | Inventory status plan、Provider logs | plan Secret、主机、磁盘、网络或权限 |
| handoff 后失败 | final Global Provider/Registry/handoff record | Provider 未重装、仍指向 Bootstrap、Secret 未导入 |

先保存 `kubectl describe`、Events、controller logs、主机日志和镜像 digest，不要盲目删除 Cluster 重试。

---

## 16. Day-2、数据盘和 DR

- `reprovision` 会重建 immutable 系统并清理 kubelet/containerd/etcd/Kubernetes 状态；
- `clean` 释放物理机，但不自动 wipe managed data volume；
- 数据盘跟随长期 `MachineInventory`，不会自动跟随另一台替换物理机；
- Internal LB 使用 alive/keepalived/IPVS/kube-lock；External LB 由客户维护四层 listener 和后端；
- Bare Metal DR 需要共享 etcd encryption 配置、ServiceAccount signing key、split-auth 和 system-agent 权限；
- 没有经过独立验证时，本 PoC 不自动启用 DR；
- 物理机、数据盘、Inventory 和最终 Cluster 清理必须经过客户批准。

---

## 17. 安全要求

禁止提交：

- 密码、Token、BMC 凭证；
- SSH 私钥和 kubeconfig；
- 签名下载 URL；
- 真实 Kubernetes Secret；
- 客户实际 IP、域名和旧环境地址；
- 生成日志和镜像大文件。

Base64 不是加密。Registry 使用客户 CA；脚本和命令不能把密码写进命令行或日志。清理默认采用保守方式，不自动删除物理机和数据盘。

---

## 17. 项目文件说明

README 已包含完整部署步骤；仓库中的其他目录用于辅助部署：

- `config/`：版本和客户参数模板；
- `manifests/templates/`：Bare Metal Kubernetes YAML 模板；
- `scripts/`：preflight、渲染、镜像导入、状态检查和静态验证工具；
- `tests/`：模板结构和静态检查；
- `build/rendered/`：本地渲染产物，默认不提交。

---

## 19. 官方来源

- [Installing the global Cluster](https://docs.alauda.io/immutable-infra/1.0/global/install.html)
- [Bare Metal Provider Installation](https://docs.alauda.io/immutable-infra/1.0/install/bare-metal.html)
- [Creating Clusters on Bare Metal](https://docs.alauda.io/immutable-infra/1.0/create-cluster/bare-metal.html)
- [Bare Metal Provider](https://docs.alauda.io/immutable-infra/1.0/overview/providers/bare-metal.html)
