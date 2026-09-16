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
# setup.sh creates this platform-owned registry on the Bootstrap Host.
export BOOTSTRAP_REGISTRY=192.0.2.10:11443
export BASE_IMAGE=${BOOTSTRAP_REGISTRY}/tkestack/baremetal-base-image:${OS_IMAGE_TAG}
export BASE_IMAGE_ISO=${BOOTSTRAP_REGISTRY}/tkestack/baremetal-base-image-iso:${OS_IMAGE_TAG}
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
- `BOOTSTRAP_REGISTRY`：由 Bootstrap `setup.sh` 创建的平台自建 Registry，物理节点 provisioning 阶段从这里拉取镜像；
- `GLOBAL_API_HOST`/`WORKLOAD_API_HOST`：API 稳定入口，必须和 DNS、LB、证书 SAN 一致；
- 三个 CIDR：不能与物理机网段、管理网、存储网、业务网或同一 Global 上其他 CAPI 集群重叠。

---

## 3. 第 0 步：版本和兼容性冻结

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

## 4. 第 1 步：客户基础设施前置条件

### 5.1 Bootstrap Host

准备一台传统 64-bit Linux 机器：

- root 权限；
- Bash；
- Docker 或 containerd；
- KIND、kubectl、curl、jq、nerdctl、gzip、sha256sum；
- 固定 IP；
- 建议至少 8 CPU、16 GB RAM、300 GB 可用空间；
- 能访问客户网络、物理机和最终 Global API；
- `setup.sh` 启动的平台自建 Bootstrap Registry 能被待安装节点访问；
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

磁盘规划必须在创建 Registration/SeedImage 之前完成，详见第 20 节；不要先启动物理机再临时决定安装盘或数据盘。

安装盘必须明确，不能在多盘主机上盲目使用 `/dev/sda`。清理所有旧的 `COS_STATE`、`COS_PERSISTENT`、`COS_OEM`、`COS_RECOVERY` 标签；需要保留的数据盘不能误擦除。

### 5.3 网络、DNS、NTP、平台自建 Registry 和 LB

默认不使用客户已有镜像仓库。平台 Registry 的生命周期分为两个阶段：

1. **Bootstrap 阶段**：在 Bootstrap Host 执行 `setup.sh`，由平台创建临时 Bootstrap Registry；Global 节点首次安装和 Provider 包使用该 Registry；
2. **Handoff 后**：平台在最终 Global 上接管并提供最终 Registry。后续 Workload 节点使用最终 Global 的平台 Registry，不需要客户另建 Registry。

因此，部署前只需要确认 Bootstrap Host 的 Registry 地址可以被待安装节点访问，以及平台后续使用的 Registry 端口和 TLS/认证策略。客户可以提供网络连通和 CA 信任，但不需要提供客户自建镜像仓库。

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

## 5. 第 2 步：创建 Bootstrap，再把镜像推入平台 Registry

> 顺序很重要：先执行第 3 步的 Bootstrap `setup.sh`，确认平台自建 Bootstrap Registry 已启动；再回到本节执行镜像导入和 push。不能在 Bootstrap Registry 尚未创建时，把镜像推送到一个假定的客户 Registry。

必须同时导入两个配套镜像：

- `baremetal-base-image-iso:<tag>`：给 `SeedImage.spec.baseImage`，用于首次 ISO 启动；
- `baremetal-base-image:<tag>`：给 `elemental-image-catalog`，用于 reprovision/升级。

两者必须同版本、同架构，并最终能从平台自建 Bootstrap Registry pull。离线包当前是 amd64-only。此处的 Registry 地址使用 `BOOTSTRAP_REGISTRY`，不是客户自建 Registry。

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

先确认第 7 节的 `setup.sh` 已完成，并取得平台实际创建的 Bootstrap Registry 地址。如果平台 Registry 使用认证，按现场生成的 Registry Secret/凭证登录；不把凭证写入本文档。

```bash
# BOOTSTRAP_REGISTRY 必须是 setup.sh 创建的平台 Registry 的可达地址。
# 例如：<bootstrap-host-ip>:11443
export BOOTSTRAP_REGISTRY=192.0.2.10:11443
export BASE_IMAGE=${BOOTSTRAP_REGISTRY}/tkestack/baremetal-base-image:${OS_IMAGE_TAG}
export BASE_IMAGE_ISO=${BOOTSTRAP_REGISTRY}/tkestack/baremetal-base-image-iso:${OS_IMAGE_TAG}

sudo nerdctl --namespace default tag \
  build-harbor.alauda.cn/tkestack/baremetal-base-image-iso:${OS_IMAGE_TAG} \
  ${BASE_IMAGE_ISO}

sudo nerdctl --namespace default tag \
  build-harbor.alauda.cn/tkestack/baremetal-base-image:${OS_IMAGE_TAG} \
  ${BASE_IMAGE}

# 只有平台 Registry 启用认证时才执行交互式 login。
sudo nerdctl --namespace default login "${BOOTSTRAP_REGISTRY}"
sudo nerdctl --namespace default push "${BASE_IMAGE_ISO}"
sudo nerdctl --namespace default push "${BASE_IMAGE}"
sudo nerdctl --namespace default pull "${BASE_IMAGE_ISO}"
sudo nerdctl --namespace default pull "${BASE_IMAGE}"
```

