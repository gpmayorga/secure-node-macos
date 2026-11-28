# Security policy

## Reporting a vulnerability

Please do not open a public issue for security problems.

Report them privately through GitHub: go to the **Security** tab of this
repository and click **Report a vulnerability**. Include the shim command you
ran, what you expected, and what happened.

Reports about the container isolation (a way for code running in the Node
container to reach the host, read host credentials, or escape the project
mount) are especially welcome.

## Supported versions

Only the latest commit on `main` is supported.
