# MaaS Platform Provisioning using Gitops and ACM automation

> **Work in progress.**

## Design

[osac-gitops-acm-design.md](osac-gitops-acm-design.md)

## Reference Implementation

[install.md](install.md)

## Models and governance

The `site-a` and `site-b` implementation of models and governance is only to prove out the provisioning.

## Topology of Reference implementation

```mermaid
flowchart TB
    git["Git repository"]

    subgraph hub["Hub cluster, site-a"]
        argo["Argo CD<br/>Reads Git, pushes intent"]
        acm["ACM<br/>Distributes platform policies"]
        hubgw["MaaS gateway<br/>CPU model: facebook-opt"]
        kc["Keycloak<br/>Identity for both sites"]
    end

    subgraph spoke["Spoke cluster, site-b"]
        intent["Models and governance<br/>Granite on NVIDIA A10G"]
        agent["ACM agent<br/>Enforces policies locally"]
        spokegw["MaaS gateway<br/>Serves the GPU model"]
    end

    git --> argo
    argo --> intent
    acm --> agent
    hubgw <-->|Cross-site model calls| spokegw
```