生产环境优先把平台 Registry CA 安装到 containerd 信任目录。`--insecure-registry` 只可用于临时验证。最终 YAML 不得引用 `build-harbor.alauda.cn`；该地址只能作为离线包 load 后的原始镜像名。

成功标准：平台自建 Bootstrap Registry 中两个镜像均可 pull，并记录 digest。

---

## 6. 第 3 步：创建临时 Bootstrap 管理集群

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

## 7. 第 4 步：在 Bootstrap 上安装 Provider

### 8.1 执行的资源

准备并执行最终版本对应的：

1. Kubeadm Provider AppRelease；
2. Bare Metal Provider umbrella chart/AppRelease（包含 Bare Metal manager 和 `elemental-operator`）。

本仓库不伪造 ACP 4.3.2 的 AppRelease schema。`manifests/bootstrap/00-kubeadm-provider-apprelease.yaml` 和 `01-baremetal-provider-apprelease.yaml` 是待由 ACP 4.3.2 正式交付包替换的占位文件，不能直接 apply；官方 AppRelease YAML 替换后才执行。镜像目录对应 `manifests/bootstrap/02-image-catalog.yaml`。

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
# Apply the ACP 4.3.2 release-matched AppRelease YAML supplied with the delivery package.
# Do not invent or copy fields from another release:
kubectl apply -f <acp-4.3.2-kubeadm-provider-apprelease.yaml>
kubectl apply -f <acp-4.3.2-baremetal-provider-apprelease.yaml>
# Then apply the repository image catalog after its registry/version values are rendered:
kubectl apply -f manifests/bootstrap/02-image-catalog.yaml
kubectl -n cpaas-system get deploy,pods
kubectl get crd | grep -E \
  'baremetal|machineinventory|machineregistration|seedimage|kubeadmcontrolplane'
kubectl -n cpaas-system get configmap elemental-image-catalog -o yaml
```

成功标准：Provider controllers Running、CRD Established、image catalog 对象存在。目标 Kubernetes 版本的映射在下一节确认。

### 8.4 镜像导入后的 Image Catalog 配置（现有传统 OS Global 场景必做）

如果 Global Cluster 已经通过传统 OS 方式部署完成，本次只创建 Bare Metal Workload，则不重新创建 Bootstrap Global，也不执行 Global CP/Worker 的 Bare Metal 部署。此时应在现有 Global 上完成以下配置：

1. 将 `base-image-iso` 和 `base-image` 推送到现有 Global 平台 Registry；
2. 确认 `elemental-image-catalog` ConfigMap 已由 Bare Metal Provider 创建；
3. 使用 merge patch 增加 `Kubernetes version → base-image` 映射；
4. 保留 ConfigMap 中已有的其他版本，不要整体替换；
5. 确认映射完成后，再创建 Workload 的 `MachineRegistration`、`SeedImage` 和 `Machine`。

本次 ACP 4.3.2 基线对应：

```bash
export GLOBAL_KUBECONFIG=/secure/path/global-kubeconfig
export GLOBAL_REGISTRY=<existing-global-registry-address>
export KUBERNETES_VERSION=v1.34.5
export OS_IMAGE_TAG=v4.3.2-1-1.34.5-3
export BASE_IMAGE=${GLOBAL_REGISTRY}/tkestack/baremetal-base-image:${OS_IMAGE_TAG}
export BASE_IMAGE_ISO=${GLOBAL_REGISTRY}/tkestack/baremetal-base-image-iso:${OS_IMAGE_TAG}
```

Global Registry 地址应从现有 Global 配置获取，不要猜测。例如：

```bash
kubectl --kubeconfig "${GLOBAL_KUBECONFIG}" \\
  -n cpaas-system get cluster global \\
  -o jsonpath='{.metadata.annotations.cpaas\\.io/registry-address}'
```

如果 Registry 需要认证，admin 密码通常来自现有 Global 的 `registry-admin` Secret。不要把密码写入命令文件或 YAML：

```bash
export GLOBAL_REGISTRY_PASSWORD="$({
  kubectl --kubeconfig "${GLOBAL_KUBECONFIG}" \\
    -n cpaas-system get secret registry-admin \\
    -o jsonpath='{.data.password}' | base64 -d
})"
```

确认两个镜像已 push 到 `${GLOBAL_REGISTRY}` 后，读取当前 Image Catalog：

```bash
kubectl --kubeconfig "${GLOBAL_KUBECONFIG}" \\
  -n cpaas-system get configmap elemental-image-catalog -o yaml
```

使用 **merge patch** 增加目标版本映射，不要覆盖已有 `data`：

```bash
kubectl --kubeconfig "${GLOBAL_KUBECONFIG}" \\
  -n cpaas-system patch configmap elemental-image-catalog \\
  --type merge \\
  -p "{\\"data\\":{\\"${KUBERNETES_VERSION}\\":\\"${BASE_IMAGE}\\"}}"
```

验证：

```bash
kubectl --kubeconfig "${GLOBAL_KUBECONFIG}" \\
  -n cpaas-system get configmap elemental-image-catalog -o yaml

kubectl --kubeconfig "${GLOBAL_KUBECONFIG}" \\
  -n cpaas-system get configmap elemental-image-catalog \\
  -o jsonpath="{.data.${KUBERNETES_VERSION}}"
