# Manifest map

The phase directories are the names used by the deployment README. `templates/` contains parameterized source material only.

- `bootstrap/`: provider AppRelease placeholders (must be replaced by ACP 4.3.2 delivery YAML) and image catalog.
- `global/`: Global CP registration/SeedImage, CP pool, BaremetalCluster, CP machine template, Cluster, KCP, then Worker registration/pool/template/config/MachineDeployment.
- `workload/`: same resource sequence for the Workload cluster, applied from final Global kubeconfig.

`MachineRegistration` and `SeedImage` are separate Kubernetes kinds but are intentionally combined in each role registration YAML. `MachineInventory` objects are created by Elemental after physical servers boot the SeedImage; they are observed and then named in the pool YAML.

All provider-specific YAML must be checked against the ACP 4.3.2 CRDs before apply.
