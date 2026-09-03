ReSide Backend Services

Use the launcher at the package root for guided setup.

Manual operation:
1. Run run.bat, run.ps1, or run.sh.
2. Run stop.bat, stop.ps1, or stop.sh to stop all services while preserving data.
3. Visit http://localhost:3000/admin/ locally, or use the LAN URL printed by the package launcher.

The scripts here start the same services as the package-root launcher and detect this host's
game-server address the same way, but they do not add host firewall rules. Use the package-root
launcher, or open TCP 3000, UDP 3002, and the SERVER_MANAGER_PORT_MIN-MAX UDP range yourself,
before remote clients connect.

The included .env contains service credentials and the stable deployment identity. Keep it private.
The package-root startup launcher prints the administrator token when the panel asks for it.
JWT_KEY here already matches the supplied game servers; do not replace it independently in only one
of the .env files, or the API and dedicated servers will no longer validate each other's tokens.
This folder also includes reset-database.bat/.ps1/.sh. Run one only when you intend to erase the database.