```

期望结果是：

```text
<existing-global-registry>/tkestack/baremetal-base-image:v4.3.2-1-1.34.5-3
```

`elemental-image-catalog` 使用 `base-image`，不能写入 `base-image-iso`。`SeedImage.spec.baseImage` 才使用 `base-image-iso`。如果 `v1.34.5` 缺失，Bare Metal Provider 后续会出现 `ImageCatalogMiss`，相关 `BaremetalMachine` 可能进入 `Failed`；不要等到创建 Workload Machine 后才补这个映射。

对于本仓库的完整 Bare Metal Global 从零部署路径，`manifests/bootstrap/02-image-catalog.yaml` 是模板；对于已经存在的传统 OS Global，优先使用上面的 merge patch 保留现有 ConfigMap 内容。

---

## 8. 第 5 步：创建 Bare Metal Global 控制面

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

对应 YAML 片段（文件中还包含 SeedImage 的完整 registrationRef、cloud-config 和 COS_STATE 配置）：

```yaml
spec:
  config:
    elemental:
      install:
        device: /dev/elemental-install-target
      registration:
        emulate-tpm: true
  # SeedImage document
  baseImage: <global-registry>/tkestack/baremetal-base-image-iso:v4.3.2-1-1.34.5-3
  cloud-config:
    stages:
      boot:
        - name: "Size COS_STATE for reprovisioning"
          files:
            - path: /etc/elemental/config.d/partitions.yaml
              permissions: 0644
              content: |
                install:
                  partitions:
                    state:
                      size: 20480
```

需要修改：`device`、TPM 参数、Registry 地址和 role-specific `metadata.name`；不要修改 SMBIOS `${System Information/...}` 表达式。

执行：

```bash
kubectl apply -f manifests/global/10-control-plane-registration.yaml
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
    - name: <actual-inventory-name-1>
    - name: <actual-inventory-name-2>
    - name: <actual-inventory-name-3>
```

需要修改：只替换 `inventoryRefs[].name`，使用物理机启动 ISO 后实际生成的 `MachineInventory.metadata.name`；不要使用预估主机名，不要把 Worker Inventory 放进 CP pool。

检查每个 Inventory 只在一个 active pool 中，pool capacity 不小于 KCP replicas，然后执行：

```bash
kubectl apply -f manifests/global/11-control-plane-pool.yaml
kubectl -n cpaas-system get machineinventorypool
```

### 9.3 创建 Global BaremetalCluster、CP Template、Cluster、KCP

按依赖顺序准备并执行四类 YAML：

1. `manifests/global/12-baremetal-cluster.yaml`：API VIP/LB、端口、Internal/External 模式；
2. `manifests/global/13-control-plane-machine-template.yaml`：引用 `global-control-plane-pool`；
3. `manifests/global/14-cluster.yaml`：引用 Global `BaremetalCluster` 和 KCP；
4. `manifests/global/15-control-plane.yaml`：replicas、Kubernetes version、bootstrap data、CP template。

必须修改/确认：

- `metadata.name` 和所有 cross-reference 完全一致；
- 所有资源 namespace 为 `cpaas-system`；
- `spec.controlPlaneLoadBalancer.type` 只能是 `Internal` 或 `External`；
- `host/port` 对应客户 Global API VIP/LB 和 6443；
- KCP replicas 不超过 CP pool capacity；
- KCP `spec.version` 与 image catalog、OS image、兼容矩阵一致；
- KCP `machineTemplate.infrastructureRef.name` 与 CP template metadata name 一致。

关键 YAML 片段（完整资源在上述四个文件中）：

```yaml
# BaremetalCluster: manifests/global/12-baremetal-cluster.yaml
spec:
  controlPlaneLoadBalancer:
    type: External
    host: <global-api-vip-or-fqdn>
    port: 6443

# BaremetalMachineTemplate: manifests/global/13-control-plane-machine-template.yaml
spec:
  template:
    spec:
      machineInventoryPoolRef:
        name: global-control-plane-pool
      allocationPolicy: Ordered

# KubeadmControlPlane: manifests/global/15-control-plane.yaml
spec:
  replicas: 3
  version: v1.34.5
  machineTemplate:
    infrastructureRef:
      kind: BaremetalMachineTemplate
      name: global-control-plane-machine-template
```

需要修改：Global API endpoint/LB mode、replicas、Kubernetes version 和引用名；Internal VIP 模式还要按 ACP 4.3.2 CRD 增加 VRID 等字段，不能直接沿用 External 示例。

执行：

```bash
kubectl apply -f manifests/global/12-baremetal-cluster.yaml
kubectl apply -f manifests/global/13-control-plane-machine-template.yaml
kubectl apply -f manifests/global/14-cluster.yaml
kubectl apply -f manifests/global/15-control-plane.yaml
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

## 9. 第 6 步：添加 Bare Metal Global Worker Nodes

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
kubectl apply -f manifests/global/21-worker-pool.yaml
kubectl -n cpaas-system get machineinventorypool
```

### 10.3 创建 Global Worker Template、Bootstrap Config、Deployment

准备并修改：

1. `manifests/global/22-worker-machine-template.yaml`：`machineInventoryPoolRef.name` 指向 `global-worker-pool`；
2. `manifests/global/23-worker-kubeadm-config-template.yaml`：join configuration、SSH key、版本；
3. `manifests/global/24-worker-machine-deployment.yaml`：`clusterName: global`、replicas、Worker template 引用、bootstrap config 引用、version。

所有 `metadata.name` 和 `infrastructureRef/configRef` 必须一致。Worker replicas 不得超过 Worker pool capacity。

关键 YAML 片段：

```yaml
# Worker BaremetalMachineTemplate
spec:
  template:
    spec:
      machineInventoryPoolRef:
        name: global-worker-pool

