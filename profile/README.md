<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/OmniTrustILM/ilm/main/logo/ot-white.svg">
  <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/OmniTrustILM/ilm/main/logo/ot-color.svg">
  <img alt="ILM — Identity Lifecycle Management" src="https://raw.githubusercontent.com/OmniTrustILM/ilm/main/logo/ot-color.svg" width="400">
</picture>

## Identity Lifecycle Management

ILM is an open-source platform for managing the full lifecycle of digital identities — certificates, cryptographic keys, secrets, and digital signatures. Built as a microservices architecture with an extensible connector framework, it integrates with existing PKI infrastructure, certificate authorities, and key management systems.

Released under the [MIT License](https://github.com/OmniTrustILM/ilm/blob/main/LICENSE.md) with additional features available under subscription plans.

### Key Capabilities

- **Certificate Management** — issue, renew, and revoke certificates through RA Profiles and standard protocols
- **Cryptographic Key Management** — generate, store, and manage keys through Token Profiles
- **Secrets Management** — passwords, API keys, JWT tokens, and keystores through Vault Profiles with versioning and approval workflows
- **CBOM Scanning** — scan filesystems, containers, and network ports for cryptographic assets and generate CycloneDX CBOMs
- **Discovery** — find certificates across networks, CT logs, and third-party systems
- **Compliance** — evaluate and enforce certificate policies across your inventory

### Key Repositories

| Repository                                                           | Description                                                   |
|----------------------------------------------------------------------|---------------------------------------------------------------|
| [ilm](https://github.com/OmniTrustILM/ilm)                           | Platform overview, full repository catalog, and architecture  |
| [core](https://github.com/OmniTrustILM/core)                         | Core service managing certificate lifecycle operations        |
| [fe-administrator](https://github.com/OmniTrustILM/fe-administrator) | Administrator web interface                                   |
| [helm-charts](https://github.com/OmniTrustILM/helm-charts)           | Helm charts for Kubernetes deployment                         |
| [cbom-lens](https://github.com/OmniTrustILM/cbom-lens)               | CLI tool for cryptographic asset scanning and CBOM generation |
| [interfaces](https://github.com/OmniTrustILM/interfaces)             | API definitions for building connectors and integrations      |

See the [full repository catalog](https://github.com/OmniTrustILM/ilm#repositories) for all platform components, connectors, and integrations.

### Contributing

We welcome contributions from everyone. To get started:

- Read the [Contributing Guide](https://github.com/OmniTrustILM/.github/blob/main/CONTRIBUTING.md) for workflow, commit conventions, and issue guidelines
- Set up your local environment with the [Development Environment](https://github.com/OmniTrustILM/development-environment) repository
- Look for issues labeled [`good first issue`](https://github.com/search?q=org%3AOmniTrustILM+label%3A%22good+first+issue%22+is%3Aopen&type=issues) to find a good starting point

### Resources & Community

- [Documentation](https://docs.otilm.com) — guides, API reference, and deployment instructions
- [Discussions](https://github.com/orgs/OmniTrustILM/discussions) — ask questions, propose ideas, or discuss the platform
- [Discord](https://discord.gg/XYsSZKjSt4) — chat with the community and the team
- [OmniTrust](https://www.omnitrust.com) — company website and subscription plans
- [Contact](mailto:ilm@omnitrust.com) — reach us directly

### License

ILM is released under the [MIT License](https://github.com/OmniTrustILM/ilm/blob/main/LICENSE.md).
