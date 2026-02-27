we want to document steps for macos and linux!

  Next steps (manual, require OrbStack):
  1. ./install.sh — symlink commands into PATH
  2. sandbox-setup — create VM, install Incus, build golden images
  3. sandbox-create my-project git@github.com:you/repo.git --stack base — create first
  sandbox
  4. sandbox my-project --claude — launch Claude in the sandbox


Egress filtering allows all HTTPS traffic. Agents can reach any HTTPS endpoint (npm registry, PyPI, crates.io, but also arbitrary APIs). Content inspection is not performed.
- could we restrict, if we want, to a list of preapproved domains?