# Worker MachineDeployment
spec:
  clusterName: global
  replicas: 3
  template:
    spec:
      version: v1.34.5
      bootstrap:
        configRef:
          kind: KubeadmConfigTemplate
          name: global-worker-kubeadm-config
      infrastructureRef:
        kind: BaremetalMachineTemplate
        name: global-worker-machine-template
```

需要修改：Worker pool 的真实 Inventory 名、Deployment replicas、KubeadmConfigTemplate 的 join/SSH 配置和所有引用名；不要把 `PROVIDER_ID` 留在最终文件中。

```bash
kubectl apply -f manifests/global/22-worker-machine-template.yaml
kubectl apply -f manifests/global/23-worker-kubeadm-config-template.yaml
kubectl apply -f manifests/global/24-worker-machine-deployment.yaml
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

## 10. 第 7 步：安装平台并完成 Global Handoff

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

## 11. 第 8 步：创建 Bare Metal Workload 控制面

此阶段必须使用最终 Global kubeconfig。Workload 名称不能为 `global`。Workload CP 与 Global CP 使用独立的物理机、Inventory 和 pool。

### 12.1 注册 Workload CP

为 Workload CP 创建专用 `MachineRegistration` 和 `SeedImage`，使用 `${BASE_IMAGE_ISO}`。物理机从 ISO 启动后：

```bash
kubectl --kubeconfig <global-kubeconfig> \
  -n cpaas-system get machineregistration,seedimage,machineinventory -o wide
```

等待所有 Workload CP Inventory Available/Ready。

对应文件 `manifests/workload/10-control-plane-registration.yaml` 的关键片段：

```yaml
# MachineRegistration
metadata:
  name: workload-poc-control-plane-registration
spec:
  machineName: "workload-poc-control-plane-${System Information/UUID}"
  config:
    elemental:
      install:
        device: <stable-install-device>
      registration:
        emulate-tpm: true

# SeedImage
metadata:
  name: workload-poc-control-plane-registration-iso
spec:
  baseImage: <global-registry>/tkestack/baremetal-base-image-iso:v4.3.2-1-1.34.5-3
  registrationRef:
    name: workload-poc-control-plane-registration
  cloud-config:
    stages:
      boot:
        - files:
            - path: /etc/elemental/config.d/partitions.yaml
              content: |
                install:
                  partitions:
                    state:
                      size: 20480
```

需要修改：`metadata.name` 前缀、安装盘、TPM 决策、Global Registry 地址；保留 SMBIOS 表达式和 `registrationRef` 的精确引用。完整 YAML 在该文件中。apply 后先等待 `SeedImageReady=True`，再让物理 CP 从生成的 ISO 启动；详见第 20–22 节门禁。

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
kubectl --kubeconfig <global-kubeconfig> apply -f manifests/workload/11-control-plane-pool.yaml
```

### 12.3 创建 Workload Cluster、BaremetalCluster、CP Template、KCP

按依赖顺序执行：

1. `manifests/workload/12-baremetal-cluster.yaml`：Workload API VIP/LB、端口、LB mode；
2. `manifests/workload/13-control-plane-machine-template.yaml`：引用 Workload CP pool；
3. `manifests/workload/14-cluster.yaml`：引用 Workload BaremetalCluster；
4. `manifests/workload/15-control-plane.yaml`：replicas、version、CP template。

必须修改/确认：

- Workload name 不是 `global`；
- Workload API VIP/LB 已由客户准备；
- Workload CP pool capacity 足够；
- Cluster、BaremetalCluster、KCP、CP template 所有引用一致；
- Workload Pod/Service/Join CIDR 不冲突；
- Kubernetes version 与 Global/OS image catalog 一致。

关键 YAML 片段（完整资源在本节列出的四个文件中）：

```yaml
# manifests/workload/12-baremetal-cluster.yaml
spec:
  controlPlaneLoadBalancer:
    type: External
    host: <workload-api-vip-or-fqdn>
    port: 6443

# manifests/workload/13-control-plane-machine-template.yaml
spec:
  template:
    spec:
      machineInventoryPoolRef:
        name: workload-poc-control-plane-pool

# manifests/workload/14-cluster.yaml
spec:
  infrastructureRef:
    kind: BaremetalCluster
    name: workload-poc
  controlPlaneRef:
    kind: KubeadmControlPlane
    name: workload-poc-control-plane

# manifests/workload/15-control-plane.yaml
spec:
  replicas: 3
  version: v1.34.5
  machineTemplate:
    infrastructureRef:
      name: workload-poc-control-plane-machine-template
```

需要修改：Workload API endpoint/LB 模式、真实 cluster name、CP pool 名称、replicas、Pod/Service CIDR、Kubernetes version 和所有 cross-reference；不要把 Global 的 endpoint 或 CIDR 原样复制过来。

```bash
kubectl --kubeconfig <global-kubeconfig> apply -f manifests/workload/12-baremetal-cluster.yaml
kubectl --kubeconfig <global-kubeconfig> apply -f manifests/workload/13-control-plane-machine-template.yaml
kubectl --kubeconfig <global-kubeconfig> apply -f manifests/workload/14-cluster.yaml
kubectl --kubeconfig <global-kubeconfig> apply -f manifests/workload/15-control-plane.yaml
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

