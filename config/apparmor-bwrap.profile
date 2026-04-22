# jailed: apparmor-bwrap-profile
# Narrow AppArmor profile allowing /usr/bin/bwrap to create unprivileged
# user namespaces on kernels where
# kernel.apparmor_restrict_unprivileged_userns=1 (Ubuntu 24.04+).
# Scoped to bwrap only — every other binary stays restricted.
abi <abi/4.0>,
include <tunables/global>
profile bwrap @BWRAP_PATH@ flags=(unconfined) {
  userns,
}
