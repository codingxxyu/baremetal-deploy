# Bootstrap provider resources

The ACP 4.3.2 Core Package and Customer Portal deliver the Kubeadm Provider and Bare Metal Provider umbrella AppRelease/Chart values. The exact AppRelease schema is release-specific and is not fabricated here.

After `setup.sh` creates the platform Bootstrap Registry, obtain the version-matched provider AppRelease YAML from the ACP 4.3.2 delivery package, replace its Registry/chart values with the Bootstrap Registry address, and apply it to `minialauda` before applying any `manifests/global/*` or `manifests/workload/*` resources.

Expected result: Kubeadm controller, Bare Metal manager, elemental-operator, CRDs, and `elemental-image-catalog` are Ready.