## 12. 第 9 步：添加 Bare Metal Workload Worker Nodes

Workload Worker 必须独立创建，不能因为 Workload CP Ready 就省略。

### 13.1 注册 Workload Worker

使用 Workload Worker 专用 Registration/SeedImage。启动物理机并等待：

```bash
kubectl --kubeconfig <global-kubeconfig> \
  -n cpaas-system get machineinventory -o wide
```

确认 Worker Inventory 不属于 Global 或 Workload CP pool。

对应 `manifests/workload/20-worker-registration.yaml` 的关键片段：

```yaml
# MachineRegistration
metadata:
  name: workload-poc-worker-registration
spec:
  machineName: "workload-poc-worker-${System Information/UUID}"
  config:
    elemental:
      install:
        device: <stable-install-device>
      registration:
        emulate-tpm: true

# SeedImage
metadata:
  name: workload-poc-worker-registration-iso
spec:
  baseImage: <global-registry>/tkestack/baremetal-base-image-iso:v4.3.2-1-1.34.5-3
  registrationRef:
    name: workload-poc-worker-registration
  cloud-config:
    stages:
      boot:
        - files:
            - path: /etc/elemental/config.d/partitions.yaml
              content: |
                install:
                  partitions:
                    state:
                      size: 20480
```

需要修改：Worker 专用资源名、安装盘、TPM、Global Registry 地址；保持 Worker 与 CP 的 Registration/SeedImage 名称不同。apply 后等待 `SeedImageReady=True`，再启动 Worker 物理机。

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
kubectl --kubeconfig <global-kubeconfig> apply -f manifests/workload/21-worker-pool.yaml
```

### 13.3 创建 Workload Worker Template、ConfigTemplate、Deployment

修改并执行：

1. `manifests/workload/22-worker-machine-template.yaml`：`machineInventoryPoolRef.name` 指向 Workload Worker pool；
2. `manifests/workload/23-worker-kubeadm-config-template.yaml`：join configuration、SSH key、版本；
3. `manifests/workload/24-worker-machine-deployment.yaml`：`clusterName: workload-poc`、replicas、template/config 引用、version。

关键 YAML 片段：

```yaml
# Worker BaremetalMachineTemplate
spec:
  template:
    spec:
      machineInventoryPoolRef:
        name: workload-poc-worker-pool

# Worker KubeadmConfigTemplate
spec:
  template:
    spec:
      format: cloud-config
      joinConfiguration:
        nodeRegistration:
          kubeletExtraArgs:
            provider-id: <ACP-4.3.2-provider-supported-value>

# Worker MachineDeployment
spec:
  clusterName: workload-poc
  replicas: 3
  template:
    spec:
      version: v1.34.5
      bootstrap:
        configRef:
          name: workload-poc-worker-kubeadm-config
      infrastructureRef:
        name: workload-poc-worker-machine-template
```

需要修改：Worker pool 的真实 Inventory 名、replicas、版本、join 配置和引用名；`provider-id` 必须按 ACP 4.3.2 官方 Bare Metal 示例确认，不能保留 `PROVIDER_ID` 字面值。

```bash
kubectl --kubeconfig <global-kubeconfig> \
  apply -f manifests/workload/22-worker-machine-template.yaml
kubectl --kubeconfig <global-kubeconfig> \
  apply -f manifests/workload/23-worker-kubeadm-config-template.yaml
kubectl --kubeconfig <global-kubeconfig> \
  apply -f manifests/workload/24-worker-machine-deployment.yaml
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

## 13. 最终验收和证据

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

## 14. 常见故障排查

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

## 15. Day-2、数据盘和 DR

- `reprovision` 会重建 immutable 系统并清理 kubelet/containerd/etcd/Kubernetes 状态；
- `clean` 释放物理机，但不自动 wipe managed data volume；
- 数据盘跟随长期 `MachineInventory`，不会自动跟随另一台替换物理机；
- Internal LB 使用 alive/keepalived/IPVS/kube-lock；External LB 由客户维护四层 listener 和后端；
- Bare Metal DR 需要共享 etcd encryption 配置、ServiceAccount signing key、split-auth 和 system-agent 权限；
- 没有经过独立验证时，本 PoC 不自动启用 DR；
- 物理机、数据盘、Inventory 和最终 Cluster 清理必须经过客户批准。

---

## 16. 安全要求

禁止提交：

- 密码、Token、BMC 凭证；
- SSH 私钥和 kubeconfig；
- 签名下载 URL；
- 真实 Kubernetes Secret；
- 客户实际 IP、域名和旧环境地址；
- 生成日志和镜像大文件。

Base64 不是加密。Registry 使用客户 CA；脚本和命令不能把密码写进命令行或日志。清理默认采用保守方式，不自动删除物理机和数据盘。

---

## 17. Manifest 文件与部署阶段对应关系

以下是本仓库实际存在的 YAML 文件。README 中的每一步都必须使用这里的路径，不使用未提交的临时文件名。

| 阶段 | 实际文件 | 使用的 kubeconfig | 说明 |
|---|---|---|---|
| Bootstrap Provider | `manifests/bootstrap/00-kubeadm-provider-apprelease.yaml` | `minialauda` | ACP 4.3.2 交付包提供的 Kubeadm AppRelease；需先放入并按 schema 核对 |
| Bootstrap Provider | `manifests/bootstrap/01-baremetal-provider-apprelease.yaml` | `minialauda` | ACP 4.3.2 交付包提供的 Bare Metal umbrella AppRelease；需先放入并按 schema 核对 |
| Bootstrap image catalog | `manifests/bootstrap/02-image-catalog.yaml` | `minialauda` | `base-image` 的 Kubernetes version → image 映射；ISO 不放在 catalog |
| Global CP registration | `manifests/global/10-control-plane-registration.yaml` | `minialauda` | 同一 YAML 包含 Global CP 的 `MachineRegistration` 和 `SeedImage` |
| Global CP pool | `manifests/global/11-control-plane-pool.yaml` | `minialauda` | 只填写 Global CP Inventory |
| Global CP cluster | `manifests/global/12-baremetal-cluster.yaml`, `13-control-plane-machine-template.yaml`, `14-cluster.yaml`, `15-control-plane.yaml` | `minialauda` | 依次创建 BaremetalCluster、CP template、Cluster、KCP |
| Global Worker | `manifests/global/20-worker-registration.yaml`, `21-worker-pool.yaml`, `22-worker-machine-template.yaml`, `23-worker-kubeadm-config-template.yaml`, `24-worker-machine-deployment.yaml` | `minialauda` | 独立 Registration/SeedImage、InventoryPool、template、bootstrap config、MachineDeployment |
| Workload CP | `manifests/workload/10-control-plane-registration.yaml`, `11-control-plane-pool.yaml`, `12-baremetal-cluster.yaml`, `13-control-plane-machine-template.yaml`, `14-cluster.yaml`, `15-control-plane.yaml` | final Global | Workload CP 独立物理机和 pool |
| Workload Worker | `manifests/workload/20-worker-registration.yaml`, `21-worker-pool.yaml`, `22-worker-machine-template.yaml`, `23-worker-kubeadm-config-template.yaml`, `24-worker-machine-deployment.yaml` | final Global | Workload Worker 独立物理机和 pool |

`manifests/templates/` 是这些阶段文件的参数化来源。当前 Bootstrap AppRelease 两个文件和对应 chart values 必须由 ACP 4.3.2 正式交付包提供；没有官方 schema 时不得自行补写 AppRelease 字段。

## 18. 项目文件说明

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

## 20. 物理机磁盘与 SeedImage 详细规划

### 20.1 `MachineRegistration` 与 `SeedImage` 是两个阶段

`MachineRegistration` 描述物理机如何注册以及首次安装参数；`SeedImage` 描述由 Elemental 生成的可启动 ISO。二者通过 `spec.registrationRef` 关联。

实际顺序为：

```text
apply MachineRegistration + SeedImage
  → wait SeedImageReady=True
  → 取得/挂载生成的 ISO
  → 物理机 BIOS/UEFI 从 ISO 启动
  → elemental-register 注册
  → elemental install 写入系统盘
  → MachineInventory 出现
```

检查：

```bash
kubectl --kubeconfig "${GLOBAL_KUBECONFIG}" -n cpaas-system get machineregistration,seedimage
kubectl --kubeconfig "${GLOBAL_KUBECONFIG}" -n cpaas-system wait \
  --for=condition=SeedImageReady=True \
  seedimage/<registration-iso-name> --timeout=30m
```

当前仓库的四个角色文件分别是：

```text
manifests/global/10-control-plane-registration.yaml
manifests/global/20-worker-registration.yaml
manifests/workload/10-control-plane-registration.yaml
manifests/workload/20-worker-registration.yaml
```

每个文件包含两个 YAML 文档：一个 `MachineRegistration`，一个 `SeedImage`。四个角色必须使用不同的资源名、物理主机清单和用途，不能把同一个 registration/ISO 混用。

### 20.2 SMBIOS/UUID 字段不能被普通 envsubst 破坏

以下表达式是 `elemental-register` 在物理机上根据 SMBIOS 数据展开的官方表达式：

```yaml
machineName: "<role-name>-${System Information/UUID}"
elemental.cattle.io/serial-number: "${System Information/Serial Number}"
elemental.cattle.io/machine-uuid: "${System Information/UUID}"
```

它们不是 Bash 环境变量。渲染工具不得把包含空格和 `/` 的表达式当成 shell 变量替换。apply 前检查渲染结果仍保留这些官方表达式；如果 ACP 4.3.2 的 CRD/Elemental 版本规定了不同的表达式，应以该版本官方示例替换。

### 20.3 系统安装盘

在每台物理机启动 ISO 前完成：

1. 识别系统安装盘的稳定 WWN/设备身份；
2. 将该身份写入 `MachineRegistration.spec.config.elemental.install.device`；
3. 确认该盘允许被 `elemental install` 重建；
4. 备份并移除不应保留的旧系统；
5. 确认数据盘没有被选为安装盘；
6. BIOS/UEFI 设置从虚拟 CD/ISO 优先启动。

多盘主机不要直接假设 `/dev/sda` 永远相同。若使用 `/dev/elemental-install-target`，必须先按官方多盘固定系统盘方法配置该稳定目标。

安装盘会被系统安装覆盖。不要把业务数据、需要 Adopt 的文件系统和安装盘混在一起。

### 20.4 COS_STATE 分区

`COS_STATE` 保存运行系统和 Elemental snapshot。它不是业务持久盘。默认容量不足以支撑多次镜像切换或保留 snapshot，因此本 PoC 的 SeedImage cloud-config 示例设置：

```yaml
spec:
  cloud-config:
    stages:
      boot:
        - name: "Size COS_STATE for reprovisioning"
          files:
            - path: /etc/elemental/config.d/partitions.yaml
              permissions: 0644
              content: |
                install:
                  partitions:
                    state:
                      size: 20480
```

`20480` 的单位和最终可用容量必须按目标 ACP 4.3.2/Elemental 版本及现场磁盘容量复核。不能在没有容量评审的情况下无限增大。

### 20.5 数据盘：不要写进 MachineTemplate

Bare Metal 数据盘属于长期 `MachineInventory`，不是 VM disk list，也不是 `BaremetalMachineTemplate` 的任意字段。正式 Provider schema 确认后，在对应 Inventory 上声明 `spec.storage`。每个数据卷至少要有：

- 稳定设备身份/WWN；
- 文件系统类型（XFS/ext4）；
- 挂载路径；
- 生命周期 policy；
- Adopt 或 InitializeIfBlank 决策；
- 数据备份和初始化批准记录。

`Adopt` 适用于已有文件系统和数据的盘：先备份，核对稳定 ID、文件系统 UUID 和挂载路径，严禁误格式化。

`InitializeIfBlank` 只适用于客观为空的可丢弃磁盘，并且必须有单独的初始化批准。registration YAML 本身不应被当作格式化授权。

推荐现场填写：

| 角色 | 主机 | 系统盘 WWN | COS_STATE | 数据盘 WWN | Filesystem | Mount | Policy |
|---|---|---|---:|---|---|---|---|
| Workload CP | cp-01 | | 20 GiB | | | | |
| Workload CP | cp-02 | | 20 GiB | | | | |
| Workload CP | cp-03 | | 20 GiB | | | | |
| Workload Worker | worker-01 | | 20 GiB | | | | |
| Workload Worker | worker-02 | | 20 GiB | | | | |
| Workload Worker | worker-03 | | 20 GiB | | | | |

### 20.6 Workload CP 与 Worker 磁盘差异

- Workload CP：系统盘、COS_STATE，以及按平台/etcd/业务要求确认的数据盘；
- Workload Worker：系统盘、COS_STATE，以及按业务需求确认的数据盘；
- 不要把 DCS VM 的 `/var/lib/kubelet`、`/var/lib/containerd`、`/var/lib/etcd` 磁盘列表直接复制到 Bare Metal；
- Bare Metal 的节点系统状态由 reprovision 清理，业务数据盘由 Inventory storage 生命周期管理；
- 数据盘跟随物理 Inventory，不会自动跟随另一台替换物理机。

### 20.7 物理机启动后的检查

物理机从 ISO 启动后，先不要创建 Pool。先等待并检查：

```bash
kubectl --kubeconfig "${GLOBAL_KUBECONFIG}" -n cpaas-system \
  get machineinventory.elemental.cattle.io -o wide

kubectl --kubeconfig "${GLOBAL_KUBECONFIG}" -n cpaas-system \
  describe machineinventory <inventory-name>
```

确认：

- Inventory 名称已经产生；
- `status.conditions` 表示主机可用；
- observed network 正确；
- observed storage 与现场 worksheet 一致；
- plan Secret 存在；
- 没有 registration、TPM、磁盘、DNS、Registry 错误。

只有在 Inventory 名称和状态确认后，才把真实名称填写到：

```text
manifests/workload/11-control-plane-pool.yaml
manifests/workload/21-worker-pool.yaml
```

## 21. Workload 实际创建门禁

Workload 创建不是“apply 四个 YAML 就完成”。每个门禁必须通过：

1. Image Catalog 已包含 `v1.34.5`；
2. CP/Worker SeedImage 均 `SeedImageReady=True`；
3. 物理机均从正确 ISO 启动；
4. 真实 MachineInventory 已产生并 Available；
5. 系统盘、COS_STATE、数据盘策略已确认；
6. CP/Worker Inventory 没有重复分配；
7. CP pool capacity 不小于 KCP replicas；
8. Worker pool capacity 不小于 MachineDeployment replicas；
9. Workload API External LB 或 Internal VIP 已准备；
10. Workload CP Ready 后，才创建 Worker MachineDeployment。

如果跳过 Image Catalog 或 SeedImage 门禁，常见结果是注册成功但 reprovision 失败、`ImageCatalogMiss`、plan Failed 或节点永远不 Ready。

## 22. 官方状态门禁与存储检查命令

本节补充官方 Bare Metal 创建集群页面中的状态门禁。不能只看资源存在；每个阶段都要检查对应 Condition、Reason 和后续对象。

### 22.1 Provider 安装门禁

在现有 Global 或 Bootstrap 管理集群上确认：

```bash
kubectl -n cpaas-system get deploy,pods
kubectl get crd | grep -E \
  'baremetalclusters|baremetalmachines|baremetalmachinetemplates|machineinventorypools|machineinventories|machineregistrations|seedimages|kubeadmcontrolplanes'
kubectl -n cpaas-system get configmap elemental-image-catalog -o yaml
```

必须看到 Bare Metal manager、`elemental-operator`、Kubeadm controller 正常，并且 `elemental-image-catalog` 存在。Provider 安装完成不等于物理集群已经创建。

### 22.2 SeedImage 门禁

每一个角色的 Registration/SeedImage YAML apply 后，等待：

```bash
kubectl -n cpaas-system wait \
  --for=condition=SeedImageReady=True \
  seedimage/<role-registration-iso> \
  --timeout=30m
```

然后检查完整状态：

```bash
kubectl -n cpaas-system describe seedimage <role-registration-iso>
kubectl -n cpaas-system get seedimage <role-registration-iso> -o yaml
```

成功标准不仅是 Condition，还包括：

- `SeedImageReady=True`；
- Reason 为官方成功原因（例如 `SeedImageBuildSuccess`，以 ACP 4.3.2 实际 CRD 为准）；
- 生成的 download URL/ISO 位置非空；
- checksum URL 或 checksum 信息非空；
- `baseImage` 是目标 Registry 的 `baremetal-base-image-iso:<tag>`；
- ISO 可以被物理机的虚拟 CD/BMC 介质访问。

### 22.3 MachineInventory 门禁

物理机从 ISO 启动后，Elemental 才会创建 Inventory：

```bash
kubectl -n cpaas-system get machineinventories.elemental.cattle.io -o wide
kubectl -n cpaas-system describe machineinventory <actual-inventory-name>
```

不要用预计的主机名代替实际 Inventory 名。只有在以下条件满足后才能写入 Pool：

- Inventory 已创建；
- 对应物理主机和角色确认无误；
- Ready/Available 条件通过；
- observed network 正确；
- plan Secret 存在；
- 没有注册、TPM、DNS、NTP、TLS、Registry 或磁盘错误。

### 22.4 数据盘准备门禁

数据盘属于 `MachineInventory`，不是 `BaremetalMachineTemplate` 的 VM 磁盘列表。使用稳定设备身份（WWN/序列等），不能把 `/dev/sda`、`/dev/nvme0n1` 等运行时路径写入持久声明。

如果现场声明了 managed data volumes，在 Inventory 尚未分配前完成 storage preparation，并检查目标版本实际提供的状态字段。例如按 ACP 4.3.2 CRD/Provider 输出确认：

```bash
kubectl -n cpaas-system describe machineinventory <inventory-name>
kubectl -n cpaas-system get machineinventory <inventory-name> -o yaml
```

需要看到与目标版本对应的：

- `StoragePrepared=True` 或官方等价条件；
- 所有必需卷已准备（例如 `AllRequiredVolumesPrepared` 等官方条件）；
- storage phase 为 `Prepared` 或官方等价状态；
- 后续分配后 volume 为 Active；
- `BaremetalMachine` 的 storage 条件为 Ready（如果该版本提供）。

如果 `spec.storage` 为空，按官方行为应是 Unmanaged/NoManagedVolumes，而不是假设系统已经准备了业务盘。不要凭猜测添加 storage 字段；先用 ACP 4.3.2 CRD 确认字段名和策略。

### 22.5 Pool 门禁

每个角色建立一个 Pool：

```text
Global CP pool
Global Worker pool
Workload CP pool
Workload Worker pool
```

检查：

```bash
kubectl -n cpaas-system get machineinventorypool -o yaml
```

每个 Pool 必须满足：

- `clusterName` 正确；
- `inventoryRefs` 是实际 Inventory 名；
- CP pool capacity 不小于 KCP replicas；
- Worker pool capacity 不小于 MachineDeployment replicas；
- 一个 Inventory 不在两个 active Pool 中；
- Pool Ready、MembersValid、Available 等官方条件通过；
- 被分配 Inventory 的 plan/storage 状态满足 Provider 门禁。

### 22.6 Cluster 和节点门禁

创建 `BaremetalCluster`、CP template、Cluster、KCP 后检查：

```bash
kubectl -n cpaas-system get baremetalcluster,cluster,kubeadmcontrolplane,machine,baremetalmachine
kubectl -n cpaas-system describe kubeadmcontrolplane <cluster>-control-plane
kubectl -n cpaas-system get events --sort-by=.lastTimestamp
```

CP 成功标准：

- `BaremetalCluster` Ready/EndpointReady；
- control-plane endpoint 可达；
- CP plan Applied；
- KCP replicas 达标；
- kubeconfig Secret 生成；
- CP Nodes Ready。

Workload Worker 的 MachineDeployment 只能在 Workload CP Ready 后创建。检查：

```bash
kubectl -n cpaas-system get machinedeployment,machine,baremetalmachine
kubectl --kubeconfig <workload-kubeconfig> get nodes -o wide
```

Worker 成功标准：

- desired/available replicas 达标；
- Worker plans Applied；
- Worker storage 条件满足（如启用 managed data volumes）；
- Workload CP 和 Worker 全部 Ready。

### 22.7 失败定位优先级

- `ImageCatalogMiss`：先查版本 key、base-image 地址和 digest；
- `SeedImage` build 失败：查 Registry、TLS、registrationRef、Operator logs、download/checksum URL；
- Inventory 不出现：查 ISO 启动、DNS、平台 443、TPM、硬件时钟；
- Inventory 出现但 Pool 不可用：查 Ready、plan Secret、storage 状态和重复分配；
- CP endpoint 不通：查 External LB listener/backend/DNS/TLS SAN，或 Internal VIP 的 L2、VRID、VRRP、IPVS/sysctl；
- reprovision 失败：查 `MachineInventory` plan、OS image、安装盘和 cloud-config；
- Worker 不加入：查 KubeadmConfigTemplate、6443、Registry 和 MachineDeployment 引用。
